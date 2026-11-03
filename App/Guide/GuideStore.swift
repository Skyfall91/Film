import SwiftUI

/// Alles, was sich der Guide merkt: Merkliste, Gesehenes und die eigenen Streamingdienste.
/// Kein Konto, kein Abo, kein Abgleich: Die Daten bleiben auf dem Gerät.
@Observable
final class GuideStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Neueste zuerst.
    var watchlist: [String] { didSet { defaults.set(watchlist, forKey: Keys.watchlist) } }
    var seen: Set<String> { didSet { defaults.set(Array(seen), forKey: Keys.seen) } }
    /// Diese Dienste stehen auf den Detailseiten oben.
    var services: Set<WatchProvider> { didSet { defaults.set(services.map(\.rawValue), forKey: Keys.services) } }
    var selectedTab: GuideTab = .discover

    private enum Keys {
        static let watchlist = "guide.watchlist"
        static let seen = "guide.seen"
        static let services = "guide.services"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let known = Set(FilmIndex.all.map(\.id))
        watchlist = (defaults.stringArray(forKey: Keys.watchlist) ?? []).filter { known.contains($0) }
        seen = Set(defaults.stringArray(forKey: Keys.seen) ?? []).intersection(known)
        services = Set((defaults.stringArray(forKey: Keys.services) ?? []).compactMap(WatchProvider.init(rawValue:)))
    }

    func isSaved(_ film: Film) -> Bool { watchlist.contains(film.id) }
    func isSeen(_ film: Film) -> Bool { seen.contains(film.id) }

    func toggleSaved(_ film: Film) {
        if let index = watchlist.firstIndex(of: film.id) { watchlist.remove(at: index) }
        else { watchlist.insert(film.id, at: 0) }
    }

    func toggleSeen(_ film: Film) {
        if seen.contains(film.id) { seen.remove(film.id) }
        else {
            seen.insert(film.id)
            // Gesehen heißt: muss nicht mehr auf die Liste.
            watchlist.removeAll { $0 == film.id }
        }
    }

    func toggleService(_ provider: WatchProvider) {
        if services.contains(provider) { services.remove(provider) } else { services.insert(provider) }
    }

    /// Eigene Dienste zuerst, sonst die feste Reihenfolge.
    var orderedProviders: [WatchProvider] {
        WatchProvider.allCases.filter { services.contains($0) } + WatchProvider.allCases.filter { !services.contains($0) }
    }

    var savedFilms: [Film] { watchlist.compactMap(FilmIndex.film) }
    var seenFilms: [Film] { FilmIndex.all.filter { seen.contains($0.id) }.sorted { $0.title < $1.title } }
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
