import Foundation
#if !os(tvOS)
import FoundationModels
#endif

/// Strukturierte Interpretation einer freien Stimmungs-Anfrage.
/// Das Sprachmodell kennt den Katalog NICHT, es übersetzt nur die Anfrage
/// in Filter. Gesucht wird danach im eigenen Index (keine erfundenen Filme).
#if os(tvOS)
struct MoodQuery: Codable {
    var moods: [String]

    var genres: [String]

    var exclude: [String]

    var maxRuntimeMinutes: Int

    var familyFriendly: Bool

    var similarTo: String

    var summary: String
}
#else
@Generable
struct MoodQuery: Codable {
    @Guide(description: "Passende Stimmungen, NUR aus dieser Liste: spannend, düster, lustig, gefühlvoll, episch, gemütlich, nachdenklich, gruselig, actionreich, romantisch, bildgewaltig, schräg, inspirierend, familienfreundlich, wendungsreich, musikalisch, leicht, intensiv, bunt, ruhig")
    var moods: [String]

    @Guide(description: "Passende Genres, NUR aus dieser Liste: Action, Abenteuer, Drama, Komödie, Science-Fiction, Fantasy, Horror, Thriller, Mystery, Krimi, Romanze, Animation, Biografie, Musical, Familie, Sport. Leer lassen, wenn unklar.")
    var genres: [String]

    @Guide(description: "Genres oder Stimmungen, die ausdrücklich NICHT gewünscht sind (gleiche Listen wie oben)")
    var exclude: [String]

    @Guide(description: "Maximale Laufzeit in Minuten, falls die Person eine Zeitangabe macht, sonst 0")
    var maxRuntimeMinutes: Int

    @Guide(description: "true, wenn Kinder mitschauen oder ein Familienfilm gewünscht ist")
    var familyFriendly: Bool

    @Guide(description: "Ein Filmtitel, falls die Person 'so wie X' oder 'ähnlich wie X' sagt, sonst leer")
    var similarTo: String

    @Guide(description: "Sehr kurze deutsche Zusammenfassung des Wunsches, max. 6 Wörter, z. B. 'Leichte Komödie für zwei'")
    var summary: String
}
#endif

struct MoodResult {
    var query: MoodQuery
    var films: [Recommendation]
    var usedAppleIntelligence: Bool
    /// Erkannte Personen aus Besetzung und Regie.
    var people: [String] = []
}

enum MoodSearch {

    #if !os(tvOS)
    /// Die Abfrage beim System kostet spürbar Zeit und lief sonst bei jedem Neuzeichnen der Suche.
    /// Ein paar Sekunden alt ist genau genug: Ein Modell, das gerade fertig lädt, ist kurz danach da.
    private static var cachedAvailability: (value: SystemLanguageModel.Availability, at: Date)?
    private static var availability: SystemLanguageModel.Availability {
        if let cached = cachedAvailability, cached.at.timeIntervalSinceNow > -10 { return cached.value }
        let value = SystemLanguageModel.default.availability
        cachedAvailability = (value, .now)
        return value
    }
    #endif

    static var isAppleIntelligenceAvailable: Bool {
        #if os(tvOS)
        return false
        #else
        if case .available = availability { return true }
        return false

        #endif
    }

    static var availabilityNote: String {
        #if os(tvOS)
        return "Stichwortsuche · KI auf dem iPhone"
        #else
        switch availability {
        case .available: "Apple Intelligence · auf dem Gerät"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence ist ausgeschaltet, Stichwortsuche aktiv"
        case .unavailable(.deviceNotEligible): "Gerät ohne Apple Intelligence, Stichwortsuche aktiv"
        case .unavailable(.modelNotReady): "Modell wird geladen, Stichwortsuche aktiv"
        default: "Stichwortsuche aktiv"
        }

        #endif
    }

    static func search(_ text: String, profiles: [Profile]) async -> MoodResult {
        // Steht eine Person im Text, zählen nur ihre Filme. Der Rest („lustig“) sortiert innerhalb davon.
        let named = people(in: text)
        let rest = named.isEmpty ? text : removing(named, from: text)
        let result = await interpret(rest, profiles: profiles)
        return applyingPeople(named, remainingText: rest, to: result, profiles: profiles)
    }

    /// Sofortige Stichworttreffer, während die genauere Interpretation noch läuft.
    static func quickSearch(_ text: String, profiles: [Profile]) -> MoodResult {
        let named = people(in: text)
        let rest = named.isEmpty ? text : removing(named, from: text)
        let query: MoodQuery
        let films: [Recommendation]
        if rest.contains(where: \.isLetter) {
            query = keywordQuery(rest)
            films = named.isEmpty ? rank(query, profiles: profiles) : []
        } else {
            query = MoodQuery(moods: [], genres: [], exclude: [], maxRuntimeMinutes: 0, familyFriendly: false, similarTo: "", summary: "")
            films = []
        }
        let result = MoodResult(query: query, films: films, usedAppleIntelligence: false)
        return applyingPeople(named, remainingText: rest, to: result, profiles: profiles)
    }

    private static func applyingPeople(_ named: [String], remainingText rest: String,
                                       to initial: MoodResult, profiles: [Profile]) -> MoodResult {
        var result = initial
        if !named.isEmpty {
            result.people = named
            if result.query.summary.isEmpty || !rest.contains(where: \.isLetter) {
                result.query.summary = "Mit " + named.joined(separator: " und ")
            }
            result.films = rank(result.query, profiles: profiles, people: named)
            // Hat die Deutung zu streng gefiltert (z. B. „familienfreundlich“), zählt die Person allein.
            if result.films.isEmpty {
                let plain = MoodQuery(moods: [], genres: [], exclude: [], maxRuntimeMinutes: 0, familyFriendly: false, similarTo: "", summary: "")
                result.films = rank(plain, profiles: profiles, people: named)
            }
        }
        return result
    }

    private static func interpret(_ text: String, profiles: [Profile]) async -> MoodResult {
        guard text.contains(where: \.isLetter) else {
            let empty = MoodQuery(moods: [], genres: [], exclude: [], maxRuntimeMinutes: 0, familyFriendly: false, similarTo: "", summary: "")
            return MoodResult(query: empty, films: [], usedAppleIntelligence: false)
        }
        #if os(tvOS)
        let query = keywordQuery(text)
        return MoodResult(query: query, films: rank(query, profiles: profiles), usedAppleIntelligence: false)
        #else
        var query = keywordQuery(text)
        var usedAI = false
        if isAppleIntelligenceAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                    Du bist die Suche eines Film-Streamingdienstes. Übersetze den Wunsch der Person \
                    in Filter. Nutze ausschließlich die vorgegebenen Begriffe. Erfinde keine Filme.
                    """)
                let response = try await session.respond(to: "Wunsch: \(text)", generating: MoodQuery.self)
                query = response.content
                usedAI = true
            } catch {
                // Fallback: Stichwortsuche (z. B. bei Guardrail-Treffern oder Modellfehlern)
            }
        }
        return MoodResult(query: query, films: rank(query, profiles: profiles), usedAppleIntelligence: usedAI)

        #endif
    }

    // MARK: - Personen aus Besetzung und Regie

    private static let allPeople: [String] = Array(Set(FilmIndex.all.flatMap { $0.cast + ($0.director.isEmpty ? [] : [$0.director]) }))

    private static func normalized(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "de_DE"))
    }

    private static func lastName(_ name: String) -> String? {
        name.split(separator: " ").last.map { normalized(String($0)) }.flatMap { $0.count >= 4 ? $0 : nil }
    }

    /// Alle Namensteile mit mindestens vier Buchstaben: „leonardo“ findet genauso wie „dicaprio“.
    private static func nameParts(_ name: String) -> [String] {
        name.split(separator: " ").map { normalized(String($0)) }.filter { $0.count >= 4 }
    }

    /// Namen im Suchtext: der ganze Name oder ein Nachname mit mindestens vier Buchstaben („dicaprio“).
    static func people(in text: String) -> [String] {
        let t = normalized(text)
        let full = allPeople.filter { t.contains(normalized($0)) }
        if !full.isEmpty { return full.sorted() }
        let words = Set(t.split { !$0.isLetter && $0 != "-" && $0 != "'" }.map(String.init))
        let byLast = allPeople.filter { lastName($0).map(words.contains) ?? false }
        if !byLast.isEmpty { return byLast.sorted() }
        // Nur ein Vorname, wenn er zu höchstens drei Personen passt. Sonst wäre es eher ein normales Wort.
        let byFirst = allPeople.filter { !Set(nameParts($0)).isDisjoint(with: words) }
        return byFirst.count <= 3 ? byFirst.sorted() : []
    }

    private static func removing(_ names: [String], from text: String) -> String {
        var rest = normalized(text)
        for name in names {
            rest = rest.replacingOccurrences(of: normalized(name), with: " ")
            for part in nameParts(name) { rest = rest.replacingOccurrences(of: part, with: " ") }
        }
        for filler in ["filme mit", "film mit", "serien mit", "mit", "von", "und"] {
            rest = rest.replacingOccurrences(of: "\\b\(filler)\\b", with: " ", options: .regularExpression)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ranking im eigenen Index

    /// `people`: nur Filme, in denen eine dieser Personen spielt oder Regie führt.
    static func rank(_ q: MoodQuery, profiles: [Profile], people: [String] = []) -> [Recommendation] {
        let wanted = Set(people)
        let moods = Set(q.moods.map { $0.lowercased() })
        let genres = Set(q.genres)
        let exclude = Set(q.exclude.map { $0.lowercased() })
        let reference = q.similarTo.isEmpty ? nil : FilmIndex.all.first {
            $0.title.localizedCaseInsensitiveContains(q.similarTo) || $0.originalTitle.localizedCaseInsensitiveContains(q.similarTo)
        }
        let fsk = min(profiles.map(\.maxFSK).min() ?? 18, q.familyFriendly ? 6 : 18)

        let scored: [(Film, Double)] = FilmIndex.all.compactMap { film in
            guard film.fsk <= fsk, profiles.allSatisfy({ $0.allows(film) }), film.id != reference?.id else { return nil }
            if !wanted.isEmpty, !film.cast.contains(where: wanted.contains), !wanted.contains(film.director) { return nil }
            if q.maxRuntimeMinutes > 0, film.runtime > q.maxRuntimeMinutes { return nil }
            let tags = Set(film.moods) .union(film.genres.map { $0.lowercased() })
            if !tags.isDisjoint(with: exclude) { return nil }
            var s = Double(Set(film.moods).intersection(moods).count) * 2
            s += Double(Set(film.genres).intersection(genres).count) * 1.5
            if let reference {
                s += Double(Set(film.features.map(\.key)).intersection(reference.features.map(\.key)).count) * 0.9
            }
            if q.familyFriendly, film.moods.contains("familienfreundlich") { s += 2 }
            guard s > 0 || !wanted.isEmpty || (moods.isEmpty && genres.isEmpty && reference == nil) else { return nil }
            // Persönlicher Geschmack als Feinsortierung
            s += profiles.isEmpty ? 0 : RecommendationEngine.groupScore(film, profiles: profiles) * 0.35
            if film.comingSoon { s -= 1.5 }
            return (film, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(12).map { film, _ in
            let personal = profiles.isEmpty ? 70 : RecommendationEngine.matchPercent(RecommendationEngine.groupScore(film, profiles: profiles))
            let hit = film.moods.filter(moods.contains).prefix(2).map(\.moodLabel)
            let person = (film.cast + [film.director]).first(where: wanted.contains)
            let reason = person.map { $0 == film.director ? "Regie: \($0)" : "Mit \($0)" } ?? reference.map { "Ähnlich wie „\($0.title)“" }
                ?? (hit.isEmpty ? film.genres.prefix(2).joined(separator: " · ") : hit.joined(separator: " · "))
            return Recommendation(film: film, match: personal, reason: reason)
        }
    }

    // MARK: - Fallback ohne KI: Stichwörter → Filter

    static func keywordQuery(_ text: String) -> MoodQuery {
        let t = text.lowercased()
        let map: [(words: [String], moods: [String], genres: [String])] = [
            (["lustig", "witzig", "lachen", "komödie", "humor", "spaß"], ["lustig", "leicht"], ["Komödie"]),
            (["grusel", "horror", "angst", "schocker", "fürchten"], ["gruselig"], ["Horror"]),
            (["düster", "dunkel", "finster", "noir"], ["düster"], []),
            (["romant", "liebe", "date", "verliebt"], ["romantisch"], ["Romanze"]),
            (["spannend", "thriller", "nervenkitzel", "spannung"], ["spannend", "wendungsreich"], ["Thriller"]),
            (["action", "krawall", "explosion", "kampf", "verfolgung"], ["actionreich"], ["Action"]),
            (["kind", "familie", "familien"], ["familienfreundlich"], ["Animation", "Familie"]),
            (["gemütlich", "entspannt", "chill", "sonntag", "kuschel", "cozy"], ["gemütlich", "leicht"], []),
            (["nachdenk", "tiefgründig", "anspruchsvoll", "philosoph"], ["nachdenklich"], []),
            (["weltall", "weltraum", "space", "sci-fi", "zukunft", "planet", "alien"], [], ["Science-Fiction"]),
            (["musik", "musical", "singen", "tanzen"], ["musikalisch"], ["Musical"]),
            (["traurig", "weinen", "emotional", "berührend", "herz"], ["gefühlvoll"], ["Drama"]),
            (["episch", "bombast", "groß", "kino", "bildgewaltig"], ["episch", "bildgewaltig"], []),
            (["schräg", "verrückt", "abgedreht", "skurril", "weird"], ["schräg"], []),
            (["wendung", "twist", "überraschend", "rätsel"], ["wendungsreich"], ["Mystery"]),
            (["motiv", "inspir", "mut"], ["inspirierend"], []),
            (["ruhig", "langsam", "leise"], ["ruhig"], []),
            (["intensiv", "heftig", "krass"], ["intensiv"], [])
        ]
        var moods: [String] = [], genres: [String] = []
        for entry in map where entry.words.contains(where: t.contains) {
            moods += entry.moods; genres += entry.genres
        }
        var runtime = 0
        if let m = t.firstMatch(of: /(\d{2,3})\s*min/) { runtime = Int(m.1) ?? 0 }
        else if let m = t.firstMatch(of: /(\d)[,.]?(\d)?\s*(std|stunde)/) {
            runtime = (Int(m.1) ?? 0) * 60 + (m.2.flatMap { Int($0) }.map { $0 * 6 } ?? 0)
        } else if t.contains("kurz") || t.contains("nicht so lang") { runtime = 110 }
        var similar = ""
        if let m = t.firstMatch(of: /(?:wie|ähnlich wie|so wie)\s+(.+)$/) {
            let candidate = String(m.1).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if FilmIndex.all.contains(where: { $0.title.lowercased().contains(candidate) || $0.originalTitle.lowercased().contains(candidate) }) {
                similar = candidate
            }
        }
        return MoodQuery(moods: Array(Set(moods)), genres: Array(Set(genres)), exclude: [],
                         maxRuntimeMinutes: runtime, familyFriendly: t.contains("kind") || t.contains("famil"),
                         similarTo: similar, summary: "")
    }
}

// MARK: - Geschmacks-Satz mit Apple Intelligence (Fallback: Template)

enum TasteWriter {
    /// Die Fakten, aus denen der Satz entsteht. Ändern sie sich nicht, bleibt auch der Satz.
    private static func facts(_ summary: TasteSummary) -> String {
        """
        Lieblingsstimmungen: \(summary.topMoods.map(\.0).joined(separator: ", ")). \
        Lieblingsgenres: \(summary.topGenres.map(\.0).joined(separator: ", ")). \
        Lieblingsregie: \(summary.favoriteDirector ?? "keine"). \
        Eher nicht: \(summary.avoid.joined(separator: ", ")).
        """
    }

    private static func cacheKey(_ profile: Profile) -> String { "tasteSentence.\(profile.id)" }

    /// Bereits generierter Satz, solange die Geschmacksdaten unverändert sind, sofort, ohne Modellaufruf.
    static func cached(for profile: Profile) -> String? {
        guard let entry = UserDefaults.standard.dictionary(forKey: cacheKey(profile)) as? [String: String],
              entry["facts"] == facts(TasteSummary(profile: profile)) else { return nil }
        return entry["text"]?.withoutDashes
    }

    static func sentence(for profile: Profile) async -> (String, Bool) {
        #if os(tvOS)
        return (TasteSummary(profile: profile).sentence, false)
        #else
        let summary = TasteSummary(profile: profile)
        guard MoodSearch.isAppleIntelligenceAvailable, !summary.topMoods.isEmpty else { return (summary.sentence, false) }
        if let cached = cached(for: profile) { return (cached, true) }
        let facts = facts(summary)
        do {
            let session = LanguageModelSession(instructions: """
                Schreibe EINEN kurzen deutschen Satz (max. 25 Wörter), der den Filmgeschmack beschreibt. \
                Regeln: Beginne mit „Du“. Keine Begrüßung, keine Anrede, kein Name. \
                Verwende keine geschlechtsspezifischen Wörter (z. B. keine Personenbezeichnungen wie \
                Entdecker, Fan, Liebhaber, weder männlich noch weiblich). Keine Ich-Perspektive. \
                Keine Filmtitel und keine Personennamen. Keine Gedankenstriche.
                """)
            let text = try await session.respond(to: facts).content
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"„“")))
                .withoutDashes
            guard isNeutral(text) else { return (summary.sentence, false) }
            UserDefaults.standard.set(["facts": facts, "text": text], forKey: cacheKey(profile))
            return (text, true)
        } catch {
            return (summary.sentence, false)
        }

        #endif
    }

    /// Sicherheitsnetz: Anreden oder gegenderte Personenbezeichnungen → neutraler Standardsatz.
    static func isNeutral(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.hasPrefix("du"), text.count < 220 else { return false }
        // „ich“ nur als ganzes Wort, sonst fliegen „dich“ und „mich“ mit raus.
        if t.firstMatch(of: /\bich\b/) != nil { return false }
        let banned = ["hallo", "hi ", "hey", "liebe ", "lieber ", "liebe:",
                      "entdeckerin", "entdecker", "liebhaberin", "liebhaber", "kennerin", "kenner",
                      "freundin", "freund ", "fan ", "cineast", "filmfan", "zuschauerin", "zuschauer"]
        if banned.contains(where: t.contains) { return false }
        // Typische weibliche Personenendungen („-erin“, „-istin“)
        return t.firstMatch(of: /\b\w+(erin|istin|innen)\b/) == nil
    }
}

// MARK: - Notlösung: Anreißer schreiben, wenn ein Film keine Beschreibung hat

/// Schreibt NUR aus gesicherten Metadaten (Genre, Stimmung, Regie, Laufzeit) einen
/// kurzen, spoilerfreien Anreißer. Keine Handlungsdetails, das kleine Modell kennt
/// viele Filme nicht und würde sonst raten. Ergebnis wird gecacht.
enum SynopsisWriter {
    static func teaser(for film: Film) async -> String? {
        #if os(tvOS)
        return UserDefaults.standard.string(forKey: "teaser.\(film.id)")
        #else
        let cacheKey = "teaser.\(film.id)"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) { return cached.withoutDashes }
        guard MoodSearch.isAppleIntelligenceAvailable else { return nil }
        let facts = """
            Titel: \(film.title). Jahr: \(film.year). Genres: \(film.genres.joined(separator: ", ")). \
            Stimmung: \(film.moods.joined(separator: ", ")). Regie: \(film.director). Laufzeit: \(film.runtime) Minuten.
            """
        do {
            let session = LanguageModelSession(instructions: """
                Schreibe 1-2 kurze deutsche Sätze, die neugierig auf einen Film machen. \
                Nutze NUR die gegebenen Fakten, erfinde keine Handlung, keine Figuren und keine Wendungen. \
                Beschreibe Stimmung und Art des Films. Keine Anrede, keine gegenderten Wörter, keine Gedankenstriche.
                """)
            let text = try await session.respond(to: facts).content
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"„“")))
                .withoutDashes
            UserDefaults.standard.set(text, forKey: cacheKey)
            return text
        } catch {
            return nil
        }

        #endif
    }
}
