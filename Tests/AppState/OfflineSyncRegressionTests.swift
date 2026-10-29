import XCTest
import FilmSync
import LightCode
@testable import Film

final class OfflineSyncRegressionTests: XCTestCase {

    @MainActor func testBulkImportKeepsEachOfflineRatingIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let userID = "11111111-1111-4111-8111-111111111111"
        let store = AppStore(ephemeral: true)
        store.account = Account(email: "offline@example.invalid", passwordHash: "", salt: "", created: .now, consented: .now)
        store.signedIn = true
        let profile = Profile(name: "A", colorIndex: 0)
        store.profiles = [profile]; store.activeProfileIDs = [profile.id]
        let sync = DeviceStateSync(store: store, userID: userID, token: { throw AuthError.offline }, storageDir: directory)
        store.deviceSync = sync
        let films = try ["dune", "inception", "interstellar"].map { try XCTUnwrap(FilmIndex.film($0)) }
        store.importRatings(profile: profile.id, ratings: films.map { ($0, .liked) }, unmatched: 1)
        sync.captureLocalChanges()
        let saved = try JSONDecoder().decode(SyncOutbox.self, from: Data(contentsOf: directory.appending(path: userID + ".json")))
        let ratings = saved.pending.map(\.operation).filter { $0.kind == "ratingSet" }
        XCTAssertEqual(Set(ratings.compactMap(\.filmID)), Set(films.map(\.id)))
        for operation in ratings {
            let samples = operation.payload["learning"]?["samples"]?.array ?? []
            XCTAssertEqual(samples.count, 1, "A rejected title must not carry another title's learning")
            XCTAssertEqual(samples.first?["filmID"]?.string, operation.filmID)
        }
        XCTAssertTrue(saved.pending.contains { $0.operation.kind == "profileUpdate" })
        sync.stop()
    }
    @MainActor func testLargeOfflineImportKeepsAllRatings() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let userID = "11111111-1111-4111-8111-111111111111"
        let store = AppStore(ephemeral: true)
        store.account = Account(email: "offline@example.invalid", passwordHash: "", salt: "", created: .now, consented: .now)
        store.signedIn = true
        let profile = Profile(name: "A", colorIndex: 0)
        store.profiles = [profile]; store.activeProfileIDs = [profile.id]
        let sync = DeviceStateSync(store: store, userID: userID, token: { throw AuthError.offline }, storageDir: directory)
        store.deviceSync = sync
        let films = Array(FilmIndex.all.filter { !$0.isSeries && !$0.comingSoon }.prefix(120))
        let begin = CFAbsoluteTimeGetCurrent()
        let finished = await store.importRatingsResponsively(profile: profile.id, ratings: films.map { ($0, .liked) })
        print("PERF offline-responsive-import-120 ms=\((CFAbsoluteTimeGetCurrent() - begin) * 1000)")
        XCTAssertTrue(finished)
        let saved = try JSONDecoder().decode(SyncOutbox.self, from: Data(contentsOf: directory.appending(path: userID + ".json")))
        let ratings = saved.pending.map(\.operation).filter { $0.kind == "ratingSet" }
        XCTAssertEqual(ratings.count, films.count)
        for operation in ratings {
            let samples = operation.payload["learning"]?["samples"]?.array ?? []
            XCTAssertEqual(samples.count, 1)
            XCTAssertEqual(samples.first?["filmID"]?.string, operation.filmID)
        }
        XCTAssertEqual(store.profiles[0].interactions.count, films.count)
        sync.stop()
    }

    @MainActor func testVerifiedCloudIdentitySurvivesOfflineAccountPersistence() throws {
        let database = AccountDatabase(inMemory: true)
        let account = Account(email: "offline@example.invalid", passwordHash: "hash", salt: "salt", created: .now, consented: .now)
        let userID = "11111111-1111-4111-8111-111111111111"
        database.upsert(account, state: Data("first".utf8), cloudUserID: userID)
        database.upsert(account, state: Data("offline edit".utf8))
        XCTAssertEqual(database.record(account.email)?.cloudUserID, userID)
        XCTAssertEqual(database.record(account.email)?.state, Data("offline edit".utf8))
    }

    @MainActor func testOfflineCoordinatorPersistsActionsBeforeFirstSuccessfulRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let userID = "11111111-1111-4111-8111-111111111111"
        let store = AppStore(ephemeral: true)
        store.account = Account(email: "offline@example.invalid", passwordHash: "hash", salt: "salt", created: .now, consented: .now)
        store.signedIn = true
        let profile = Profile(name: "Offline", colorIndex: 0)
        store.profiles = [profile]; store.activeProfileIDs = [profile.id]
        let sync = DeviceStateSync(store: store, userID: userID, token: { throw AuthError.offline }, storageDir: directory)
        do { try await sync.start(); XCTFail("Expected offline read failure") } catch { }
        store.profiles[0].watchlist.append("dune")
        sync.captureLocalChanges()
        let data = try Data(contentsOf: directory.appending(path: userID + ".json"))
        let saved = try JSONDecoder().decode(SyncOutbox.self, from: data)
        XCTAssertEqual(saved.pending.map { $0.operation.kind }, ["watchlistAdd"])
        XCTAssertEqual(saved.pending.first?.operation.filmID, "dune")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"passwordHash\":\"hash\""))
        sync.stop()
    }

    @MainActor func testStoppedAccountEpochCannotCaptureIntoSavedOutbox() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let userID = "11111111-1111-4111-8111-111111111111"
        let store = AppStore(ephemeral: true)
        store.account = Account(email: "offline@example.invalid", passwordHash: "", salt: "", created: .now, consented: .now)
        store.signedIn = true; store.profiles = [Profile(name: "A", colorIndex: 0)]
        let sync = DeviceStateSync(store: store, userID: userID, token: { throw AuthError.offline }, storageDir: directory)
        sync.stop()
        store.sessionEpoch = UUID(); store.profiles[0].watchlist.append("dune")
        sync.captureLocalChanges()
        let saved = try JSONDecoder().decode(SyncOutbox.self, from: Data(contentsOf: directory.appending(path: userID + ".json")))
        XCTAssertTrue(saved.pending.isEmpty)
    }
}
