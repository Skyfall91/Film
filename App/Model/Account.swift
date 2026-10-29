import CryptoKit
import Foundation
import StoreKit

/// Ein Konto gehört einem Haushalt: eine E-Mail, ein Abo, mehrere Profile.
/// Bisher liegt es nur auf dem Gerät, ein echtes Produkt hätte dafür einen Account-Dienst.
struct Account: Codable, Hashable, Sendable {
    var email: String
    /// Nur der Hash wird gespeichert, nie das Passwort (SHA-256 mit Salz).
    var passwordHash: String
    var salt: String
    var created: Date
    var consented: Date
    var subscription: Subscription?

    static func hash(_ password: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + password).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ password: String) -> Bool { Self.hash(password, salt: salt) == passwordHash }

}

/// Tarife. Der Unterschied ist bewusst klein: Profile, gleichzeitige Streams, Bildqualität.
/// Jugendschutz (Kinderprofile, FSK) ist in jedem Tarif enthalten, das ist keine Bezahlfunktion.
enum Plan: String, Codable, CaseIterable, Identifiable, Sendable {
    case solo, duo, familie

    var id: String { rawValue }
    var name: String {
        switch self {
        case .solo: "Solo"
        case .duo: "Duo"
        case .familie: "Familie"
        }
    }
    var tagline: String {
        switch self {
        case .solo: "Für dich allein"
        case .duo: "Für zwei, mit Zusammen-Modus"
        case .familie: "Für alle auf dem Sofa"
        }
    }
    /// Preis in Euro pro Monat (Anzeige, falls StoreKit nicht verfügbar ist).
    var price: Decimal {
        switch self {
        case .solo: 6.99
        case .duo: 10.99
        case .familie: 14.99
        }
    }
    var maxProfiles: Int {
        switch self {
        case .solo: 2
        case .duo: 4
        case .familie: 8
        }
    }
    /// Gegen Account-Sharing zählen gleichzeitige Geräte, nicht Profile: Lieber jedem im Haushalt
    /// ein eigenes Profil geben (bessere Vorschläge), als dass sich Leute ein Profil teilen.
    var streams: Int {
        switch self {
        case .solo: 1
        case .duo: 2
        case .familie: 4
        }
    }
    /// Bildqualität ist kein Verkaufsargument für teurere Tarife, 4K gibt es in jedem.
    var quality: String { "4K · HDR" }
    /// Zusammen-Modus gibt es ab Duo. Solo hat ein zweites Profil, z. B. für Kinder oder Gäste.
    var allowsTogether: Bool { self != .solo }
    var productID: String { "app.film.abo.\(rawValue)" }

    var features: [String] {
        [
            maxProfiles == 1 ? "1 Profil" : "Bis zu \(maxProfiles) Profile",
            streams == 1 ? "1 Gerät gleichzeitig" : "\(streams) Geräte gleichzeitig",
            quality,
        ] + (allowsTogether ? ["Zusammen-Modus"] : [])
    }

    var priceText: String { price.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE"))) }

    static func forProduct(_ id: String) -> Plan? { allCases.first { $0.productID == id } }
}

struct Subscription: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case appStore, demo }

    var plan: Plan
    var started: Date
    /// Ende der Testphase bzw. nächste Abbuchung.
    var renews: Date
    var trial: Bool
    var canceled = false
    var source: Source

    /// Gekündigt heißt: läuft noch bis zum Ende des bezahlten Zeitraums.
    var isActive: Bool { !canceled || renews > .now }

    var statusText: String {
        let date = renews.formatted(.dateTime.day().month(.wide))
        if canceled { return renews > .now ? "Gekündigt · läuft bis \(date)" : "Abgelaufen" }
        return trial ? "Kostenlos bis \(date), danach \(plan.priceText) im Monat" : "Verlängert sich am \(date)"
    }

    static func trial(_ plan: Plan, source: Source) -> Subscription {
        Subscription(plan: plan, started: .now, renews: .now.addingTimeInterval(7 * 86_400), trial: true, source: source)
    }
}

/// Bezahlung über StoreKit 2. In Xcode läuft sie gegen die lokale Testkonfiguration (`Abo.storekit`):
/// echtes System-Kaufblatt, aber kein echtes Geld. Ohne Konfiguration (z. B. Start per Simulator-Befehl)
/// fällt die App auf einen klar markierten Demo-Kauf zurück.
@Observable
final class PurchaseService {
    var products: [Plan: Product] = [:]
    var loaded = false
    var accountToken: UUID?
    private var updates: Task<Void, Never>?
    /// Canonical Apple JWS from a locally verified result. Memory only: the
    /// server verifies the certificate chain and derives the granted plan.
    private(set) var signedTransaction: String?

    var storeKitAvailable: Bool { !products.isEmpty }

    func load() async {
        guard !loaded else { return }
        let found = (try? await Product.products(for: Plan.allCases.map(\.productID))) ?? []
        for p in found { if let plan = Plan.forProduct(p.id) { products[plan] = p } }
        loaded = true
    }

    func displayPrice(_ plan: Plan) -> String { products[plan]?.displayPrice ?? plan.priceText }

    enum Outcome { case purchased(Subscription), cancelled, failed(String) }

    func purchase(_ plan: Plan) async -> Outcome {
        signedTransaction = nil
        guard let product = products[plan] else {
            // Kein StoreKit: Testphase lokal anlegen (im UI als Demo-Kauf gekennzeichnet).
            try? await Task.sleep(for: .milliseconds(600))
            return .purchased(.trial(plan, source: .demo))
        }
        do {
            switch try await product.purchase(options: accountToken.map { [.appAccountToken($0)] } ?? []) {
            case .success(let result):
                guard case .verified(let transaction) = result else { return .failed("Kauf konnte nicht bestätigt werden.") }
                signedTransaction = result.jwsRepresentation
                await transaction.finish()
                return .purchased(Self.subscription(from: transaction, plan: plan))
            case .userCancelled: return .cancelled
            case .pending: return .failed("Der Kauf wartet noch auf Bestätigung.")
            @unknown default: return .cancelled
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Aktuelles Abo laut App Store (z. B. nach Neuinstallation oder Kündigung im Systemblatt).
    func currentSubscription() async -> Subscription? {
        signedTransaction = nil
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, let plan = Plan.forProduct(t.productID) else { continue }
            signedTransaction = result.jwsRepresentation
            return Self.subscription(from: t, plan: plan)
        }
        return nil
    }

    func listen(_ onChange: @escaping @MainActor (Subscription?) -> Void) {
        updates?.cancel()
        updates = Task {
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                onChange(await currentSubscription())
            }
        }
    }

    private static func subscription(from t: Transaction, plan: Plan) -> Subscription {
        Subscription(plan: plan, started: t.originalPurchaseDate,
                     renews: t.expirationDate ?? .now.addingTimeInterval(30 * 86_400),
                     trial: t.offer?.type == .introductory, canceled: t.revocationDate != nil, source: .appStore)
    }
}
