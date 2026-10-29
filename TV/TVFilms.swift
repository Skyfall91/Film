import SwiftUI

struct TVForYouView: View {
    @Environment(AppStore.self) private var store
    @State private var playback: PlaybackRequest?
    @State private var plans = false
    @State private var mood = ""
    @State private var viewers = false
    @State private var details = false
    @State private var deck = TVPreparedDeck<Recommendation>()
    @State private var undoBounce = 0
    @State private var handledRevision = -1
    @State private var refillTask: Task<Void, Never>?

    /// Run only when inputs change or the prepared deck gets low, never during rendering.
    private func rankedSuggestions() -> [Recommendation] {
        let began = CFAbsoluteTimeGetCurrent()
        defer {
            #if DEBUG
            NSLog("FilmTV prepared ranking: %.1f ms", (CFAbsoluteTimeGetCurrent() - began) * 1000)
            #endif
        }
        let profiles = store.activeProfiles
        let eligible = RecommendationEngine.candidates(profiles: profiles, runtime: store.runtimeFilter, kind: store.kindFilter, skipped: store.skippedToday)
            .filter { mood.isEmpty || $0.moods.contains(mood) }
        guard let query = store.companionMoodQuery else {
            return eligible.map { ($0, RecommendationEngine.groupScore($0, profiles: profiles)) }
                .sorted { $0.1 > $1.1 }.prefix(8)
                .map { Recommendation(film: $0.0, match: RecommendationEngine.matchPercent($0.1), reason: RecommendationEngine.reason(for: $0.0, profiles: profiles)) }
        }
        let allowed = Set(eligible.map(\.id))
        return Array(MoodSearch.rank(query, profiles: profiles).filter { allowed.contains($0.film.id) }.prefix(8))
    }
    private func prepareDeck() {
        refillTask?.cancel()
        deck.replace(rankedSuggestions())
        handledRevision = store.tasteRevision
        warmDeck()
    }
    private func warmDeck() {
        let ids = deck.items.prefix(4).map(\.film.id)
        PosterCache.warmUp(ids)
        BackdropBlur.warmUp(ids)
    }
    private func scheduleRefill() {
        refillTask?.cancel()
        guard deck.items.count < 3 else { warmDeck(); return }
        refillTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            deck.append(rankedSuggestions())
            warmDeck()
        }
    }
    private func undoFilm() {
        guard store.canUndo else { return }
        refillTask?.cancel()
        let began = CFAbsoluteTimeGetCurrent()
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            store.undo()
            if !deck.undo() { prepareDeck() }
            handledRevision = store.tasteRevision
            displacement = .zero
        }
        undoBounce += 1
        warmDeck()
        #if DEBUG
        NSLog("FilmTV undo handler: %.1f ms", (CFAbsoluteTimeGetCurrent() - began) * 1000)
        #endif
    }

    @FocusState private var coverTarget: Bool
    @Namespace private var filmFocusScope
    @Environment(\.resetFocus) private var resetFilmFocus
    @State private var inputReady = false
    @State private var options = false
    @State private var coverFocused = false
    @State private var displacement = CGSize.zero
    @State private var changing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let rec = deck.items.first, store.allowsForViewers(rec.film) {
                BlurredBackdrop(film: rec.film).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 30) {
                    if options { optionsBar.transition(.move(edge: .top).combined(with: .opacity)) }
                    HStack(alignment: .center, spacing: 76) {
                        TVPosterView(film: rec.film, width: 430, height: 645)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(.white.opacity(coverFocused ? 0.95 : 0), lineWidth: 4)
                            }
                            .overlay {
                                if abs(displacement.width) > 12 || abs(displacement.height) > 12 {
                                    Text(abs(displacement.width) > abs(displacement.height) ? (displacement.width < 0 ? "Heute nicht" : "Merken") : (displacement.height < 0 ? "Details" : "Gesehen"))
                                        .font(.system(size: 34, weight: .bold)).padding(22)
                                        .foregroundStyle(previewAction.color)
                                        .background(.black.opacity(0.9), in: Capsule())
                                }
                            }
                            .scaleEffect(coverFocused ? 1.025 : 1)
                            .offset(displacement)
                            .rotationEffect(.degrees(reduceMotion ? 0 : Double(displacement.width / 25)))
                            .overlay {
                                TVFilmRemoteInput(enabled: inputReady && !options && !details && playback == nil && !plans && !viewers && store.ratingToPresent == nil,
                                    preview: { value in
                                        guard !changing else { return }
                                        withAnimation(value == .zero ? .spring(response: 0.3, dampingFraction: 0.8) : .linear(duration: 0.06)) {
                                            displacement = reduceMotion ? .zero : CGSize(width: max(-110, min(110, value.width * 0.4)), height: max(-85, min(85, value.height * 0.4)))
                                        }
                                    }, action: { handle($0, film: rec.film) }, focusChanged: { coverFocused = $0 })
                                    .focused($coverTarget)
                                    .prefersDefaultFocus(!options, in: filmFocusScope)
                            }
                        VStack(alignment: .leading, spacing: 27) {
                            Text(rec.film.title).font(Theme.filmTitle(size: 68)).lineLimit(2)
                            Text(rec.film.hook).font(.system(size: 34, weight: .medium)).lineSpacing(5).lineLimit(3)
                            HStack(spacing: 24) {
                                Text("\(rec.match)% Match").foregroundStyle(store.accent).bold()
                                Text(rec.film.metaLine)
                            }.font(.system(size: 25)).foregroundStyle(.white.opacity(0.8))
                            Text(rec.film.genres.joined(separator: " · ")).font(.system(size: 23)).foregroundStyle(.white.opacity(0.75))
                            HStack(spacing: 32) {
                                if let rating = rec.film.imdbRating { Label("IMDb \(rating.formatted(.number.precision(.fractionLength(1)))) / 10", systemImage: "star.fill") }
                                if let score = rec.film.rottenTomatoes { Text("Rotten Tomatoes \(score)%") }
                                if let score = rec.film.metascore { Text("Metascore \(score)") }
                            }.font(.system(size: 23, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            if rec.film.hook != rec.film.synopsis {
                                Text(rec.film.synopsis).font(.system(size: 26)).lineSpacing(5).lineLimit(4)
                            }
                            Text(rec.reason).font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            if !rec.film.cast.isEmpty {
                                Text(rec.film.cast.prefix(3).joined(separator: " · ")).font(.system(size: 21)).foregroundStyle(.white.opacity(0.65))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity)
                    remoteLegend
                }.padding(.horizontal, 90).padding(.vertical, 35)
            } else {
                TVScreen(title: "Heute nichts Passendes") {
                    Text("Ändere die Filter oder nimm einen Schritt zurück.")
                    optionsBar
                    Button("Filter zurücksetzen") { mood = ""; store.runtimeFilter = nil; store.kindFilter = .all; store.skippedToday = []; store.companionMoodQuery = nil; options = false }
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: options)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85), value: coverFocused)
        .onChange(of: store.tasteRevision) { _, revision in
            if revision != handledRevision { prepareDeck() }
        }
        .onChange(of: store.activeProfileIDs) { _, _ in prepareDeck() }
        .onChange(of: store.runtimeFilter) { _, _ in prepareDeck() }
        .onChange(of: store.kindFilter) { _, _ in prepareDeck() }
        .onChange(of: mood) { _, _ in prepareDeck() }
        .onChange(of: store.companionMoodQuery?.summary) { _, _ in prepareDeck() }
        .onDisappear { refillTask?.cancel() }
        .focusScope(filmFocusScope)
        .defaultFocus($coverTarget, true, priority: .userInitiated)
        .task(id: store.selectedTab) {
            inputReady = false
            guard store.selectedTab == FilmSection.forYou.rawValue else { return }
            options = false
            prepareDeck()
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            inputReady = true
            coverTarget = true
            resetFilmFocus(in: filmFocusScope)
        }
        .fullScreenCover(item: $playback) { TVPlayerView(request: $0) }
        .sheet(isPresented: $details) { if let film = deck.items.first?.film { TVFilmDetailsView(film: film) } }
        .sheet(isPresented: $plans) { TVPlanPicker() }
        .sheet(isPresented: $viewers) { TVViewerPicker() }
    }
    private var optionsBar: some View {
        HStack(spacing: 30) {
            Button("Zum Film", systemImage: "rectangle.portrait") { options = false; coverTarget = true }.filmPrimaryAction()
            Button("Wer schaut?", systemImage: "person.2") { viewers = true }.tint(.white)
            TVFilterMenu(mood: $mood).tint(store.runtimeFilter != nil || store.kindFilter != .all || !mood.isEmpty ? store.accent : .white)
            Button { undoFilm() } label: {
                Label("Rückgängig", systemImage: "arrow.uturn.backward")
                    .symbolEffect(.rotate.counterClockwise, value: undoBounce)
            }.tint(.white).disabled(!store.canUndo)
            Spacer()
            Text("↑ Zur Navigation").font(.system(size: 22)).foregroundStyle(.secondary)
        }
    }
    private var remoteLegend: some View {
        HStack(spacing: 36) {
            Label("Heute nicht", systemImage: "arrow.left").foregroundStyle(SwipeAction.notToday.color)
            Label("Merken", systemImage: "arrow.right").foregroundStyle(SwipeAction.watchlist.color)
            Label("Gesehen", systemImage: "arrow.down").foregroundStyle(SwipeAction.alreadySeen.color)
            Label("Details", systemImage: "arrow.up").foregroundStyle(SwipeAction.details.color)
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Label(coverFocused ? "Klicken · Film starten" : "Cover auswählen", systemImage: "circle.inset.filled")
                Text("Zurück · Navigation & Optionen").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7))
            }
        }.font(.system(size: 23, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            .padding(.top, 18)
    }
    private var previewAction: SwipeAction {
        if abs(displacement.width) > abs(displacement.height) { return displacement.width < 0 ? .notToday : .watchlist }
        return displacement.height < 0 ? .details : .alreadySeen
    }
    private func handle(_ action: TVFilmRemoteAction, film: Film) {
        guard !changing else { return }
        switch action {
        case .play: start(film)
        case .navigation: options = true; displacement = .zero
        case .up: details = true; displacement = .zero
        case .left, .right, .down:
            changing = true
            let began = CFAbsoluteTimeGetCurrent()
            // The next image is already decoded; state changes need no ranking or network.
            deck.advance()
            switch action {
            case .left: store.apply(.notToday, to: film)
            case .right: store.apply(.watchlist, to: film)
            case .down: store.apply(.alreadySeen, to: film); store.ratingToPresent = store.pendingRatings.last
            default: break
            }
            handledRevision = store.tasteRevision
            // The incoming poster enters from the opposite edge; no artificial wait before advancing.
            displacement = reduceMotion ? .zero : action == .left ? CGSize(width: 65, height: 0) : action == .right ? CGSize(width: -65, height: 0) : CGSize(width: 0, height: -50)
            Task { @MainActor in
                await Task.yield()
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) { displacement = .zero }
                changing = false
                scheduleRefill()
            }
            #if DEBUG
            NSLog("FilmTV swipe handler: %.1f ms", (CFAbsoluteTimeGetCurrent() - began) * 1000)
            #endif
        }
    }
    private func start(_ film: Film) {
        guard !film.comingSoon, store.activeProfiles.allSatisfy({ $0.allows(film) }) else { return }
        if !store.canPlay { plans = true; return }
        playback = PlaybackRequest(film: film, episode: store.upNext(film), countsAsWatched: true, sourceID: film.id)
    }
}

struct TVFilters: View {
    @Environment(AppStore.self) private var store
    @Binding var mood: String
    var body: some View {
        @Bindable var store = store
        HStack(spacing: 24) {
            Picker("Format", selection: $store.kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).frame(width: 230)
            Picker("Laufzeit", selection: Binding(get: { store.runtimeFilter?.minutes ?? 0 }, set: { store.runtimeFilter = $0 == 0 ? nil : RuntimeFilter(minutes: $0) })) {
                Text("Jede Länge").tag(0)
                Text("Bis 90 Min.").tag(90)
                Text("Bis 120 Min.").tag(120)
                Text("Bis 150 Min.").tag(150)
                Text("Bis 180 Min.").tag(180)
            }.pickerStyle(.menu).frame(width: 260)
            Picker("Stimmung", selection: $mood) {
                Text("Jede Stimmung").tag("")
                ForEach(FilmIndex.allMoods, id: \.self) { Text($0.moodLabel).tag($0) }
            }.pickerStyle(.menu).frame(width: 270)
        }
    }
}

struct TVCatalogView: View {
    var searchMode = false
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var mood = ""
    @State private var sort = "match"
    @State private var genre = ""
    private var films: [Film] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let result = FilmIndex.all.filter { film in
            guard store.activeProfiles.allSatisfy({ $0.allows(film) }), store.kindFilter.allows(film), store.runtimeFilter?.allows(film.runtime) ?? true,
                  mood.isEmpty || film.moods.contains(mood), genre.isEmpty || film.genres.contains(genre) else { return false }
            let text = ([film.title, film.originalTitle, film.director, film.synopsis] + film.cast + film.genres + film.moods).joined(separator: " ").lowercased()
            return terms.allSatisfy(text.contains)
        }
        return result.sorted { a, b in
            if sort == "title" { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if sort == "year" { return a.year == b.year ? a.title < b.title : a.year > b.year }
            if sort == "rating" { return (a.imdbRating ?? 0) > (b.imdbRating ?? 0) }
            return store.recommendation(for: a).match > store.recommendation(for: b).match
        }
    }

    var body: some View {
        TVScreen(title: searchMode ? "Suche" : "Katalog") {
            if searchMode { TextField("Filme, Serien, Menschen", text: $query).frame(maxWidth: 1050) }
            HStack(spacing: 24) {
                TVFilters(mood: $mood)
                Picker("Genre", selection: $genre) {
                    Text("Alle Genres").tag("")
                    ForEach(FilmIndex.allGenres, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).frame(width: 260)
                Picker("Sortieren", selection: $sort) {
                    Text("Passend").tag("match")
                    Text("Titel").tag("title")
                    Text("Neueste").tag("year")
                    Text("IMDb").tag("rating")
                }.pickerStyle(.menu).frame(width: 230)
            }
            Text("\(films.count) Titel").font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary)
            if films.isEmpty {
                TVEmptyState(title: "Keine passenden Titel", message: "Versuche einen kürzeren Suchbegriff oder ändere die Filter.", symbol: "magnifyingglass")
                Button("Suche und Filter zurücksetzen") { query = ""; mood = ""; genre = ""; store.kindFilter = .all; store.runtimeFilter = nil }
            } else { TVFilmGrid(films: films) }
        }
    }
}

struct TVWatchlistView: View {
    @Environment(AppStore.self) private var store
    private var films: [Film] { store.watchlist.filter { film in store.activeProfiles.allSatisfy { $0.allows(film) } } }
    var body: some View {
        TVScreen(title: "Liste") {
            if films.isEmpty {
                TVEmptyState(title: "Noch nichts auf der Merkliste", message: "Merke einen Vorschlag unter „Für dich“ oder entdecke Titel im Katalog.", symbol: "bookmark")
                Button("Katalog öffnen") { store.selectedTab = FilmSection.catalog.rawValue }
            } else { TVFilmGrid(films: films) }
        }
    }
}

struct TVFilmDetailsView: View {
    @Environment(AppStore.self) private var store
    let film: Film
    @State private var playback: PlaybackRequest?
    @State private var plans = false
    @State private var companion: TVCompanionRequest?
    private var allowed: Bool { !store.activeProfiles.isEmpty && store.activeProfiles.allSatisfy { $0.allows(film) } }

    var body: some View {
        TVScreen(title: allowed ? film.title : "Altersfreigabe", subtitle: allowed ? film.metaLine : "", filmHeading: allowed) {
            if !allowed {
                TVEmptyState(title: "Altersfreigabe passt nicht", message: "Dieser Titel ist für mindestens eines der aktiven Profile gesperrt. Wähle im Profilbereich passende Zuschauer.", symbol: "lock")
            } else {
                header
                if !film.trailers.isEmpty {
                    Text("Trailer").font(.system(size: 32, weight: .semibold))
                    HStack(spacing: 28) {
                        ForEach(film.trailers) { trailer in
                            Button { playback = PlaybackRequest(film: film, trailer: trailer, countsAsWatched: false, sourceID: trailer.id) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    AsyncImage(url: trailer.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.3) }
                                        .frame(width: 270, height: 152).clipped()
                                    Text(trailer.title).font(.system(size: 24, weight: .semibold)).lineLimit(2)
                                    Text(trailer.german ? "Deutsch" : "Originalfassung").font(.system(size: 20)).foregroundStyle(.secondary)
                                }.frame(width: 270).padding(12)
                            }.buttonStyle(.card)
                        }
                    }
                }
                if film.isSeries, let seasons = film.seasons {
                    Text("Staffeln & Folgen").font(.system(size: 32, weight: .semibold))
                    ForEach(seasons, id: \.number) { season in
                        Text("Staffel \(season.number)").font(.system(size: 24, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 25)], spacing: 24) {
                            ForEach(season.episodes, id: \.number) { episode in
                                let ref = EpisodeRef(season: season.number, episode: episode.number)
                                Button("\(ref.short) · \(episode.title)") { start(episode: ref) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Text("Der Trailer steht stellvertretend für die gewählte Folge. Erst ein vollständig abgespielter Trailer oder die ausdrückliche Abschlussaktion aktualisiert den Fortschritt.").font(.system(size: 20)).foregroundStyle(.secondary)
                }
                if let voices = film.voices, !voices.isEmpty {
                    Text("Stimmen zum Film").font(.system(size: 32, weight: .semibold))
                    ForEach(voices, id: \.label) { voice in
                        VStack(alignment: .leading, spacing: 12) { Text(voice.label).font(.system(size: 24, weight: .semibold)); Text(voice.text).foregroundStyle(.secondary) }
                    }
                }
                Text("Bewertungen").font(.system(size: 32, weight: .semibold))
                HStack(spacing: 30) {
                    if let rating = film.imdbRating { Button("IMDb \(rating.formatted()) / 10") { external("https://www.imdb.com/title/\(film.imdbID)/", title: "IMDb auf dem iPhone öffnen") } }
                    if let rating = film.rottenTomatoes { Button("Rotten Tomatoes \(rating) %") { external("https://www.rottentomatoes.com/search?search=\(film.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")", title: "Rotten Tomatoes öffnen") } }
                    if let rating = film.metascore { Text("Metascore \(rating) / 100").foregroundStyle(.secondary) }
                }
                ForEach(store.activeProfiles) { profile in
                    if let review = profile.reviews.first(where: { $0.filmID == film.id }) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(profile.name): \(TVRatingView.label(review.rating))").font(.system(size: 24, weight: .semibold))
                            if !review.text.isEmpty { Text(review.text).foregroundStyle(.secondary) }
                        }
                    }
                }
                Button("Eigene Bewertung schreiben") {
                    let pending = store.pendingRatings.first { $0.filmID == film.id } ?? PendingRating(filmID: film.id, profileIDs: store.activeProfileIDs, date: .now)
                    store.ratingToPresent = pending
                }
            }
        }
        .fullScreenCover(item: $playback) { TVPlayerView(request: $0) }
        .sheet(isPresented: $plans) { TVPlanPicker() }
        .sheet(item: $companion) { TVCompanionView(store: store, request: $0) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 60) {
            TVPosterView(film: film, width: 280, height: 420)
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) { MatchRing(match: store.recommendation(for: film).match, size: 64); Text(store.recommendation(for: film).reason).font(.system(size: 24)).foregroundStyle(.secondary) }
                Text(film.synopsis).font(.system(size: 26)).lineSpacing(5).frame(maxWidth: 1000, alignment: .leading)
                Text(film.genres.joined(separator: ", ")).font(.system(size: 24, weight: .semibold)).foregroundStyle(.secondary)
                if !film.director.isEmpty { Text("Regie: \(film.director)").foregroundStyle(.secondary) }
                if !film.cast.isEmpty { Text(film.cast.joined(separator: ", ")).font(.system(size: 20)).foregroundStyle(.secondary) }
                HStack(spacing: 24) {
                    Button { start(episode: store.upNext(film)) } label: { Label(store.playLabel(film), systemImage: "play.fill") }.filmPrimaryAction().disabled(film.comingSoon)
                    Button(store.isOnWatchlist(film) ? "Von Merkliste entfernen" : "Merken") { store.toggleWatchlist(film) }
                    if film.trailers.isEmpty, !film.youtubeID.isEmpty {
                        Button("Trailer") { playback = PlaybackRequest(film: film, countsAsWatched: false, sourceID: film.id) }
                    }
                }
                Text(film.comingSoon ? film.releaseNote ?? "Demnächst verfügbar" : "„Abspielen“ zeigt derzeit einen Trailer, keinen vollständigen Film.").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
    }
    private func start(episode: EpisodeRef?) {
        guard allowed, !film.comingSoon else { return }
        if !store.canPlay { plans = true; return }
        playback = PlaybackRequest(film: film, episode: episode, countsAsWatched: true, sourceID: film.id)
    }
    private func external(_ url: String, title: String) {
        companion = TVCompanionRequest(kind: "externalLink", title: title, filmID: film.id, payload: url)
    }
}

struct TVFilterMenu: View {
    @Environment(AppStore.self) private var store
    @Binding var mood: String
    var body: some View {
        @Bindable var store = store
        Menu {
            Picker("Film oder Serie", selection: $store.kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.title).tag($0) }
            }
            Picker("Zeit", selection: Binding(get: { store.runtimeFilter?.minutes ?? 0 }, set: { store.runtimeFilter = $0 == 0 ? nil : RuntimeFilter(minutes: $0) })) {
                Text("Jede Länge").tag(0)
                Text("Bis 90 Min.").tag(90)
                Text("Bis 120 Min.").tag(120)
                Text("Bis 150 Min.").tag(150)
                Text("Bis 180 Min.").tag(180)
            }
            Picker("Stimmung", selection: $mood) {
                Text("Jede Stimmung").tag("")
                ForEach(FilmIndex.allMoods, id: \.self) { Text($0.moodLabel).tag($0) }
            }
        } label: { Image(systemName: "line.3.horizontal.decrease") }
        .buttonBorderShape(.circle).accessibilityLabel("Film oder Serie, Zeit")
    }
}

/// Same entry, suggestions and search engine as the phone; text input stays native to TV.
struct TVSearchView: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var result: MoodResult?
    @State private var searching = false
    @State private var companion: TVCompanionRequest?
    private let suggestions = ["Was Lustiges unter 2 Stunden", "Düster und spannend", "Filmabend mit Kindern", "Etwas wie Interstellar", "Romantisch, aber nicht kitschig", "Gruselig, mit Twist", "Bildgewaltig und episch", "Gemütlicher Sonntag"]
    var body: some View {
        TVScreen(title: "Suche") {
            HStack(spacing: 24) {
                TextField("Worauf hast du Lust?", text: $text).onSubmit { Task { await search() } }
                    .padding(.horizontal, 18).padding(.vertical, 10).background(.white.opacity(0.08), in: Capsule())
                Button("Suchen", systemImage: "magnifyingglass") { Task { await search() } }
                    .filmPrimaryAction().disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                    .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching ? 0.4 : 1)
            }
            Label(MoodSearch.availabilityNote, systemImage: "text.magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
            if searching { ProgressView("Verstehe deinen Wunsch …") }
            else if let result {
                Text(result.query.summary).font(.system(size: 32, weight: .bold))
                let films = store.activeProfiles.isEmpty ? [] : result.films.map(\.film).filter { film in store.activeProfiles.allSatisfy { $0.allows(film) } }
                if films.isEmpty { TVEmptyState(title: "Nichts Passendes", message: "Versuche es mit einem anderen Wunsch.", symbol: "magnifyingglass") }
                else { TVFilmGrid(films: films) }
            } else {
                Text("Zum Beispiel").font(.system(size: 32, weight: .bold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 24) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { text = suggestion; Task { await search() } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button { companion = TVCompanionRequest(kind: "mood", title: "Worauf hast du Lust?", profileID: store.activeProfileIDs.first) } label: {
                Label("Auf dem iPhone beschreiben", systemImage: "iphone")
            }
        }
        .sheet(item: $companion) { TVCompanionView(store: store, request: $0) }
        .onChange(of: store.companionMoodQuery?.summary) { _, _ in
            if let query = store.companionMoodQuery { result = MoodResult(query: query, films: MoodSearch.rank(query, profiles: store.activeProfiles), usedAppleIntelligence: false) }
        }
    }
    private func search() async {
        guard !searching else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searching = true; defer { searching = false }
        result = await MoodSearch.search(query, profiles: store.activeProfiles)
    }
}
