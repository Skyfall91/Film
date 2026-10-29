import Foundation
import SwiftData

/// Eine Zeile in der Konten-Datenbank: Anmeldedaten plus alles, was zum Konto gehört
/// (Abo, Profile, Bewertungen, Merklisten). So kommt man mit E-Mail und Passwort
/// jederzeit zu genau diesem Stand zurück, auch nach dem Abmelden oder mit mehreren Konten.
@Model
final class AccountRecord {
    @Attribute(.unique) var email: String
    /// Nur der Hash, nie das Passwort.
    var passwordHash: String
    var salt: String
    var created: Date
    var lastSignIn: Date
    /// Gespeicherter Zustand des Kontos (JSON).
    var state: Data
    /// Verified Supabase account identity; never a bearer or refresh token.
    var cloudUserID: String? = nil

    init(email: String, passwordHash: String, salt: String, created: Date, lastSignIn: Date, state: Data, cloudUserID: String? = nil) {
        self.email = email; self.passwordHash = passwordHash; self.salt = salt
        self.created = created; self.lastSignIn = lastSignIn; self.state = state; self.cloudUserID = cloudUserID
    }
}

/// Kleine echte Datenbank (SwiftData, darunter SQLite) auf dem Gerät.
/// Ein fertiger Dienst hätte dafür einen Server, damit das Konto auf jedem Gerät klappt.
final class AccountDatabase {
    private let context: ModelContext?

    init(inMemory: Bool = false) {
        let url = URL.applicationSupportDirectory.appending(path: "Konten.store")
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        let configuration = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration(url: url)
        let container = try? ModelContainer(for: AccountRecord.self, configurations: configuration)
        context = container.map(ModelContext.init)
    }

    func record(_ email: String) -> AccountRecord? {
        var query = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.email == email })
        query.fetchLimit = 1
        return try? context?.fetch(query).first
    }

    /// Alle Konten auf diesem Gerät, zuletzt genutzte zuerst.
    var emails: [String] {
        let query = FetchDescriptor<AccountRecord>(sortBy: [SortDescriptor(\.lastSignIn, order: .reverse)])
        return (try? context?.fetch(query).map(\.email)) ?? []
    }

    func upsert(_ account: Account, state: Data, signedInNow: Bool = false, cloudUserID: String? = nil) {
        guard let context else { return }
        let verifiedID = cloudUserID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        if let r = record(account.email) {
            r.passwordHash = account.passwordHash
            r.salt = account.salt
            r.state = state
            if let verifiedID { r.cloudUserID = verifiedID }
            if signedInNow { r.lastSignIn = .now }
        } else {
            context.insert(AccountRecord(email: account.email, passwordHash: account.passwordHash, salt: account.salt,
                                         created: account.created, lastSignIn: .now, state: state, cloudUserID: verifiedID))
        }
        try? context.save()
    }

    func delete(_ email: String) {
        guard let context, let r = record(email) else { return }
        context.delete(r)
        try? context.save()
    }
}
