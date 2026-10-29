import Foundation
#if !os(tvOS)
import FoundationModels
#endif

/// Ein Film, der nicht im Katalog ist, aber im Chat genannt wurde. Die Merkmale kommen aus
/// Wikidata (Genre, Regie, Besetzung); Stimmungen werden aus den Genres abgeleitet und, /// wenn verfügbar, von Apple Intelligence ergänzt, aber nur aus unserer festen Liste.
struct ExternalFilm: Codable, Hashable, Sendable {
    var id: String          // "ext:Q27590871"
    var title: String
    var year: Int?
    var genres: [String]
    var moods: [String]
    var director: String
    var cast: [String]

    /// Gleiche Gewichtung wie bei Katalogfilmen, so lernt die Regression beide gleich.
    var features: [(key: String, weight: Double)] {
        genres.map { ("g:\($0)", 1.0) }
        + moods.map { ("m:\($0)", 1.2) }
        + (director.isEmpty ? [] : [("d:\(director)", 0.8)])
        + cast.prefix(2).map { ("c:\($0)", 0.4) }
    }
}

/// Nachschlagen bei Wikidata (frei, ohne API-Schlüssel). Austauschbar gegen TMDb o. Ä. (Adapter).
enum WikidataLookup {
    private static let agent = "Film/0.1"

    static func find(_ title: String) async -> ExternalFilm? {
        guard let ids = await search(title), !ids.isEmpty,
              let film = await details(ids: ids, title: title) else { return nil }
        return await withMoods(film)
    }

    /// Arten von Filmen in Wikidata (Spielfilm, Animationsfilm, …).
    private static let filmTypes = ["Q11424", "Q202866", "Q229390", "Q29168811", "Q24869", "Q506240"]

    /// Kandidaten: zuerst Volltextsuche nur unter Filmen (sonst findet „Hereditary“ Erbkrankheiten),
    /// danach die normale Schnellsuche als Ergänzung.
    private static func search(_ title: String) async -> [String]? {
        var c = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: "\(title) haswbstatement:" + filmTypes.map { "P31=\($0)" }.joined(separator: "|")),
            .init(name: "srlimit", value: "5"), .init(name: "format", value: "json")
        ]
        struct FullText: Decodable {
            struct Query: Decodable { struct Hit: Decodable { let title: String }; let search: [Hit] }
            let query: Query
        }
        var ids = (await get(c.url!)).flatMap { try? JSONDecoder().decode(FullText.self, from: $0) }?.query.search.map(\.title) ?? []

        var q = URLComponents(string: "https://www.wikidata.org/w/api.php")!
        q.queryItems = [
            .init(name: "action", value: "wbsearchentities"), .init(name: "search", value: title),
            .init(name: "language", value: "de"), .init(name: "uselang", value: "de"),
            .init(name: "type", value: "item"), .init(name: "limit", value: "8"), .init(name: "format", value: "json")
        ]
        struct Quick: Decodable { struct Hit: Decodable { let id: String }; let search: [Hit] }
        let quick = (await get(q.url!)).flatMap { try? JSONDecoder().decode(Quick.self, from: $0) }?.search.map(\.id) ?? []
        ids += quick.filter { !ids.contains($0) }
        return ids
    }

    /// Erster Treffer, der wirklich ein Film ist, mit Genres (deutsch), Regie und Besetzung.
    private static func details(ids: [String], title: String) async -> ExternalFilm? {
        let query = """
            SELECT ?item (YEAR(MIN(?date)) AS ?y) (GROUP_CONCAT(DISTINCT ?gLabel;separator="|") AS ?genres) \
            (SAMPLE(?dLabel) AS ?director) (GROUP_CONCAT(DISTINCT ?cLabel;separator="|") AS ?cast) WHERE {
             VALUES ?item { \(ids.map { "wd:\($0)" }.joined(separator: " ")) }
             ?item wdt:P31 ?type . VALUES ?type { \(filmTypes.map { "wd:\($0)" }.joined(separator: " ")) }
             OPTIONAL { ?item wdt:P577 ?date }
             OPTIONAL { ?item wdt:P136 ?g . ?g rdfs:label ?gLabel FILTER(LANG(?gLabel)="de") }
             OPTIONAL { ?item wdt:P57 ?d . ?d rdfs:label ?dLabel FILTER(LANG(?dLabel)="en") }
             OPTIONAL { ?item wdt:P161 ?c . ?c rdfs:label ?cLabel FILTER(LANG(?cLabel)="en") }
            } GROUP BY ?item
            """
        var c = URLComponents(string: "https://query.wikidata.org/sparql")!
        c.queryItems = [.init(name: "query", value: query), .init(name: "format", value: "json")]
        struct Response: Decodable {
            struct Value: Decodable { let value: String }
            struct Results: Decodable { let bindings: [[String: Value]] }
            let results: Results
        }
        guard let data = await get(c.url!),
              let rows = (try? JSONDecoder().decode(Response.self, from: data))?.results.bindings else { return nil }
        // Reihenfolge der Suche beibehalten: der relevanteste Film zuerst.
        let byID = Dictionary(rows.compactMap { row in
            row["item"].map { (String($0.value.split(separator: "/").last ?? ""), row) }
        }, uniquingKeysWith: { a, _ in a })
        guard let id = ids.first(where: { byID[$0] != nil }), let row = byID[id] else { return nil }
        let genres = mapGenres((row["genres"]?.value ?? "").split(separator: "|").map(String.init))
        // Besetzung: bevorzugt Namen, die wir aus dem Katalog kennen, sonst die ersten.
        let cast = (row["cast"]?.value ?? "").split(separator: "|").map(String.init)
        let known = Set(FilmIndex.all.flatMap(\.cast))
        let orderedCast = cast.filter { known.contains($0) } + cast.filter { !known.contains($0) }
        return ExternalFilm(id: "ext:\(id)", title: title, year: row["y"].flatMap { Int($0.value) },
                            genres: genres, moods: moods(for: genres),
                            director: row["director"]?.value ?? "", cast: Array(orderedCast.prefix(3)))
    }

    /// Mit einem zweiten Versuch, Wikidata drosselt bei vielen Anfragen kurz.
    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 { return data }
            if attempt == 0 { try? await Task.sleep(for: .seconds(1.2)) }
        }
        return nil
    }

    // MARK: Übersetzung in unser Vokabular

    private static let genreMap: [(String, String)] = [
        ("science-fiction", "Science-Fiction"), ("horror", "Horror"), ("komödie", "Komödie"), ("comedy", "Komödie"),
        ("action", "Action"), ("thriller", "Thriller"), ("krimi", "Krimi"), ("fantasy", "Fantasy"),
        ("animation", "Animation"), ("zeichentrick", "Animation"), ("anime", "Animation"), ("abenteuer", "Abenteuer"),
        ("liebesfilm", "Romanze"), ("romant", "Romanze"), ("musical", "Musical"), ("musikfilm", "Musik"),
        ("kriegsfilm", "Krieg"), ("biografi", "Biografie"), ("biopic", "Biografie"), ("historienfilm", "Historie"),
        ("mystery", "Mystery"), ("familienfilm", "Familie"), ("sportfilm", "Sport"), ("drama", "Drama")
    ]

    static func mapGenres(_ labels: [String]) -> [String] {
        let known = Set(FilmIndex.allGenres)
        var out: [String] = []
        for label in labels.map({ $0.lowercased() }) {
            for (needle, genre) in genreMap where label.contains(needle) && known.contains(genre) && !out.contains(genre) {
                out.append(genre)
            }
        }
        return out
    }

    /// Grobe Stimmungen aus den Genres, Grundlage, falls Apple Intelligence nicht verfügbar ist.
    static func moods(for genres: [String]) -> [String] {
        let map: [String: [String]] = [
            "Horror": ["gruselig", "düster"], "Komödie": ["lustig", "leicht"], "Animation": ["bunt", "familienfreundlich"],
            "Familie": ["familienfreundlich", "gemütlich"], "Action": ["actionreich"], "Thriller": ["spannend", "intensiv"],
            "Krimi": ["spannend", "düster"], "Mystery": ["wendungsreich"], "Romanze": ["romantisch", "gefühlvoll"],
            "Drama": ["gefühlvoll", "nachdenklich"], "Science-Fiction": ["bildgewaltig"], "Fantasy": ["episch", "bildgewaltig"],
            "Abenteuer": ["episch"], "Krieg": ["intensiv", "düster"], "Biografie": ["inspirierend"], "Sport": ["inspirierend"],
            "Musical": ["musikalisch"], "Musik": ["musikalisch"], "Historie": ["episch"]
        ]
        var out: [String] = []
        for g in genres { for m in map[g] ?? [] where !out.contains(m) && FilmIndex.allMoods.contains(m) { out.append(m) } }
        return Array(out.prefix(3))
    }

    #if os(tvOS)
    struct MoodGuess {
            var moods: [String]
    }
    #else
    @Generable
    struct MoodGuess {
            @Guide(description: "2 bis 3 Stimmungen, die den Film am besten beschreiben, nur aus der vorgegebenen Liste")
            var moods: [String]
    }
    #endif

    /// Apple Intelligence schätzt die Stimmungen, nur Begriffe aus unserer Liste werden übernommen.
    private static func withMoods(_ film: ExternalFilm) async -> ExternalFilm {
        #if os(tvOS)
        return film
        #else
        guard MoodSearch.isAppleIntelligenceAvailable else { return film }
        let session = LanguageModelSession(instructions: """
            Ordne einen Film Stimmungen zu. Erlaubt sind ausschließlich: \(FilmIndex.allMoods.joined(separator: ", ")).
            """)
        let facts = "Film: \(film.title)\(film.year.map { " (\($0))" } ?? ""). Genres: \(film.genres.joined(separator: ", ")). Regie: \(film.director)."
        guard let guess = try? await session.respond(to: facts, generating: MoodGuess.self).content else { return film }
        let valid = guess.moods.map { $0.lowercased() }.filter { FilmIndex.allMoods.contains($0) }
        guard !valid.isEmpty else { return film }
        var f = film
        f.moods = Array((valid + film.moods).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
        return f

        #endif
    }
}
