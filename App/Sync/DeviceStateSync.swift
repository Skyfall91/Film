import Foundation
import CryptoKit
import Observation
import FilmSync
import LightCode

nonisolated struct CloudStateReply: Codable, Sendable {
    let state: JSONValue
    let revision: Int
    let userID: String
    let email: String
}

/// Records local actions before its first network request and keeps doing so
/// while offline. Every response is checked against the account's local epoch.
@MainActor @Observable
final class DeviceStateSync {
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let token: () async throws -> String
    @ObservationIgnored private let client: PairingClient
    @ObservationIgnored private let epoch: UUID
    @ObservationIgnored private let outboxURL: URL
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var localBatchDepth = 0
    @ObservationIgnored private var localBatchChanged = false
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var signal: SyncSignal?
    private var outbox: SyncOutbox
    var revision: Int { outbox.revision ?? 0 }
    var conflicts: [SyncConflict] { outbox.conflicts }

    init(store: AppStore, userID: String, token: @escaping () async throws -> String,
         client: PairingClient? = nil, storageDir: URL? = nil) {
        self.store = store; self.userID = userID.lowercased(); self.token = token; epoch = store.sessionEpoch
        self.client = client ?? PairingClient(baseURL: CloudAccounts.backendURL, publishableKey: CloudAccounts.pairingPublishableKey)
        outboxURL = (storageDir ?? URL.applicationSupportDirectory.appending(path: "SyncOutbox"))
            .appending(path: userID.lowercased() + ".json")
        let local = (try? JSONValue.decode(store.onlineSnapshotData())) ?? .object([:])
        var restored = SyncOutbox(accountID: userID, local: local)
        if let data = try? Data(contentsOf: outboxURL) {
            if let saved = try? SyncOutbox.restore(data, accountID: userID, local: local) { restored = saved }
            else if let legacy = try? JSONDecoder().decode([SyncOperation].self, from: data) { restored.importLegacy(legacy) }
        }
        outbox = restored
        signal = SyncSignal(userID: userID) { [weak self] in self?.signalReceived() }
        if !restored.pending.isEmpty || !restored.conflicts.isEmpty {
            try? store.applyCloudSnapshot(restored.projectedState().data())
        }
    }
    private var active: Bool { !stopped && store?.signedIn == true && store?.sessionEpoch == epoch }

    func start() async throws {
        do {
            try await initializeIfNeeded()
            startRetrying()
            try await flush()
        } catch {
            handle(error)
            throw error
        }
    }

    /// Also called after the initial read failed. The coordinator remains the
    /// local recorder, so an offline app never falls back to snapshot upserts.
    func startRetrying() {
        guard active, reader == nil else { return }
        signal?.connect()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Mit Echtzeit-Signal reicht seltenes Nachfragen, ohne fragt die App alle 8 s.
                    try await Task.sleep(for: .seconds(self?.signal?.joined == true ? 30 : 8)); try Task.checkCancellation()
                    guard let self, self.active else { break }
                    try await self.refresh()
                } catch is CancellationError { break }
                catch { self?.handle(error) }
            }
        }
    }

    private func initializeIfNeeded() async throws {
        guard active else { throw CancellationError() }
        while starting {
            try await Task.sleep(for: .milliseconds(30)); try Task.checkCancellation()
            guard active else { throw CancellationError() }
        }
        guard !ready else { return }
        starting = true; defer { starting = false }
        try captureCurrent()
        let credential = try await token()
        guard active else { throw CancellationError() }
        let body: JSONValue
        #if os(tvOS)
        body = .object([:])
        #else
        body = .object(["bootstrapState": outbox.bootstrapState])
        #endif
        let reply: CloudStateReply = try await client.post(route: "readState", body: body, bearerToken: credential, as: CloudStateReply.self)
        try check(reply)
        try captureCurrent()
        outbox.reconcile(server: reply.state, revision: reply.revision)
        try persistOutbox()
        try applyProjection()
        ready = true
    }

    /// Capture each rating separately, but persist and start the sender only once.
    /// This preserves failure isolation if one title is rejected by the server.
    func beginLocalBatch() { localBatchDepth += 1 }

    func endLocalBatch() {
        guard localBatchDepth > 0 else { return }
        localBatchDepth -= 1
        guard localBatchDepth == 0, active else { return }
        if localBatchChanged {
            do { try persistOutbox(); localBatchChanged = false }
            catch { handle(error); return }
        }
        scheduleCapturedChanges()
    }

    func captureLocalChanges() {
        guard active else { return }
        do { try captureCurrent() }
        catch { handle(error); return }
        guard localBatchDepth == 0 else { return }
        scheduleCapturedChanges()
    }

    private func scheduleCapturedChanges() {
        guard !outbox.pending.isEmpty else { return }
        store?.syncStatus = "Änderungen werden übertragen"
        // Never cancel an already transmitting task: an accepted response must
        // reach acknowledgement even if another local action arrives meanwhile.
        guard !sending else { return }
        sender?.cancel()
        sender = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(800)); try Task.checkCancellation()
                try await self?.flush()
            } catch is CancellationError { }
            catch { self?.handle(error) }
        }
    }

    func flush() async throws {
        do {
            try await initializeIfNeeded()
            while sending {
                try await Task.sleep(for: .milliseconds(30)); try Task.checkCancellation()
                guard active else { throw CancellationError() }
            }
            guard active else { throw CancellationError() }
            sending = true; defer { sending = false }
            var delivered = false
            defer { if delivered { signal?.notify() } }
            var isolateFailures = false
            var retriedRevision: Int?
            while active && !outbox.pending.isEmpty {
                try Task.checkCancellation()
                let batch = Array(outbox.pending.prefix(isolateFailures ? 1 : 100))
                nonisolated struct Body: Encodable, Sendable { let baseRevision: Int; let operations: [SyncOperation] }
                let credential = try await token()
                guard active else { throw CancellationError() }
                do {
                    let body = Body(baseRevision: batch.first?.submissionRevision ?? revision, operations: batch.map(\.operation))
                    let reply: CloudStateReply = try await client.post(route: "applyMutations", body: body, bearerToken: credential, as: CloudStateReply.self)
                    try check(reply)
                    try captureCurrent()
                    // Jeder neue Vorgang zählt die Revision um eins hoch. Liegt sie danach noch höher,
                    // hat zwischendurch ein anderes Gerät gespeichert.
                    let foreign = reply.revision > revision + batch.count
                    outbox.acknowledge(Set(batch.map { $0.operation.id }), server: reply.state, revision: reply.revision)
                    delivered = true
                    try persistOutbox(); try applyProjection(fromOtherDevice: foreign)
                    retriedRevision = nil
                } catch PairingClientError.server(let status, let code) where status == 400 || status == 409 {
                    let reply = try await readCurrentState()
                    try captureCurrent()
                    outbox.reconcile(server: reply.state, revision: reply.revision)
                    try persistOutbox(); try applyProjection()
                    let remaining = Set(outbox.pending.map { $0.operation.id })
                    guard batch.contains(where: { remaining.contains($0.operation.id) }) else { continue }
                    if code == "revision_conflict", retriedRevision != reply.revision {
                        retriedRevision = reply.revision
                        continue
                    }
                    if batch.count > 1 { isolateFailures = true; continue }
                    if let entry = batch.first {
                        outbox.quarantine(id: entry.operation.id, title: conflictTitle(code))
                        try persistOutbox(); try applyProjection()
                    }
                }
            }
            guard active else { throw CancellationError() }
            updateStatus()
        } catch {
            handle(error)
            throw error
        }
    }

    func refresh() async throws {
        do {
            guard active, !sending else { return }
            try await flush()
            let known = revision
            let reply = try await readCurrentState()
            try captureCurrent()
            // Nichts Neues auf dem Server und nichts offen: kein Neuschreiben, kein Neuaufbau der Ansichten.
            if reply.revision == known && outbox.pending.isEmpty { updateStatus(); return }
            outbox.reconcile(server: reply.state, revision: reply.revision)
            try persistOutbox(); try applyProjection(fromOtherDevice: reply.revision != known)
            updateStatus()
        } catch { handle(error); throw error }
    }

    func resolveConflict(id: UUID, useLocal: Bool) async throws {
        guard active else { throw CancellationError() }
        // A new remote edit might have occurred while the choice was on screen.
        let reply = try await readCurrentState()
        try captureCurrent()
        outbox.reconcile(server: reply.state, revision: reply.revision)
        outbox.resolveConflict(id: id, useLocal: useLocal)
        try persistOutbox(); try applyProjection()
        try await flush()
    }

    /// App kommt nach vorn: Signal-Verbindung wieder aufbauen und sofort nachsehen, was es Neues gibt.
    func wake() {
        guard active else { return }
        signal?.connect()
        Task { try? await refresh() }
    }

    /// Ein anderes Gerät dieses Kontos hat gerade etwas gespeichert.
    private func signalReceived() {
        guard active else { return }
        Task { try? await refresh() }
    }

    func stop() {
        signal?.stop(); signal = nil
        stopped = true; sender?.cancel(); reader?.cancel(); sender = nil; reader = nil
        try? persistOutbox()
    }

    /// Only confirmed account deletion removes unacknowledged local actions.
    func purge() {
        stop()
        try? FileManager.default.removeItem(at: outboxURL)
    }

    private func captureCurrent() throws {
        guard active, let store else { throw CancellationError() }
        let queued = outbox.pending.count
        outbox.capture(try JSONValue.decode(store.onlineSnapshotData()))
        // Nur schreiben, wenn wirklich etwas Neues zu übertragen ist: Der Abgleich ruft das oft auf.
        if outbox.pending.count != queued {
            if localBatchDepth > 0 { localBatchChanged = true }
            else { try persistOutbox() }
        }
    }
    private func readCurrentState() async throws -> CloudStateReply {
        guard active else { throw CancellationError() }
        let credential = try await token()
        guard active else { throw CancellationError() }
        let reply: CloudStateReply = try await client.post(route: "readState", body: JSONValue.object([:]), bearerToken: credential, as: CloudStateReply.self)
        try check(reply)
        return reply
    }
    private func check(_ reply: CloudStateReply) throws {
        guard active, reply.userID.lowercased() == userID, reply.email == store?.account?.email else { throw CancellationError() }
    }
    private func applyProjection(fromOtherDevice: Bool = true) throws {
        guard active, let store else { throw CancellationError() }
        try store.applyCloudSnapshot(outbox.projectedState().data(), fromOtherDevice: fromOtherDevice)
    }
    private func persistOutbox() throws {
        let data = try JSONEncoder().encode(outbox)
        try FileManager.default.createDirectory(at: outboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outboxURL, options: .atomic)
    }
    private func updateStatus() {
        guard active else { return }
        if !conflicts.isEmpty { store?.syncStatus = "Andere Änderungen aktuell · Konflikte bitte prüfen" }
        else if !outbox.pending.isEmpty { store?.syncStatus = "Änderungen werden übertragen" }
        else { store?.syncStatus = "iPhone und Fernseher aktuell" }
    }
    private func conflictTitle(_ code: String) -> String {
        switch code {
        case "profile_deleted", "profile_not_found": "Das Profil wurde gelöscht. Diese Änderung wurde nicht übernommen."
        case "age_restricted": "Die aktuelle Altersfreigabe erlaubt diese Änderung nicht."
        case "profile_limit": "Der aktuelle Tarif hat keinen freien Profilplatz."
        case "unverified_subscription": "Dieser Tarif muss zuerst über den App Store bestätigt werden."
        default: "Diese Änderung wurde vom Kontodienst abgelehnt (\(code))."
        }
    }
    private func handle(_ error: Error) {
        guard active, !(error is CancellationError) else { return }
        if case PairingClientError.server(let status, _) = error, status == 401 || status == 403 {
            stop(); store?.signOut()
            store?.syncStatus = "Die Geräteanmeldung ist abgelaufen oder wurde entfernt. Bitte erneut anmelden."
        } else {
            store?.syncStatus = "Offline · Änderungen bleiben auf diesem Gerät gespeichert"
        }
    }
    deinit { sender?.cancel(); reader?.cancel() }
}

/// Kurzes Signal „Es gibt Neues“ zwischen den Geräten eines Kontos, über Supabase Realtime.
/// Es trägt keine Daten: Wer es hört, holt den Stand wie bisher über die geprüfte Funktion.
/// Der Kanalname ist ein Hash der Konto-ID. Fällt die Verbindung aus, bleibt das Nachfragen alle 8 s.
@MainActor
final class SyncSignal {
    private let topic: String
    private let onSignal: @MainActor () -> Void
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var ref = 0
    private var stopped = false
    /// Der Kanal hat den Beitritt bestätigt: Signale kommen an.
    private(set) var joined = false

    init(userID: String, onSignal: @escaping @MainActor () -> Void) {
        let digest = SHA256.hash(data: Data(("film-sync|" + userID.lowercased()).utf8))
        topic = "realtime:film-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        self.onSignal = onSignal
    }

    func connect() {
        guard !stopped, socket == nil else { return }
        retry?.cancel(); retry = nil
        var url = URLComponents(url: CloudAccounts.backendURL.appending(path: "realtime/v1/websocket"), resolvingAgainstBaseURL: false)!
        url.scheme = "wss"
        url.queryItems = [URLQueryItem(name: "apikey", value: CloudAccounts.pairingPublishableKey),
                          URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let address = url.url else { return }
        let task = URLSession.shared.webSocketTask(with: address)
        socket = task
        task.resume()
        send(topic, "phx_join", ["config": ["broadcast": ["self": false], "private": false]])
        Task { [weak self] in await self?.listen(task) }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.send("phoenix", "heartbeat", [:])
            }
        }
    }

    /// Den anderen Geräten sagen, dass es Neues gibt.
    func notify() {
        send(topic, "broadcast", ["type": "broadcast", "event": "changed", "payload": [String: Any]()])
    }

    func stop() {
        stopped = true
        retry?.cancel(); retry = nil
        drop()
    }

    private func listen(_ task: URLSessionWebSocketTask) async {
        while let message = try? await task.receive() {
            if case .string(let text) = message,
               let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                if json["event"] as? String == "broadcast" { onSignal() }
                if json["event"] as? String == "phx_reply", json["topic"] as? String == topic,
                   (json["payload"] as? [String: Any])?["status"] as? String == "ok" { joined = true }
            }
        }
        // Verbindung weg (Funkloch, Hintergrund): nach kurzer Pause neu verbinden.
        guard socket === task else { return }
        drop()
        guard !stopped else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func drop() {
        joined = false
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func send(_ topic: String, _ event: String, _ payload: [String: Any]) {
        guard let socket else { return }
        ref += 1
        let message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": String(ref)]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
