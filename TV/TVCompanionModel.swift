import Foundation
import Observation
import LightCode
import FilmSync

@MainActor @Observable
final class TVCompanionModel {
    var code: String?
    var status = "Auf dem iPhone fortsetzen"
    var error: String?
    var waiting = false
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let client = PairingClient(baseURL: CloudAccounts.backendURL, publishableKey: CloudAccounts.pairingPublishableKey)
    @ObservationIgnored private var job: CompanionJob?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    nonisolated private struct CompanionJob: Codable, Sendable {
        var id: String; var kind: String; var profileID: String?; var payload: JSONValue
        var status: String; var version: Int; var expiresAt: String; var result: JSONValue?
    }
    nonisolated private struct JobReply: Codable, Sendable { let job: CompanionJob }
    nonisolated private struct JobsReply: Codable, Sendable { let jobs: [CompanionJob] }
    init(store: AppStore) { self.store = store }
    private func credential() throws -> String {
        guard store.signedIn, let credential = TVSessionStore.load(), credential.email == store.account?.email else { throw AuthError.wrongCredentials }
        return credential.token
    }
    func start(kind: String, profileID: UUID?, filmID: String?, payload: String?) async {
        await cancel()
        let run = UUID(); generation = run; waiting = true; error = nil
        do {
            var values: [String: JSONValue] = [:]
            if let payload { values["text"] = .string(payload); if kind == "externalLink" { values["url"] = .string(payload) } }
            if let filmID { values["filmID"] = .string(filmID) }
            var body: [String: JSONValue] = ["kind": .string(kind), "payload": .object(values), "operationID": .string(UUID().uuidString)]
            if let profileID { body["profileID"] = .string(profileID.uuidString) }
            let response: CompanionJob = try await client.post(route: "createJob", body: JSONValue.object(body), bearerToken: credential(), as: CompanionJob.self)
            guard generation == run else { return }
            job = response; status = "Öffne auf deinem iPhone Film → Konto → Fernseher und wähle diese Aufgabe."
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)); try Task.checkCancellation(); await self?.refresh() }
                    catch { break }
                    if self?.job == nil { break }
                }
            }
        } catch { if generation == run { self.error = error.localizedDescription; waiting = false } }
    }
    func refresh() async {
        guard let current = job else { return }
        let run = generation
        do {
            let response: JobsReply = try await client.post(route: "listJobs", body: JSONValue.object([:]), bearerToken: credential(), as: JobsReply.self)
            guard generation == run else { return }
            guard let found = response.jobs.first(where: { $0.id == current.id }) else {
                if PairingClient.date(current.expiresAt).map({$0 <= .now}) == true { job = nil; waiting = false; status = "Aufgabe abgelaufen. Bitte erneut starten." }
                return
            }
            job = found
            if found.status == "completed" {
                if found.kind == "mood", let query = found.result?["query"], let data = try? query.data(), let decoded = try? JSONDecoder().decode(MoodQuery.self, from: data) { store.companionMoodQuery = decoded }
                try await store.refreshCloudState()
                status = found.result?["summary"]?.string ?? "Aufgabe abgeschlossen · der Stand ist übernommen"
                job = nil; waiting = false; polling?.cancel(); polling = nil
            } else if ["cancelled", "expired"].contains(found.status) {
                status = "Aufgabe beendet. Bitte erneut starten."; job = nil; waiting = false; polling?.cancel(); polling = nil
            } else if found.status == "claimed" { status = "Auf dem iPhone geöffnet · auf Abschluss warten" }
        } catch { if generation == run { self.error = error.localizedDescription } }
    }
    func cancel() async {
        generation = UUID(); polling?.cancel(); polling = nil
        let previous = job; job = nil; code = nil; waiting = false
        if let previous, let credential = try? credential() {
            do {
                // A phone may have claimed the task since the last poll. Cancel the current revision.
                for _ in 0..<3 {
                    let latest:JobsReply=try await client.post(route:"listJobs",body:JSONValue.object([:]),bearerToken:credential,as:JobsReply.self)
                    guard let current=latest.jobs.first(where:{$0.id==previous.id}),!["completed","cancelled","expired"].contains(current.status) else { return }
                    let body:JSONValue = .object(["id":.string(current.id),"version":.number(Double(current.version))])
                    do { _ = try await client.postData(route:"cancelJob",body:body.data(),bearerToken:credential);return }
                    catch PairingClientError.server(let status,_) where status==409 { continue }
                }
                error="Die Aufgabe konnte noch nicht beendet werden. Bitte auf dem iPhone prüfen."
            } catch { self.error=error.localizedDescription }
        }
    }
}
