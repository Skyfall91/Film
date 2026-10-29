import XCTest
@testable import FilmSync

final class OutboxTests: XCTestCase {
    private let accountID = "11111111-1111-4111-8111-111111111111"
    private let profileID = "22222222-2222-4222-8222-222222222222"
    private func state(name: String = "Before", watchlist: [String] = [], avatar: String = "original") -> JSONValue {
        .object(["profiles": .array([.object(["id": .string(profileID), "name": .string(name), "avatar": .string(avatar), "watchlist": .array(watchlist.map(JSONValue.string)), "interactions": .object([:]), "samples": .array([])])]), "pendingRatings": .array([]), "onboardingDone": .bool(true)])
    }

    func testFirstBootstrapContainsOnlyTheBaselineSoQueuedActionsAreNotImportedTwice() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.capture(state(watchlist: ["queued"]))
        XCTAssertEqual(outbox.bootstrapState["profiles"]?.array?.first?["watchlist"], .array([]))
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["watchlist"], .array([.string("queued")]))
    }

    func testLateReadCannotRollBackAnAlreadyAcknowledgedRevision() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(watchlist: ["newest"]), revision: 4)
        outbox.reconcile(server: state(), revision: 3)
        XCTAssertEqual(outbox.revision, 4)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["watchlist"], .array([.string("newest")]))
    }

    func testLegacyStoreKitWriteIsDroppedWhileWatchlistIDIsPreserved() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        let wanted = SyncOperation(kind: "watchlistAdd", profileID: profileID, filmID: "keep", payload: .object([:]))
        let storeKit = SyncOperation(kind: "subscriptionSet", payload: .object(["subscription": .object(["source": .string("appStore")])]))
        outbox.importLegacy([storeKit, wanted])
        XCTAssertEqual(outbox.pending.map { $0.operation.id }, [wanted.id])
        XCTAssertTrue(outbox.conflicts.isEmpty)
    }

    func testProfileCreationAndOrderRemainOneReplayableSequence() {
        let secondID = "33333333-3333-4333-8333-333333333333"
        let thirdID = "44444444-4444-4444-8444-444444444444"
        let first = state()["profiles"]!.array!.first!
        var second = first.object!; second["id"] = .string(secondID)
        var third = first.object!; third["id"] = .string(thirdID)
        var baseline = state().object!; baseline["profiles"] = .array([first, .object(second)])
        var changed = state().object!; changed["profiles"] = .array([.object(second), .object(third), first])
        var outbox = SyncOutbox(accountID: accountID, local: .object(baseline))
        outbox.capture(.object(changed))
        outbox.reconcile(server: .object(baseline), revision: 1)
        XCTAssertTrue(outbox.conflicts.isEmpty)
        XCTAssertEqual(outbox.pending.map { $0.operation.kind }, ["profileCreate", "profileOrder"])
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["id"], .string(secondID))
    }

    func testExternalMetadataConflictDoesNotOverwriteNewerDefinition() {
        let externalID = "ext:Q123"
        func withExternal(_ title: String) -> JSONValue {
            var p = state()["profiles"]!.array!.first!.object!
            p["external"] = .object([externalID: .object(["id": .string(externalID), "title": .string(title)])])
            var root = state().object!; root["profiles"] = .array([.object(p)]); return .object(root)
        }
        var outbox = SyncOutbox(accountID: accountID, local: withExternal("Before"))
        outbox.capture(withExternal("Local definition"))
        outbox.reconcile(server: withExternal("Remote definition"), revision: 2)
        XCTAssertEqual(outbox.conflicts.count, 1)
        XCTAssertTrue(outbox.pending.isEmpty)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["external"]?[externalID]?["title"], .string("Remote definition"))
    }

    func testEmptyRestoredOutboxDoesNotRelearnSnapshotAlreadyLoadedByLogin() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        let saved = try JSONEncoder().encode(outbox)
        let alreadyLoaded = state(name: "Remote name", watchlist: ["remote"])
        var restored = try SyncOutbox.restore(saved, accountID: accountID, local: alreadyLoaded)
        restored.capture(alreadyLoaded)
        XCTAssertTrue(restored.pending.isEmpty)
    }

    func testEditsDuringDelayedFirstReadSurviveReceivingServerState() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.capture(state(watchlist: ["local"]))
        XCTAssertEqual(outbox.pending.count, 1)
        let operationID = try XCTUnwrap(outbox.pending.first?.operation.id)
        outbox.reconcile(server: state(watchlist: ["remote"]), revision: 3)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["watchlist"], .array([.string("remote"), .string("local")]))
        XCTAssertEqual(outbox.pending.first?.operation.id, operationID)
    }

    func testOfflinePersistenceRetainsCaptureBaselineOriginalRevisionAndOperationID() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 7)
        outbox.capture(state(name: "Offline name"))
        let identifier = try XCTUnwrap(outbox.pending.first?.operation.id)
        let saved = try JSONEncoder().encode(outbox)
        var restored = try SyncOutbox.restore(saved, accountID: accountID, local: state())
        XCTAssertEqual(restored.pending.count, 1)
        XCTAssertEqual(restored.pending.first?.baseRevision, 7)
        XCTAssertEqual(restored.pending.first?.operation.id, identifier)
        restored.reconcile(server: state(watchlist: ["other device"]), revision: 8)
        XCTAssertTrue(restored.conflicts.isEmpty)
        XCTAssertEqual(restored.projectedState()["profiles"]?.array?.first?["name"], .string("Offline name"))
        XCTAssertEqual(restored.pending.first?.baseRevision, 7)
        XCTAssertEqual(restored.pending.first?.submissionRevision, 8)
        XCTAssertThrowsError(try SyncOutbox.restore(saved, accountID: "different-account", local: state()))
    }

    func testMetadataRebasesWhenOnlyUnchangedFieldsDiffer() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(name: "Local name"))
        outbox.reconcile(server: state(avatar: "remote avatar"), revision: 2)
        XCTAssertTrue(outbox.conflicts.isEmpty)
        XCTAssertEqual(outbox.pending.first?.submissionRevision, 2)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["avatar"], .string("remote avatar"))
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["name"], .string("Local name"))
    }

    func testSameFieldConflictIsQuarantinedWithoutBlockingIndependentWatchlistEdit() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(name: "Local name", watchlist: ["local title"]))
        let renameID = try XCTUnwrap(outbox.pending.first(where: { $0.operation.kind == "profileUpdate" })?.operation.id)
        outbox.reconcile(server: state(name: "Remote name", watchlist: ["remote title"]), revision: 2)
        XCTAssertEqual(outbox.conflicts.map(\.id), [renameID])
        XCTAssertEqual(outbox.pending.map { $0.operation.kind }, ["watchlistAdd"])
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["name"], .string("Remote name"))
        let saved = try JSONEncoder().encode(outbox)
        let restored = try SyncOutbox.restore(saved, accountID: accountID, local: outbox.projectedState())
        XCTAssertEqual(restored.conflicts.map(\.id), [renameID])
    }

    func testExplicitLocalConflictResolutionKeepsOperationIDAndUsesLatestBase() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(name: "Local name"))
        outbox.reconcile(server: state(name: "Remote name"), revision: 2)
        let conflictID = try XCTUnwrap(outbox.conflicts.first?.id)
        outbox.resolveConflict(id: conflictID, useLocal: true)
        XCTAssertTrue(outbox.conflicts.isEmpty)
        XCTAssertEqual(outbox.pending.first?.operation.id, conflictID)
        XCTAssertEqual(outbox.pending.first?.baseRevision, 1)
        XCTAssertEqual(outbox.pending.first?.submissionRevision, 2)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["name"], .string("Local name"))
    }

    func testRemoteConflictResolutionDiscardsOnlyRejectedOperation() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(name: "Local name", watchlist: ["keep"]))
        outbox.reconcile(server: state(name: "Remote name"), revision: 2)
        outbox.resolveConflict(id: try XCTUnwrap(outbox.conflicts.first?.id), useLocal: false)
        XCTAssertTrue(outbox.conflicts.isEmpty)
        XCTAssertEqual(outbox.pending.map { $0.operation.kind }, ["watchlistAdd"])
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["name"], .string("Remote name"))
    }

    func testSequentialLocalMetadataEditsDoNotConflictWithEachOther() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(name: "First local name"))
        outbox.capture(state(name: "Second local name"))
        outbox.reconcile(server: state(avatar: "Changed remotely"), revision: 2)
        XCTAssertTrue(outbox.conflicts.isEmpty)
        XCTAssertEqual(outbox.pending.count, 2)
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["name"], .string("Second local name"))
    }

    func testAcknowledgementPreservesEditsCapturedWhileRequestWasInFlight() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        outbox.reconcile(server: state(), revision: 1)
        outbox.capture(state(watchlist: ["first"]))
        let sent = Set(outbox.pending.map { $0.operation.id })
        outbox.capture(state(watchlist: ["first", "second"]))
        let last = try XCTUnwrap(outbox.pending.last?.operation.id)
        outbox.acknowledge(sent, server: state(watchlist: ["first", "other device"]), revision: 3)
        XCTAssertEqual(outbox.pending.map { $0.operation.id }, [last])
        XCTAssertEqual(outbox.projectedState()["profiles"]?.array?.first?["watchlist"], .array([.string("first"), .string("other device"), .string("second")]))
    }

    func testLegacyStoreKitOperationsCannotBlockUnrelatedQueuedChanges() {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        var changed = state(watchlist: ["keep"]).object!
        changed["account"] = .object(["subscription": .object(["source": .string("appStore"), "plan": .string("solo")])])
        outbox.capture(.object(changed))
        XCTAssertEqual(outbox.pending.map { $0.operation.kind }, ["watchlistAdd"])
        XCTAssertTrue(outbox.conflicts.isEmpty)
    }

    func testLearningDeltaIsReplayedOnceAndNativeMarkerSurvivesPersistence() throws {
        var outbox = SyncOutbox(accountID: accountID, local: state())
        var profile = state()["profiles"]!.array!.first!.object!
        profile["interactions"] = .object(["film": .string("liked")])
        profile["samples"] = .array([.object(["filmID": .string("film"), "target": .number(1)])])
        var changed = state().object!; changed["profiles"] = .array([.object(profile)])
        outbox.capture(.object(changed))
        let saved = try JSONEncoder().encode(outbox)
        var restored = try SyncOutbox.restore(saved, accountID: accountID, local: .object(changed))
        restored.reconcile(server: state(), revision: 1)
        restored.reconcile(server: state(), revision: 1)
        XCTAssertEqual(restored.pending.count, 1)
        XCTAssertEqual(restored.pending.first?.operation.payload["learning"]?["samples"]?.array?.count, 1)
        XCTAssertEqual(restored.projectedState()["profiles"]?.array?.first?["samples"]?.array?.first?["target"], .number(1))
    }
}
