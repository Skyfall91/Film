import SwiftUI

/// Der Film-Guide: alle Titel finden, filtern, merken, und von dort zu den Diensten springen,
/// auf denen sie laufen. Abspielen gehört nicht dazu.
struct GuideRoot: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        Group {
            if store.onboarded {
                GuideTabs()
                    .transition(.opacity)
            } else {
                GuideOnboarding()
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: store.onboarded)
    }
}

struct GuideTabs: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        TabView(selection: Bindable(store).selectedTab) {
            Tab("Für dich", systemImage: "sparkles.tv.fill", value: GuideTab.discover) {
                NavigationStack { GuideDiscoverView().guideDestinations() }
            }
            Tab("Stöbern", systemImage: "square.grid.2x2.fill", value: GuideTab.all) {
                NavigationStack { GuideAllView().guideDestinations() }
            }
            Tab("Merkliste", systemImage: "bookmark.fill", value: GuideTab.watchlist) {
                NavigationStack { GuideWatchlistView().guideDestinations() }
            }
            Tab("Suche", systemImage: "magnifyingglass", value: GuideTab.search, role: .search) {
                NavigationStack { GuideSearchView().guideDestinations() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

// MARK: - Anzeige-Helfer

extension Film {
    /// IMDb bei kuratierten Titeln, sonst TMDB.
    var guideRating: Double? { imdbRating ?? tmdbRating }
    var isCurated: Bool { FilmIndex.byID[id] != nil }

    /// „2021 · 2 Std. 35 Min.“, ohne unbekannte Angaben.
    var guideMeta: String {
        var parts: [String] = []
        if year > 0 { parts.append(yearText) }
        if isSeries {
            if totalSeasons != nil || seasons != nil { parts.append(seasonsText) } else { parts.append("Serie") }
        } else if runtime > 0 {
            parts.append(runtimeText)
        }
        return parts.joined(separator: " · ")
    }

    /// Erster Satz der Beschreibung (ohne Redaktionszeile).
    var guideTeaser: String {
        let text = synopsis.withoutDashes
        guard let end = text.firstMatch(of: /[.!?](\s|$)/) else { return text }
        let sentence = String(text[..<end.range.lowerBound]) + String(text[end.range.lowerBound])
        return sentence.count >= 40 ? sentence : text
    }
}

// MARK: - Navigation

/// Eine Liste von Titeln unter eigener Überschrift („Alle Thriller“, „Mit Zendaya“).
struct GuideList: Hashable {
    let title: String
    let ids: [String]
    var films: [Film] { ids.compactMap(FilmIndex.film) }
}

struct GuidePerson: Hashable {
    let name: String
}

extension View {
    func guideDestinations() -> some View {
        navigationDestination(for: Film.self) { GuideDetailView(film: $0) }
            .navigationDestination(for: GuideList.self) { list in
                ScrollView { GuideGrid(films: list.films).padding(.horizontal, 16).padding(.vertical, 12) }
                    .background(Theme.background)
                    .navigationTitle(list.title)
            }
            .navigationDestination(for: GuidePerson.self) { GuidePersonView(name: $0.name) }
    }
}

// MARK: - Kacheln

struct GuideTile: View {
    @Environment(GuideStore.self) private var store
    let film: Film
    var width: CGFloat? = nil

    var body: some View {
        NavigationLink(value: film) {
            VStack(alignment: .leading, spacing: 6) {
                PosterView(film: film, cornerRadius: 12)
                    .overlay(alignment: .topTrailing) {
                        if store.isSeen(film) {
                            badge("checkmark")
                        } else if store.isSaved(film) {
                            badge("bookmark.fill")
                        } else if store.isLiked(film) {
                            badge("heart.fill")
                        }
                    }
                Text(film.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if film.year > 0 { Text(film.yearText) }
                    if film.isSeries { Text("Serie") }
                    if let rating = film.guideRating {
                        Label { Text(rating, format: .number.precision(.fractionLength(1))) } icon: { Image(systemName: "star.fill") }
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(width: width)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("guide.tile.\(film.id)")
        .contextMenu {
            Button(store.isSaved(film) ? "Von Merkliste entfernen" : "Merken",
                   systemImage: store.isSaved(film) ? "bookmark.slash" : "bookmark") { store.toggleSaved(film) }
            Button(store.isLiked(film) ? "Mag ich nicht mehr" : "Mag ich",
                   systemImage: store.isLiked(film) ? "heart.slash" : "heart") { store.toggleLiked(film) }
            Button(store.isSeen(film) ? "Nicht gesehen" : "Gesehen",
                   systemImage: store.isSeen(film) ? "eye.slash" : "eye") { store.toggleSeen(film) }
            if let google = WatchLinks.google(film) {
                Link(destination: google) { Label("Wo läuft das?", systemImage: "play.tv") }
            }
        } preview: {
            PosterView(film: film, cornerRadius: 0, showsBadge: false).frame(width: 260)
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.black)
            .frame(width: 24, height: 24)
            .background(Color.white, in: .circle)
            .padding(6)
    }
}

struct GuideGrid: View {
    let films: [Film]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 18) {
            ForEach(films) { GuideTile(film: $0) }
        }
    }
}

struct GuideSectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

struct GuideShelf: View {
    let title: String
    var subtitle: String? = nil
    let films: [Film]

    var body: some View {
        if !films.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(value: GuideList(title: title, ids: films.map(\.id))) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.title3.weight(.bold))
                            if let subtitle {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("Alle").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(films.prefix(20)) { GuideTile(film: $0, width: 120) }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// Reihe aus dem Online-Katalog, lädt beim ersten Erscheinen.
struct GuideOnlineShelf: View {
    @Environment(GuideStore.self) private var store
    let title: String
    var subtitle: String? = nil
    let load: @MainActor () async -> [Film]
    @State private var films: [Film] = []

    var body: some View {
        GuideShelf(title: title, subtitle: subtitle, films: films)
            .task(id: store.tmdbKey) {
                let loaded = await load()
                withAnimation(.smooth) { films = loaded }
            }
    }
}

// MARK: - Für dich (Startseite)

struct GuideDiscoverView: View {
    @Environment(GuideStore.self) private var store
    @State private var showSettings = false

    private static let released = FilmIndex.all.filter { !$0.comingSoon }
    private static let topFilms = GuideCatalog.byRating(released.filter { !$0.isSeries })
    private static let topSeries = GuideCatalog.byRating(released.filter(\.isSeries))
    private static let newest = released.filter { $0.year >= 2023 }.sorted { ($0.year, $0.imdbRating ?? 0) > ($1.year, $1.imdbRating ?? 0) }
    private static let comingSoon = FilmIndex.all.filter(\.comingSoon)
    private static let hiddenGems = GuideCatalog.byRating(released.filter(\.niche))
    private static let family = GuideCatalog.byRating(released.filter { $0.fsk <= 6 && ($0.genres.contains("Animation") || $0.genres.contains("Familie")) })
    private static let short = GuideCatalog.byRating(released.filter { !$0.isSeries && $0.runtime <= 95 })
    private static let genres: [String] = {
        var counts: [String: Int] = [:]
        for film in released { for genre in film.genres { counts[genre, default: 0] += 1 } }
        return counts.filter { $0.value >= 15 }.sorted { $0.value > $1.value }.map(\.key)
    }()
    static let moods = ["spannend", "lustig", "gefühlvoll", "gruselig", "nachdenklich", "gemütlich", "wendungsreich", "bildgewaltig",
                        "romantisch", "episch", "leicht", "schräg"]
        .filter { mood in FilmIndex.all.contains { $0.moods.contains(mood) } }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<11: "Guten Morgen"
        case 11..<17: "Hallo"
        case 17..<22: "Guten Abend"
        default: "Noch wach?"
        }
    }

    /// Lieblingsgenres zuerst.
    private var orderedGenres: [String] {
        Self.genres.filter { store.likedGenres.contains($0) } + Self.genres.filter { !store.likedGenres.contains($0) }
    }

    var body: some View {
        let picks = store.todaysPicks()
        let forYou = store.forYou()
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("Heute für dich ausgesucht")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                GuideTodayCarousel(films: picks)

                GuideMoodTiles()

                GuideShelf(title: "Für dich", subtitle: store.liked.isEmpty ? "Die besten Titel im Guide" : "Passend zu dem, was du magst",
                           films: forYou.filter { film in !picks.contains { $0.id == film.id } })
                if let because = store.becauseYouLiked() {
                    GuideShelf(title: "Weil du „\(because.film.title)“ magst", films: because.matches)
                }
                GuideOnlineShelf(title: "Gerade beliebt", subtitle: "Was diese Woche viele schauen") {
                    await OnlineCatalog.trending()
                }
                GuideShelf(title: "Neu", films: Self.newest)
                GuideShelf(title: "Am besten bewertet", films: Self.topFilms)
                GuideShelf(title: "Serien", films: Self.topSeries)
                GuideShelf(title: "Demnächst", films: Self.comingSoon)
                ForEach(orderedGenres, id: \.self) { genre in
                    GuideShelf(title: genre, films: GuideCatalog.byRating(Self.released.filter { $0.genres.contains(genre) }))
                }
                GuideShelf(title: "Für die ganze Familie", films: Self.family)
                GuideShelf(title: "Unter 95 Minuten", films: Self.short)
                GuideShelf(title: "Geheimtipps", subtitle: "Kennen vor allem Filmfans", films: Self.hiddenGems)

                Button {
                    store.selectedTab = .all
                } label: {
                    Label("Alle Filme durchstöbern", systemImage: "square.grid.2x2")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
                .buttonStyle(.glass)
                .padding(.horizontal, 16)

                GuideSourcesFooter()
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Einstellungen", systemImage: "slider.horizontal.3") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { GuideSettingsSheet() }
    }
}

/// Große Karten „Heute für dich“, eine pro Bildschirmbreite, mit Blick auf die nächste.
struct GuideTodayCarousel: View {
    let films: [Film]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(films) { film in
                    NavigationLink(value: film) { card(film) }
                        .buttonStyle(.plain)
                        .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.78, 360) }
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                .opacity(phase.isIdentity ? 1 : 0.7)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
    }

    private func card(_ film: Film) -> some View {
        PosterView(film: film, cornerRadius: 26, showsBadge: false)
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(film.genres.prefix(2), id: \.self) { genre in
                            Text(genre)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: .capsule)
                        }
                        Spacer()
                        if let rating = film.guideRating {
                            Label { Text(rating, format: .number.precision(.fractionLength(1))) } icon: { Image(systemName: "star.fill") }
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: .capsule)
                        }
                    }
                    Text(film.title)
                        .font(Theme.recommendationTitle(size: 28))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(film.guideTeaser)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
                .foregroundStyle(Color.white)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.clear, .black.opacity(0.75), .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(.rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            .accessibilityElement(children: .combine)
    }
}

/// „Worauf hast du Lust?“: Stimmungen als farbige Kacheln.
struct GuideMoodTiles: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GuideSectionHeader(title: "Worauf hast du Lust?")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(64), spacing: 10), GridItem(.fixed(64), spacing: 10)], spacing: 10) {
                    ForEach(GuideDiscoverView.moods, id: \.self) { mood in
                        NavigationLink(value: GuideList(title: mood.moodLabel,
                                                        ids: GuideCatalog.byRating(FilmIndex.all.filter { $0.moods.contains(mood) && !$0.comingSoon }).map(\.id))) {
                            tile(mood)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }

    private func tile(_ mood: String) -> some View {
        let color = GuideStyle.moodColor(mood)
        return HStack(spacing: 10) {
            Image(systemName: GuideStyle.moodSymbol(mood))
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(mood.moodLabel)
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 150, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [color.opacity(0.32), color.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 18)
        )
        .contentShape(.rect)
    }
}

struct GuideSourcesFooter: View {
    var body: some View {
        Text(OnlineCatalog.usesTMDB
             ? "Wertungen: IMDb und TMDB. Weitere Titel und Verfügbarkeiten von TMDB und JustWatch. Dieses Produkt nutzt die TMDB-API, ist aber nicht von TMDB unterstützt oder zertifiziert."
             : "Wertungen: IMDb. Weitere Titel aus dem iTunes Store. Verfügbarkeiten sucht der Guide live bei Google, JustWatch und den Diensten.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
    }
}

// MARK: - Stöbern

struct GuideAllView: View {
    @Environment(GuideStore.self) private var store
    @State private var filter = GuideFilter()
    @State private var scope = Scope.everything
    @State private var onlyMyServices = false

    enum Scope: String, CaseIterable, Identifiable {
        case everything = "Alle Filme", curated = "Handverlesen"
        var id: String { rawValue }
    }

    private var online: OnlineBrowse {
        OnlineBrowse(kind: filter.kind, genre: filter.genre, decade: filter.decade, maxRuntime: filter.maxRuntime,
                     maxFSK: filter.maxFSK, sort: filter.sort,
                     providerIDs: onlyMyServices ? store.serviceTMDBIDs : [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Auswahl", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                filterBar

                switch scope {
                case .curated:
                    curated
                case .everything:
                    GuideOnlineGrid(request: online, sourceKey: store.tmdbKey, hideSeen: filter.hideSeen)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.background)
        .navigationTitle("Stöbern")
        .animation(.smooth, value: filter)
        .animation(.smooth, value: scope)
        .onChange(of: scope) { _, new in
            // Stimmungen kennt nur der handverlesene Katalog.
            if new == .everything { filter.mood = nil }
        }
    }

    @ViewBuilder private var curated: some View {
        let films = filter.apply(FilmIndex.all, seen: store.seen)
        Text(films.count == 1 ? "1 handverlesener Titel" : "\(films.count) handverlesene Titel")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        if films.isEmpty {
            ContentUnavailableView {
                Label("Nichts gefunden", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Mit diesen Filtern gibt es keinen Titel.")
            } actions: {
                Button("Filter zurücksetzen") { filter = GuideFilter(sort: filter.sort) }
            }
        } else {
            GuideGrid(films: films).padding(.horizontal, 16)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sortierung", selection: $filter.sort) {
                        ForEach(GuideFilter.Sort.allCases.filter { scope == .curated || $0 != .shortest }) { Text($0.rawValue).tag($0) }
                    }
                } label: { chip(filter.sort.rawValue, active: false, symbol: "arrow.up.arrow.down") }

                if scope == .everything && OnlineCatalog.usesTMDB && !store.services.isEmpty {
                    Button { onlyMyServices.toggle() } label: {
                        chip("Auf meinen Diensten", active: onlyMyServices, symbol: "tv")
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Picker("Art", selection: $filter.kind) {
                        ForEach(GuideFilter.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { chip(filter.kind.rawValue, active: filter.kind != .all) }

                Menu {
                    Picker("Genre", selection: $filter.genre) {
                        Text("Alle Genres").tag(String?.none)
                        ForEach(scope == .curated ? FilmIndex.allGenres : GuideFilter.onlineGenres, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                } label: { chip(filter.genre ?? "Genre", active: filter.genre != nil) }

                if scope == .curated {
                    Menu {
                        Picker("Stimmung", selection: $filter.mood) {
                            Text("Jede Stimmung").tag(String?.none)
                            ForEach(FilmIndex.allMoods, id: \.self) { Text($0.moodLabel).tag(Optional($0)) }
                        }
                    } label: { chip(filter.mood?.moodLabel ?? "Stimmung", active: filter.mood != nil) }
                }

                Menu {
                    Picker("Jahrzehnt", selection: $filter.decade) {
                        Text("Alle Jahre").tag(Int?.none)
                        ForEach(scope == .curated ? GuideFilter.decades : GuideFilter.onlineDecades, id: \.self) { Text("\(String($0))er").tag(Optional($0)) }
                    }
                } label: { chip(filter.decade.map { "\(String($0))er" } ?? "Jahrzehnt", active: filter.decade != nil) }

                Menu {
                    Picker("Länge", selection: $filter.maxRuntime) {
                        Text("Jede Länge").tag(Int?.none)
                        ForEach(GuideFilter.runtimes, id: \.self) { Text("Bis \($0) Min.").tag(Optional($0)) }
                    }
                } label: { chip(filter.maxRuntime.map { "Bis \($0) Min." } ?? "Länge", active: filter.maxRuntime != nil) }

                Menu {
                    Picker("Alter", selection: $filter.maxFSK) {
                        Text("Alle Altersstufen").tag(Int?.none)
                        ForEach(GuideFilter.fskLevels, id: \.self) { Text("Bis FSK \($0)").tag(Optional($0)) }
                    }
                } label: { chip(filter.maxFSK.map { "Bis FSK \($0)" } ?? "Alter", active: filter.maxFSK != nil) }

                Button { filter.hideSeen.toggle() } label: {
                    chip("Gesehene ausblenden", active: filter.hideSeen)
                }
                .buttonStyle(.plain)

                if filter.isActive || onlyMyServices {
                    Button {
                        filter = GuideFilter(sort: filter.sort)
                        onlyMyServices = false
                    } label: {
                        chip("Zurücksetzen", active: false, symbol: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }

    private func chip(_ text: String, active: Bool, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
            Text(text)
            if symbol == nil { Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.6) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(active ? Color.black : Color.white)
        .padding(.horizontal, 14).frame(height: 36)
        .background(active ? Color.white : Color.white.opacity(0.12), in: .capsule)
    }
}

/// Alle Filme aus dem Online-Katalog zu einer Anfrage, Seite für Seite beim Scrollen.
struct GuideOnlineGrid: View {
    @Environment(GuideStore.self) private var store
    let request: OnlineBrowse
    /// Wechselt der TMDB-Schlüssel, wird neu geladen.
    let sourceKey: String
    var hideSeen = false

    private struct LoadID: Hashable {
        let request: OnlineBrowse
        let sourceKey: String
    }

    @State private var films: [Film] = []
    @State private var page = 0
    @State private var loading = false
    @State private var finished = false
    @State private var failed = false

    var body: some View {
        let shown = hideSeen ? films.filter { !store.isSeen($0) } : films
        VStack(alignment: .leading, spacing: 14) {
            if !shown.isEmpty {
                GuideGrid(films: shown).padding(.horizontal, 16)
            }
            if failed && films.isEmpty {
                ContentUnavailableView {
                    Label("Keine Verbindung", systemImage: "wifi.slash")
                } description: {
                    Text("Alle Filme kommen aus dem Netz. Die handverlesenen Titel gehen auch offline.")
                } actions: {
                    Button("Nochmal versuchen") { Task { await reload() } }
                }
            } else if finished && films.isEmpty {
                ContentUnavailableView("Nichts gefunden", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Zu diesen Filtern gibt es online keine Titel."))
            }
            if !finished {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 60)
                .onAppear { Task { await loadMore() } }
            } else if !films.isEmpty {
                Text(OnlineCatalog.usesTMDB ? "Ende der Liste" : "Ohne TMDB-Schlüssel zeigt Stöbern die Bestenlisten des iTunes Store. Über die Suche findest du trotzdem jeden Film.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .task(id: LoadID(request: request, sourceKey: sourceKey)) { await reload() }
    }

    private func reload() async {
        films = []
        page = 0
        finished = false
        failed = false
        loading = false
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !finished else { return }
        loading = true
        let next = page + 1
        let current = request
        let batch = await OnlineCatalog.browse(current, page: next)
        loading = false
        // Inzwischen andere Filter gewählt: Ergebnis verwerfen.
        guard current == request else { return }
        if batch.isEmpty {
            finished = true
            failed = next == 1
            return
        }
        page = next
        let known = Set(films.map(\.id))
        films += batch.filter { !known.contains($0.id) }
        // Mehr als 25 Seiten (500 Titel) lädt TMDB pro Anfrage nicht aus, iTunes hat nur eine Seite.
        if !OnlineCatalog.usesTMDB || next >= 25 { finished = true }
    }
}

// MARK: - Suche

struct GuideSearchView: View {
    @Environment(GuideStore.self) private var store
    @State private var text = ""
    @State private var online: [Film] = []
    @State private var searching = false

    private static let suggestions = ["Christopher Nolan", "Zeitreise", "Komödie", "gruselig", "Animation", "Tom Hanks",
                                      "Harry Potter", "Science-Fiction", "1990", "Pixar"]

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let films = GuideCatalog.search(trimmed)
        let curatedIDs = Set(films.map(\.id))
        let more = online.filter { !curatedIDs.contains($0.id) }
        let people = GuideCatalog.people(matching: trimmed)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Suche in allen Filmen und Serien: nach Titel, Regie, Besetzung, Genre, Stimmung oder Jahr.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        WrapLayout(spacing: 8) {
                            ForEach(Self.suggestions, id: \.self) { suggestion in
                                Button(suggestion) { text = suggestion }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).frame(height: 36)
                                    .background(Color.white.opacity(0.12), in: .capsule)
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Personen").font(.headline)
                            ForEach(people, id: \.self) { name in
                                NavigationLink(value: GuidePerson(name: name)) {
                                    HStack {
                                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
                                        Text(name)
                                        Spacer()
                                        Text("\(GuideCatalog.films(with: name).count)").foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    if !films.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(films.count == 1 ? "Im Guide · 1 Titel" : "Im Guide · \(films.count) Titel").font(.headline)
                            GuideGrid(films: films)
                        }
                        .padding(.horizontal, 16)
                    }
                    if !more.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Alle weiteren Filme und Serien").font(.headline)
                            GuideGrid(films: more)
                        }
                        .padding(.horizontal, 16)
                    } else if searching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Suche in allen Filmen …").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                    if films.isEmpty && people.isEmpty && more.isEmpty && !searching {
                        ContentUnavailableView {
                            Label("Nichts gefunden", systemImage: "magnifyingglass")
                        } description: {
                            Text("Zu „\(trimmed)“ gibt es keinen Titel. Vielleicht anders geschrieben?")
                        } actions: {
                            if let url = WatchLinks.url("https://www.google.com/search", ["q": "\(trimmed) Film stream"]) {
                                Link("Bei Google suchen", destination: url)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Suche")
        .searchable(text: $text, prompt: "Filme, Serien, Personen …")
        .autocorrectionDisabled()
        .task(id: "\(trimmed)|\(store.tmdbKey)") {
            online = []
            guard trimmed.count >= 2 else { searching = false; return }
            searching = true
            // Erst suchen, wenn das Tippen kurz pausiert.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let found = await OnlineCatalog.search(trimmed)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                online = found
                searching = false
            }
        }
    }
}

// MARK: - Person

struct GuidePersonView: View {
    let name: String

    var body: some View {
        let films = GuideCatalog.films(with: name)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url = WatchLinks.person(name) {
                    Link(destination: url) {
                        Label("Alle Filme mit \(name) bei Google", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                GuideGrid(films: films)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle(name)
    }
}

// MARK: - Merkliste

struct GuideWatchlistView: View {
    @Environment(GuideStore.self) private var store
    @State private var list = WatchList.saved

    enum WatchList: String, CaseIterable, Identifiable {
        case saved = "Merkliste", liked = "Mag ich", seen = "Gesehen"
        var id: String { rawValue }
    }

    var body: some View {
        let films = currentFilms
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Liste", selection: $list) {
                    ForEach(WatchList.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if films.isEmpty {
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: emptySymbol)
                    } description: {
                        Text(emptyText)
                    } actions: {
                        Button("Titel entdecken") { store.selectedTab = .discover }
                    }
                    .padding(.top, 40)
                } else {
                    GuideGrid(films: films).padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Theme.background)
        .navigationTitle(list.rawValue)
    }

    private var currentFilms: [Film] {
        switch list {
        case .saved: store.savedFilms
        case .liked: store.likedFilms
        case .seen: store.seenFilms
        }
    }

    private var emptyTitle: String {
        switch list {
        case .saved: "Noch nichts gemerkt"
        case .liked: "Noch keine Lieblinge"
        case .seen: "Noch nichts gesehen"
        }
    }

    private var emptySymbol: String {
        switch list {
        case .saved: "bookmark"
        case .liked: "heart"
        case .seen: "eye"
        }
    }

    private var emptyText: String {
        switch list {
        case .saved: "Tippe auf einer Titelseite auf „Merken“, dann landet er hier."
        case .liked: "Mit dem Herz auf einer Titelseite werden deine Vorschläge besser."
        case .seen: "Markiere Titel auf ihrer Seite als gesehen."
        }
    }
}

// MARK: - Einstellungen

struct GuideSettingsSheet: View {
    @Environment(GuideStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section("Geschmack") {
                    NavigationLink {
                        GuideServicesList()
                    } label: {
                        LabeledContent("Meine Dienste", value: store.services.isEmpty ? "Keine" : "\(store.services.count)")
                    }
                    NavigationLink {
                        GuideGenresList()
                    } label: {
                        LabeledContent("Lieblingsgenres", value: store.likedGenres.isEmpty ? "Keine" : "\(store.likedGenres.count)")
                    }
                    Button("Kennenlernen neu starten", role: .destructive) { confirmReset = true }
                }

                Section {
                    LabeledContent("Quelle", value: OnlineCatalog.usesTMDB ? "TMDB, mit Verfügbarkeit" : "iTunes Store")
                    SecureField("TMDB-API-Schlüssel", text: $store.tmdbKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let url = URL(string: "https://www.themoviedb.org/settings/api") {
                        Link("Kostenlosen Schlüssel bei TMDB holen", destination: url)
                    }
                } header: {
                    Text("Alle Filme")
                } footer: {
                    Text("Ohne Schlüssel findet der Guide jeden Film, den es im iTunes Store gibt. Mit einem kostenlosen TMDB-Schlüssel kommen über eine Million Filme und Serien dazu, und jede Titelseite zeigt, bei welchem Dienst er gerade im Abo läuft.")
                }

                Section("Quellen") {
                    Text("Filmdaten und Verfügbarkeit: TMDB und JustWatch. Dieses Produkt nutzt die TMDB-API, ist aber nicht von TMDB unterstützt oder zertifiziert.")
                    Text("Weitere Titel ohne Schlüssel: iTunes Search API von Apple.")
                    Text("Wertungen der handverlesenen Titel: OMDb (CC BY-NC 4.0). Geschmacksdaten: MovieLens, GroupLens Research.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .confirmationDialog("Kennenlernen neu starten?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Neu starten", role: .destructive) {
                    dismiss()
                    store.resetPreferences()
                }
            } message: {
                Text("Lieblingsgenres und „Mag ich“ werden zurückgesetzt. Merkliste und Gesehenes bleiben.")
            }
        }
    }
}

struct GuideServicesList: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(WatchProvider.allCases) { provider in
                    Button { store.toggleService(provider) } label: {
                        HStack(spacing: 12) {
                            GuideProviderMark(provider: provider, size: 32)
                            VStack(alignment: .leading) {
                                Text(provider.name).foregroundStyle(.primary)
                                Text(provider.kindNote).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.services.contains(provider) {
                                Image(systemName: "checkmark").font(.body.weight(.semibold))
                            }
                        }
                    }
                    .accessibilityAddTraits(store.services.contains(provider) ? .isSelected : [])
                }
            } footer: {
                Text("Deine Dienste stehen auf jeder Titelseite oben.")
            }
        }
        .navigationTitle("Meine Dienste")
    }
}

struct GuideGenresList: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        List {
            ForEach(FilmIndex.allGenres, id: \.self) { genre in
                Button { store.toggleGenre(genre) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: GuideStyle.genreSymbol(genre))
                            .foregroundStyle(GuideStyle.genreColor(genre))
                            .frame(width: 28)
                        Text(genre).foregroundStyle(.primary)
                        Spacer()
                        if store.likedGenres.contains(genre) {
                            Image(systemName: "checkmark").font(.body.weight(.semibold))
                        }
                    }
                }
            }
        }
        .navigationTitle("Lieblingsgenres")
    }
}

/// Für die Titelseite: nur die Dienste wählen, in einem eigenen Blatt.
struct GuideServicesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GuideServicesList()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
    }
}

struct GuideProviderMark: View {
    let provider: WatchProvider
    var size: CGFloat = 36

    var body: some View {
        Text(provider.monogram)
            .font(.system(size: size * 0.4, weight: .heavy, design: .rounded))
            .foregroundStyle(provider == .appleTV ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(provider.color, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}
