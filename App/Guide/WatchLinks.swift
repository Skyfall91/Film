import SwiftUI

/// Wo man einen Titel schauen kann. Die App spielt nichts ab und kennt keine Verfügbarkeiten,
/// sie führt wie eine Suchmaschine dorthin: Google zeigt zu Filmen und Serien eine „Ansehen“-Box
/// mit den Diensten, auf denen der Titel gerade läuft, JustWatch die vollständige Übersicht.
/// Bei den Diensten öffnet sich deren eigene Suche, wo sie eine offene Suchadresse haben,
/// sonst eine Google-Suche auf ihrer Seite.
enum WatchProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case netflix, prime, disney, appleTV, wow, paramount, joyn, rtl, magenta, mediathek, youtube, googlePlay

    var id: String { rawValue }

    var name: String {
        switch self {
        case .netflix: "Netflix"
        case .prime: "Prime Video"
        case .disney: "Disney+"
        case .appleTV: "Apple TV"
        case .wow: "WOW / Sky"
        case .paramount: "Paramount+"
        case .joyn: "Joyn"
        case .rtl: "RTL+"
        case .magenta: "MagentaTV"
        case .mediathek: "ARD & ZDF"
        case .youtube: "YouTube"
        case .googlePlay: "Google Play"
        }
    }

    /// Kurzer Hinweis unter dem Namen: Abo oder Leihen/Kaufen.
    var kindNote: String {
        switch self {
        case .appleTV, .youtube, .googlePlay: "Leihen & kaufen"
        case .mediathek: "Kostenlos"
        case .prime: "Abo, leihen & kaufen"
        default: "Abo"
        }
    }

    var color: Color {
        switch self {
        case .netflix: Color(red: 0.90, green: 0.04, blue: 0.08)
        case .prime: Color(red: 0.0, green: 0.66, blue: 0.88)
        case .disney: Color(red: 0.07, green: 0.24, blue: 0.62)
        case .appleTV: Color(white: 0.85)
        case .wow: Color(red: 0.35, green: 0.20, blue: 0.75)
        case .paramount: Color(red: 0.0, green: 0.39, blue: 1.0)
        case .joyn: Color(red: 0.95, green: 0.20, blue: 0.45)
        case .rtl: Color(red: 0.95, green: 0.35, blue: 0.10)
        case .magenta: Color(red: 0.89, green: 0.0, blue: 0.45)
        case .mediathek: Color(red: 0.25, green: 0.55, blue: 0.95)
        case .youtube: Color(red: 1.0, green: 0.0, blue: 0.0)
        case .googlePlay: Color(red: 0.20, green: 0.70, blue: 0.35)
        }
    }

    /// Kürzel im farbigen Feld, statt fremder Logos.
    var monogram: String {
        switch self {
        case .netflix: "N"
        case .prime: "P"
        case .disney: "D+"
        case .appleTV: "tv"
        case .wow: "W"
        case .paramount: "P+"
        case .joyn: "J"
        case .rtl: "R+"
        case .magenta: "M"
        case .mediathek: "ÖR"
        case .youtube: "▶"
        case .googlePlay: "G"
        }
    }

    /// Anbieter-Nummern bei TMDB/JustWatch in Deutschland, für „läuft bei“ und den Filter „Auf meinen Diensten“.
    var tmdbIDs: [Int] {
        switch self {
        case .netflix: [8, 1796]
        case .prime: [9, 10]
        case .disney: [337]
        case .appleTV: [350, 2]
        case .wow: [30, 29]
        case .paramount: [531]
        case .joyn: [304, 421]
        case .rtl: [298]
        case .magenta: [178]
        case .mediathek: [219, 537]
        case .youtube: [192]
        case .googlePlay: [3]
        }
    }

    func url(for film: Film) -> URL? {
        let term = film.title
        switch self {
        case .netflix:
            return WatchLinks.url("https://www.netflix.com/search", ["q": term])
        case .prime:
            return WatchLinks.url("https://www.amazon.de/s", ["k": term, "i": "instant-video"])
        case .appleTV:
            return WatchLinks.url("https://tv.apple.com/de/search", ["term": term])
        case .youtube:
            return WatchLinks.url("https://www.youtube.com/results", ["search_query": "\(term) \(film.isSeries ? "Serie" : "Film")"])
        case .googlePlay:
            return WatchLinks.url("https://play.google.com/store/search", ["q": term, "c": "movies"])
        case .disney:
            return WatchLinks.siteSearch(film, site: "disneyplus.com")
        case .wow:
            return WatchLinks.siteSearch(film, site: "wowtv.de")
        case .paramount:
            return WatchLinks.siteSearch(film, site: "paramountplus.com")
        case .joyn:
            return WatchLinks.siteSearch(film, site: "joyn.de")
        case .rtl:
            return WatchLinks.siteSearch(film, site: "plus.rtl.de")
        case .magenta:
            return WatchLinks.siteSearch(film, site: "magentatv.de")
        case .mediathek:
            return WatchLinks.url("https://www.google.com/search",
                                  ["q": "\"\(term)\" (site:ardmediathek.de OR site:zdf.de OR site:arte.tv)"])
        }
    }
}

enum WatchLinks {
    /// Suchadresse mit sauber kodierten Parametern (Umlaute, Leerzeichen, Sonderzeichen).
    static func url(_ base: String, _ query: KeyValuePairs<String, String>) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    static func siteSearch(_ film: Film, site: String) -> URL? {
        url("https://www.google.com/search", ["q": "\"\(film.title)\" site:\(site)"])
    }

    /// Google zeigt zu „<Titel> <Jahr> stream“ die Box mit allen Diensten, auf denen der Titel läuft.
    static func google(_ film: Film) -> URL? {
        let year = film.year > 0 ? " \(film.year)" : ""
        return url("https://www.google.com/search", ["q": "\(film.title)\(year) \(film.isSeries ? "Serie" : "Film") stream"])
    }

    /// Zum Teilen: Letterboxd, wenn der Titel eine IMDb-Nummer hat, sonst seine Seite bei TMDB oder Apple, sonst Google.
    static func share(_ film: Film) -> URL {
        if !film.imdbID.isEmpty, let url = URL(string: "https://letterboxd.com/imdb/\(film.imdbID)/") { return url }
        if let link = film.link, let url = URL(string: link) { return url }
        return google(film) ?? URL(string: "https://www.google.com")!
    }

    static func justWatch(_ film: Film) -> URL? {
        url("https://www.justwatch.com/de/Suche", ["q": film.title])
    }

    static func imdb(_ film: Film) -> URL? {
        film.imdbID.isEmpty ? nil : URL(string: "https://www.imdb.com/title/\(film.imdbID)/")
    }

    static func wikipedia(_ film: Film) -> URL? {
        url("https://de.wikipedia.org/w/index.php", ["search": "\(film.title) \(film.year > 0 ? String(film.year) : "") \(film.isSeries ? "Fernsehserie" : "Film")"])
    }

    /// Der Trailer öffnet sich bei YouTube, die App selbst spielt nichts ab.
    static func trailer(_ film: Film) -> URL? {
        guard !film.youtubeID.isEmpty else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(film.youtubeID)")
    }

    static func person(_ name: String) -> URL? {
        url("https://www.google.com/search", ["q": "\(name) Filme"])
    }
}
