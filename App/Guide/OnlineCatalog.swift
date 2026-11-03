import Foundation

// MARK: - Verfügbarkeit

/// Ein Anbieter, bei dem ein Titel gerade läuft (Daten von JustWatch über TMDB).
struct ProviderOffer: Hashable, Identifiable, Sendable {
    let id: Int
    let name: String
    let logoPath: String?

    var logoURL: URL? { logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w154\($0)") } }

    /// Der passende Dienst aus der eigenen Liste, für den direkten Suchlink.
    var provider: WatchProvider? { WatchProvider.allCases.first { $0.tmdbIDs.contains(id) } }
}

struct Availability: Equatable, Sendable {
    var flatrate: [ProviderOffer] = []
    var free: [ProviderOffer] = []
    var rent: [ProviderOffer] = []
    var buy: [ProviderOffer] = []
    /// Übersichtsseite bei TMDB mit Links zu allen Anbietern.
    var link: String?

    var isEmpty: Bool { flatrate.isEmpty && free.isEmpty && rent.isEmpty && buy.isEmpty }
}

struct FilmDetails: Sendable {
    var film: Film
    var availability: Availability?
}

/// Anfrage für „Alle Filme“ im Online-Katalog.
struct OnlineBrowse: Hashable, Sendable {
    var kind: GuideFilter.Kind = .all
    var genre: String?
    var decade: Int?
    var maxRuntime: Int?
    var maxFSK: Int?
    var sort: GuideFilter.Sort = .rating
    /// TMDB-Anbieter: nur Titel, die bei diesen Diensten im Abo oder kostenlos laufen.
    var providerIDs: [Int] = []
}

// MARK: - Online-Katalog

/// Wirklich alle Filme: Mitgeliefert sind gut 400 kuratierte Titel, alles Weitere kommt live dazu.
/// Mit TMDB-Schlüssel aus der TMDB (über eine Million Filme und Serien, mit Verfügbarkeit in Deutschland),
/// ohne Schlüssel aus Apples iTunes-Katalog (alle Filme, die es in Deutschland zu leihen oder kaufen gibt).
enum OnlineCatalog {
    /// Schlüssel aus den Einstellungen, sonst aus der Info.plist (Build-Einstellung `TMDB_API_KEY`).
    static var tmdbKey: String? {
        let stored = UserDefaults.standard.string(forKey: "guide.tmdbKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "TMDBAPIKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return bundled.isEmpty || bundled.hasPrefix("$(") ? nil : bundled
    }

    static var usesTMDB: Bool { tmdbKey != nil }
    static var sourceName: String { usesTMDB ? "TMDB" : "iTunes" }

    private static var detailCache: [String: FilmDetails] = [:]
    private static var searchCache: [String: [Film]] = [:]
    /// Älteste Suchen zuerst, damit der Zwischenspeicher nicht endlos wächst.
    private static var searchOrder: [String] = []
    private static var trendingCache: (key: String, date: Date, films: [Film])?

    static func search(_ text: String) async -> [Film] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let cacheKey = "\(sourceName):\(query.lowercased())"
        if let cached = searchCache[cacheKey] { return cached }
        let films: [Film]
        if let key = tmdbKey { films = await TMDB.search(query, key: key) } else { films = await ITunes.search(query) }
        let merged = curatedFirst(films)
        FilmIndex.register(merged)
        searchCache[cacheKey] = merged
        searchOrder.append(cacheKey)
        if searchOrder.count > 60 { searchCache[searchOrder.removeFirst()] = nil }
        return merged
    }

    /// Eine Seite „Alle Filme“. Leer heißt: keine weiteren Titel.
    static func browse(_ request: OnlineBrowse, page: Int) async -> [Film] {
        let films: [Film]
        if let key = tmdbKey { films = await TMDB.discover(request, page: page, key: key) }
        else if page == 1 { films = await ITunes.top(genre: request.genre) }
        else { films = [] }
        let merged = curatedFirst(films)
        FilmIndex.register(merged)
        return merged
    }

    /// Was gerade viele schauen.
    static func trending() async -> [Film] {
        // Eine halbe Stunde lang gilt die Liste: Die Startseite fragt bei jedem Erscheinen.
        if let cached = trendingCache, cached.key == sourceName, Date.now.timeIntervalSince(cached.date) < 1800 { return cached.films }
        let films: [Film]
        if let key = tmdbKey { films = await TMDB.trending(key: key) } else { films = await ITunes.top(genre: nil) }
        let merged = curatedFirst(films)
        FilmIndex.register(merged)
        if !merged.isEmpty { trendingCache = (sourceName, Date.now, merged) }
        return merged
    }

    /// Ausführliche Angaben (Laufzeit, Besetzung, Trailer, Altersfreigabe) und, mit TMDB, wo der Titel läuft.
    /// Für mitgelieferte Filme bleibt der Eintrag aus dem Katalog, nur die Verfügbarkeit kommt dazu.
    static func details(for film: Film) async -> FilmDetails? {
        if let cached = detailCache[film.id] { return cached }
        var result: FilmDetails?
        if let key = tmdbKey {
            if let ref = TMDB.ref(film.id) {
                result = await TMDB.details(kind: ref.kind, id: ref.id, key: key)
            } else if !film.imdbID.isEmpty, let ref = await TMDB.find(imdbID: film.imdbID, key: key) {
                if let online = await TMDB.details(kind: ref.kind, id: ref.id, key: key) {
                    result = FilmDetails(film: film, availability: online.availability)
                }
            }
        } else if film.id.hasPrefix("itunes-") {
            result = await ITunes.lookup(film)
        }
        guard var details = result else { return nil }
        // Mitgelieferte Daten (Wertungen, Stimmungen) haben Vorrang.
        if FilmIndex.byID[film.id] != nil || details.film.id != film.id { details.film = film }
        FilmIndex.register([details.film])
        detailCache[film.id] = details
        return details
    }

    // MARK: Abgleich mit dem kuratierten Katalog

    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .filter { $0.isLetter || $0.isNumber }
    }

    private static let curatedIndex: [String: Film] = {
        var index: [String: Film] = [:]
        for film in FilmIndex.all {
            index["\(normalized(film.title))|\(film.year)"] = film
            index["\(normalized(film.originalTitle))|\(film.year)"] = film
        }
        return index
    }()

    /// Titel, die es auch kuratiert gibt, durch den Katalogeintrag ersetzen (mehr Daten, offline), doppelte entfernen.
    private static func curatedFirst(_ films: [Film]) -> [Film] {
        var seen = Set<String>()
        var out: [Film] = []
        for film in films {
            let curated = curatedIndex["\(normalized(film.title))|\(film.year)"]
                ?? curatedIndex["\(normalized(film.originalTitle))|\(film.year)"]
            let resolved = curated ?? film
            if seen.insert(resolved.id).inserted { out.append(resolved) }
        }
        return out
    }

    // MARK: Netz

    fileprivate static func get(_ url: URL, bearer: String? = nil) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    fileprivate static let today: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }()

    /// Erste Zahl in einer Altersangabe („ab 12 Jahren“, „FSK 16“, „12“), sonst unbekannt (-1).
    fileprivate static func fsk(from text: String?) -> Int {
        guard let text, let match = text.firstMatch(of: /\d+/), let value = Int(match.output) else { return -1 }
        return [0, 6, 12, 16, 18].contains(value) ? value : -1
    }

    /// Erster Satz-Abschnitt ohne Zeilenumbrüche.
    fileprivate static func clean(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TMDB

private enum TMDB {
    static let base = "https://api.themoviedb.org/3"

    static func ref(_ filmID: String) -> (kind: String, id: Int)? {
        let parts = filmID.split(separator: "-")
        guard parts.count == 3, parts[0] == "tmdb", let id = Int(parts[2]) else { return nil }
        return (parts[1] == "t" ? "tv" : "movie", id)
    }

    static func load(_ path: String, _ params: [(String, String)], key: String) async -> Data? {
        guard var components = URLComponents(string: base + path) else { return nil }
        // Kurze Schlüssel (v3) als Parameter, lange Lese-Token (v4) im Header.
        let bearer: String? = key.count > 40 ? key : nil
        var items = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        if bearer == nil { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        guard let url = components.url else { return nil }
        return await OnlineCatalog.get(url, bearer: bearer)
    }

    // MARK: Listen

    struct Page: Decodable {
        let results: [Item]
    }

    struct Item: Decodable {
        let id: Int
        let media_type: String?
        let title: String?
        let name: String?
        let original_title: String?
        let original_name: String?
        let release_date: String?
        let first_air_date: String?
        let overview: String?
        let poster_path: String?
        let genre_ids: [Int]?
        let vote_average: Double?
        let vote_count: Int?
        let adult: Bool?

        func film(kind: String) -> Film? {
            let isTV = kind == "tv"
            guard adult != true, let title = (isTV ? name : self.title) ?? self.title ?? name, !title.isEmpty else { return nil }
            let date = (isTV ? first_air_date : release_date) ?? ""
            let genres = Genres.names(genre_ids ?? [], tv: isTV)
            return Film(
                id: "tmdb-\(isTV ? "t" : "m")-\(id)",
                title: title,
                originalTitle: (isTV ? original_name : original_title) ?? title,
                year: Int(date.prefix(4)) ?? 0,
                runtime: 0,
                genres: genres,
                moods: WikidataLookup.moods(for: genres),
                director: "",
                cast: [],
                fsk: -1,
                synopsis: OnlineCatalog.clean(overview),
                youtubeID: "",
                imdbID: "",
                poster: poster_path.map { "https://image.tmdb.org/t/p/w500\($0)" },
                imdbRating: nil,
                rottenTomatoes: nil,
                metascore: nil,
                trailers: [],
                comingSoon: !date.isEmpty && date > OnlineCatalog.today,
                releaseNote: nil,
                mlBias: nil,
                mlFactors: nil,
                mlSeen: nil,
                kind: isTV ? "series" : nil,
                tmdbRating: (vote_count ?? 0) >= 20 ? vote_average : nil,
                link: "https://www.themoviedb.org/\(kind)/\(id)"
            )
        }
    }

    static func films(_ data: Data?, kind: String?) -> [Film] {
        guard let data, let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        return page.results.compactMap { item in
            let itemKind = kind ?? item.media_type ?? ""
            guard itemKind == "movie" || itemKind == "tv" else { return nil }
            // Ohne Poster und Beschreibung hilft ein Treffer beim Finden kaum.
            guard item.poster_path != nil else { return nil }
            return item.film(kind: itemKind)
        }
    }

    static func search(_ query: String, key: String) async -> [Film] {
        let data = await load("/search/multi", [("query", query), ("language", "de-DE"), ("region", "DE"), ("include_adult", "false")], key: key)
        return films(data, kind: nil)
    }

    static func trending(key: String) async -> [Film] {
        films(await load("/trending/all/week", [("language", "de-DE")], key: key), kind: nil)
    }

    static func discover(_ request: OnlineBrowse, page: Int, key: String) async -> [Film] {
        let tv = request.kind == .series
        let dateField = tv ? "first_air_date" : "primary_release_date"
        var params: [(String, String)] = [
            ("language", "de-DE"), ("region", "DE"), ("watch_region", "DE"),
            ("include_adult", "false"), ("page", String(page))
        ]
        switch request.sort {
        case .rating: params += [("sort_by", "vote_average.desc"), ("vote_count.gte", tv ? "200" : "500")]
        case .newest: params += [("sort_by", "\(dateField).desc"), ("\(dateField).lte", OnlineCatalog.today), ("vote_count.gte", "10")]
        case .oldest: params += [("sort_by", "\(dateField).asc"), ("vote_count.gte", "50")]
        case .title: params += [("sort_by", tv ? "name.asc" : "title.asc"), ("vote_count.gte", "50")]
        case .shortest: params += [("sort_by", "popularity.desc"), ("with_runtime.gte", "40")]
        }
        if let genre = request.genre {
            guard let id = Genres.id(for: genre, tv: tv) else { return [] }
            params.append(("with_genres", String(id)))
        }
        if let decade = request.decade {
            params += [("\(dateField).gte", "\(decade)-01-01"), ("\(dateField).lte", "\(decade + 9)-12-31")]
        }
        if let maxRuntime = request.maxRuntime { params.append(("with_runtime.lte", String(maxRuntime))) }
        if let maxFSK = request.maxFSK, !tv {
            params += [("certification_country", "DE"), ("certification.lte", String(maxFSK))]
        }
        if !request.providerIDs.isEmpty {
            params += [("with_watch_providers", request.providerIDs.map(String.init).joined(separator: "|")),
                       ("with_watch_monetization_types", "flatrate|free|ads")]
        }
        return films(await load(tv ? "/discover/tv" : "/discover/movie", params, key: key), kind: tv ? "tv" : "movie")
    }

    // MARK: Einzelner Titel

    struct Named: Decodable { let name: String }
    struct CastMember: Decodable { let name: String }
    struct CrewMember: Decodable { let name: String; let job: String? }
    struct Credits: Decodable { let cast: [CastMember]?; let crew: [CrewMember]? }
    struct Video: Decodable { let key: String; let site: String; let type: String; let iso_639_1: String? }
    struct Videos: Decodable { let results: [Video] }
    struct ReleaseDate: Decodable { let certification: String? }
    struct CountryRelease: Decodable { let iso_3166_1: String; let release_dates: [ReleaseDate] }
    struct ReleaseDates: Decodable { let results: [CountryRelease] }
    struct ContentRating: Decodable { let iso_3166_1: String; let rating: String? }
    struct ContentRatings: Decodable { let results: [ContentRating] }
    struct ExternalIDs: Decodable { let imdb_id: String? }
    struct Offer: Decodable { let provider_id: Int; let provider_name: String; let logo_path: String? }
    struct Region: Decodable {
        let link: String?
        let flatrate: [Offer]?
        let free: [Offer]?
        let ads: [Offer]?
        let rent: [Offer]?
        let buy: [Offer]?
    }
    struct Providers: Decodable { let results: [String: Region] }

    struct Details: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let original_title: String?
        let original_name: String?
        let overview: String?
        let tagline: String?
        let poster_path: String?
        let release_date: String?
        let first_air_date: String?
        let last_air_date: String?
        let runtime: Int?
        let episode_run_time: [Int]?
        let number_of_seasons: Int?
        let in_production: Bool?
        let genres: [Named]?
        let vote_average: Double?
        let vote_count: Int?
        let imdb_id: String?
        let created_by: [Named]?
        let credits: Credits?
        let videos: Videos?
        let release_dates: ReleaseDates?
        let content_ratings: ContentRatings?
        let external_ids: ExternalIDs?
        let watchProviders: Providers?

        enum CodingKeys: String, CodingKey {
            case id, title, name, original_title, original_name, overview, tagline, poster_path
            case release_date, first_air_date, last_air_date, runtime, episode_run_time, number_of_seasons, in_production
            case genres, vote_average, vote_count, imdb_id, created_by, credits, videos, release_dates, content_ratings, external_ids
            case watchProviders = "watch/providers"
        }
    }

    static func details(kind: String, id: Int, key: String) async -> FilmDetails? {
        let tv = kind == "tv"
        let append = tv ? "credits,videos,content_ratings,external_ids,watch/providers" : "credits,videos,release_dates,external_ids,watch/providers"
        guard let data = await load("/\(kind)/\(id)", [("language", "de-DE"), ("append_to_response", append),
                                                       ("include_video_language", "de,en,null")], key: key),
              let d = try? JSONDecoder().decode(Details.self, from: data) else { return nil }
        let title = (tv ? d.name : d.title) ?? d.title ?? d.name ?? ""
        let date = (tv ? d.first_air_date : d.release_date) ?? ""
        let year = Int(date.prefix(4)) ?? 0
        let genres = Genres.names(fromLabels: (d.genres ?? []).map(\.name))
        let director: String
        if tv { director = d.created_by?.first?.name ?? "" }
        else { director = d.credits?.crew?.first(where: { $0.job == "Director" })?.name ?? "" }
        let cast = (d.credits?.cast ?? []).prefix(6).map(\.name)
        let certification: String?
        if tv {
            certification = d.content_ratings?.results.first(where: { $0.iso_3166_1 == "DE" })?.rating
        } else {
            let german = d.release_dates?.results.first(where: { $0.iso_3166_1 == "DE" })
            certification = german?.release_dates.compactMap(\.certification).first(where: { !$0.isEmpty })
        }
        let youtube = (d.videos?.results ?? []).filter { $0.site == "YouTube" }
        let trailer = youtube.first(where: { $0.type == "Trailer" && $0.iso_639_1 == "de" })
            ?? youtube.first(where: { $0.type == "Trailer" })
            ?? youtube.first(where: { $0.type == "Teaser" })
        let endYear = tv && d.in_production == false ? d.last_air_date.flatMap { Int($0.prefix(4)) } : nil
        let film = Film(
            id: "tmdb-\(tv ? "t" : "m")-\(id)",
            title: title,
            originalTitle: (tv ? d.original_name : d.original_title) ?? title,
            year: year,
            runtime: tv ? (d.episode_run_time?.first ?? 0) : (d.runtime ?? 0),
            genres: genres,
            moods: WikidataLookup.moods(for: genres),
            director: director,
            cast: Array(cast),
            fsk: OnlineCatalog.fsk(from: certification),
            synopsis: OnlineCatalog.clean(d.overview),
            youtubeID: trailer?.key ?? "",
            imdbID: d.imdb_id ?? d.external_ids?.imdb_id ?? "",
            poster: d.poster_path.map { "https://image.tmdb.org/t/p/w500\($0)" },
            imdbRating: nil,
            rottenTomatoes: nil,
            metascore: nil,
            trailers: [],
            comingSoon: !date.isEmpty && date > OnlineCatalog.today,
            releaseNote: nil,
            mlBias: nil,
            mlFactors: nil,
            mlSeen: nil,
            kind: tv ? "series" : nil,
            endYear: endYear,
            totalSeasons: d.number_of_seasons,
            tmdbRating: (d.vote_count ?? 0) >= 20 ? d.vote_average : nil,
            link: "https://www.themoviedb.org/\(kind)/\(id)"
        )
        var availability: Availability?
        if let region = d.watchProviders?.results["DE"] {
            func offers(_ list: [Offer]?) -> [ProviderOffer] {
                (list ?? []).map { ProviderOffer(id: $0.provider_id, name: $0.provider_name, logoPath: $0.logo_path) }
            }
            availability = Availability(flatrate: offers(region.flatrate), free: offers(region.free) + offers(region.ads),
                                        rent: offers(region.rent), buy: offers(region.buy), link: region.link)
        } else if d.watchProviders != nil {
            availability = Availability()
        }
        return FilmDetails(film: film, availability: availability)
    }

    struct FindResult: Decodable {
        struct Hit: Decodable { let id: Int }
        let movie_results: [Hit]
        let tv_results: [Hit]
    }

    static func find(imdbID: String, key: String) async -> (kind: String, id: Int)? {
        guard let data = await load("/find/\(imdbID)", [("external_source", "imdb_id")], key: key),
              let result = try? JSONDecoder().decode(FindResult.self, from: data) else { return nil }
        if let movie = result.movie_results.first { return ("movie", movie.id) }
        if let show = result.tv_results.first { return ("tv", show.id) }
        return nil
    }

    // MARK: Genres

    enum Genres {
        static let movie: [Int: [String]] = [
            28: ["Action"], 12: ["Abenteuer"], 16: ["Animation"], 35: ["Komödie"], 80: ["Krimi"], 99: ["Dokumentarfilm"],
            18: ["Drama"], 10751: ["Familie"], 14: ["Fantasy"], 36: ["Historie"], 27: ["Horror"], 10402: ["Musik"],
            9648: ["Mystery"], 10749: ["Romanze"], 878: ["Science-Fiction"], 53: ["Thriller"], 10752: ["Krieg"], 37: ["Western"]
        ]
        static let tv: [Int: [String]] = [
            10759: ["Action", "Abenteuer"], 16: ["Animation"], 35: ["Komödie"], 80: ["Krimi"], 99: ["Dokumentarfilm"],
            18: ["Drama"], 10751: ["Familie"], 10762: ["Familie"], 9648: ["Mystery"], 10765: ["Science-Fiction", "Fantasy"],
            10768: ["Krieg"], 37: ["Western"]
        ]

        static func names(_ ids: [Int], tv isTV: Bool) -> [String] {
            var out: [String] = []
            for id in ids { for name in (isTV ? tv : movie)[id] ?? [] where !out.contains(name) { out.append(name) } }
            return out
        }

        /// Deutsche Genre-Namen aus den Details („Science Fiction“, „Liebesfilm“, „Action & Adventure“).
        static func names(fromLabels labels: [String]) -> [String] {
            let map: [(String, String)] = [
                ("science", "Science-Fiction"), ("fantasy", "Fantasy"), ("action", "Action"), ("abenteuer", "Abenteuer"),
                ("adventure", "Abenteuer"), ("animation", "Animation"), ("komödie", "Komödie"), ("comedy", "Komödie"),
                ("krimi", "Krimi"), ("crime", "Krimi"), ("dokument", "Dokumentarfilm"), ("drama", "Drama"),
                ("familie", "Familie"), ("family", "Familie"), ("kids", "Familie"), ("histor", "Historie"), ("horror", "Horror"),
                ("musik", "Musik"), ("music", "Musik"), ("mystery", "Mystery"), ("liebes", "Romanze"), ("romant", "Romanze"),
                ("thriller", "Thriller"), ("krieg", "Krieg"), ("war", "Krieg"), ("western", "Western")
            ]
            var out: [String] = []
            for label in labels.map({ $0.lowercased() }) {
                for (needle, genre) in map where label.contains(needle) && !out.contains(genre) { out.append(genre) }
            }
            return out
        }

        static func id(for genre: String, tv isTV: Bool) -> Int? {
            let table = isTV ? tv : movie
            return table.filter { $0.value.contains(genre) }.map(\.key).sorted().first
        }
    }
}

// MARK: - iTunes (ohne Schlüssel)

private enum ITunes {
    struct Response: Decodable { let results: [Item] }

    struct Item: Decodable {
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let primaryGenreName: String?
        let releaseDate: String?
        let trackTimeMillis: Int?
        let longDescription: String?
        let shortDescription: String?
        let artworkUrl100: String?
        let contentAdvisoryRating: String?
        let trackViewUrl: String?

        var film: Film? {
            guard let trackId, let title = trackName, !title.isEmpty else { return nil }
            let date = releaseDate ?? ""
            let genres = ITunes.genres(primaryGenreName ?? "")
            return Film(
                id: "itunes-\(trackId)",
                title: title,
                originalTitle: title,
                year: Int(date.prefix(4)) ?? 0,
                runtime: (trackTimeMillis ?? 0) / 60_000,
                genres: genres,
                moods: WikidataLookup.moods(for: genres),
                director: artistName ?? "",
                cast: [],
                fsk: OnlineCatalog.fsk(from: contentAdvisoryRating),
                synopsis: OnlineCatalog.clean(longDescription ?? shortDescription),
                youtubeID: "",
                imdbID: "",
                poster: artworkUrl100.map { ITunes.largeArtwork($0) },
                imdbRating: nil,
                rottenTomatoes: nil,
                metascore: nil,
                trailers: [],
                comingSoon: date.prefix(10) > OnlineCatalog.today.prefix(10),
                releaseNote: nil,
                mlBias: nil,
                mlFactors: nil,
                mlSeen: nil,
                link: trackViewUrl
            )
        }
    }

    static func largeArtwork(_ url: String) -> String {
        url.replacing(/\d+x\d+bb/, with: "600x900bb")
    }

    static func genres(_ label: String) -> [String] {
        let l = label.lowercased()
        let map: [(String, [String])] = [
            ("action", ["Action", "Abenteuer"]), ("abenteuer", ["Abenteuer"]), ("kom", ["Komödie"]), ("comedy", ["Komödie"]),
            ("drama", ["Drama"]), ("horror", ["Horror"]), ("thriller", ["Thriller"]), ("krimi", ["Krimi"]),
            ("kinder", ["Familie", "Animation"]), ("familie", ["Familie"]), ("sci-fi", ["Science-Fiction", "Fantasy"]),
            ("science", ["Science-Fiction"]), ("fantasy", ["Fantasy"]), ("liebes", ["Romanze"]), ("roman", ["Romanze"]),
            ("anime", ["Animation"]), ("animation", ["Animation"]), ("doku", ["Dokumentarfilm"]), ("musical", ["Musical"]),
            ("musik", ["Musik"]), ("sport", ["Sport"]), ("western", ["Western"])
        ]
        var out: [String] = []
        for (needle, names) in map where l.contains(needle) { for n in names where !out.contains(n) { out.append(n) } }
        return out
    }

    static func search(_ query: String) async -> [Film] {
        guard let url = WatchLinks.url("https://itunes.apple.com/search",
                                       ["term": query, "country": "de", "media": "movie", "entity": "movie", "lang": "de_de", "limit": "40"]),
              let data = await OnlineCatalog.get(url),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return response.results.compactMap(\.film)
    }

    static func lookup(_ film: Film) async -> FilmDetails? {
        let id = film.id.replacingOccurrences(of: "itunes-", with: "")
        guard let url = WatchLinks.url("https://itunes.apple.com/lookup", ["id": id, "country": "de", "lang": "de_de"]),
              let data = await OnlineCatalog.get(url),
              let found = (try? JSONDecoder().decode(Response.self, from: data))?.results.first?.film else { return nil }
        return FilmDetails(film: found, availability: nil)
    }

    // Bestenlisten des iTunes Store je Genre (ohne Schlüssel, ohne Seiten).
    struct Label: Decodable { let label: String }
    struct Attributed: Decodable { let label: String?; let attributes: [String: String]? }
    struct Entry: Decodable {
        let name: Label
        let image: [Label]?
        let summary: Label?
        let artist: Label?
        let releaseDate: Label?
        let id: Attributed
        let category: Attributed?

        enum CodingKeys: String, CodingKey {
            case name = "im:name", image = "im:image", summary, artist = "im:artist", releaseDate = "im:releaseDate", id, category
        }
    }
    struct Feed: Decodable {
        struct Inner: Decodable { let entry: [Entry]? }
        let feed: Inner
    }

    static let genreIDs: [String: Int] = [
        "Action": 4401, "Abenteuer": 4401, "Animation": 4410, "Familie": 4410, "Komödie": 4404, "Drama": 4406,
        "Horror": 4408, "Romanze": 4412, "Science-Fiction": 4413, "Fantasy": 4413, "Thriller": 4416, "Krimi": 4416,
        "Mystery": 4416, "Sport": 4417, "Musical": 4411, "Musik": 4411, "Dokumentarfilm": 4405, "Western": 4418
    ]

    static func top(genre: String?) async -> [Film] {
        var path = "https://itunes.apple.com/de/rss/topmovies/limit=100"
        if let genre {
            guard let id = genreIDs[genre] else { return [] }
            path += "/genre=\(id)"
        }
        guard let url = URL(string: path + "/json"),
              let data = await OnlineCatalog.get(url),
              let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return (feed.feed.entry ?? []).compactMap { entry -> Film? in
            guard let trackID = entry.id.attributes?["im:id"] else { return nil }
            let date = entry.releaseDate?.label ?? ""
            let genres = ITunes.genres(entry.category?.attributes?["label"] ?? "")
            return Film(
                id: "itunes-\(trackID)",
                title: entry.name.label,
                originalTitle: entry.name.label,
                year: Int(date.prefix(4)) ?? 0,
                runtime: 0,
                genres: genres,
                moods: WikidataLookup.moods(for: genres),
                director: entry.artist?.label ?? "",
                cast: [],
                fsk: -1,
                synopsis: OnlineCatalog.clean(entry.summary?.label),
                youtubeID: "",
                imdbID: "",
                poster: entry.image?.last.map { ITunes.largeArtwork($0.label) },
                imdbRating: nil,
                rottenTomatoes: nil,
                metascore: nil,
                trailers: [],
                comingSoon: false,
                releaseNote: nil,
                mlBias: nil,
                mlFactors: nil,
                mlSeen: nil,
                link: entry.id.label
            )
        }
    }
}
