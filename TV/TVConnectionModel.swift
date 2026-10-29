import Foundation
import Observation
import Security
import CryptoKit
import LightCode
import FilmSync

nonisolated struct TVCredential: Codable, Sendable {
    var token: String
    var userID: String
    var email: String
    var expiresAt: Date
    var rotatedAt: Date
    var candidate: String?
    var rotationID: String?
}

@MainActor
enum TVSessionStore {
    private static let service = "app.film.tv-session"
    /// Frühere Versionen speicherten die Anmeldung unter diesem Namen. Einmal übernehmen, sonst wäre das TV abgemeldet.
    private static let legacyService = "de.beispiel.filmprototyp.tv-session"
    static func load() -> TVCredential? {
        if let credential = load(from: service) { return credential }
        guard let credential = load(from: legacyService) else { return nil }
        if (try? save(credential)) != nil {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: legacyService, kSecAttrAccount as String: "device"] as CFDictionary)
        }
        return credential
    }
    private static func load(from service: String) -> TVCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(TVCredential.self, from: data)
    }
    static func save(_ credential: TVCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AuthError.server("Die Anmeldung konnte nicht sicher gespeichert werden.") }
        } else if status != errSecSuccess { throw AuthError.server("Die Anmeldung konnte nicht sicher gespeichert werden.") }
    }
    private static let revocationService = service + ".revocations"
    private static func pendingRevocations() -> [String] {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:revocationService,kSecAttrAccount as String:"pending",kSecReturnData as String:true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&item)==errSecSuccess,let data=item as? Data else { return [] }
        return (try? JSONDecoder().decode([String].self,from:data)) ?? []
    }
    private static func saveRevocations(_ tokens:[String]) throws {
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:revocationService,kSecAttrAccount as String:"pending"]
        if tokens.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data=try JSONEncoder().encode(tokens)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var item=query;item[kSecValueData as String]=data;item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary,nil)==errSecSuccess else { throw AuthError.server("Abmeldung konnte nicht gespeichert werden.") }
        } else if status != errSecSuccess { throw AuthError.server("Abmeldung konnte nicht gespeichert werden.") }
    }
    static func revokeCurrent() {
        if let old=load() {
            var tokens=pendingRevocations()
            for token in [old.token,old.candidate].compactMap({$0}) where !tokens.contains(token) { tokens.append(token) }
            try? saveRevocations(tokens)
        }
        clear()
        Task { await drainRevocations() }
    }
    static func drainRevocations() async {
        let client=PairingClient(baseURL:CloudAccounts.backendURL,publishableKey:CloudAccounts.pairingPublishableKey)
        for token in pendingRevocations() {
            do { _ = try await client.postData(route:"revokeSession",body:Data("{}".utf8),bearerToken:token) }
            catch PairingClientError.server(let status,_) where status==401 || status==403 { }
            catch { continue }
            // Merge with the current queue after the suspension, so a new logout is retained.
            try? saveRevocations(pendingRevocations().filter {$0 != token})
        }
    }
    static func clear() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}

@MainActor @Observable
final class TVConnectionModel {
    var code: String?
    var status = "Mit dem iPhone anmelden"
    var error: String?
    var waiting = false
    var expiresAt: Date? { request.flatMap { PairingClient.date($0.expiresAt) } }
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let client = PairingClient(baseURL: CloudAccounts.backendURL, publishableKey: CloudAccounts.pairingPublishableKey)
    @ObservationIgnored private var request: PairingRequest?
    @ObservationIgnored private var pollSecret = ""
    @ObservationIgnored private var sessionSecret = ""
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var nearbyService: NetService?
    @ObservationIgnored private var restoring = false
    init(store: AppStore) { self.store = store; restoring = TVSessionStore.load() != nil }
    func restore() async {
        defer { restoring = false }
        Task { await TVSessionStore.drainRevocations() }
        guard var credential = TVSessionStore.load(), credential.expiresAt > .now else { TVSessionStore.clear(); return }
        waiting = true
        defer { waiting = false }
        do {
            if credential.candidate != nil || credential.rotatedAt < .now.addingTimeInterval(-7 * 86400) {
                // A previous rotation may have reached the server before the app stopped.
                if let candidate=credential.candidate {
                    do {
                        let recovered:CloudStateReply=try await client.post(route:"readState",body:JSONValue.object([:]),bearerToken:candidate,as:CloudStateReply.self)
                        guard recovered.userID==credential.userID,recovered.email==credential.email else { throw PairingClientError.invalidResponse }
                        credential.token=candidate;credential.candidate=nil;credential.rotationID=nil;credential.rotatedAt = .now
                        try TVSessionStore.save(credential)
                    } catch PairingClientError.server(let status,_) where status==401 || status==403 {
                        // The candidate was never activated; retry the persisted rotation below.
                    }
                }
                if credential.candidate != nil || credential.rotatedAt < .now.addingTimeInterval(-7 * 86400) {
                let next = try credential.candidate ?? Self.secret()
                let operationID = credential.rotationID ?? UUID().uuidString
                credential.candidate = next; credential.rotationID = operationID; try TVSessionStore.save(credential)
                let rotation = try await client.rotateSession(newHash: Self.hash(next), operationID: operationID, bearerToken: credential.token)
                credential.token = next; credential.candidate = nil; credential.rotationID = nil; credential.rotatedAt = .now
                credential.expiresAt = rotation.expiresAt.flatMap(PairingClient.date) ?? .now.addingTimeInterval(30 * 86400)
                try TVSessionStore.save(credential)
                }
            }
            let reply: CloudStateReply = try await client.post(route: "readState", body: JSONValue.object([:]), bearerToken: credential.token, as: CloudStateReply.self)
            guard reply.userID == credential.userID, reply.email == credential.email else { throw PairingClientError.invalidResponse }
            try store.adoptTVAccount(reply.state.data(), email: reply.email)
            try await store.installCloudSync()
            status = "Angemeldet"
        } catch PairingClientError.server(let status, _) where status == 401 || status == 403 {
            TVSessionStore.clear(); store.signedIn = false; self.error = "Diese TV-Anmeldung ist abgelaufen oder wurde entfernt."
        } catch {
            if store.account?.email == credential.email { store.signedIn = true; store.syncStatus = "Offline · gespeicherter Stand" }
            self.error = error.localizedDescription
        }
    }
    func start() async {
        guard !restoring else { return }
        await cancel()
        Task { await TVSessionStore.drainRevocations() }
        let run = UUID(); generation = run; waiting = true; error = nil; status = "Code wird erstellt"
        do {
            let poll = try Self.secret(), session = try Self.secret()
            let result = try await client.createPairing(pollHash: Self.hash(poll), sessionHash: Self.hash(session), deviceName: "Apple TV")
            guard generation == run, !Task.isCancelled else { return }
            request = result; pollSecret = poll; sessionSecret = session; code = result.code; status = "Auf deine Bestätigung warten"
            advertiseNearby(true)
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)); try Task.checkCancellation(); await self?.claim() }
                    catch { break }
                    if self?.request == nil { break }
                }
            }
        } catch { if generation == run { self.error = error.localizedDescription; status = "Code konnte nicht erstellt werden"; waiting = false } }
    }
    func claim() async {
        guard let request else { return }
        let run = generation
        if let expires = PairingClient.date(request.expiresAt), expires <= .now { await cancel(); status = "Code abgelaufen · bitte neu erstellen"; return }
        do {
            let response = try await client.activateSession(id: request.id, pollSecret: pollSecret)
            guard generation == run else { return }
            if response.status == "active", let userID = response.userID, let email = response.email, let expiresAt = response.expiresAt.flatMap(PairingClient.date) {
                let credential = TVCredential(token: sessionSecret, userID: userID, email: email, expiresAt: expiresAt, rotatedAt: .now)
                try TVSessionStore.save(credential)
                let reply: CloudStateReply = try await client.post(route: "readState", body: JSONValue.object([:]), bearerToken: sessionSecret, as: CloudStateReply.self)
                guard generation == run, reply.userID == userID else { return }
                try store.adoptTVAccount(reply.state.data(), email: email)
                advertiseNearby(false)
                self.request = nil; code = nil; pollSecret = ""; sessionSecret = ""; polling?.cancel(); polling = nil; waiting = false; status = "Angemeldet"
                try await store.installCloudSync()
            } else if ["rejected", "expired", "cancelled"].contains(response.status) {
                await cancel(); status = response.status == "rejected" ? "Anmeldung abgelehnt" : "Code nicht mehr gültig"
            }
        } catch { if generation == run { self.error = error.localizedDescription } }
    }
    func cancel() async {
        advertiseNearby(false)
        generation = UUID(); polling?.cancel(); polling = nil
        let old = request, secret = pollSecret
        request = nil; code = nil; waiting = false; pollSecret = ""; sessionSecret = ""
        if let old { _ = try? await client.postData(route: "cancelPairing", body: JSONValue.object(["id":.string(old.id),"pollSecret":.string(secret)]).data()) }
    }
    func advertiseNearby(_ active: Bool) {
        nearbyService?.stop(); nearbyService = nil
        guard active, let code, expiresAt.map({ $0 > .now }) == true else { return }
        // Discovery only: the name carries the public, short-lived code. No
        // connection is accepted here; resolve/approve still use the HTTPS API.
        let service = NetService(domain: "local.", type: "_film-pair._tcp.", name: "Film-" + code, port: 9)
        nearbyService = service
        service.publish(options: .noAutoRename)
    }
    private static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthError.server("Sicherer Code nicht verfügbar.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
