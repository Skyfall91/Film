import Foundation

public struct SyncConflict: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
}

/// The original revision and field values survive both retries and process death.
public struct QueuedMutation: Codable, Equatable, Sendable {
    public var operation: SyncOperation
    public let baseRevision: Int?
    public var submissionRevision: Int?
    public var before: JSONValue
}

public enum OutboxError: Error { case wrongAccount }

/// Durable business state; deliberately independent of networking and UI actors.
public struct SyncOutbox: Codable, Sendable {
    public let accountID: String
    public private(set) var lastLocal: JSONValue
    public private(set) var revision: Int?
    public private(set) var pending: [QueuedMutation] = []
    public var bootstrapState: JSONValue { server }
    private var server: JSONValue
    private var rejected: [QueuedMutation] = []
    private var rejectionTitles: [String: String] = [:]
    public var conflicts: [SyncConflict] {
        rejected.map { SyncConflict(id: $0.operation.id, title: rejectionTitles[$0.operation.id.uuidString] ?? "Diese Änderung kollidiert mit einem anderen Gerät.") }
    }

    public init(accountID: String, local: JSONValue) {
        self.accountID = accountID.lowercased(); lastLocal = local; server = local
    }

    public static func restore(_ data: Data, accountID: String, local: JSONValue) throws -> Self {
        var saved = try JSONDecoder().decode(Self.self, from: data)
        guard saved.accountID == accountID.lowercased() else { throw OutboxError.wrongAccount }
        // A login may already have loaded a remote snapshot. It must not turn
        // persisted offline changes into compensating deletes during restore.
        saved.removeUnverifiedSubscriptions()
        if saved.pending.isEmpty && saved.rejected.isEmpty {
            saved.lastLocal = local
            saved.server = local
        }
        return saved
    }

    public mutating func capture(_ current: JSONValue) {
        let operations = SnapshotChanges.operations(from: lastLocal, to: current)
        var projection = lastLocal
        for operation in operations where !Self.unverifiedSubscription(operation) {
            pending.append(QueuedMutation(operation: operation, baseRevision: revision, submissionRevision: revision,
                                          before: Self.expectedValues(for: operation, in: projection)))
            Self.apply(operation, to: &projection)
        }
        lastLocal = current
    }

    /// Compare metadata with its captured field values, never with a freshly
    /// invented base. Independent operations can still proceed after a conflict.
    public mutating func reconcile(server state: JSONValue, revision: Int) {
        guard revision >= (self.revision ?? 0) else { return }
        self.server = state; self.revision = revision
        var projection = state
        var retained: [QueuedMutation] = []
        for var entry in pending {
            if Self.unverifiedSubscription(entry.operation) { continue }
            if Self.requiresCompare(entry.operation), !Self.canRebase(entry, onto: projection) {
                rejected.append(entry)
                rejectionTitles[entry.operation.id.uuidString] = Self.title(for: entry.operation)
                continue
            }
            entry.submissionRevision = revision
            retained.append(entry)
            Self.apply(entry.operation, to: &projection)
        }
        pending = retained
        lastLocal = projection
    }

    public mutating func acknowledge(_ ids: Set<UUID>, server: JSONValue, revision: Int) {
        pending.removeAll { ids.contains($0.operation.id) }
        reconcile(server: server, revision: revision)
        lastLocal = projectedState()
    }

    public mutating func quarantine(id: UUID, title: String) {
        guard let index = pending.firstIndex(where: { $0.operation.id == id }) else { return }
        let entry = pending.remove(at: index)
        rejected.append(entry); rejectionTitles[id.uuidString] = title
        lastLocal = projectedState()
    }

    public mutating func resolveConflict(id: UUID, useLocal: Bool) {
        guard let index = rejected.firstIndex(where: { $0.operation.id == id }) else { return }
        var entry = rejected.remove(at: index)
        rejectionTitles.removeValue(forKey: id.uuidString)
        if useLocal {
            entry.before = Self.expectedValues(for: entry.operation, in: projectedState())
            entry.submissionRevision = revision
            pending.append(entry)
        }
        lastLocal = projectedState()
    }

    public func projectedState() -> JSONValue {
        var state = server
        for entry in pending { Self.apply(entry.operation, to: &state) }
        return state
    }

    /// Legacy outboxes did not retain a baseline. Preserve all IDs and require
    /// an explicit choice for metadata instead of pretending it is current.
    public mutating func importLegacy(_ operations: [SyncOperation]) {
        for operation in operations where !Self.unverifiedSubscription(operation) {
            let entry = QueuedMutation(operation: operation, baseRevision: nil, submissionRevision: nil, before: .null)
            if Self.requiresCompare(operation) {
                rejected.append(entry); rejectionTitles[operation.id.uuidString] = Self.title(for: operation)
            } else { pending.append(entry) }
        }
    }

    private mutating func removeUnverifiedSubscriptions() {
        pending.removeAll { Self.unverifiedSubscription($0.operation) }
        rejected.removeAll { Self.unverifiedSubscription($0.operation) }
    }
    private static func unverifiedSubscription(_ operation: SyncOperation) -> Bool {
        operation.kind == "subscriptionSet" && operation.payload["subscription"]?["source"]?.string == "appStore"
    }
    private static func requiresCompare(_ operation: SyncOperation) -> Bool {
        ["profileUpdate", "profileReplace", "profileOrder"].contains(operation.kind)
    }
    private static func profile(_ id: String?, in state: JSONValue) -> JSONValue? {
        guard let id else { return nil }
        return state["profiles"]?.array?.first { $0["id"]?.string?.lowercased() == id.lowercased() }
    }
    private static func expectedValues(for operation: SyncOperation, in state: JSONValue) -> JSONValue {
        if operation.kind == "profileOrder" { return .array((state["profiles"]?.array ?? []).compactMap { $0["id"]?.string.map { .string($0.lowercased()) } }) }
        guard let profile = profile(operation.profileID, in: state) else { return .null }
        if operation.kind == "profileReplace" { return profile }
        let keys = ["name", "colorIndex", "maxFSK", "littleKid", "avatar", "onboardingComplete"]
            .filter { operation.payload.object?[$0] != nil }
        var expected = Dictionary(uniqueKeysWithValues: keys.map { ($0, profile[$0] ?? .null) })
        for (id, desired) in operation.payload["external"]?.object ?? [:] where profile["external"]?[id] != desired {
            expected["external:" + id] = profile["external"]?[id] ?? .null
        }
        return .object(expected)
    }
    private static func canRebase(_ entry: QueuedMutation, onto state: JSONValue) -> Bool {
        let operation = entry.operation
        let now = expectedValues(for: operation, in: state)
        guard entry.before != .null, now != .null else { return false }
        if operation.kind == "profileOrder" { return entry.before == now || now == operation.payload["profileIDs"] }
        if operation.kind == "profileReplace" { return entry.before == now || now == operation.payload["profile"] }
        guard let profile = profile(operation.profileID, in: state) else { return false }
        return (entry.before.object ?? [:]).allSatisfy { key, old in
            let current: JSONValue, desired: JSONValue
            if key.hasPrefix("external:") {
                let id = String(key.dropFirst("external:".count))
                current = profile["external"]?[id] ?? .null
                desired = operation.payload["external"]?[id] ?? .null
            } else {
                current = profile[key] ?? .null
                desired = operation.payload[key] ?? .null
            }
            return current == old || current == desired
        }
    }
    private static func title(for operation: SyncOperation) -> String {
        if operation.kind == "profileOrder" { return "Die aktiven und pausierten Profile wurden auf einem anderen Gerät geändert." }
        return "Das Profil wurde auf einem anderen Gerät geändert oder gelöscht."
    }

    /// Replays only unacknowledged semantic changes over the accepted snapshot.
    /// No local selection, password, credential or derived training cache is merged.
    private static func apply(_ operation: SyncOperation, to value: inout JSONValue) {
        guard var state = value.object else { return }
        var profiles = state["profiles"]?.array ?? []
        let payload = operation.payload
        switch operation.kind {
        case "profileCreate":
            if let profile = payload["profile"], !profiles.contains(where: { $0["id"]?.string?.lowercased() == operation.profileID?.lowercased() }) { profiles.append(profile) }
        case "profileDelete":
            profiles.removeAll { $0["id"]?.string?.lowercased() == operation.profileID?.lowercased() }
            state["pendingRatings"] = .array((state["pendingRatings"]?.array ?? []).compactMap { pending in
                guard var row = pending.object else { return nil }
                let ids = (row["profileIDs"]?.array ?? []).filter { $0.string?.lowercased() != operation.profileID?.lowercased() }
                guard !ids.isEmpty else { return nil }; row["profileIDs"] = .array(ids); return .object(row)
            })
        case "profileOrder":
            let ids = (payload["profileIDs"]?.array ?? []).compactMap { $0.string?.lowercased() }
            profiles.sort { (ids.firstIndex(of: $0["id"]?.string?.lowercased() ?? "") ?? ids.count) < (ids.firstIndex(of: $1["id"]?.string?.lowercased() ?? "") ?? ids.count) }
        case "subscriptionSet":
            var account = state["account"]?.object ?? [:]; account["subscription"] = payload["subscription"] ?? .null; state["account"] = .object(account)
        case "pendingRatingSet":
            if let pending = payload["pending"] {
                var rows = state["pendingRatings"]?.array ?? []
                rows.removeAll { pendingKey($0) == pendingKey(pending) }; rows.append(pending); state["pendingRatings"] = .array(rows)
            }
        case "pendingRatingRemove":
            state["pendingRatings"] = .array((state["pendingRatings"]?.array ?? []).filter { pendingKey($0) != payload["id"]?.string })
        default:
            guard let index = profiles.firstIndex(where: { $0["id"]?.string?.lowercased() == operation.profileID?.lowercased() }), var p = profiles[index].object else { return }
            let filmID = operation.filmID ?? ""
            switch operation.kind {
            case "profileReplace": if let profile = payload["profile"] { profiles[index] = profile }; state["profiles"] = .array(profiles); value = .object(state); return
            case "profileUpdate":
                for key in ["name", "colorIndex", "maxFSK", "littleKid", "avatar", "onboardingComplete"] { if let v = payload[key] { p[key] = v } }
                if let delta = payload["importedCountDelta"]?.number { p["importedCount"] = .number(max(0, (p["importedCount"]?.number ?? 0) + delta)) }
                if let external = payload["external"]?.object { p["external"] = .object((p["external"]?.object ?? [:]).merging(external) { _, new in new }) }
                applyLearning(payload["learning"], to: &p)
            case "watchlistAdd", "watchlistRemove":
                var list = p["watchlist"]?.array ?? []
                if operation.kind == "watchlistAdd" { if !list.contains(.string(filmID)) { list.append(.string(filmID)) } }
                else { list.removeAll { $0.string == filmID } }
                p["watchlist"] = .array(list)
            case "ratingSet":
                var ratings = p["interactions"]?.object ?? [:]
                if payload["rating"] == .null { ratings.removeValue(forKey: filmID) } else if let rating = payload["rating"] { ratings[filmID] = rating }
                p["interactions"] = .object(ratings); applyLearning(payload["learning"], to: &p)
            case "hintSet":
                if let key = payload["key"]?.string, let delta = payload["value"]?.number {
                    for field in ["hints", "affinity"] { var data = p[field]?.object ?? [:]; data[key] = .number((data[key]?.number ?? 0) + delta); p[field] = .object(data) }
                }
            case "reviewSet":
                var reviews = (p["reviews"]?.array ?? []).filter { $0["filmID"]?.string != filmID }
                if let review = payload["review"], review != .null { reviews.append(review) }; p["reviews"] = .array(reviews)
            case "progressSet":
                if let key = payload["positionKey"]?.string { var positions = p["playbackPositions"]?.object ?? [:]; positions[key] = payload["seconds"]; p["playbackPositions"] = .object(positions) }
                else { var progress = p["progress"]?.object ?? [:]; if payload["progress"] == .null { progress.removeValue(forKey: filmID) } else { progress[filmID] = payload["progress"] }; p["progress"] = .object(progress) }
            default: break
            }
            p["weights"] = .object([:]); p["taste"] = .array([]); profiles[index] = .object(p)
        }
        state["profiles"] = .array(profiles)
        value = .object(state)
    }
    private static func pendingKey(_ value: JSONValue) -> String {
        if let id = value["id"]?.string { return id }
        let date = value["date"]?.number.map { $0 == $0.rounded() ? String(format: "%.0f", $0) : String($0) } ?? ""
        return (value["filmID"]?.string ?? "") + "|" + date
    }
    private static func applyLearning(_ learning: JSONValue?, to profile: inout [String: JSONValue]) {
        guard let learning else { return }
        for field in ["affinity", "exposure"] {
            var values = profile[field]?.object ?? [:]
            for (key, delta) in learning[field]?.object ?? [:] { values[key] = .number((values[key]?.number ?? 0) + (delta.number ?? 0)) }
            profile[field] = .object(values)
        }
        for field in ["signalN", "signalTotal"] { if let delta = learning[field]?.number { profile[field] = .number((profile[field]?.number ?? 0) + delta) } }
        var samples = profile["samples"]?.array ?? []
        for delta in learning["samples"]?.array ?? [] {
            guard let film = delta["filmID"]?.string, let change = delta["delta"]?.number else { continue }
            if let index = samples.firstIndex(where: { $0["filmID"]?.string == film }) { samples[index] = .object(["filmID": .string(film), "target": .number((samples[index]["target"]?.number ?? 0) + change)]) }
            else { samples.append(.object(["filmID": .string(film), "target": .number(change)])) }
        }
        profile["samples"] = .array(samples.filter { abs($0["target"]?.number ?? 0) > 1e-9 })
    }
}
