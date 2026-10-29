import SwiftUI

/// Was ein Profil mit einem Film gemacht hat.
enum Interaction: String, Codable, Sendable {
    // Onboarding-Kalibrierung
    case liked, disliked, loved, unseen
    // Empfehlungsmodus (Swipe-Gesten)
    case notToday, watchlist, alreadySeen, played
    // Bewertung nach dem Schauen
    case ratedDown, ratedOkay, ratedUp, ratedLove

    /// Wie stark das Signal ins Geschmacksprofil eingeht.
    /// „Heute nicht“ ist schwächer als „mag ich nicht“, aber spürbar, sonst schlägt der
    /// Stapel nach einem Wisch immer wieder Ähnliches vor (Offline-Test: −0,5 statt −0,15).
    var signal: Double {
        switch self {
        case .loved, .ratedLove: 2.0
        case .liked, .ratedUp: 1.0
        case .played: 0.8
        case .watchlist: 0.6
        case .ratedOkay: 0.2
        case .unseen, .alreadySeen: 0
        case .notToday: -0.5
        case .disliked: -1.0
        case .ratedDown: -1.2
        }
    }

    /// Filme mit diesen Interaktionen werden nicht mehr vorgeschlagen.
    var excludesFromDeck: Bool {
        switch self {
        case .liked, .disliked, .loved, .alreadySeen, .played,
             .ratedDown, .ratedOkay, .ratedUp, .ratedLove, .watchlist: true
        case .unseen, .notToday: false
        }
    }

    var isPositive: Bool { signal >= 1 }
}

struct Review: Codable, Hashable, Sendable {
    var filmID: String
    var rating: Interaction
    var text: String
    var date: Date
}

struct Profile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var maxFSK: Int = 18
    /// Profil für kleine Kinder (bis etwa 5): nur Animations- und Familientitel ab 0,
    /// und die Eltern wählen die Lieblingsfilme, statt das Kind wischen zu lassen.
    var littleKid = false
    /// Gelerntes Geschmacksprofil: Merkmal („g:Drama“, „m:düster“, „d:Regie“) → Gewicht.
    var affinity: [String: Double] = [:]
    var interactions: [String: Interaction] = [:]
    var watchlist: [String] = []
    var reviews: [Review] = []
    var importedCount = 0
    /// Wie oft ein Merkmal schon in bewerteten Filmen vorkam, damit häufige Merkmale
    /// wie „Drama“ nicht allein durch ihre Menge dominieren.
    var exposure: [String: Double] = [:]
    /// Summe und Anzahl der bisherigen Signale, für die Zentrierung („mehr als sonst“).
    var signalTotal = 0.0
    var signalN = 0
    /// Bewertete Filme als Trainingsdaten (Film → Zielwert), Grundlage der Ridge-Regression.
    var samples: [Sample] = []
    /// Direkte Hinweise aus dem Chat („mag Nolan“), dienen der Regression als Vorwissen.
    var hints: [String: Double] = [:]
    /// Daraus gelernte Gewichte je Merkmal (Cache, wird bei jedem Lernschritt neu berechnet).
    var weights: [String: Double] = [:]
    /// Persönliche Geschmacksfaktoren, passend zu den Faktoren der Filme (Cache).
    var taste: [Double] = []
    /// Im Chat genannte Filme, die nicht im Katalog sind (Merkmale aus Wikidata).
    var external: [String: ExternalFilm] = [:]
    /// Profilbild aus der Avatar-Galerie (`nil` = Initiale).
    var avatar: String?
    /// Serien: nächste Folge je Serie („Weiterschauen“).
    var progress: [String: EpisodeRef] = [:]
    var playbackPositions: [String: Double] = [:]
    var onboardingComplete = false

    struct Sample: Codable, Hashable, Sendable {
        var filmID: String
        var target: Double
    }

    init(id: UUID = UUID(), name: String, colorIndex: Int, maxFSK: Int = 18, avatar: String? = nil) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.maxFSK = maxFSK; self.avatar = avatar
    }

    // Ältere Speicherstände ohne die neuen Felder weiter lesen können.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorIndex = try c.decode(Int.self, forKey: .colorIndex)
        maxFSK = try c.decodeIfPresent(Int.self, forKey: .maxFSK) ?? 18
        littleKid = try c.decodeIfPresent(Bool.self, forKey: .littleKid) ?? false
        affinity = try c.decodeIfPresent([String: Double].self, forKey: .affinity) ?? [:]
        interactions = try c.decodeIfPresent([String: Interaction].self, forKey: .interactions) ?? [:]
        watchlist = try c.decodeIfPresent([String].self, forKey: .watchlist) ?? []
        reviews = try c.decodeIfPresent([Review].self, forKey: .reviews) ?? []
        importedCount = try c.decodeIfPresent(Int.self, forKey: .importedCount) ?? 0
        exposure = try c.decodeIfPresent([String: Double].self, forKey: .exposure) ?? [:]
        signalTotal = try c.decodeIfPresent(Double.self, forKey: .signalTotal) ?? 0
        signalN = try c.decodeIfPresent(Int.self, forKey: .signalN) ?? 0
        hints = try c.decodeIfPresent([String: Double].self, forKey: .hints) ?? [:]
        external = try c.decodeIfPresent([String: ExternalFilm].self, forKey: .external) ?? [:]
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        progress = try c.decodeIfPresent([String: EpisodeRef].self, forKey: .progress) ?? [:]
        playbackPositions = try c.decodeIfPresent([String: Double].self, forKey: .playbackPositions) ?? [:]
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        if let saved = try c.decodeIfPresent([Sample].self, forKey: .samples) {
            samples = saved
        } else {
            // Alter Speicherstand: Trainingsdaten aus den Interaktionen rekonstruieren.
            samples = interactions.compactMap { $0.value.signal == 0 ? nil : Sample(filmID: $0.key, target: $0.value.signal) }
        }
        // Das gelernte Modell wird mitgespeichert. Neu rechnen nur, wenn es fehlt (alter Stand, oder der
        // Server hat es nach einer Änderung geleert), sonst kostet jedes Laden und jeder Sync spürbar Zeit.
        weights = try c.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
        taste = try c.decodeIfPresent([Double].self, forKey: .taste) ?? []
        let hasSamples = !samples.isEmpty
        if (weights.isEmpty && (hasSamples || !hints.isEmpty)) || (taste.isEmpty && hasSamples) { refit() }
    }

    /// Farbe der Figur im Profilbild, sonst eine aus der Grundpalette.
    var color: Color { avatarArt?.color ?? Profile.palette[colorIndex % Profile.palette.count] }
    var avatarArt: AvatarArt? { avatar.flatMap(AvatarArt.byID) }
    var initial: String { String(name.prefix(1)).uppercased() }
    var isKid: Bool { maxFSK <= 12 }

    /// „Kleine Kinder“, „Kinderprofil · bis FSK 6“ oder „Erwachsenenprofil“.
    var ageLabel: String {
        littleKid ? "Kleine Kinder · bis 5 Jahre" : isKid || maxFSK < 18 ? "Kinderprofil · bis FSK \(maxFSK)" : "Erwachsenenprofil"
    }

    /// Darf dieses Profil den Titel sehen?
    func allows(_ film: Film) -> Bool {
        // Unknown or malformed ratings must never be interpreted as FSK 0.
        guard [0, 6, 12, 16, 18].contains(film.fsk) else { return maxFSK >= 18 && !littleKid }
        return film.fsk <= maxFSK && (!littleKid || film.forLittleKids)
    }

    static let palette: [Color] = [
        Color(red: 1.0, green: 0.42, blue: 0.24),  // Orange
        Color(red: 0.36, green: 0.55, blue: 1.0),  // Blau
        Color(red: 0.75, green: 0.42, blue: 1.0),  // Lila
        Color(red: 0.2, green: 0.8, blue: 0.6),    // Mint
        Color(red: 1.0, green: 0.3, blue: 0.5),    // Pink
        Color(red: 1.0, green: 0.78, blue: 0.2)    // Gelb
    ]

    mutating func learn(_ film: Film, _ interaction: Interaction, scale: Double = 1, refitImmediately: Bool = true) {
        var s = interaction.signal * scale
        guard s != 0 else { return }
        if interaction != .notToday {
            // Zentriert: Wer fast alles mag, dem sagt ein „mag ich“ weniger als jemandem,
            // der selten etwas mag.
            if signalN > 2 { s -= 0.5 * signalTotal / Double(signalN) * scale }
            signalTotal += interaction.signal; signalN += 1
            for (key, _) in film.features { exposure[key, default: 0] += 1 }
        }
        for (key, weight) in film.features {
            affinity[key, default: 0] += s * weight
        }
        let target = interaction.signal * scale
        if let i = samples.firstIndex(where: { $0.filmID == film.id }) {
            samples[i].target += target
        } else {
            samples.append(Sample(filmID: film.id, target: target))
        }
        if refitImmediately { refit() }
    }

    /// Direkter Hinweis aus dem Chat, z. B. „+ Christopher Nolan“.
    mutating func nudge(_ key: String, by delta: Double) {
        affinity[key, default: 0] += delta
        hints[key, default: 0] += delta
        refit()
    }

    /// Ein Film außerhalb des Katalogs, wird wie ein bewerteter Katalogfilm gelernt.
    mutating func learn(external film: ExternalFilm, _ interaction: Interaction) {
        external[film.id] = film
        for (key, weight) in film.features { affinity[key, default: 0] += interaction.signal * weight }
        if let i = samples.firstIndex(where: { $0.filmID == film.id }) {
            samples[i].target += interaction.signal
        } else {
            samples.append(Sample(filmID: film.id, target: interaction.signal))
        }
        refit()
    }

    mutating func refit() {
        weights = TasteModel.fit(samples: samples, hints: [:], external: external)
        taste = TasteModel.foldIn(samples: samples)
    }

    /// Anzahl echter Geschmackssignale, Grundlage für „Wie gut kennen wir dich?“.
    var signalCount: Int {
        interactions.values.filter { $0.signal != 0 && $0 != .notToday }.count + importedCount
    }
}
