import SwiftUI

/// Alles, was sich der Guide merkt: Vorlieben aus dem Onboarding, Merkliste, Gesehenes und die eigenen Dienste.
/// Kein Konto, kein Abo, kein Abgleich: Die Daten bleiben auf dem Gerät.
@Observable
final class GuideStore {
    @ObservationIgnored private let defaults: UserDefaults

    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    /// Neueste zuerst.
    var watchlist: [String] { didSet { defaults.set(watchlist, forKey: Keys.watchlist); storeOnline() } }
    var seen: Set<String> { didSet { defaults.set(Array(seen), forKey: Keys.seen); storeOnline(); invalidateSuggestions() } }
    /// Filme, die man mag (Onboarding und Herz auf der Titelseite). Daraus entsteht „Für dich“.
    var liked: [String] { didSet { defaults.set(liked, forKey: Keys.liked); storeOnline(); invalidateSuggestions() } }
    var likedGenres: Set<String> { didSet { defaults.set(Array(likedGenres), forKey: Keys.likedGenres); invalidateSuggestions() } }
    /// Diese Dienste stehen auf den Detailseiten oben.
    var services: Set<WatchProvider> { didSet { defaults.set(services.map(\.rawValue), forKey: Keys.services) } }
    /// Eigener TMDB-Schlüssel: schaltet die TMDB mit Verfügbarkeiten frei (sonst iTunes).
    var tmdbKey: String { didSet { defaults.set(tmdbKey, forKey: Keys.tmdbKey) } }
    var selectedTab: GuideTab = .discover

    /// Vorschläge hängen nur an Vorlieben und Gesehenem: einmal rechnen, bis sich davon etwas ändert,
    /// statt bei jedem Neuzeichnen der Startseite alle Titel zu bewerten.
    @ObservationIgnored private var forYouCache: [Int: [Film]] = [:]
    @ObservationIgnored private var picksCache: (day: Int, films: [Film])?
    @ObservationIgnored private var becauseCache: (day: Int, value: (film: Film, matches: [Film])?)?

    private func invalidateSuggestions() {
        forYouCache = [:]
        picksCache = nil
        becauseCache = nil
    }

    /// Liest die Vorlieben, damit Ansichten auch bei einem Treffer im Zwischenspeicher davon abhängen.
    private func observePreferences() {
        _ = liked
        _ = likedGenres
        _ = seen
    }

    private static var today: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    private enum Keys {
        static let onboarded = "guide.onboarded"
        static let watchlist = "guide.watchlist"
        static let seen = "guide.seen"
        static let liked = "guide.liked"
        static let likedGenres = "guide.likedGenres"
        static let services = "guide.services"
        static let tmdbKey = "guide.tmdbKey"
        static let onlineFilms = "guide.onlineFilms"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Gemerkte Titel aus dem Online-Katalog zuerst bekannt machen, damit Listen und Poster sie finden.
        if let data = defaults.data(forKey: Keys.onlineFilms),
           let films = try? JSONDecoder().decode([Film].self, from: data) {
            FilmIndex.register(films)
        }
        let known: (String) -> Bool = { FilmIndex.film($0) != nil }
        onboarded = defaults.bool(forKey: Keys.onboarded)
        watchlist = (defaults.stringArray(forKey: Keys.watchlist) ?? []).filter(known)
        seen = Set((defaults.stringArray(forKey: Keys.seen) ?? []).filter(known))
        liked = (defaults.stringArray(forKey: Keys.liked) ?? []).filter(known)
        likedGenres = Set(defaults.stringArray(forKey: Keys.likedGenres) ?? [])
        services = Set((defaults.stringArray(forKey: Keys.services) ?? []).compactMap(WatchProvider.init(rawValue:)))
        tmdbKey = defaults.string(forKey: Keys.tmdbKey) ?? ""
    }

    /// Titel aus dem Online-Katalog, die in einer Liste stehen, mitspeichern: Sie sind nicht im mitgelieferten Katalog.
    private func storeOnline() {
        let ids = Set(watchlist).union(seen).union(liked)
        let films = ids.filter { FilmIndex.byID[$0] == nil }.compactMap { FilmIndex.film($0) }
        if let data = try? JSONEncoder().encode(films) { defaults.set(data, forKey: Keys.onlineFilms) }
    }

    func isSaved(_ film: Film) -> Bool { watchlist.contains(film.id) }
    func isSeen(_ film: Film) -> Bool { seen.contains(film.id) }
    func isLiked(_ film: Film) -> Bool { liked.contains(film.id) }

    func toggleSaved(_ film: Film) {
        FilmIndex.register([film])
        if let index = watchlist.firstIndex(of: film.id) { watchlist.remove(at: index) }
        else { watchlist.insert(film.id, at: 0) }
    }

    func toggleSeen(_ film: Film) {
        FilmIndex.register([film])
        if seen.contains(film.id) { seen.remove(film.id) }
        else {
            seen.insert(film.id)
            // Gesehen heißt: muss nicht mehr auf die Liste.
            watchlist.removeAll { $0 == film.id }
        }
    }

    func toggleLiked(_ film: Film) {
        FilmIndex.register([film])
        if let index = liked.firstIndex(of: film.id) { liked.remove(at: index) }
        else { liked.insert(film.id, at: 0) }
    }

    func toggleService(_ provider: WatchProvider) {
        if services.contains(provider) { services.remove(provider) } else { services.insert(provider) }
    }

    func toggleGenre(_ genre: String) {
        if likedGenres.contains(genre) { likedGenres.remove(genre) } else { likedGenres.insert(genre) }
    }

    /// Eigene Dienste zuerst, sonst die feste Reihenfolge.
    var orderedProviders: [WatchProvider] {
        WatchProvider.allCases.filter { services.contains($0) } + WatchProvider.allCases.filter { !services.contains($0) }
    }

    var serviceTMDBIDs: [Int] { WatchProvider.allCases.filter { services.contains($0) }.flatMap(\.tmdbIDs) }

    var savedFilms: [Film] { watchlist.compactMap(FilmIndex.film) }
    var seenFilms: [Film] { seen.compactMap(FilmIndex.film).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var likedFilms: [Film] { liked.compactMap(FilmIndex.film) }

    // MARK: Für dich

    /// Titel aus dem Katalog nach den eigenen Vorlieben: gemeinsame Merkmale mit gemochten Filmen
    /// und Lieblingsgenres, die Wertung entscheidet bei Gleichstand. Ohne Vorlieben die besten Titel.
    func forYou(limit: Int = 40) -> [Film] {
        observePreferences()
        if let cached = forYouCache[limit] { return cached }
        let result = computeForYou(limit: limit)
        forYouCache[limit] = result
        return result
    }

    private func computeForYou(limit: Int) -> [Film] {
        var weights: [String: Double] = [:]
        for film in likedFilms { for feature in film.features { weights[feature.key, default: 0] += feature.weight } }
        for genre in likedGenres { weights["g:\(genre)", default: 0] += 2 }
        let excluded = seen.union(liked)
        let candidates = FilmIndex.all.filter { !$0.comingSoon && !excluded.contains($0.id) }
        guard !weights.isEmpty else { return Array(GuideCatalog.byRating(candidates).prefix(limit)) }
        return candidates
            .map { film -> (Film, Double) in
                let features = film.features
                let match = features.reduce(0.0) { $0 + (weights[$1.key] ?? 0) * $1.weight } / Double(max(features.count, 1)).squareRoot()
                return (film, match + (film.imdbRating ?? 6.5) * 0.5)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Fünf Vorschläge für heute: wechseln jeden Tag, bleiben über den Tag gleich.
    func todaysPicks(count: Int = 6) -> [Film] {
        observePreferences()
        let day = Self.today
        if let cached = picksCache, cached.day == day, cached.films.count == count { return cached.films }
        let pool = forYou(limit: 30)
        let keyed = pool.map { (film: $0, key: GuideStore.stableHash("\(day)\($0.id)")) }
        let films = Array(keyed.sorted { $0.key < $1.key }.prefix(count).map(\.film))
        picksCache = (day, films)
        return films
    }

    /// „Weil du X magst“: ein gemochter Film des Tages und was dazu passt.
    func becauseYouLiked() -> (film: Film, matches: [Film])? {
        observePreferences()
        let day = Self.today
        if let cached = becauseCache, cached.day == day { return cached.value }
        let films = likedFilms
        var value: (film: Film, matches: [Film])?
        if !films.isEmpty {
            let anchor = films[day % films.count]
            let likedIDs = Set(liked)
            let matches = GuideCatalog.similar(to: anchor, limit: 16).filter { !seen.contains($0.id) && !likedIDs.contains($0.id) }
            value = matches.isEmpty ? nil : (anchor, matches)
        }
        becauseCache = (day, value)
        return value
    }

    /// Gleich auf jedem Start (anders als `hashValue`), für die Auswahl des Tages.
    static func stableHash(_ text: String) -> UInt64 {
        text.unicodeScalars.reduce(5381 as UInt64) { ($0 &* 33) &+ UInt64($1.value) }
    }

    func resetPreferences() {
        liked = []
        likedGenres = []
        onboarded = false
    }
}

enum GuideTab: Hashable {
    case discover, all, watchlist, search
}

// MARK: - Katalog-Abfragen

/// Abfragen über den mitgelieferten Katalog. Alles, was beim Tippen oder Neuzeichnen gebraucht wird,
/// liegt als Index bereit, statt jedes Mal über alle Titel zu laufen.
enum GuideCatalog {
    static var films: [Film] { FilmIndex.all }

    static func byRating(_ films: [Film]) -> [Film] {
        films.sorted { ($0.imdbRating ?? 0, $0.year) > ($1.imdbRating ?? 0, $1.year) }
    }

    /// Für den Vergleich ohne Groß-/Kleinschreibung und Akzente („Amelie“ findet „Amélie“).
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
    }

    // MARK: Ähnliche Titel

    private static var similarCache: [String: [Film]] = [:]

    /// Ähnliche Titel über gemeinsame Merkmale (Genre, Stimmung, Regie, Besetzung), Wertung als Gleichstand-Brecher.
    /// Einmal je Titel berechnet: Die Detailseite fragt bei jedem Neuzeichnen (Merken, Herz) erneut.
    static func similar(to film: Film, limit: Int = 12) -> [Film] {
        let cacheKey = "\(film.id)|\(limit)|\(film.genres.count)"
        if let cached = similarCache[cacheKey] { return cached }
        let mine = Dictionary(film.features.map { ($0.key, $0.weight) }, uniquingKeysWith: { max($0, $1) })
        var scored: [(Film, Double)] = []
        scored.reserveCapacity(films.count)
        for other in films where other.id != film.id {
            var shared = 0.0
            for feature in other.features { shared += (mine[feature.key] ?? 0) * feature.weight }
            guard shared > 0 else { continue }
            let kindBonus = other.isSeries == film.isSeries ? 0.5 : 0
            let score = shared + kindBonus + (other.imdbRating ?? 6) * 0.05
            if score > 1.5 { scored.append((other, score)) }
        }
        let result = Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
        similarCache[cacheKey] = result
        return result
    }

    // MARK: Personen

    /// Titel je Person (Regie und Besetzung), neueste zuerst.
    private static let byPerson: [String: [Film]] = {
        var index: [String: [Film]] = [:]
        for film in FilmIndex.all {
            var names = Set(film.cast)
            if !film.director.isEmpty { names.insert(film.director) }
            for name in names { index[name, default: []].append(film) }
        }
        return index.mapValues { $0.sorted { $0.year > $1.year } }
    }()

    static func films(with person: String) -> [Film] { byPerson[person] ?? [] }

    /// Personen nach Zahl ihrer Titel, mit vorbereitetem Suchtext.
    private static let peopleIndex: [(name: String, folded: String)] = byPerson
        .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        .map { ($0.key, fold($0.key)) }

    static func people(matching text: String) -> [String] {
        let trimmed = fold(text.trimmingCharacters(in: .whitespaces))
        guard trimmed.count >= 2 else { return [] }
        var out: [String] = []
        for person in peopleIndex where person.folded.contains(trimmed) {
            out.append(person.name)
            if out.count == 8 { break }
        }
        return out
    }

    // MARK: Suche

    /// Suchtext je Titel (Titel, Originaltitel, Personen, Jahr, Genres, Stimmungen), einmal vorbereitet.
    private static let searchIndex: [(film: Film, haystack: String, titles: String)] = FilmIndex.all.map { film in
        let all = ([film.title, film.originalTitle, film.director, String(film.year)] + film.cast + film.genres + film.moods)
            .joined(separator: " ")
        return (film, fold(all), fold("\(film.title) \(film.originalTitle)"))
    }

    private static var lastSearch: (text: String, result: [Film]) = ("", [])

    /// Freitextsuche über Titel, Originaltitel, Personen, Genres und Stimmungen. Titeltreffer zuerst.
    static func search(_ text: String) -> [Film] {
        if text == lastSearch.text { return lastSearch.result }
        let folded = fold(text)
        let terms = folded.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var titleHits: [Film] = []
        var otherHits: [Film] = []
        for entry in searchIndex where terms.allSatisfy({ entry.haystack.contains($0) }) {
            if entry.titles.contains(folded) { titleHits.append(entry.film) } else { otherHits.append(entry.film) }
        }
        let byScore: (Film, Film) -> Bool = { ($0.imdbRating ?? 0) > ($1.imdbRating ?? 0) }
        let result = titleHits.sorted(by: byScore) + otherHits.sorted(by: byScore)
        lastSearch = (text, result)
        return result
    }

    // MARK: Fertige Reihen

    /// Reihen der Startseite, einmal beim ersten Öffnen sortiert.
    static let released = FilmIndex.all.filter { !$0.comingSoon }
    static let byGenre: [String: [Film]] = {
        var index: [String: [Film]] = [:]
        for film in released { for genre in film.genres { index[genre, default: []].append(film) } }
        return index.mapValues { byRating($0) }
    }()
    static let byMood: [String: [Film]] = {
        var index: [String: [Film]] = [:]
        for film in released { for mood in film.moods { index[mood, default: []].append(film) } }
        return index.mapValues { byRating($0) }
    }()
}

// MARK: - Filter für „Alle Titel“

struct GuideFilter: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "Filme & Serien", films = "Nur Filme", series = "Nur Serien"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case rating = "Beste Wertung", newest = "Neueste zuerst", oldest = "Älteste zuerst", title = "Titel A-Z", shortest = "Kürzeste zuerst"
        var id: String { rawValue }
    }

    var kind: Kind = .all
    var genre: String?
    var mood: String?
    var decade: Int?
    var maxRuntime: Int?
    var maxFSK: Int?
    var hideSeen = false
    var sort: Sort = .rating

    static let decades: [Int] = Array(Set(FilmIndex.all.map { $0.year / 10 * 10 })).sorted(by: >)
    /// Online gibt es mehr Genres und Jahrzehnte als im handverlesenen Katalog.
    static let onlineGenres = ["Action", "Abenteuer", "Animation", "Komödie", "Krimi", "Dokumentarfilm", "Drama", "Familie",
                               "Fantasy", "Historie", "Horror", "Musik", "Mystery", "Romanze", "Science-Fiction", "Thriller",
                               "Krieg", "Western"]
    static let onlineDecades: [Int] = Array(stride(from: 2020, through: 1920, by: -10))
    static let runtimes: [Int] = [90, 105, 120, 150]
    static let fskLevels: [Int] = [0, 6, 12, 16]

    var isActive: Bool { self != GuideFilter(sort: sort) }

    func apply(_ films: [Film], seen: Set<String>) -> [Film] {
        let filtered = films.filter { film in
            switch kind {
            case .all: break
            case .films: if film.isSeries { return false }
            case .series: if !film.isSeries { return false }
            }
            if let genre, !film.genres.contains(genre) { return false }
            if let mood, !film.moods.contains(mood) { return false }
            if let decade, film.year / 10 * 10 != decade { return false }
            if let maxRuntime, film.runtime > maxRuntime { return false }
            if let maxFSK, film.fsk > maxFSK { return false }
            if hideSeen, seen.contains(film.id) { return false }
            return true
        }
        switch sort {
        case .rating: return GuideCatalog.byRating(filtered)
        case .newest: return filtered.sorted { ($0.year, $0.imdbRating ?? 0) > ($1.year, $1.imdbRating ?? 0) }
        case .oldest: return filtered.sorted { ($0.year, $0.title) < ($1.year, $1.title) }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .shortest: return filtered.sorted { $0.runtime < $1.runtime }
        }
    }
}
