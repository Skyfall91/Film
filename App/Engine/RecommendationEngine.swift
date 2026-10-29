import Foundation
import Accelerate

/// Ein Vorschlag inkl. Begründung, „Warum dieser Film?“ ist Teil des Konzepts.
struct Recommendation: Identifiable, Hashable {
    var film: Film
    /// 0-100, wie gut der Film zur aktuellen Runde passt.
    var match: Int
    var reason: String
    /// Kommt von der Watchlist: „Auf deiner Liste, seit 5 Wochen“.
    var watchlistNote: String? = nil
    var id: String { film.id }
}

/// Inhaltsbasierte Empfehlung: Filme werden über ihre Merkmale (Genre, Stimmung,
/// Regie, Besetzung) mit dem gelernten Geschmacksprofil verglichen.
/// Bei mehreren Profilen zählt vor allem, dass *niemand* leer ausgeht.
enum RecommendationEngine {

    /// Hybrid, getestet an 8.116 echten Personen aus MovieLens 32M:
    /// Filmbonus + „Leute wie du“ + etwas Qualität + Inhalt (Genre, Stimmung, Regie) + Chat-Hinweise.
    static func score(_ film: Film, for profile: Profile) -> Double {
        var collaborative = film.mlBias ?? 0
        if let q = film.mlFactors, q.count == profile.taste.count {
            collaborative += zip(q, profile.taste).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let content = film.features.reduce(0) { $0 + profile.weights[$1.key, default: 0] * $1.weight }
        let hints = film.features.reduce(0) { $0 + profile.hints[$1.key, default: 0] * $1.weight }
        // Serien werden auf IMDb im Schnitt gut eine Note besser bewertet als Filme (8,6 vs. 7,4), // ohne Ausgleich stünden sie fast immer oben.
        let quality = ((film.imdbRating ?? 7) - 7 - (film.isSeries ? 1.1 : 0)) * 0.08
        return collaborative + quality + 0.06 * content + 0.12 * hints
    }

    static func matchPercent(_ score: Double) -> Int {
        let p = 0.52 + 0.47 * tanh(score / 0.6)
        return Int((p * 100).rounded()).clamped(to: 20...99)
    }

    /// Kombinierter Wert für eine Runde mit mehreren Profilen („least misery“):
    /// Der schwächste Einzelwert zählt stärker als der Durchschnitt.
    static func groupScore(_ film: Film, profiles: [Profile]) -> Double {
        let scores = profiles.map { score(film, for: $0) }
        guard let minS = scores.min() else { return 0 }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return profiles.count == 1 ? mean : 0.6 * minS + 0.4 * mean
    }

    static func candidates(profiles: [Profile], runtime: RuntimeFilter?, kind: KindFilter = .all, skipped: Set<String>) -> [Film] {
        return FilmIndex.all.filter { film in
            guard !film.comingSoon, profiles.allSatisfy({ $0.allows(film) }), !skipped.contains(film.id), kind.allows(film) else { return false }
            if let runtime, !runtime.allows(film.runtime) { return false }
            return !profiles.contains { $0.interactions[film.id]?.excludesFromDeck == true }
        }
    }

    static func recommendations(profiles: [Profile], runtime: RuntimeFilter?, kind: KindFilter = .all, skipped: Set<String>, limit: Int = 3) -> [Recommendation] {
        candidates(profiles: profiles, runtime: runtime, kind: kind, skipped: skipped)
            .map { ($0, groupScore($0, profiles: profiles)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { Recommendation(film: $0.0, match: matchPercent($0.1), reason: reason(for: $0.0, profiles: profiles)) }
    }

    // MARK: - Begründung

    /// Ein sachlicher Satz statt „Weil du X mochtest“: was genau an diesem Film zu dir passt.
    /// Reihenfolge nach Aussagekraft: dieselbe Regie, dieselbe Besetzung, mag/meide-Kontrast,
    /// gemeinsame Stimmung mit einem Lieblingsfilm, die eigene Mischung, zuletzt die Kritik.
    /// Regie und Besetzung bekommen die passende Stimmung angehängt, wenn es eine gibt.
    static func reason(for film: Film, profiles: [Profile]) -> String {
        if profiles.count > 1 { return groupReason(for: film, profiles: profiles) }
        guard let profile = profiles.first else { return "" }
        let favorites = favorites(of: profile, excluding: film.id)
        let liked = film.moods
            .map { ($0, profile.affinity["m:\($0)", default: 0]) }
            .filter { $0.1 > 0.5 }
            .sorted { $0.1 > $1.1 }
        let mood = liked.first.map { ", \($0.0) wie deine Favoriten" } ?? ""

        if !film.director.isEmpty, let first = favorites.first(where: { $0.director == film.director }) {
            return "Gleiche Regie wie „\(first.title)“" + mood
        }
        let actor = film.cast.prefix(3)
            .map { name in (name, favorites.filter { $0.cast.prefix(3).contains(name) }) }
            .max { $0.1.count < $1.1.count }
        if let actor, actor.1.count >= 2 {
            return "\(actor.0) spielt auch in \(actor.1.count == 2 ? "zwei" : actor.1.count == 3 ? "drei" : "\(actor.1.count)") deiner Favoriten"
        }
        if let top = liked.first?.0, let avoided = avoidedMood(beside: top, in: film, profile: profile) {
            return "\(top.moodLabel) wie deine Favoriten, aber nicht \(avoided)"
        }
        if let similar = mostSimilarFavorite(to: film, profile: profile) {
            let shared = film.moods.filter(similar.moods.contains)
                .sorted { profile.affinity["m:\($0)", default: 0] > profile.affinity["m:\($1)", default: 0] }
            if let m = shared.first { return "Genauso \(m) wie „\(similar.title)“" }
        }
        if let actor, let film = actor.1.first { return "Mit \(actor.0) aus „\(film.title)“" + mood }
        if liked.count >= 2 { return "\(liked[0].0.moodLabel) und \(liked[1].0), wie deine Favoriten" }
        if let top = liked.first?.0 { return "\(top.moodLabel), wie deine Favoriten" }
        if let rating = film.imdbRating, rating >= 8 {
            return "Bei IMDb mit \(rating.formatted(.number.precision(.fractionLength(1)))) bewertet"
        }
        let moods = film.moods.prefix(2)
        return moods.isEmpty ? "Mal etwas anderes für dich" : "Mal etwas anderes: \(moods.joined(separator: " und "))"
    }

    /// Für mehrere: was jede Person an dem Film hat, oder dass niemand etwas meiden muss.
    static func groupReason(for film: Film, profiles: [Profile]) -> String {
        // Je Person das stärkste Merkmal: zuerst eine Stimmung, sonst ein Genre („Abenteuer für Ceren“).
        let picks = profiles.map { p -> (name: String, mood: String?) in
            let mood = film.moods
                .map { ($0, p.affinity["m:\($0)", default: 0]) }
                .filter { $0.1 > 0.3 }
                .max { $0.1 < $1.1 }
            let genre = film.genres
                .map { ($0, p.affinity["g:\($0)", default: 0]) }
                .filter { $0.1 > 0.3 }
                .max { $0.1 < $1.1 }
            return (p.name, mood?.0 ?? genre?.0)
        }
        let common = film.moods.filter { m in profiles.allSatisfy { $0.affinity["m:\(m)", default: 0] > 0.3 } }
            .max { a, b in
                profiles.map { $0.affinity["m:\(a)", default: 0] }.min()! < profiles.map { $0.affinity["m:\(b)", default: 0] }.min()!
            }
        if let common { return "\(common.moodLabel), das mögt ihr \(profiles.count == 2 ? "beide" : "alle")" }
        let happy = picks.filter { $0.mood != nil }
        if happy.count >= 2 {
            if happy.count == 2 { return "\(happy[0].mood!.moodLabel) für \(happy[0].name), \(happy[1].mood!) für \(happy[1].name)" }
            let moods = Array(Set(happy.compactMap(\.mood))).sorted().prefix(3)
            return "Für jeden etwas: \(moods.joined(separator: ", "))"
        }
        let nobodyMinds = profiles.allSatisfy { p in film.features.allSatisfy { p.affinity[$0.key, default: 0] > -0.3 } }
        if let one = happy.first, nobodyMinds {
            let others = picks.filter { $0.mood == nil }.map(\.name).formatted(.list(type: .and))
            return "\(one.mood!.moodLabel) für \(one.name), nichts, was \(others) meidet"
        }
        if let rating = film.imdbRating, rating >= 8 {
            return "Bei IMDb mit \(rating.formatted(.number.precision(.fractionLength(1)))), nichts, was einer von euch meidet"
        }
        return "Nichts dabei, was einer von euch meidet"
    }

    /// Eine Stimmung, die das Profil meidet, die oft mit `mood` zusammen kommt und hier fehlt.
    private static func avoidedMood(beside mood: String, in film: Film, profile: Profile) -> String? {
        let avoided = profile.affinity.filter { entry in
            entry.key.hasPrefix("m:") && entry.value < -0.5
        }
        let candidates = avoided.compactMap { entry -> (String, Double)? in
            let name = String(entry.key.dropFirst(2))
            let together = cooccurrence[mood]?[name] ?? 0
            return film.moods.contains(name) || together < 0.25 ? nil : (name, entry.value)
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Gemochte Filme eines Profils, die stärksten zuerst (feste Reihenfolge, sonst springt der Grund).
    static func favorites(of profile: Profile, excluding id: String) -> [Film] {
        let liked: [(film: Film, signal: Double)] = profile.interactions.compactMap { entry in
            guard entry.value.isPositive, entry.key != id, let film = FilmIndex.film(entry.key) else { return nil }
            return (film, entry.value.signal)
        }
        return liked
            .sorted { a, b in a.signal != b.signal ? a.signal > b.signal : a.film.title < b.film.title }
            .map(\.film)
    }

    /// Wie oft eine Stimmung B in Filmen mit Stimmung A vorkommt. „Spannend, aber nicht gruselig“
    /// ist nur dann ein Grund, wenn spannende Filme oft auch gruselig sind.
    static let cooccurrence: [String: [String: Double]] = {
        var result: [String: [String: Double]] = [:]
        for a in FilmIndex.allMoods {
            let with = FilmIndex.all.filter { $0.moods.contains(a) }
            guard !with.isEmpty else { continue }
            for b in FilmIndex.allMoods where b != a {
                result[a, default: [:]][b] = Double(with.filter { $0.moods.contains(b) }.count) / Double(with.count)
            }
        }
        return result
    }()

    static func mostSimilarFavorite(to film: Film, profile: Profile) -> Film? {
        // Zuerst „Leute wie du“: Welcher Lieblingsfilm wird von denselben Menschen gemocht?
        if let q = film.mlFactors {
            let best = profile.interactions
                .filter { $0.value.isPositive && $0.key != film.id }
                .compactMap { FilmIndex.film($0.key) }
                .compactMap { f in f.mlFactors.map { (f, cosine(q, $0)) } }
                .max { $0.1 < $1.1 }
            if let best, best.1 > 0.35 { return best.0 }
        }
        let target = Set(film.features.map(\.key))
        return profile.interactions
            .filter { $0.value.isPositive && $0.key != film.id }
            .compactMap { FilmIndex.film($0.key) }
            .map { ($0, Set($0.features.map(\.key)).intersection(target).count) }
            .filter { $0.1 >= 2 }
            .max { $0.1 < $1.1 }?.0
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = sqrt(a.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.reduce(0) { $0 + $1 * $1 })
        return na > 0 && nb > 0 ? dot / (na * nb) : 0
    }

    /// Lesbare Bezeichnung für ein Merkmal.
    static func label(_ key: String) -> String {
        let value = String(key.dropFirst(2))
        switch key.prefix(2) {
        case "m:": return value.moodLabel + "es"
        case "g:": return value
        case "d:": return "Filme von \(value)"
        default: return value
        }
    }
}

// MARK: - Zeitfilter

/// „Wie viel Zeit hast du?“, höchstens oder mindestens so lang.
/// Film, Serie oder beides, wählbar auf der Startseite.
enum KindFilter: String, CaseIterable, Identifiable {
    case all, films, series
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Beides"
        case .films: "Filme"
        case .series: "Serien"
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .films: "film"
        case .series: "tv"
        }
    }
    func allows(_ film: Film) -> Bool {
        switch self {
        case .all: true
        case .films: !film.isSeries
        case .series: film.isSeries
        }
    }
}

/// Laufzeit als Bereich: mindestens, höchstens oder beides („1,5 bis 2,5 Std.“).
struct RuntimeFilter: Equatable {
    var min: Int?
    var max: Int?

    init(min: Int? = nil, max: Int? = nil) { self.min = min; self.max = max }
    /// Eine Grenze: höchstens (Standard) oder mindestens.
    init(minutes: Int, atLeast: Bool = false) { self.init(min: atLeast ? minutes : nil, max: atLeast ? nil : minutes) }

    /// Die Dauer, an der sich Schnellwahlen orientieren: die Obergrenze, sonst die Untergrenze.
    var minutes: Int { max ?? min ?? 0 }

    func allows(_ runtime: Int) -> Bool {
        (min.map { runtime >= $0 } ?? true) && (max.map { runtime <= $0 } ?? true)
    }

    /// „bis 2 Std.“, „ab 1,5 Std.“ oder „1,5 bis 2,5 Std.“
    var label: String {
        switch (min, max) {
        case let (lo?, hi?): "\(Self.short(lo, unit: false)) bis \(Self.short(hi))"
        case let (lo?, nil): "ab \(Self.short(lo))"
        case let (nil, hi?): "bis \(Self.short(hi))"
        case (nil, nil): "Egal"
        }
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? (m > 0 ? "\(h) Std. \(m) Min." : "\(h) Std.") : "\(m) Min."
    }

    /// Kurz für Menü und Kopfzeile: „2 Std.“, „1,5 Std.“, „1:45 Std.“, „45 Min.“
    static func short(_ minutes: Int, unit: Bool = true) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) Min." }
        let value = m == 0 ? "\(h)" : m == 30 ? "\(h),5" : "\(h):\(String(format: "%02d", m))"
        return unit ? value + " Std." : value
    }
}

// MARK: - Lernen: Ridge-Regression

/// Lernt aus den bewerteten Filmen, wie stark jedes Merkmal den Geschmack bestimmt.
/// Anders als einfaches Aufsummieren werden alle Merkmale *gemeinsam* geschätzt:
/// Liebt jemand drei düstere Nolan-Thriller, bekommt nicht jedes Merkmal den vollen
/// Kredit, sondern das, was die Bewertungen am besten erklärt. Offline-Test: +6-7 Punkte
/// Treffer gegenüber der Summen-Variante. Chat-Hinweise dienen als Vorwissen.
enum TasteModel {
    static let lambda = 3.0
    static let hintScale = 0.25
    static let maxSamples = 200

    /// „Leute wie du“: persönliche Faktoren aus den eigenen Swipes schätzen (Fold-in mit
    /// starker Regularisierung, λ = 100, im Test an echten Personen am besten).
    static func foldIn(samples: [Profile.Sample]) -> [Double] {
        let rows = samples.suffix(maxSamples).compactMap { s -> ([Double], Double, Double)? in
            guard let f = FilmIndex.film(s.filmID), let q = f.mlFactors else { return nil }
            return (q, stars(s.target), f.mlBias ?? 0)
        }
        guard let k = rows.first?.0.count, !rows.isEmpty else { return [] }
        let mean = rows.count > 2 ? rows.map(\.1).reduce(0, +) / Double(rows.count) : 0
        let width = k + 1
        var a = [Double](repeating: 0, count: k * width)
        a.withUnsafeMutableBufferPointer { m in
            for (q, y, bias) in rows {
                let target = y - 0.5 * mean - bias
                q.withUnsafeBufferPointer { v in
                    for i in 0..<k {
                        let qi = v[i], row = i * width
                        for j in 0..<k { m[row + j] += qi * v[j] }
                        m[row + k] += qi * target
                    }
                }
            }
            for i in 0..<k { m[i * width + i] += 100 }
        }
        return solve((0..<k).map { Array(a[($0 * width)..<($0 * width + width)]) })
    }

    /// Swipe-Signal → grobe Abweichung vom eigenen Schnitt (wie im Test: Liebe +1, Mag +0,3, Mag nicht −1).
    static func stars(_ signal: Double) -> Double {
        if signal >= 1.8 { return 1 }
        if signal > 0 { return 0.3 * min(signal, 1.5) }
        return max(signal, -1)
    }

    /// Gauß-Jordan für das erweiterte System [A | b].
    static func solve(_ m: [[Double]]) -> [Double] {
        var a = m; let n = a.count
        for c in 0..<n {
            let p = (c..<n).max { abs(a[$0][c]) < abs(a[$1][c]) }!
            a.swapAt(c, p)
            guard a[c][c] != 0 else { continue }
            for r in 0..<n where r != c {
                let f = a[r][c] / a[c][c]
                if f != 0 { for k in c...n { a[r][k] -= f * a[c][k] } }
            }
        }
        return (0..<n).map { a[$0][$0] != 0 ? a[$0][n] / a[$0][$0] : 0 }
    }

    /// Ridge kernels are symmetric positive definite. Cholesky preserves the same
    /// solution without eliminating every row against every other row on the UI actor.
    static func solveRidge(_ m: [[Double]]) -> [Double] {
        let n = m.count
        guard n > 0 else { return [] }
        var lower = [Double](repeating: 0, count: n * n)
        var valid = true
        lower.withUnsafeMutableBufferPointer { l in
            for i in 0..<n {
                for j in 0...i {
                    var value = m[i][j]
                    if j > 0 {
                        var dot = 0.0
                        vDSP_dotprD(l.baseAddress! + i * n, 1, l.baseAddress! + j * n, 1, &dot, vDSP_Length(j))
                        value -= dot
                    }
                    if i == j {
                        guard value > 0, value.isFinite else { valid = false; return }
                        l[i * n + j] = sqrt(value)
                    } else { l[i * n + j] = value / l[j * n + j] }
                }
            }
        }
        guard valid else { return solve(m) }
        var result = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var value = m[i][n]
            for j in 0..<i { value -= lower[i * n + j] * result[j] }
            result[i] = value / lower[i * n + i]
        }
        for i in (0..<n).reversed() {
            var value = result[i]
            for j in (i + 1)..<n { value -= lower[j * n + i] * result[j] }
            result[i] = value / lower[i * n + i]
        }
        return result
    }

    /// Merkmale als Zahlen-Indizes, der Kernel über ein invertiertes Verzeichnis: Nur Filme mit
    /// gemeinsamen Merkmalen tragen etwas bei. Läuft bei jedem Swipe, deshalb ohne Wörterbuch-Vergleiche.
    static func fit(samples: [Profile.Sample], hints: [String: Double], external: [String: ExternalFilm] = [:]) -> [String: Double] {
        let prior = hints.mapValues { $0 * hintScale }
        var keys: [String] = [], index: [String: Int] = [:]
        var rows: [(features: [(Int, Double)], target: Double)] = []
        for s in samples.suffix(maxSamples) {
            guard let features = FilmIndex.film(s.filmID)?.features ?? external[s.filmID]?.features else { continue }
            var merged: [Int: Double] = [:]
            for f in features {
                let k = index[f.key] ?? { keys.append(f.key); index[f.key] = keys.count - 1; return keys.count - 1 }()
                merged[k, default: 0] += f.weight
            }
            rows.append((merged.map { ($0.key, $0.value) }, s.target))
        }
        guard !rows.isEmpty else { return prior }
        let n = rows.count
        let mean = n > 2 ? rows.map(\.target).reduce(0, +) / Double(n) : 0
        let priorByIndex = keys.map { prior[$0] ?? 0 }
        var postings = [[(row: Int, x: Double)]](repeating: [], count: keys.count)
        for (i, row) in rows.enumerated() { for (k, x) in row.features { postings[k].append((i, x)) } }
        // Erweiterte Matrix [K + λI | y − X·w₀], flach gespeichert.
        let width = n + 1
        var a = [Double](repeating: 0, count: n * width)
        for list in postings {
            for p in list { for q in list where q.row >= p.row { a[p.row * width + q.row] += p.x * q.x } }
        }
        for i in 0..<n {
            for j in (i + 1)..<n { a[j * width + i] = a[i * width + j] }
            a[i * width + i] += lambda
            a[i * width + n] = rows[i].target - 0.5 * mean - rows[i].features.reduce(0) { $0 + $1.1 * priorByIndex[$1.0] }
        }
        let matrix = (0..<n).map { Array(a[($0 * width)..<($0 * width + width)]) }
        let solution = solveRidge(matrix)
        var w = prior
        for i in 0..<n {
            let alpha = solution[i]
            for (k, x) in rows[i].features { w[keys[k], default: 0] += alpha * x }
        }
        return w
    }

}

// MARK: - Geschmacksprofil (für Onboarding-Abschluss & Profil-Tab)

struct TasteSummary {
    var topMoods: [(String, Double)]
    var topGenres: [(String, Double)]
    var favoriteDirector: String?
    var avoid: [String]

    init(profile: Profile) {
        func top(_ prefix: String, _ n: Int) -> [(String, Double)] {
            profile.affinity.filter { $0.key.hasPrefix(prefix) && $0.value > 0.2 }
                .sorted { $0.value > $1.value }
                .prefix(n)
                .map { (String($0.key.dropFirst(2)), $0.value) }
        }
        topMoods = top("m:", 4)
        topGenres = top("g:", 3)
        favoriteDirector = top("d:", 1).first.flatMap { $0.1 > 1.5 ? $0.0 : nil }
        avoid = profile.affinity.filter { ($0.key.hasPrefix("m:") || $0.key.hasPrefix("g:")) && $0.value < -0.8 }
            .sorted { $0.value < $1.value }.prefix(2).map { String($0.key.dropFirst(2)) }
    }

    /// Satz ohne KI, Fallback, wenn Apple Intelligence nicht verfügbar ist.
    var sentence: String {
        guard !topMoods.isEmpty || !topGenres.isEmpty else {
            return "Wir lernen dich gerade erst kennen. Jeder Swipe macht die Vorschläge besser."
        }
        var s = "Du stehst auf "
        let moods = topMoods.prefix(2).map(\.0)
        s += moods.isEmpty ? "gute Geschichten" : moods.map { $0 + "e" }.formatted(.list(type: .and)) + " Filme"
        if let g = topGenres.first?.0 { s += ", am liebsten \(g)" }
        s += "."
        if let d = favoriteDirector { s += " \(d) trifft deinen Nerv." }
        if let a = avoid.first { s += " \(a.moodLabel) eher nicht." }
        return s
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
