import SwiftUI

/// Startseite: genau ein Vorschlag. Wischen statt Scrollen.
struct ForYouView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing: PlaybackRequest?
    @Namespace private var zoom
    @State private var trigger: SwipeDirection?
    /// Details öffnen sich als Morph über der ganzen App (siehe `HeroOverlay`).
    @Environment(HeroCoordinator.self) private var hero
    @State private var addingProfile = false
    @State private var managingProfiles = false
    @State private var toast: Toast?
    @State private var undoBounce = 0
    /// Feste Warteschlange: Was hinten im Stapel liegt, bleibt dort. Nach jedem Swipe
    /// wird nur hinten aufgefüllt, sonst würden Karten (und Hintergrund) durch das
    /// Nachlernen plötzlich ausgetauscht.
    @State private var queue: [Recommendation] = []
    @State private var swiped: [Recommendation] = []
    /// Wohin jede Karte gewischt wurde, damit sie bei „Rückgängig“ von dort zurückfliegt.
    @State private var swipeDirections: [Recommendation.ID: SwipeDirection] = [:]
    @State private var returning: (id: Recommendation.ID, from: SwipeDirection)?
    /// Geschmack hat sich geändert, während „Für dich“ nicht zu sehen war: beim Zurückkommen neu sortieren.
    @State private var visible = false
    @State private var stale = false
    /// Die Änderung kam von hier (Swipe, Rückgängig): Die oberste Karte bleibt liegen.
    @State private var ownChange = false
    @State private var viewerRebuild: Task<Void, Never>?
    /// Gewischt, aber noch nicht gelernt (läuft, sobald die Karte weggeflogen ist).
    @State private var pendingWork: [(id: UUID, work: () -> Void)] = []

    struct Toast: Equatable {
        var text: String
        var symbol: String
        var color: Color
    }

    private let options: [SwipeDirection: SwipeOption] = [
        .left: .init(title: SwipeAction.notToday.title, symbol: SwipeAction.notToday.symbol, color: SwipeAction.notToday.color),
        .right: .init(title: SwipeAction.watchlist.title, symbol: SwipeAction.watchlist.symbol, color: SwipeAction.watchlist.color),
        .down: .init(title: SwipeAction.alreadySeen.title, symbol: SwipeAction.alreadySeen.symbol, color: SwipeAction.alreadySeen.color),
        .up: .init(title: SwipeAction.details.title, symbol: SwipeAction.details.symbol, color: SwipeAction.details.color, flyOut: false)
    ]

    var body: some View {
        let recs = queue.filter { store.allowsForViewers($0.film) }
        GeometryReader { geometry in
            let expanded = sizeClass == .regular && geometry.size.width >= 760 && geometry.size.height >= 500 && !typeSize.isAccessibilitySize
            VStack(spacing: expanded ? 24 : 14) {
                header
                if let pending = store.visiblePendingRatings.last, let film = FilmIndex.film(pending.filmID) {
                    ratingBanner(pending, film)
                } else if let id = store.watchlistQuestion, let film = FilmIndex.film(id), store.allowsForViewers(film) {
                    watchlistBanner(film)
                }
                if recs.isEmpty {
                    emptyState
                } else if expanded, let rec = recs.first {
                    tabletLayout(recs, rec)
                } else {
                    deck(recs)
                        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
                    if store.homeSwipeCount < 3 {
                        SwipeLegend(options: options)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    controls(recs.first!.film)
                }
            }
            .padding(.horizontal, expanded ? 36 : 18)
            .padding(.bottom, expanded ? 24 : 6)
            // Die Banner oben kommen aus dem Lernen nach dem Wischen, ohne eigene Animation.
            // Hier gleiten sie herein und die Karte rückt weich nach unten.
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.pendingRatings.last?.filmID)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: store.watchlistQuestion)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background { BlurredBackdrop(film: recs.first?.film) }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast.text, systemImage: toast.symbol)
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white, toast.color)
                    .symbolEffect(.bounce, value: toast)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .glassEffect()
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .padding(.top, 54)
            }
        }
        .filmPlayer($playing, in: zoom)
        .fullScreenCover(isPresented: $managingProfiles) {
            NavigationStack { ManageProfilesView() }
        }
        .fullScreenCover(isPresented: $addingProfile) {
            OnboardingFlow(mode: .addProfile, cancel: { addingProfile = false }) { id in
                if !store.activeProfileIDs.contains(id) { store.activeProfileIDs.append(id) }
                store.save()
                addingProfile = false
            }
        }
        .onAppear {
            visible = true
            if queue.isEmpty || stale { stale = false; rebuildQueue(animated: !queue.isEmpty) }
        }
        .onDisappear { visible = false }
        // Geht die App weg, sofort lernen und schreiben: Wer direkt nach dem Wischen schließt,
        // verliert sonst den letzten Swipe, der noch auf das Ende des Flugs wartet.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, !pendingWork.isEmpty else { return }
            runPendingWork()
            store.flush()
        }
        .onChange(of: store.tasteRevision) { _, _ in tasteChanged() }
        // Mehrere Profile hintereinander antippen: erst neu sortieren, wenn die Auswahl kurz steht.
        .onChange(of: store.activeProfileIDs) { _, _ in
            viewerRebuild?.cancel()
            viewerRebuild = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                rebuildQueue(animated: true)
            }
        }
        .onChange(of: store.runtimeFilter) { _, _ in rebuildQueue(animated: true) }
        .onChange(of: store.kindFilter) { _, _ in rebuildQueue(animated: true) }
        .onChange(of: store.pendingRatings.count) { _, _ in prune() }
        // Sobald ein Poster da ist, auch seinen Hintergrund vorbereiten.
        // Das Video der obersten Karte schon auflösen, damit „Abspielen“ ohne Warten startet.
        .onChange(of: queue.map(\.id), initial: true) { _, _ in
            BackdropBlur.warmUp(queue.prefix(4).map(\.film.id))
            if store.signedIn, let top = queue.first?.film { TrailerLoader.prefetch(top.youtubeID) }
        }
        .task {
            if queue.isEmpty { rebuildQueue() }
            switch DemoScreen.current {
            case "detail": if let f = UserDefaults.standard.string(forKey: "detailID").flatMap(FilmIndex.film) ?? recs.first?.film { hero.show(f, from: "foryou") }
            case "player": if let f = recs.first?.film { playing = PlaybackRequest(film: f, episode: store.upNext(f), countsAsWatched: true, sourceID: f.id) }
            case "rating": store.ratingToPresent = store.pendingRatings.last
            default: break
            }
        }
    }

    // MARK: iPad

    /// Breite Fenster: Die Karte bleibt so groß wie möglich, daneben steht, warum sie passt,
    /// und was danach kommt. Querformat: alles in zwei Spalten. Hochformat: unten „Als Nächstes“
    /// über die ganze Breite, damit unter der Karte kein leerer Streifen bleibt.
    private func tabletLayout(_ recs: [Recommendation], _ rec: Recommendation) -> some View {
        GeometryReader { area in
            let landscape = area.size.width > area.size.height
            let bottom: CGFloat = landscape ? 0 : 300
            let cardHeight = min(area.size.height - bottom, area.size.width * (landscape ? 0.5 : 0.56) * 1.5)
            let cardWidth = cardHeight * 2 / 3
            let next = Array(recs.dropFirst().prefix(3))
            if landscape {
                HStack(alignment: .top, spacing: 40) {
                    deck(recs, showsReason: false).frame(width: cardWidth, height: cardHeight)
                    VStack(alignment: .leading, spacing: 20) {
                        tabletInformation(rec, large: true)
                        Spacer(minLength: 0)
                        if !next.isEmpty { upNext(next, posterHeight: min(150, area.size.height * 0.2)) }
                        SwipeLegend(options: options)
                        controls(rec.film)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 28) {
                        deck(recs, showsReason: false).frame(width: cardWidth, height: cardHeight)
                        tabletInformation(rec, large: false)
                            .frame(maxWidth: .infinity, maxHeight: cardHeight, alignment: .topLeading)
                    }
                    if !next.isEmpty { upNext(next, posterHeight: 170) }
                    Spacer(minLength: 0)
                    HStack(spacing: 20) {
                        SwipeLegend(options: options)
                        controls(rec.film).frame(maxWidth: 360)
                    }
                }
            }
        }
    }

    /// Worum es geht und warum er passt. Der Grund steht groß, er ist das Versprechen der App.
    private func tabletInformation(_ rec: Recommendation, large: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let note = rec.watchlistNote {
                    Label(note, systemImage: "bookmark.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SwipeAction.watchlist.color)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(rec.film.isSeries ? "Warum diese Serie?" : "Warum dieser Film?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.match(rec.match))
                    Text(rec.reason)
                        .font(.system(large ? .title : .title3, design: .rounded).weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(rec.film.synopsis)
                    .font(large ? .body : .callout).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                CriticScores(film: rec.film)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rec.film.genres.joined(separator: " · ") + " · FSK \(rec.film.fsk)")
                    Text("Regie \(rec.film.director) · mit \(rec.film.cast.prefix(3).formatted(.list(type: .and)))")
                }
                .font(.footnote).foregroundStyle(.secondary)
                Button("Alle Details", systemImage: "info.circle") { hero.show(rec.film, from: "foryou") }
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .id(rec.id)
        .transition(.opacity)
    }

    /// Die nächsten Karten im Stapel, mit ihrem Grund. Antippen öffnet die Details.
    private func upNext(_ next: [Recommendation], posterHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Als Nächstes").font(.headline)
            HStack(alignment: .top, spacing: 16) {
                ForEach(next) { rec in
                    Button { hero.show(rec.film, from: "upnext") } label: {
                        HStack(alignment: .top, spacing: 10) {
                            PosterView(film: rec.film, cornerRadius: 10)
                                .frame(width: posterHeight * 2 / 3, height: posterHeight)
                                .heroSource(rec.film, in: "upnext", cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rec.film.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("\(rec.match) % Match").font(.caption.weight(.bold)).foregroundStyle(Color.match(rec.match))
                                Text(rec.reason).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Kopfzeile

    /// Bewusst leise: Avatar, eine Zeile Text, zwei kleine Symbole. Der Film ist der Star.
    private var header: some View {
        HStack(spacing: 12) {
            ProfileMenu(onCreate: { addingProfile = true }, onManage: { managingProfiles = true }) {
                AvatarStack(profiles: store.activeProfiles, size: 34)
                    .padding(4)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel("Wer schaut?")

            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text((["für heute"] + (store.kindFilter == .all ? [] : [store.kindFilter.title])
                      + (store.runtimeFilter.map { [$0.label] } ?? [])).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .contentTransition(.interpolate)

            Spacer()

            Button {
                if pendingWork.isEmpty, let id = store.undoPlayedFilm, let film = FilmIndex.film(id) {
                    // Zuletzt wurde ein Film fertig geschaut: Er kommt wieder nach vorn, die offene Bewertung verschwindet.
                    ownChange = true
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                        store.undo()
                        queue.removeAll { $0.film.id == id }
                        queue.insert(store.recommendation(for: film), at: 0)
                    }
                } else if let last = swiped.popLast() {
                    // Erst die Karte zurückfliegen lassen. Lernen, Speichern und Sync folgen im nächsten Moment,
                    // sonst kosten sie das erste Bild der Animation.
                    returning = (last.id, swipeDirections[last.id] ?? .left)
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                        queue.removeAll { $0.id == last.id }
                        queue.insert(last, at: 0)
                    }
                    Task { @MainActor in
                        runPendingWork()
                        ownChange = true
                        store.undo()
                        try? await Task.sleep(for: .milliseconds(700))
                        if returning?.id == last.id { returning = nil }
                    }
                } else {
                    runPendingWork()
                    ownChange = true
                    withAnimation(.snappy) { store.undo() }
                }
                undoBounce += 1
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.headline)
                    .symbolEffect(.rotate.counterClockwise, value: undoBounce)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .foregroundStyle(.white)
            // Keep navigation in a fixed place; unavailable undo is disabled, never hidden.
            .disabled(!store.canUndo)
            .accessibilityLabel("Rückgängig")
            .accessibilityHint(store.canUndo ? "Macht den letzten Film-Swipe rückgängig" : "Noch kein Film-Swipe zum Rückgängigmachen")

            RuntimeMenu {
                let active = store.runtimeFilter != nil || store.kindFilter != .all
                Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.headline)
                    .foregroundStyle(active ? store.accent : Color.primary)
                    .frame(width: 42, height: 42)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Film oder Serie, Zeit")
        }
        .padding(.top, 4)
    }

    /// „Dein Film“ / „Deine Serie“, je nachdem, was oben liegt.
    private var headline: String {
        let together = store.activeProfiles.count > 1
        let series = queue.first?.film.isSeries ?? (store.kindFilter == .series)
        switch (together, series) {
        case (false, false): return "Dein Film"
        case (false, true): return "Deine Serie"
        case (true, false): return "Euer Film"
        case (true, true): return "Eure Serie"
        }
    }

    // MARK: Karten

    private func deck(_ recs: [Recommendation], showsReason: Bool = true) -> some View {
        // Kartenbreite aus der verfügbaren Höhe ableiten, damit das Poster ohne Ränder sitzt.
        GeometryReader { geo in
            let width = min(geo.size.width, (geo.size.height - RecommendationCard.infoHeight) * 2 / 3)
            SwipeDeck(items: recs, options: options, trigger: $trigger,
                      onCommit: { rec, direction in handle(direction, rec.film) },
                      onTap: { hero.show($0.film, from: "foryou") },
                      returning: returning) { rec, isTop in
                RecommendationCard(rec: rec, compact: !isTop, width: width, viewers: store.activeProfileIDs.count,
                                   heroScope: "foryou", showsReason: showsReason)
                    // Form explizit setzen, sonst zeigt die Quelle vor der ersten Zoom-Animation
                    // ein eckiges Rechteck hinter den runden Ecken.
                    .matchedTransitionSource(id: rec.film.id, in: zoom) { $0.clipShape(.rect(cornerRadius: 28)).background(.clear) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
    }

    /// Nur eine Handlung: abspielen. Alles andere geht per Wischen.
    private func controls(_ film: Film) -> some View {
        Button {
            playing = PlaybackRequest(film: film, episode: store.upNext(film), countsAsWatched: true, sourceID: film.id)
        } label: {
            PlayButtonLabel(title: store.playLabel(film), progress: store.resumeShare(film))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(store.accent)
        // Fliegt nicht mit: blendet aus, wenn die Details aufgehen, und wieder ein, wenn sie zugehen.
        .opacity(hero.isShowingDetails(film.id, in: "foryou") ? 0 : 1)
        // Lang und weich, damit er mit dem Knopf der Detailseite überblendet statt hart wegzuspringen.
        .animation(.easeInOut(duration: 0.45), value: hero.isShowingDetails(film.id, in: "foryou"))
    }

    /// Jede Änderung am Geschmack (Swipe, Chat, Kalibrieren, Bewertung) wirkt sofort.
    /// Eigene Swipes lassen die oberste Karte liegen und sortieren nur dahinter neu,
    /// alles andere (z. B. der KI-Chat) baut den Stapel ganz neu auf.
    private func tasteChanged() {
        guard visible else { stale = true; return }
        if ownChange, let top = queue.first {
            ownChange = false
            let fresh = store.recommendations(limit: 6).filter { $0.id != top.id }
            PosterCache.warmUp(fresh.prefix(3).map(\.film.id)); BackdropBlur.warmUp(fresh.prefix(3).map(\.film.id))
            withAnimation(.smooth(duration: 0.4)) { queue = [top] + fresh.prefix(3) }
        } else {
            ownChange = false
            rebuildQueue(animated: true)
        }
    }

    private func rebuildQueue(animated: Bool = false) {
        let fresh = store.recommendations(limit: 4)
        PosterCache.warmUp(fresh.map(\.film.id)); BackdropBlur.warmUp(fresh.prefix(4).map(\.film.id))
        if animated { withAnimation(.smooth(duration: 0.4)) { queue = fresh } } else { queue = fresh }
        swiped = []
    }

    /// Filme entfernen, die nicht mehr in Frage kommen (z. B. gerade abgespielt), und auffüllen.
    private func prune() {
        let eligible = Set(RecommendationEngine.candidates(profiles: store.activeProfiles, runtime: store.runtimeFilter,
                                                           kind: store.kindFilter, skipped: store.skippedToday).map(\.id))
        withAnimation(.smooth(duration: 0.4)) {
            queue.removeAll { !eligible.contains($0.id) }
            let known = Set(queue.map(\.id))
            for next in store.recommendations(limit: 10) where queue.count < 4 && !known.contains(next.id) {
                queue.append(next)
            }
        }
    }

    /// Oberste Karte entfernen und hinten mit frischen Vorschlägen auffüllen.
    private func advance(past rec: Recommendation) {
        queue.removeAll { $0.id == rec.id }
        swiped.append(rec)
        if swiped.count > 20 { swiped.removeFirst() }
        // Hinten auffüllen erst nach dem Abflug, die nächsten drei Karten liegen ja schon bereit.
        Task {
            // Erst wenn die nachgerückte Karte ausgefedert ist, sonst schneidet das Auffüllen die Animation ab.
            try? await Task.sleep(for: .milliseconds(750))
            guard queue.count < 4 else { return }
            let known = Set(queue.map(\.id)).union(swiped.map(\.id))
            for next in store.recommendations(limit: 10) where queue.count < 4 && !known.contains(next.id) {
                queue.append(next)
            }
            PosterCache.warmUp(queue.map(\.film.id)); BackdropBlur.warmUp(queue.map(\.film.id))
        }
    }

    private func handle(_ direction: SwipeDirection, _ film: Film) {
        let rec = direction == .up ? nil : queue.first(where: { $0.film.id == film.id })
        defer { if let rec { swipeDirections[rec.id] = direction; advance(past: rec) } }
        if rec != nil { store.homeSwipeCount += 1 }
        switch direction {
        case .up:
            hero.show(film, from: "foryou")
        case .left:
            afterFlight { store.apply(.notToday, to: film) }
        case .right:
            afterFlight { store.apply(.watchlist, to: film) }
            show(rec?.watchlistNote == nil ? "Auf der Merkliste" : "Bleibt auf der Liste, nur heute nicht", "bookmark.circle.fill", SwipeAction.watchlist.color)
        case .down:
            afterFlight { store.apply(.alreadySeen, to: film) }
        }
    }

    /// Lernen und Neusortieren erst, wenn die Karte weg ist: Während sie fliegt,
    /// bekommt die Animation die volle Rechenzeit.
    private func afterFlight(_ work: @escaping () -> Void) {
        let id = UUID()
        pendingWork.append((id, work))
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard let i = pendingWork.firstIndex(where: { $0.id == id }) else { return }
            // Erst hier als eigene Änderung markieren: Sonst baut ein später verarbeiteter Swipe
            // den ganzen Stapel neu auf, z. B. während gerade die Details der obersten Karte aufgehen.
            ownChange = true
            pendingWork.remove(at: i).work()
        }
    }

    /// Noch ausstehendes Lernen sofort erledigen (z. B. vor „Rückgängig“).
    private func runPendingWork() {
        let work = pendingWork
        pendingWork = []
        work.forEach { $0.work() }
    }

    private func show(_ text: String, _ symbol: String, _ color: Color) {
        let t = Toast(text: text, symbol: symbol, color: color)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.smooth) { if toast == t { toast = nil } }
        }
    }

    // MARK: Bewertung & Leerzustand

    private func ratingBanner(_ pending: PendingRating, _ film: Film) -> some View {
        Button { store.ratingToPresent = pending } label: {
            HStack(spacing: 12) {
                PosterView(film: film, cornerRadius: 6).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Calendar.current.isDateInToday(pending.date) ? "Gerade geschaut" : "Gestern geschaut")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Wie war „\(film.title)“?").font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "star.bubble.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 2.5)))
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Ecken wie beim Cover.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Dreimal von der Watchlist übersprungen: kurz nachfragen, statt die Liste weiter wachsen zu lassen.
    private func watchlistBanner(_ film: Film) -> some View {
        HStack(spacing: 12) {
            PosterView(film: film, cornerRadius: 6).frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dreimal übersprungen").font(.caption).foregroundStyle(.secondary)
                Text("Noch Lust auf „\(film.title)“?").font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Loslassen") {
                withAnimation(.snappy) { store.letGo(film) }
                show("Von der Liste genommen", "bookmark.slash.fill", .secondary)
            }
            .buttonStyle(.glass)
            Button("Behalten") { withAnimation(.snappy) { store.keepOnWatchlist(film) } }
                .buttonStyle(.glassProminent)
                .tint(SwipeAction.watchlist.color)
        }
        .font(.subheadline.weight(.semibold))
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Für heute alles gesehen", systemImage: "popcorn.fill")
                .symbolEffect(.bounce, options: .repeat(.periodic(delay: 2)))
        } description: {
            Text("Lockere die Filter, probier die Suche, oder hol die übersprungenen Titel zurück.")
        } actions: {
            Button("Übersprungene zurückholen") {
                withAnimation { store.skippedToday = []; store.runtimeFilter = nil; store.kindFilter = .all }
            }
            .buttonStyle(.glass)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Die große Vorschlagskarte: Das Poster füllt die Karte, unten liegt in einem dunklen Verlauf
/// alles, was neugierig macht: Match, großer Titel, ein Satz über den Film und warum er passt.
struct RecommendationCard: View {
    let rec: Recommendation
    var compact = false
    var width: CGFloat? = nil
    /// Wie viele zusammen schauen: Der Match gilt dann für alle gemeinsam.
    var viewers = 1
    /// Bereich für den Morph zu den Details. Cover und Titel fliegen dann als eigene Ebene,
    /// Match und Einzeiler blenden aus, solange die Details offen sind.
    var heroScope: String? = nil
    /// Nur für die fliegende Ebene: gesetzt heißt „ich bin die Karte im Flug“, `true` = schon bei den Details.
    var ghostOpen: Bool? = nil
    /// Nur für die fliegende Ebene: Höhe des Verlaufs und des oberen Schattens der Detailseite (in Kartenpunkten).
    /// Die Detailseite nimmt den Verlauf der Karte maßstäblich mit, darum wird er im Flug nur größer.
    var ghostShade: CGFloat? = nil
    var cornerRadius: CGFloat = 28
    /// Auf dem iPad steht der Grund groß neben der Karte, dort nicht doppelt.
    var showsReason = true
    @Environment(HeroCoordinator.self) private var hero
    private var lifted: Bool { heroScope.map { hero.isLifted(rec.film.id, in: $0) } ?? false }
    private var detailsUp: Bool { heroScope.map { hero.isShowingDetails(rec.film.id, in: $0) } ?? false }
    @State private var shownMatch = 0

    static let titleFont = Theme.recommendationTitle(size: 36)
    /// Setzt ohne Kante ein und läuft ohne Knick ins Schwarz: viele Stufen auf einer weichen Kurve.
    static let shade = tintedShade(.black)
    /// Derselbe Verlauf in einer anderen Farbe: Die Detailseite läuft in die Farbe ihres Posters aus.
    static func tintedShade(_ color: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: color.opacity(0), location: 0),
                               .init(color: color.opacity(0.012), location: 0.1),
                               .init(color: color.opacity(0.045), location: 0.2),
                               .init(color: color.opacity(0.1), location: 0.3),
                               .init(color: color.opacity(0.18), location: 0.4),
                               .init(color: color.opacity(0.29), location: 0.5),
                               .init(color: color.opacity(0.43), location: 0.6),
                               .init(color: color.opacity(0.6), location: 0.7),
                               .init(color: color.opacity(0.78), location: 0.8),
                               .init(color: color.opacity(0.93), location: 0.9),
                               .init(color: color, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
    /// Auf der Detailseite ist das Cover groß, der Verlauf reicht dort entsprechend weiter hinauf.
    static let detailShadeStretch: CGFloat = 2.2
    /// Der Verlauf reicht über den Text hinaus nach oben, so setzt er unmerklich ein.
    static let shadeLead: CGFloat = 80

    /// Alles liegt auf dem Poster, unter der Karte braucht es keinen Platz mehr.
    static let infoHeight: CGFloat = 0

    var body: some View {
        let atDetails = ghostOpen ?? false
        PosterView(film: rec.film, cornerRadius: 0, badgesHidden: atDetails)
            // Im Flug zum Detail-Cover bleibt der Verlauf stehen (kein Hell-Dunkel-Flackern),
            // nur Match, Titel und Einzeiler lösen sich weich auf, während die Detailseite ihre einblendet.
            .overlay(alignment: .bottom) {
                if let ghostShade {
                    // Auf der Karte schwarz, auf der Detailseite in der Farbe des Posters: Beide Töne blenden im Flug ineinander.
                    ZStack {
                        Self.shade.opacity(atDetails ? 0 : 1)
                        Self.tintedShade(PosterTint.color(rec.film.id) ?? .black).opacity(atDetails ? 1 : 0)
                    }
                    .frame(maxHeight: ghostShade * (atDetails ? Self.detailShadeStretch : 1))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                cover
                    // Nur Cover, Titel und Knöpfe morphen. Der übrige Text blendet gleich am Anfang aus,
                    // statt mit dem Cover mitzufliegen, und kommt beim Schließen genauso schnell gleich zu Beginn des Rückflugs zurück.
                    .animation(atDetails ? .easeOut(duration: 0.12) : .easeOut(duration: 0.12).delay(0.06)) {
                        $0.opacity(atDetails ? 0 : 1)
                    }
            }
            .overlay(alignment: .topTrailing) {
                // Kleines Badge statt eigener Funktion: Die Liste soll geguckt werden, nicht wachsen.
                if let note = rec.watchlistNote {
                    Label(note.contains(", ") ? "Gemerkt " + note.components(separatedBy: ", ").last! : "Gemerkt",
                          systemImage: "bookmark.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white, SwipeAction.watchlist.color)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: .capsule)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .padding(12)
                        // Fliegt mit und blendet im selben Takt wie die Texte.
                        .animation(atDetails ? .easeOut(duration: 0.12) : .easeOut(duration: 0.12).delay(0.06)) {
                            $0.opacity(atDetails ? 0 : 1)
                        }
                }
            }
            .frame(width: width)
            .background(Color(white: 0.1))
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.white.opacity(atDetails ? 0 : 0.08)))
            // Während die Karte fliegt, bleibt hier nur ihr Schatten als Platzhalter.
            .opacity(lifted ? 0 : 1)
            .modifier(OptionalHeroSource(rec: rec, scope: heroScope))
            .animation(.smooth(duration: 0.3), value: compact)
            .background {
                if ghostOpen == nil {
                    // Schatten der Karte; solange sie fliegt, trägt die fliegende Ebene ihn. Die Fläche bleibt
                    // als Platzhalter und deckt die nächste Karte ab, bis die Detailseite darüber liegt.
                    RoundedRectangle(cornerRadius: 28).fill(.black)
                        .shadow(color: .black.opacity(lifted ? 0 : 0.5), radius: 24, y: 12)
                        // Erst weg, wenn die Detailseite ganz steht. Sonst scheint im Flug die nächste Karte durch.
                        .opacity(detailsUp && hero.ghost == nil ? 0 : 1)
                }
            }
            .task(id: "\(rec.id)-\(rec.match)-\(viewers)") {
                // Hinten liegende Karten zeigen den Wert gleich; nur die erste zählt sichtbar hoch.
                guard !compact, ghostOpen == nil else { shownMatch = rec.match; return }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.smooth(duration: 0.9)) { shownMatch = rec.match }
            }
    }

    /// Der Titel fliegt als eigene Ebene an seinen Platz auf der Detailseite (`HeroOverlay`),
    /// darum gibt es ihn einmal zum Zeichnen hier und gemessen an der echten Karte.
    static func title(_ film: Film) -> some View {
        Text(film.title)
            .font(titleFont)
            .foregroundStyle(.white)
            .lineLimit(2).minimumScaleFactor(0.6)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func matchBadge(_ value: Int, color match: Int) -> some View {
        Text("\(value)")
            .font(.subheadline.weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 8).frame(minWidth: 34, minHeight: 24)
            .background(Color.match(match), in: .capsule)
    }

    static func hook(_ film: Film) -> some View {
        RedactedText(film.hook)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func reason(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func meta(_ film: Film) -> some View {
        Text(film.isSeries ? "\(film.yearText) · \(film.seasonsText)" : "\(String(film.year)) · \(film.runtimeText)")
            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
    }

    private func measure(_ change: (inout HeroCoordinator.CardText) -> Void) {
        guard let heroScope, ghostOpen == nil else { return }
        let key = HeroCoordinator.key(rec.film.id, heroScope)
        var t = hero.cardTexts[key] ?? .init()
        change(&t)
        hero.cardTexts[key] = t
    }

    /// Die fliegende Karte zeigt den Wert gleich, sie soll nicht noch einmal hochzählen.
    private var displayedMatch: Int { ghostOpen == nil ? shownMatch : rec.match }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if rec.film.comingSoon {
                    Label(rec.film.releaseNote ?? "Demnächst", systemImage: "calendar")
                        .font(.subheadline.weight(.heavy))
                } else {
                    // Nur die Zahl als Badge, die Farbe sagt, wie gut er passt.
                    Self.matchBadge(displayedMatch, color: rec.match)
                        .contentTransition(.numericText(value: Double(displayedMatch)))
                        .accessibilityLabel(viewers > 1 ? "\(rec.match) Prozent Match für euch \(viewers == 2 ? "beide" : "alle")" : "\(rec.match) Prozent Match")
                }
                Self.meta(rec.film)
            }
            .lineLimit(1)

            Self.title(rec.film)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                    measure { $0.parts[.title] = f }
                }
                .opacity(ghostOpen == nil ? 1 : 0)

            // Ein Satz, der neugierig macht. Die längere Beschreibung steht in den Details.
            // Ein Satz, der neugierig macht. Die längere Beschreibung steht in den Details.
            Self.hook(rec.film)

            // Darunter leise, warum er zu dir passt. Auf dem iPad steht der Grund groß daneben.
            if showsReason && !rec.reason.isEmpty && !rec.film.comingSoon {
                Self.reason(rec.reason)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 90)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in measure { $0.shade = h + Self.shadeLead } }
        .background {
            // Verlauf statt Kasten: Das Poster bleibt sichtbar, der Text trotzdem lesbar.
            // Die fliegende Karte zeichnet ihn getrennt, damit er beim Auflösen des Textes stehen bleibt.
            if ghostOpen == nil { Self.shade.padding(.top, -Self.shadeLead) }
        }
    }
}

// MARK: - Zeitfilter

/// Film oder Serie und „Wie viel Zeit hast du?“ als natives Menü, wächst wie das Profilmenü aus dem Button.
/// Darunter Mindest- und Höchstdauer, je „Egal“ oder eine von drei Dauern.
/// Das Menü bleibt beim Einstellen offen, der Stapel dahinter sortiert sich live um.
struct RuntimeMenu<MenuLabel: View>: View {
    @Environment(AppStore.self) private var store
    @ViewBuilder var label: () -> MenuLabel


    var body: some View {
        Menu {
            Section {
                Picker("Was möchtest du schauen?", selection: Binding(
                    get: { store.kindFilter },
                    set: { v in withAnimation(.snappy) { store.kindFilter = v } })) {
                    ForEach(KindFilter.allCases) { k in Text(k.title).tag(k) }
                }
                .pickerStyle(.palette)
                .menuActionDismissBehavior(.disabled)
            }
            Section(timeTitle) {
                bound("Mindestens", options: [60, 90, 120], value: store.runtimeFilter?.min, isMin: true)
                bound("Höchstens", options: [90, 120, 180], value: store.runtimeFilter?.max, isMin: false)
            }
            if store.runtimeFilter != nil || store.kindFilter != .all {
                Section {
                    Button("Filter zurücksetzen", systemImage: "arrow.counterclockwise") {
                        withAnimation(.snappy) { store.runtimeFilter = nil; store.kindFilter = .all }
                    }
                }
            }
        } label: {
            label()
        }
        .sensoryFeedback(.selection, trigger: store.runtimeFilter)
        .sensoryFeedback(.selection, trigger: store.kindFilter)
        .accessibilityLabel("Film oder Serie, Zeit")
    }

    /// Überschrift der Zeit: die Frage, oder die aktuelle Wahl mit Trefferzahl.
    private var timeTitle: String {
        guard let filter = store.runtimeFilter else {
            return store.kindFilter == .series ? "Wie lang darf eine Folge sein?" : "Wie viel Zeit hast du?"
        }
        return "\(filter.label) · \(matching) Titel"
    }

    private var matching: Int {
        RecommendationEngine.candidates(profiles: store.activeProfiles, runtime: store.runtimeFilter,
                                        kind: store.kindFilter, skipped: store.skippedToday).count
    }

    /// Eine Zeile je Grenze: Egal oder eine von drei Dauern.
    private func bound(_ title: String, options: [Int], value: Int?, isMin: Bool) -> some View {
        Picker(title, selection: Binding(get: { value ?? 0 }, set: { change(isMin, $0 == 0 ? nil : $0) })) {
            Text("Egal").tag(0)
            ForEach(options, id: \.self) { Text(RuntimeFilter.short($0)).tag($0) }
        }
        .pickerStyle(.palette)
        .menuActionDismissBehavior(.disabled)
    }

    /// Die andere Grenze rückt mit, damit der Bereich nie leer wird.
    private func change(_ isMin: Bool, _ value: Int?) {
        var filter = store.runtimeFilter ?? RuntimeFilter()
        if isMin {
            filter.min = value
            if let value, let hi = filter.max, hi < value { filter.max = value }
        } else {
            filter.max = value
            if let value, let lo = filter.min, lo > value { filter.min = value }
        }
        set(filter.min == nil && filter.max == nil ? nil : filter)
    }

    private func set(_ filter: RuntimeFilter?) {
        withAnimation(.snappy) { store.runtimeFilter = filter }
    }
}

// MARK: - Details als Morph

/// Das Cover fliegt von seinem Platz (Karte, Merkliste, Katalog, Suche) an seinen Platz auf der
/// Detailseite und zurück. Die Detailseite liegt über der ganzen App (auch über der Tab-Leiste),
/// deshalb bleibt das Layout dahinter unverändert und Start- und Zielpunkt stimmen exakt.
/// Beide Punkte werden in Bildschirmkoordinaten gemessen, das fliegende Cover ist eine eigene Ebene.
@Observable @MainActor
final class HeroCoordinator {
    /// Woher ein Cover losfliegt: Rahmen, Ecken und ob es eine Vorschlagskarte ist
    /// (dann fliegen Verlauf und Titel mit).
    struct Source {
        var frame: CGRect
        var radius: CGFloat
        var rec: Recommendation?
        var card: Bool { rec != nil }
    }

    private(set) var film: Film?
    /// Bereich, aus dem die Details geöffnet wurden. Derselbe Film kann an mehreren Stellen stehen.
    private(set) var scope: String?
    private(set) var open = false
    /// Das fliegende Cover, solange es unterwegs ist.
    private(set) var ghost: Film?
    /// Ändern sich bei jedem Scrollen; nur der Flug selbst liest sie, darum ohne Beobachtung.
    @ObservationIgnored var sources: [String: Source] = [:]
    var detailFrame: CGRect = .zero
    /// Wo Titel und Verlauf auf der Karte stehen, und wo der Titel auf der Detailseite.
    /// Was von der Karte an seinen Platz auf der Detailseite fliegt. Der Rest blendet nur,
    /// sonst fliegen zu viele Texte übereinander.
    enum Part: Hashable { case title }
    struct CardText { var parts: [Part: CGRect] = [:]; var shade: CGFloat = 0 }
    @ObservationIgnored var cardTexts: [String: CardText] = [:]
    @ObservationIgnored var detailParts: [Part: CGRect] = [:]
    var cardText: CardText? { film.flatMap { f in scope.flatMap { cardTexts[Self.key(f.id, $0)] } } }
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    /// Während des Rückflugs angetippt: danach direkt öffnen statt den Tipp zu verlieren.
    @ObservationIgnored private var closingNow = false
    @ObservationIgnored private var pendingShow: (Film, String)?

    static func key(_ id: String, _ scope: String) -> String { scope + "|" + id }

    /// Cover und Titel an der Quelle verstecken, solange die Details offen sind oder es fliegt.
    func isLifted(_ id: String, in scope: String) -> Bool { film?.id == id && self.scope == scope }
    /// Match und Einzeiler der Karte: weg, sobald die Details aufgehen, zurück, sobald sie zugehen.
    func isShowingDetails(_ id: String, in scope: String) -> Bool { isLifted(id, in: scope) && open }

    var source: Source? { film.flatMap { f in scope.flatMap { sources[Self.key(f.id, $0)] } } }

    func show(_ film: Film, from scope: String) {
        if self.film != nil {
            if closingNow { pendingShow = (film, scope) }
            return
        }
        transitionTask?.cancel()
        open = false
        detailFrame = .zero
        detailParts = [:]
        self.scope = scope
        ghost = sources[Self.key(film.id, scope)] == nil ? nil : film
        self.film = film
        transitionTask = Task {
            // Warten, bis die Detailseite steht und ihr Cover gemessen ist.
            for _ in 0..<20 where detailFrame == .zero {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.84)) { open = true }
            try? await Task.sleep(for: .milliseconds(760))
            guard !Task.isCancelled else { return }
            if open { ghost = nil }
        }
    }

    /// Hide a title immediately when the current viewers no longer allow it.
    func closeImmediately() {
        transitionTask?.cancel(); transitionTask = nil
        pendingShow = nil; closingNow = false
        open = false; film = nil; ghost = nil; scope = nil
        detailFrame = .zero; detailParts = [:]
    }

    func close() {
        guard let film else { return }
        guard !closingNow else { return }
        transitionTask?.cancel()
        // A close before layout must not let a stale opening task present later.
        guard open else {
            self.film = nil; scope = nil; ghost = nil
            return
        }
        // Ist die Quelle verschwunden (z. B. von der Merkliste genommen), blendet die Seite nur aus.
        let flies = source != nil
        let alreadyFlying = ghost != nil
        if flies { ghost = film }
        closingNow = true
        if alreadyFlying || !flies {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) { open = false }
        }
        transitionTask = Task {
            // Erst einen Frame mit dem Cover an der Detailposition zeigen, dann losfliegen.
            if flies && !alreadyFlying { try? await Task.sleep(for: .milliseconds(20)) }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.88)) { open = false }
            // Erst übergeben, wenn die Feder fast steht: Sonst springen Knopf und Titel beim Landen.
            try? await Task.sleep(for: .milliseconds(flies ? 560 : 380))
            closingNow = false
            guard !open else { return }
            // Gelandet: Cover und Titel der Quelle übernehmen ohne Sprung.
            self.film = nil
            scope = nil
            ghost = nil
            if let (next, nextScope) = pendingShow {
                pendingShow = nil
                show(next, from: nextScope)
            }
        }
    }
}

extension View {
    /// Macht ein Cover zum Startpunkt des Morphs: misst seine Lage und blendet es aus, solange es fliegt.
    func heroSource(_ film: Film, in scope: String, cornerRadius: CGFloat) -> some View {
        modifier(HeroSourceModifier(film: film, scope: scope, radius: cornerRadius))
    }
}

/// Karten ohne Bereich (z. B. Vorschau) messen nichts.
private struct OptionalHeroSource: ViewModifier {
    let rec: Recommendation
    let scope: String?
    func body(content: Content) -> some View {
        if let scope { content.modifier(HeroSourceModifier(film: rec.film, scope: scope, radius: 28, rec: rec)) } else { content }
    }
}

private struct HeroSourceModifier: ViewModifier {
    @Environment(HeroCoordinator.self) private var hero
    let film: Film
    let scope: String
    let radius: CGFloat
    /// Gesetzt bei Vorschlagskarten: Dann fliegt die ganze Karte mit Verlauf und Text.
    var rec: Recommendation? = nil

    /// Letzte Lage merken: Nach einem Tabwechsel meldet sich die Geometrie nicht neu,
    /// wenn sich nichts bewegt hat. Ohne Merken gäbe es dann keinen Startpunkt mehr.
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        let key = HeroCoordinator.key(film.id, scope)
        content
            // Die Karte versteckt sich selbst und lässt ihren Schatten als Platzhalter stehen.
            .opacity(rec == nil && hero.isLifted(film.id, in: scope) ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frame = $0
                hero.sources[key] = .init(frame: $0, radius: radius, rec: rec)
            }
            .onAppear { if let frame { hero.sources[key] = .init(frame: frame, radius: radius, rec: rec) } }
            .onDisappear { hero.sources[key] = nil }
    }
}

struct HeroOverlay: View {
    @Environment(HeroCoordinator.self) private var hero
    @Environment(AppStore.self) private var store

    var body: some View {
        let source = hero.source
        ZStack {
            if let film = hero.film, store.allowsForViewers(film) {
                // Beim Öffnen liegt das echte Cover schon darunter, das fliegende blendet am Ziel aus.
                // So erscheinen Verlauf und Titel auf dem Cover mit, statt am Ende aufzuspringen.
                // Kommt sie von einer Karte, nimmt die Seite deren Verlauf maßstäblich mit.
                let cardShade = source.flatMap { s in
                    hero.cardText.map { $0.shade * hero.detailFrame.width / max(s.frame.width, 1) }
                }
                FilmDetailView(film: film, posterHidden: hero.ghost != nil && !hero.open,
                               contentVisible: hero.open,
                               shadeHeight: source?.card == true && hero.detailFrame != .zero ? cardShade : nil,
                               titleHidden: hero.ghost != nil && source?.card == true,
                               onClose: hero.close, onPosterFrame: { hero.detailFrame = $0 },
                               onPartFrame: { hero.detailParts[$0] = $1 })
            }
            // Ganzer Bildschirm ohne Ränder. Gemessen wird global, darum vom eigenen Ursprung aus rechnen:
            // Liegt die Ebene nicht genau bei 0,0, springt das Cover sonst beim Losfliegen.
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                if let film = hero.ghost, store.allowsForViewers(film), let source {
                    let r = hero.open ? hero.detailFrame : source.frame
                    // Schatten wie am jeweiligen Ort: Karte groß und weich, Detail-Cover etwas enger,
                    // kleine Listen-Cover ohne. Er wandert stufenlos mit.
                    RoundedRectangle(cornerRadius: hero.open ? 0 : source.radius)
                        .fill(.black)
                        .frame(width: r.width, height: r.height)
                        .mask { GhostFade(open: hero.open) }
                        .shadow(color: .black.opacity(!hero.open && source.card ? 0.5 : 0), radius: 24, y: 12)
                        .position(x: r.midX - origin.x, y: r.midY - origin.y)
                    if let rec = source.rec {
                        // Die ganze Karte fliegt: in Kartengröße gezeichnet und auf die aktuelle Größe skaliert,
                        // so sitzen Verlauf und Text genau wie auf der Karte. Die Ecken enden bei 14 pt am Ziel.
                        let s = source.frame.size
                        let scale = r.width / max(s.width, 1)
                        // Verlauf in Kartenpunkten: am Ziel genau der Verlauf der Detailseite, dann ist das Ausblenden unsichtbar.
                        RecommendationCard(rec: rec, width: s.width, viewers: store.activeProfileIDs.count,
                                           ghostOpen: hero.open,
                                           ghostShade: hero.cardText?.shade ?? 0,
                                           cornerRadius: hero.open ? 0 : source.radius)
                            .frame(width: s.width, height: s.height)
                            .mask { GhostFade(open: hero.open) }
                            .scaleEffect(scale)
                            .position(x: r.midX - origin.x, y: r.midY - origin.y)
                    } else {
                        PosterView(film: film, cornerRadius: 0, badgesHidden: hero.open)
                            .frame(width: r.width, height: r.height)
                            .clipShape(.rect(cornerRadius: hero.open ? 0 : source.radius))
                            .overlay(RoundedRectangle(cornerRadius: hero.open ? 0 : source.radius)
                                .strokeBorder(.white.opacity(0), lineWidth: 0.5))
                            .mask { GhostFade(open: hero.open) }
                            .position(x: r.midX - origin.x, y: r.midY - origin.y)
                    }
                }
            }
            .ignoresSafeArea()
            // Als ein Bild ausblenden: Sonst wird jede Schicht einzeln durchsichtig, das Schwarz unter dem Cover
            // scheint durch, und das Cover wird kurz dunkler, bevor die Detailseite übernimmt.
            .compositingGroup()
            // Nur die Deckkraft bekommt die verzögerte Blende, der Flug selbst bleibt die Feder.
            .animation(hero.open ? .easeOut(duration: 0.25).delay(0.3) : nil) { $0.opacity(hero.open ? 0 : 1) }
            .allowsHitTesting(false)

            // Der Titel wandert von der Karte an seinen Platz auf der Detailseite.
            // Ohne Blende: Am Ziel steht der Text genau dort, wo die Seite ihn zeigt.
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                // Steht schon da, bevor die Detailseite gemessen ist; so fliegt der Text los, statt am Ziel aufzutauchen.
                if let film = hero.ghost, store.allowsForViewers(film), source?.card == true, let text = hero.cardText {
                    // Wischt man vom Rand zurück, ist die Seite etwas kleiner: Der Text fliegt aus dieser Größe.
                    let page = hero.detailFrame == .zero ? 1 : hero.detailFrame.width / max(geo.size.width, 1)
                    let morph = { (part: HeroCoordinator.Part) -> (CGRect, CGRect)? in
                        text.parts[part].map { ($0, hero.detailParts[part] ?? $0) }
                    }
                    if let (from, to) = morph(.title) {
                        let size = FilmDetailView.titleSize(pageWidth: geo.size.width)
                        FlyingTitle(from: from, to: to, open: hero.open, origin: origin, fromSize: 36, toSize: size, page: page) {
                            FilmDetailView.title(film, size: size)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onChange(of: hero.film.map { store.allowsForViewers($0) } ?? true) { _, allowed in
            if !allowed { hero.closeImmediately() }
        }
    }
}

/// Das fliegende Cover läuft am Ziel unten aus wie das Cover der Detailseite, statt dort mit einer dunklen Kante
/// zu landen. Unterwegs wächst die Blende mit; die volle Fläche darüber reicht über den Rand, damit der Schatten bleibt.
private struct GhostFade: View {
    let open: Bool

    var body: some View {
        ZStack {
            FilmDetailView.posterFade
            Color.white.padding(-60).opacity(open ? 0 : 1)
                // Schneller als der Flug: Sonst bleibt die untere Kante der Karte unterwegs kurz sichtbar.
                // Beim Schließen langsamer, damit am Detail-Cover keine Kante aufspringt.
                .animation(open ? .easeOut(duration: 0.18) : .easeIn(duration: 0.4), value: open)
        }
    }
}

/// Der Titel fliegt als ein einziger Text von der Karte an seinen Platz auf der Detailseite.
/// Beide Seiten nutzen dieselbe Schrift, darum wird nichts überblendet: Er wird nur kleiner und wandert.
/// Er hängt an der oberen linken Ecke, so steht die erste Zeile immer am selben Punkt.
private struct FlyingTitle<Content: View>: View {
    let from: CGRect
    let to: CGRect
    let open: Bool
    let origin: CGPoint
    /// Schriftgrößen an Start und Ziel: daraus, wie stark der Titel unterwegs schrumpft.
    let fromSize: CGFloat
    let toSize: CGFloat
    /// Größe der Detailseite (kleiner, wenn man sie vom Rand wegzieht).
    let page: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let p = open ? to.origin : from.origin
        content
            .frame(width: to.width / page, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(open ? page : fromSize / toSize, anchor: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: p.x - origin.x, y: p.y - origin.y)
    }
}

/// Text, in dem Sternchen als Zensurbalken erscheinen: „über den ***** ****“.
/// Für Einzeiler mit Insider-Witz, bei denen man lieber nichts verraten will.
struct RedactedText: View {
    let string: String
    init(_ string: String) { self.string = string }

    var body: some View {
        var result = Text("")
        var rest = Substring(string)
        while let match = rest.firstMatch(of: /\*+/) {
            let hidden = Text(String(repeating: "█", count: match.output.count)).accessibilityLabel("geschwärzt")
            result = Text("\(result)\(Text(rest[..<match.range.lowerBound]))\(hidden)")
            rest = rest[match.range.upperBound...]
        }
        return Text("\(result)\(Text(rest))")
    }
}
