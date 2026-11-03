import SwiftUI

/// Der Film-Guide: alle Titel finden, filtern, merken, und von dort zu den Diensten springen,
/// auf denen sie laufen. Abspielen gehört nicht dazu.
struct GuideRoot: View {
    @Environment(GuideStore.self) private var store

    var body: some View {
        TabView(selection: Bindable(store).selectedTab) {
            Tab("Entdecken", systemImage: "sparkles.tv.fill", value: GuideTab.discover) {
                NavigationStack { GuideDiscoverView().guideDestinations() }
            }
            Tab("Alle Titel", systemImage: "square.grid.2x2.fill", value: GuideTab.all) {
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
                        }
                    }
                Text(film.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(film.yearText)
                    if film.isSeries { Text("Serie") }
                    if let rating = film.imdbRating {
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
            Button(store.isSeen(film) ? "Nicht gesehen" : "Gesehen",
                   systemImage: store.isSeen(film) ? "eye.slash" : "eye") { store.toggleSeen(film) }
            if let google = WatchLinks.google(film) {
                Link(destination: google) { Label("Wo läuft das?", systemImage: "play.tv") }
            }
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .frame(width: 24, height: 24)
            .background(.white, in: .circle)
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

struct GuideShelf: View {
    let title: String
    let films: [Film]

    var body: some View {
        if !films.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink(value: GuideList(title: title, ids: films.map(\.id))) {
                    HStack(spacing: 4) {
                        Text(title).font(.title3.weight(.bold))
                        Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        Spacer()
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

// MARK: - Entdecken

struct GuideDiscoverView: View {
    @Environment(GuideStore.self) private var store
    @State private var showServices = false

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
    private static let moods = ["spannend", "lustig", "gefühlvoll", "gruselig", "nachdenklich", "gemütlich", "wendungsreich", "bildgewaltig"]
        .filter { mood in released.contains { $0.moods.contains(mood) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("\(FilmIndex.all.count) Filme und Serien. Tippe einen Titel an, um zu sehen, wo er läuft.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                moodChips

                GuideShelf(title: "Am besten bewertet", films: Self.topFilms)
                GuideShelf(title: "Neu", films: Self.newest)
                GuideShelf(title: "Serien", films: Self.topSeries)
                GuideShelf(title: "Demnächst", films: Self.comingSoon)
                ForEach(Self.genres, id: \.self) { genre in
                    GuideShelf(title: genre, films: GuideCatalog.byRating(Self.released.filter { $0.genres.contains(genre) }))
                }
                GuideShelf(title: "Für die ganze Familie", films: Self.family)
                GuideShelf(title: "Unter 95 Minuten", films: Self.short)
                GuideShelf(title: "Geheimtipps", films: Self.hiddenGems)

                Text("Wertungen: IMDb. Verfügbarkeit ändert sich ständig, darum sucht der Guide sie live bei Google, JustWatch und den Diensten.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Film-Guide")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Meine Dienste", systemImage: "tv.badge.wifi") { showServices = true }
            }
        }
        .sheet(isPresented: $showServices) { GuideServicesSheet() }
    }

    private var moodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.moods, id: \.self) { mood in
                    NavigationLink(value: GuideList(title: mood.moodLabel,
                                                    ids: GuideCatalog.byRating(Self.released.filter { $0.moods.contains(mood) }).map(\.id))) {
                        Text(mood.moodLabel)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 36)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Alle Titel

struct GuideAllView: View {
    @Environment(GuideStore.self) private var store
    @State private var filter = GuideFilter()

    var body: some View {
        let films = filter.apply(FilmIndex.all, seen: store.seen)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                filterBar
                Text(films.count == 1 ? "1 Titel" : "\(films.count) Titel")
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
            .padding(.vertical, 8)
        }
        .background(Theme.background)
        .navigationTitle("Alle Titel")
        .animation(.smooth, value: filter)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sortierung", selection: $filter.sort) {
                        ForEach(GuideFilter.Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { chip(filter.sort.rawValue, active: false, symbol: "arrow.up.arrow.down") }

                Menu {
                    Picker("Art", selection: $filter.kind) {
                        ForEach(GuideFilter.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: { chip(filter.kind.rawValue, active: filter.kind != .all) }

                Menu {
                    Picker("Genre", selection: $filter.genre) {
                        Text("Alle Genres").tag(String?.none)
                        ForEach(FilmIndex.allGenres, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                } label: { chip(filter.genre ?? "Genre", active: filter.genre != nil) }

                Menu {
                    Picker("Stimmung", selection: $filter.mood) {
                        Text("Jede Stimmung").tag(String?.none)
                        ForEach(FilmIndex.allMoods, id: \.self) { Text($0.moodLabel).tag(Optional($0)) }
                    }
                } label: { chip(filter.mood?.moodLabel ?? "Stimmung", active: filter.mood != nil) }

                Menu {
                    Picker("Jahrzehnt", selection: $filter.decade) {
                        Text("Alle Jahre").tag(Int?.none)
                        ForEach(GuideFilter.decades, id: \.self) { Text("\(String($0))er").tag(Optional($0)) }
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

                if filter.isActive {
                    Button { filter = GuideFilter(sort: filter.sort) } label: {
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

// MARK: - Suche

struct GuideSearchView: View {
    @State private var text = ""

    private static let suggestions = ["Christopher Nolan", "Zeitreise", "Komödie", "gruselig", "Animation", "Tom Hanks", "Science-Fiction", "1990"]

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let films = GuideCatalog.search(trimmed)
        let people = GuideCatalog.people(matching: trimmed)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Suche nach Titel, Regie, Besetzung, Genre, Stimmung oder Jahr.")
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
                    if films.isEmpty && people.isEmpty {
                        ContentUnavailableView {
                            Label("Nicht im Guide", systemImage: "magnifyingglass")
                        } description: {
                            Text("„\(trimmed)“ ist nicht unter den \(FilmIndex.all.count) Titeln.")
                        } actions: {
                            if let url = WatchLinks.url("https://www.google.com/search", ["q": "\(trimmed) stream"]) {
                                Link("Bei Google suchen", destination: url)
                            }
                        }
                    } else if !films.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(films.count == 1 ? "1 Titel" : "\(films.count) Titel").font(.headline)
                            GuideGrid(films: films)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Suche")
        .searchable(text: $text, prompt: "Titel, Person, Genre …")
        .autocorrectionDisabled()
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
                        Label("Mehr über \(name) bei Google", systemImage: "arrow.up.right")
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
    @State private var showSeen = false

    var body: some View {
        let films = showSeen ? store.seenFilms : store.savedFilms
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Liste", selection: $showSeen) {
                    Text("Merkliste").tag(false)
                    Text("Gesehen").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                if films.isEmpty {
                    ContentUnavailableView {
                        Label(showSeen ? "Noch nichts gesehen" : "Noch nichts gemerkt",
                              systemImage: showSeen ? "eye" : "bookmark")
                    } description: {
                        Text(showSeen ? "Markiere Titel auf ihrer Seite als gesehen."
                                      : "Tippe auf einer Titelseite auf „Merken“, dann landet er hier.")
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
        .navigationTitle(showSeen ? "Gesehen" : "Merkliste")
    }
}

// MARK: - Meine Dienste

struct GuideServicesSheet: View {
    @Environment(GuideStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
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
