import SwiftUI
import UniformTypeIdentifiers

/// Onboarding als kurzes Spiel: Profil → bekannte Filme swipen → Geschmacksprofil → Abo.
/// Der Import (Letterboxd, IMDb) liegt bewusst nicht hier, sondern im Profil-Tab.
/// Bezahlt wird erst, nachdem man gesehen hat, wie gut die App einen kennt.
/// Wird auch zum Anlegen weiterer Profile genutzt (dann ohne Abo-Schritt; bei vollem Tarif mit Upgrade vorab).
struct OnboardingFlow: View {
    enum Step { case upgrade, name, calibrate, favorites, reveal, plan }
    enum Mode { case firstRun, addProfile }

    @Environment(AppStore.self) private var store
    var mode: Mode = .firstRun
    var onFinish: (UUID) -> Void

    /// Abbrechen (nur beim Anlegen weiterer Profile, z. B. wenn kein größerer Tarif gewählt wird).
    var cancel: (() -> Void)?
    @State private var step: Step
    @State private var profileID: UUID?
    @State private var confirmCancel = false

    init(mode: Mode = .firstRun, start: Step? = nil, profileID: UUID? = nil,
         cancel: (() -> Void)? = nil, onFinish: @escaping (UUID) -> Void) {
        self.mode = mode
        self.onFinish = onFinish
        self.cancel = cancel
        _step = State(initialValue: start ?? .name)
        _profileID = State(initialValue: profileID)
    }

    var body: some View {
        NavigationFrame { content }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch step {
            case .upgrade:
                PlanPicker(mode: .upgrade) { upgraded in
                    if upgraded { go(.name) } else { cancel?() }
                }
            case .name:
                // Nach „Zurück“ aus der Filmauswahl gibt es das Profil schon: dann bearbeiten statt neu anlegen.
                ProfileEditor(isFirst: mode == .firstRun, editing: profile, continuing: true,
                              cancel: profile == nil ? cancel : (cancel == nil ? nil : { confirmCancel = true })) { name, art, fsk, little in
                    if let profileID, profile != nil {
                        store.editProfile(profileID, name: name, avatar: art, maxFSK: fsk, littleKid: little)
                    } else {
                        profileID = store.addProfile(name: name, colorIndex: art.colorIndex, maxFSK: fsk, littleKid: little, avatar: art.id)
                    }
                    // Kleine Kinder wischen nicht selbst, die Eltern suchen Lieblingsfilme aus.
                    go(little ? .favorites : .calibrate)
                }
                .id(profileID)
            case .calibrate:
                if let profileID {
                    CalibrationStep(profileID: profileID, alreadyRated: ratedCount) { go(.reveal) }
                }
            case .favorites:
                if let profileID { KidFavoritesStep(profileID: profileID) { go(.reveal) } }
            case .reveal:
                if let profileID {
                    RevealStep(profileID: profileID, buttonTitle: mode == .firstRun ? "Zeig mir meinen Film" : "Fertig") {
                        if mode == .firstRun && !store.canPlay { go(.plan) } else { onFinish(profileID) }
                    }
                }
            case .plan:
                if let profileID { PlanPicker(mode: .onboarding) { _ in onFinish(profileID) } }
            }
        }
        // Zurück führt zum Profil (Name, Bild), das Profil und alle Swipes bleiben erhalten.
        // Abbrechen gibt es nur beim Anlegen weiterer Profile, erst dann wird das Profil verworfen.
        .toolbar {
            if [.calibrate, .favorites].contains(step) {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurück zum Profil", systemImage: "chevron.left") { go(.name) }.tint(.white)
                }
                if cancel != nil {
                    ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { confirmCancel = true }.tint(.white) }
                }
            }
        }
        .confirmationDialog("Profil nicht anlegen?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Profil verwerfen", role: .destructive) {
                if let profileID { store.deleteProfile(profileID) }
                cancel?()
            }
            Button("Weitermachen", role: .cancel) {}
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if mode == .addProfile && step == .name && !store.canAddProfile { step = .upgrade }
        }
    }

    private func go(_ next: Step) {
        withAnimation(.smooth(duration: 0.45)) { step = next }
    }

    private var profile: Profile? { profileID.flatMap { id in store.profiles.first { $0.id == id } } }
    /// Schon bewertete Filme zählen weiter, wenn man zurück und wieder vor geht.
    private var ratedCount: Int { profile?.interactions.values.filter { $0 != .unseen }.count ?? 0 }
}

/// Langsam scrollende Wand aus Postern, grau, ein Poster leuchtet (wie das App-Icon).
struct PosterWall: View {
    /// Zwölf Poster reichen für die bewegte Wand und entlasten den ersten Start.
    private static let columns: [[Film]] = {
        let films = Array(FilmIndex.all.filter { !$0.niche && !$0.isSeries && !$0.comingSoon }.shuffled().prefix(12))
        return (0..<3).map { c in films.enumerated().filter { $0.offset % 3 == c }.map(\.element) }
    }()

    /// Das eine Poster, das gerade in Farbe leuchtet. Der Fokus springt durchs Bild:
    /// links, rechts, Mitte, oben, unten, aber immer auf ein Poster, das gerade gut zu sehen ist.
    private struct Focus: Equatable {
        var column: Int
        var filmID: String
    }
    @State private var focus: Focus?
    @State private var size: CGSize = .zero

    private static let speeds = [14.0, 9.0, 12.0]
    private enum Spot { case any, top, bottom }
    /// Spalte (nil = eine andere als zuletzt) und welches der gut sichtbaren Poster darin.
    private static let spots: [(column: Int?, spot: Spot)] = [(0, .any), (2, .any), (1, .any), (nil, .top), (nil, .bottom)]

    var body: some View {
        // Die Wand bewegt sich langsam; 30 Bilder/s reichen und lassen der Oberfläche Luft.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = Self.tileWidth(geo.size.width)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<3, id: \.self) { c in
                        column(c, w: w, h: w * 1.5, viewportHeight: geo.size.height)
                            .offset(y: offset(c, t: t, width: geo.size.width))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onAppear { PosterCache.warmUp(Self.columns.flatMap { $0 }.map(\.id)) }
        .task {
            var step = 0
            while !Task.isCancelled {
                if size.width > 0 {
                    let spot = Self.spots[step % Self.spots.count]
                    let c = spot.column ?? [0, 1, 2].filter { $0 != focus?.column }.randomElement()!
                    if let next = film(spot.spot, column: c, t: Date.now.timeIntervalSinceReferenceDate) { focus = next }
                    step += 1
                }
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }

    private static func tileWidth(_ width: CGFloat) -> CGFloat { (width - 24) / 3 }

    /// Senkrechte Verschiebung einer Spalte zum Zeitpunkt `t`, die mittlere läuft nach oben.
    private func offset(_ c: Int, t: Double, width: CGFloat) -> CGFloat {
        let pitch = Self.tileWidth(width) * 1.5 + 12
        let total = pitch * CGFloat(Self.columns[c].count)
        let shift = CGFloat((t * Self.speeds[c]).truncatingRemainder(dividingBy: Double(total)))
        return c == 1 ? -shift : shift - total
    }

    /// Ein Poster in Spalte `c`, das gerade (und die nächsten Sekunden) gut zu sehen ist:
    /// unter der Statusleiste und über dem Text, der ab etwa 45 % der Höhe beginnt.
    private func film(_ spot: Spot, column c: Int, t: Double) -> Focus? {
        let h = Self.tileWidth(size.width) * 1.5
        let pitch = h + 12
        let band = 50.0...(size.height * 0.45)
        let off = offset(c, t: t, width: size.width)
        let drift = (c == 1 ? -1.0 : 1.0) * Self.speeds[c] * 2   // Bewegung während der Fokuszeit
        let list = Self.columns[c] + Self.columns[c]
        let visible = list.indices.compactMap { i -> (i: Int, top: CGFloat, share: CGFloat)? in
            let top = off + CGFloat(i) * pitch + drift / 2
            let shown = min(top + h, band.upperBound) - max(top, band.lowerBound)
            guard shown > 0, list[i].id != focus?.filmID else { return nil }
            return (i, top, shown / h)
        }
        let good = visible.filter { $0.share > 0.75 }
        let pick: (i: Int, top: CGFloat, share: CGFloat)? = switch spot {
        case .any: visible.max { $0.share < $1.share }
        case .top: good.min { $0.top < $1.top } ?? visible.max { $0.share < $1.share }
        case .bottom: good.max { $0.top < $1.top } ?? visible.max { $0.share < $1.share }
        }
        return pick.map { Focus(column: c, filmID: list[$0.i].id) }
    }

    private func column(_ c: Int, w: CGFloat, h: CGFloat, viewportHeight: CGFloat) -> some View {
        // Repeat just enough to cover tall iPhones even at the end of a scrolling cycle.
        let cycleHeight = max(1, CGFloat(Self.columns[c].count) * (h + 12))
        let repetitions = max(2, Int(ceil(viewportHeight / cycleHeight)) + 1)
        let films = (0..<repetitions).flatMap { _ in Self.columns[c] }
        return VStack(spacing: 12) {
            ForEach(Array(films.enumerated()), id: \.offset) { _, film in
                let highlight = focus == Focus(column: c, filmID: film.id)
                PosterView(film: film, cornerRadius: 12)
                    .frame(width: w, height: h)
                    .saturation(highlight ? 1 : 0)
                    .opacity(highlight ? 1 : 0.38)
                    .animation(.easeInOut(duration: 0.9), value: highlight)
            }
        }
    }
}

// MARK: - Kalibrierung (Swipe bekannter Filme)

struct CalibrationStep: View {
    @Environment(AppStore.self) private var store
    let profileID: UUID
    var title = "Kennst du den?"
    var minimum = 6
    /// Schon bewertete Filme dieses Profils (nach „Zurück“ im Onboarding).
    var alreadyRated = 0
    var next: () -> Void

    @State private var queue: [Film] = []
    @State private var trigger: SwipeDirection?
    @State private var rated = 0
    @State private var picker: CalibrationPicker?
    @State private var shown: Set<String> = []

    private let target = 12
    private let options: [SwipeDirection: SwipeOption] = [
        .left: .init(title: "Nicht meins", symbol: "hand.thumbsdown.fill", color: Color(red: 1, green: 0.27, blue: 0.3)),
        .right: .init(title: "Mag ich", symbol: "hand.thumbsup.fill", color: Color(red: 0.2, green: 0.85, blue: 0.5)),
        .up: .init(title: "Lieblingsfilm", symbol: "heart.fill", color: Color(red: 1, green: 0.3, blue: 0.6)),
        .down: .init(title: "Nicht gesehen", symbol: "eye.slash.fill", color: Color(white: 0.5))
    ]

    private var profile: Profile? { store.profiles.first { $0.id == profileID } }
    private var knowledge: Double { min(Double(rated) / Double(target), 1) }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title.weight(.heavy))
                    Text("Wisch in die Richtung, die passt.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                KnowledgeRing(value: knowledge, size: 54)
            }

            SwipeDeck(items: queue, options: options, trigger: $trigger,
                      onCommit: { film, d in swiped(d, film) }) { film, _ in
                PosterView(film: film, cornerRadius: 28)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 2) {
                            Text(film.title).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                            Text("\(String(film.year)) · \(film.genres.prefix(2).joined(separator: " · "))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 14).frame(maxWidth: .infinity)
                        // Dunkel abgetönt, damit Titel auch auf hellen Postern lesbar bleibt.
                        .background(Color.black.opacity(0.55))
                        .background(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .clipShape(.rect(bottomLeadingRadius: 28, bottomTrailingRadius: 28))
                    }
                    .cardShadow()
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 12)

            HStack(spacing: 14) {
                roundButton(.left); roundButton(.down); roundButton(.up); roundButton(.right)
            }

            Button {
                next()
            } label: {
                Text(rated >= minimum ? "Weiter" : "Noch \(minimum - rated) bewerten")
                    .contentTransition(.numericText(countsDown: true))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .disabled(rated < minimum)
        }
        .padding(20)
        .ignoresSafeArea(.keyboard)
        .task {
            guard queue.isEmpty else { return }
            rated = alreadyRated
            let p = CalibrationPicker(profile: profile, excluding: Set(profile?.interactions.keys.map { $0 } ?? []))
            picker = p
            let films = p.next(4, excluding: [])
            shown = Set(films.map(\.id))
            PosterCache.warmUp(films.map(\.id))
            // Karten wachsen nach dem Wechsel animiert auf volle Größe.
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { queue = films }
        }
    }

    private func roundButton(_ d: SwipeDirection) -> some View {
        let o = options[d]!
        return VStack(spacing: 6) {
            Button { trigger = d } label: {
                Image(systemName: o.symbol).font(.title3.weight(.bold)).foregroundStyle(o.color)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .foregroundStyle(.white)
            .accessibilityLabel(o.title)
            Text(o.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(width: 74)
    }

    private func swiped(_ d: SwipeDirection, _ film: Film) {
        let interaction: Interaction = switch d {
        case .left: .disliked
        case .right: .liked
        case .up: .loved
        case .down: .unseen
        }
        store.calibrate(profile: profileID, film: film, interaction)
        if interaction != .unseen { withAnimation(.snappy) { rated += 1 } }
        // Aus jedem Swipe lernen, welche Filme jemand kennt, und die Karten hinter der nächsten neu wählen.
        picker?.record(film, seen: interaction != .unseen)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            queue.removeFirst()
            if let p = picker {
                let upcoming = Array(queue.prefix(1))
                let more = p.next(4 - upcoming.count, excluding: shown.union(upcoming.map(\.id)))
                shown.formUnion(more.map(\.id))
                queue = upcoming + more
                PosterCache.warmUp(more.map(\.id))
            }
        }
        if rated >= target + 6 || queue.isEmpty { next() }
    }
}

/// „Wie gut kennen wir dich?“, Ring, der sich mit jedem Swipe füllt.
struct KnowledgeRing: View {
    var value: Double
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: size * 0.1)
            Circle().trim(from: 0, to: value)
                .stroke(.tint,
                        style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value * 100)) %").font(.system(size: size * 0.24, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: value)
    }
}

// MARK: - Lieblingsfilme für kleine Kinder

/// Kleine Kinder können nicht wischen und lesen. Die Eltern tippen einfach an,
/// was ihr Kind gern schaut, große Poster, keine Texte nötig.
struct KidFavoritesStep: View {
    @Environment(AppStore.self) private var store
    let profileID: UUID
    var next: () -> Void
    @State private var picked: Set<String> = []

    private var profile: Profile? { store.profiles.first { $0.id == profileID } }
    private var films: [Film] {
        FilmIndex.all.filter { !$0.comingSoon && (profile?.allows($0) ?? false) }
            .sorted { ($0.mlSeen ?? 0) > ($1.mlSeen ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Was schaut \(profile?.name ?? "dein Kind") gern?").font(.largeTitle.weight(.heavy))
                    Text("Tipp alles an, was dein Kind mag. Daraus lernen die Vorschläge, nur Zeichentrick und Familienfilme.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(films) { film in
                        let on = picked.contains(film.id)
                        Button {
                            withAnimation(.snappy) { if on { picked.remove(film.id) } else { picked.insert(film.id) } }
                        } label: {
                            PosterView(film: film, cornerRadius: 14)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14).strokeBorder(.white, lineWidth: on ? 3 : 0)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if on {
                                        Image(systemName: "heart.fill")
                                            .font(.headline).foregroundStyle(.pink)
                                            .padding(7).background(.white, in: .circle)
                                            .padding(6)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .scaleEffect(on ? 0.95 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(film.title)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(24)
        }
        .sensoryFeedback(.selection, trigger: picked)
        .safeAreaInset(edge: .bottom) {
            Button {
                let ratings: [(Film, Interaction)] = picked.compactMap { id in
                    FilmIndex.film(id).map { ($0, .loved) }
                }
                store.importRatings(profile: profileID, ratings: ratings)
                next()
            } label: {
                Text(picked.isEmpty ? "Überspringen" : "Weiter mit \(picked.count)")
                    .contentTransition(.numericText())
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .task { PosterCache.warmUp(films.prefix(12).map(\.id)) }
    }
}

// MARK: - Import

struct ImportStep: View {
    @Environment(AppStore.self) private var store
    let profileID: UUID
    var next: () -> Void

    @State private var showImporter = false
    @State private var importing = false
    @State private var result: ImportResult?
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Noch genauer?").font(.largeTitle.weight(.heavy))
                Text("Bring deine Bewertungen mit, oder such dir deine Lieblingsfilme raus. Alles optional.")
                    .foregroundStyle(.secondary)

                Button { showImporter = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down.on.square.fill").font(.title2)
                            .foregroundStyle(Color(red: 0.25, green: 0.85, blue: 0.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Letterboxd oder IMDb importieren").font(.headline)
                            Text("CSV aus dem Daten-Export (ratings.csv)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(importing)
                .glassEffect(in: .rect(cornerRadius: 22))
                if importing { ProgressView("Bewertungen werden gelesen …").font(.footnote) }

                if let result {
                    Label {
                        Text("\(result.source): \(result.totalRows) Bewertungen gelesen, \(result.matched.count) davon in unserem Katalog erkannt.")
                    } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    .font(.subheadline)
                    .transition(.opacity)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Lieblingsfilme").font(.headline)
                    TextField("Film suchen …", text: $search)
                        .padding(12)
                        .glassEffect(in: .rect(cornerRadius: 16))
                    ForEach(searchResults) { film in
                        let loved = profile?.interactions[film.id] == .loved
                        HStack(spacing: 12) {
                            PosterView(film: film, cornerRadius: 6).frame(width: 40)
                            VStack(alignment: .leading) {
                                Text(film.title).font(.subheadline.weight(.semibold))
                                Text(String(film.year)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                store.calibrate(profile: profileID, film: film, loved ? .liked : .loved)
                            } label: {
                                Image(systemName: loved ? "heart.fill" : "heart")
                                    .font(.title3).foregroundStyle(loved ? .pink : .secondary)
                            }
                            .disabled(importing)
                            .sensoryFeedback(.success, trigger: loved)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: next) {
                Text("Fertig").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(importing)
            .foregroundStyle(.black)
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { res in
            guard case .success(let url) = res else { return }
            importing = true
            let epoch = store.sessionEpoch
            Task {
                defer { importing = false }
                guard let rows = await LibraryImport.readRows(from: url), let parsed = LibraryImport.parseRows(rows) else {
                    error = "Die Datei konnte nicht gelesen werden. Erwartet: ratings.csv von Letterboxd oder IMDb."
                    return
                }
                guard epoch == store.sessionEpoch,
                      await store.importRatingsResponsively(profile: profileID, ratings: parsed.matched, unmatched: parsed.unmatchedCount) else {
                    error = "Der Import wurde unterbrochen. Bereits übernommene Bewertungen bleiben gespeichert."
                    return
                }
                withAnimation { result = parsed; error = nil }
            }
        }
    }

    private var profile: Profile? { store.profiles.first { $0.id == profileID } }

    private var searchResults: [Film] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let pool = FilmIndex.all.filter { !$0.comingSoon && (profile?.allows($0) ?? true) }
        guard !q.isEmpty else {
            return pool.filter { profile?.interactions[$0.id] == .loved }
        }
        return pool.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.originalTitle.localizedCaseInsensitiveContains(q) || $0.cast.contains { $0.localizedCaseInsensitiveContains(q) } || $0.director.localizedCaseInsensitiveContains(q) }
            .prefix(6).map { $0 }
    }
}

// MARK: - Geschmacksprofil enthüllen

struct RevealStep: View {
    @Environment(AppStore.self) private var store
    let profileID: UUID
    var buttonTitle: String
    var done: () -> Void
    @State private var sentence: String?
    @State private var usedAI = false
    @State private var shown = false

    var body: some View {
        let profile = store.profiles.first { $0.id == profileID }
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 10)
            if let profile {
                HStack(spacing: 14) {
                    AvatarView(profile: profile, size: 56)
                    VStack(alignment: .leading) {
                        Text("Dein Geschmacksprofil").font(.subheadline).foregroundStyle(.secondary)
                        Text(profile.name).font(.largeTitle.weight(.heavy))
                    }
                }
                TasteCard(profile: profile, sentence: sentence, usedAI: usedAI, animate: shown)
            }
            Spacer()
            Button(action: done) {
                Text(buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
        }
        .padding(24)
        .task {
            guard let profile else { return }
            withAnimation(.smooth(duration: 1.2).delay(0.2)) { shown = true }
            let (s, ai) = await TasteWriter.sentence(for: profile)
            withAnimation(.smooth(duration: 0.6)) { sentence = s; usedAI = ai }
        }
    }
}

/// Wiederverwendbare Karte: Satz + Balken der Lieblingsstimmungen/-genres.
struct TasteCard: View {
    let profile: Profile
    var sentence: String?
    var usedAI = false
    var animate = true

    var body: some View {
        let summary = TasteSummary(profile: profile)
        let bars = Array((summary.topMoods.prefix(3) + summary.topGenres.prefix(1)))
        let maxValue = bars.map(\.1).max() ?? 1
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                // Wechsel vom Standardsatz zum KI-Satz: weich überblenden statt springen.
                Text("„\(sentence ?? summary.sentence)“")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .id(sentence ?? summary.sentence)
                    .transition(.blurReplace)
                if usedAI {
                    Label("Formuliert mit Apple Intelligence", systemImage: "apple.intelligence")
                        .font(.caption).foregroundStyle(.secondary)
                        .transition(.blurReplace)
                }
            }
            if !summary.topMoods.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bars, id: \.0) { item in
                        HStack {
                            Text(item.0.moodLabel).font(.subheadline.weight(.medium)).frame(width: 130, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(.white.opacity(0.1))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(profile.color.gradient)
                                            .frame(width: animate ? geo.size.width * item.1 / maxValue : 0)
                                    }
                            }
                            .frame(height: 10)
                        }
                    }
                }
            }
            HStack {
                Label("\(profile.signalCount) Signale", systemImage: "waveform.path.ecg")
                    .contentTransition(.numericText(value: Double(profile.signalCount)))
                Spacer()
                Text("Jeder Swipe macht's genauer")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(in: .rect(cornerRadius: 28))
    }
}
