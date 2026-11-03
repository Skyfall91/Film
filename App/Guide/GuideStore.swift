import SwiftUI

/// Alles, was sich der Guide merkt: Vorlieben aus dem Onboarding, Merkliste, Gesehenes und die eigenen Dienste.
/// Kein Konto, kein Abo, kein Abgleich: Die Daten bleiben auf dem Gerät.
@Observable
final class GuideStore {
    @ObservationIgnored private let defaults: UserDefaults

    var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    /// Neueste zuerst.
    var watchlist: [String] { didSet { defaults.set(watchlist, forKey: Keys.watchlist); storeOnline() } }
    var seen: Set<String> { didSet { defaults.set(Array(seen), forKey: Keys.seen); storeOnline() } }
    /// Filme, die man mag (Onboarding und Herz auf der Titelseite). Daraus entsteht „Für dich“.
    var liked: [String] { didSet { defaults.set(liked, forKey: Keys.liked); storeOnline() } }
    var likedGenres: Set<String> { didSet { defaults.set(Array(likedGenres), forKey: Keys.likedGenres) } }
    /// Diese Dienste stehen auf den Detailseiten oben.
    var services: Set<WatchProvider> { didSet { defaults.set(services.map(\.rawValue), forKey: Keys.services) } }
    /// Eigener TMDB-Schlüssel: schaltet die TMDB mit Verfügbarkeiten frei (sonst iTunes).
    var tmdbKey: String { didSet { defaults.set(tmdbKey, forKey: Keys.tmdbKey) } }
    var selectedTab: GuideTab = .discover

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
        let pool = forYou(limit: 30)
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return Array(pool.sorted { GuideStore.stableHash("\(day)\($0.id)") < GuideStore.stableHash("\(day)\($1.id)") }.prefix(count))
    }

    /// „Weil du X magst“: ein gemochter Film des Tages und was dazu passt.
    func becauseYouLiked() -> (film: Film, matches: [Film])? {
        let films = likedFilms
        guard !films.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let anchor = films[day % films.count]
        let matches = GuideCatalog.similar(to: anchor, limit: 16).filter { !seen.contains($0.id) && !liked.contains($0.id) }
        return matches.isEmpty ? nil : (anchor, matches)
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

enum GuideCatalog {
    static var films: [Film] { FilmIndex.all }

    static func byRating(_ films: [Film]) -> [Film] {
        films.sorted { ($0.imdbRating ?? 0, $0.year) > ($1.imdbRating ?? 0, $1.year) }
    }

    /// Ähnliche Titel über gemeinsame Merkmale (Genre, Stimmung, Regie, Besetzung), Wertung als Gleichstand-Brecher.
    static func similar(to film: Film, limit: Int = 12) -> [Film] {
        let mine = Dictionary(film.features.map { ($0.key, $0.weight) }, uniquingKeysWith: { max($0, $1) })
        return films
            .filter { $0.id != film.id }
            .map { other -> (Film, Double) in
                let shared = other.features.reduce(0.0) { $0 + (mine[$1.key] ?? 0) * $1.weight }
                let kindBonus = other.isSeries == film.isSeries ? 0.5 : 0
                return (other, shared + kindBonus + (other.imdbRating ?? 6) * 0.05)
            }
            .filter { $0.1 > 1.5 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func films(with person: String) -> [Film] {
        films.filter { $0.director == person || $0.cast.contains(person) }.sorted { $0.year > $1.year }
    }

    /// Freitextsuche über Titel, Originaltitel, Personen, Genres und Stimmungen.
    static func search(_ text: String) -> [Film] {
        let terms = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let matches = films.filter { film in
            let haystack = ([film.title, film.originalTitle, film.director, String(film.year)] + film.cast + film.genres + film.moods)
                .joined(separator: " ")
            return terms.allSatisfy { haystack.localizedStandardContains($0) }
        }
        // Treffer im Titel zuerst.
        return matches.sorted { a, b in
            let aTitle = a.title.localizedStandardContains(text) || a.originalTitle.localizedStandardContains(text)
            let bTitle = b.title.localizedStandardContains(text) || b.originalTitle.localizedStandardContains(text)
            if aTitle != bTitle { return aTitle }
            return (a.imdbRating ?? 0) > (b.imdbRating ?? 0)
        }
    }

    static let allPeople: [String] = {
        var counts: [String: Int] = [:]
        for film in FilmIndex.all {
            if !film.director.isEmpty { counts[film.director, default: 0] += 1 }
            for name in film.cast { counts[name, default: 0] += 1 }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }()

    static func people(matching text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        return Array(allPeople.filter { $0.localizedStandardContains(trimmed) }.prefix(8))
    }
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
