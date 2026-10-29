import Foundation
import Security

/// Online-Konten über Supabase (Server in Frankfurt): Anmeldung mit E-Mail und Passwort,
/// je Konto eine Zeile mit dem gespeicherten Stand (Profile, Bewertungen, Merklisten).
/// Jedes Konto darf nur seine eigene Zeile lesen und schreiben (Row Level Security).
/// Ohne Netz arbeitet die App mit der Konten-Datenbank auf dem Gerät weiter.
enum CloudAccounts {
    static let backendURL = URL(string: "https://rdjgtjuytrjuqlvrpask.supabase.co")!
    /// Öffentlicher Schlüssel, laut Supabase zum Teilen gedacht. Geschützt wird über die Regeln in der Datenbank.
    static let pairingPublishableKey = "sb_publishable_hrGW1J9lq2srROJup1HDNA_MRstT4hO"

    struct Session: Codable {
        var email: String
        var accessToken: String
        var refreshToken: String
        var userID: String
        var expires: Date
    }

    enum CloudError: Error {
        /// Server nicht erreichbar (kein Netz): dann zählt das Konto auf dem Gerät.
        case offline
        case invalidCredentials
        case alreadyRegistered
        case server(String)
    }

    // MARK: Anmelden

    static func signUp(email: String, password: String) async throws -> Session {
        try await authRequest("signup", body: ["email": email, "password": password])
    }

    static func signIn(email: String, password: String) async throws -> Session {
        try await authRequest("token?grant_type=password", body: ["email": email, "password": password])
    }

    /// Gespeicherte Sitzung aus dem Schlüsselbund (nach einem Neustart der App).
    static var storedSession: Session? { Keychain.session }

    /// Sitzung mit gültigem Zugangsschlüssel, bei Bedarf erneuert.
    static func valid(_ session: Session) async -> Session? {
        guard session.expires < .now.addingTimeInterval(60) else { return session }
        guard let fresh=try? await authRequest("token?grant_type=refresh_token", body:["refresh_token":session.refreshToken],persist:false) else {return nil}
        if Keychain.session?.userID==session.userID {Keychain.session=fresh}
        return fresh
    }

    static func signOut() { Keychain.session = nil }

    // MARK: Gespeicherter Stand

    static func loadState(_ session: Session) async throws -> Data? {
        var request = restRequest("account_state?select=state&user_id=eq.\(session.userID)", session: session)
        request.httpMethod = "GET"
        let data = try await send(request)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let state = rows.first?["state"] else { return nil }
        return try JSONSerialization.data(withJSONObject: state)
    }

    static func saveState(_ state: Data, session: Session) async throws {
        var request = restRequest("account_state", session: session)
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": session.userID,
            "state": try JSONSerialization.jsonObject(with: state),
            "updated_at": ISO8601DateFormatter().string(from: .now),
        ])
        _ = try await send(request)
    }

    /// DSGVO: Konto samt gespeichertem Stand auf dem Server löschen.
    static func deleteAccount(_ session: Session) async throws {
        var request = restRequest("rpc/delete_own_account", session: session)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        _ = try await send(request)
        signOut()
    }

    // MARK: Netzwerk

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let user: User
    }

    private static func authRequest(_ path: String, body: [String: String], persist: Bool = true) async throws -> Session {
        var request = URLRequest(url: URL(string: "auth/v1/\(path)", relativeTo: backendURL)!)
        request.httpMethod = "POST"
        request.setValue(pairingPublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        guard let r = try? JSONDecoder().decode(AuthResponse.self, from: data) else {
            throw CloudError.server("Unerwartete Antwort vom Server.")
        }
        let session = Session(email: r.user.email ?? "", accessToken: r.access_token, refreshToken: r.refresh_token, userID: r.user.id,
                              expires: .now.addingTimeInterval(r.expires_in))
        if persist { Keychain.session = session }
        return session
    }

    private static func restRequest(_ path: String, session: Session) -> URLRequest {
        var request = URLRequest(url: URL(string: "rest/v1/\(path)", relativeTo: backendURL)!)
        request.setValue(pairingPublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 10
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw CloudError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return data }
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = info?["error_code"] as? String ?? info?["code"] as? String ?? ""
        switch code {
        case "invalid_credentials": throw CloudError.invalidCredentials
        case "user_already_exists", "email_exists": throw CloudError.alreadyRegistered
        default:
            throw CloudError.server(info?["msg"] as? String ?? info?["message"] as? String ?? "Fehler \(status)")
        }
    }
}

/// Die Sitzung liegt im Schlüsselbund, nicht in den App-Daten.
private enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "Film.Supabase"]

    /// Frühere Versionen speicherten die Sitzung unter diesem Namen. Einmal übernehmen, sonst wäre man abgemeldet.
    private static let legacyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                                     kSecAttrService as String: "FilmPrototyp.Supabase"]

    static var session: CloudAccounts.Session? {
        get {
            if let data = read(query) { return try? JSONDecoder().decode(CloudAccounts.Session.self, from: data) }
            guard let data = read(legacyQuery),
                  let session = try? JSONDecoder().decode(CloudAccounts.Session.self, from: data) else { return nil }
            Self.session = session
            SecItemDelete(legacyQuery as CFDictionary)
            return session
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    private static func read(_ query: [String: Any]) -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
