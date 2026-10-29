import XCTest
@testable import FilmSync

final class ProfileOrderAndSubscriptionTests:XCTestCase {
    func testReorderingUnchangedProfilesOnlyEmitsExplicitOrder() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"11111111-1111-4111-8111-111111111111","name":"Anna"},{"id":"22222222-2222-4222-8222-222222222222","name":"Ben"}],"activeProfileIDs":["11111111-1111-4111-8111-111111111111"]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"22222222-2222-4222-8222-222222222222","name":"Ben"},{"id":"11111111-1111-4111-8111-111111111111","name":"Anna"}],"activeProfileIDs":["22222222-2222-4222-8222-222222222222"]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileOrder"])
        XCTAssertNil(operations.first?.profileID)
        XCTAssertNil(operations.first?.filmID)
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"profileIDs":["22222222-2222-4222-8222-222222222222","11111111-1111-4111-8111-111111111111"]}"#))
    }
    func testCreationAndDeletionAloneDoNotEmitOrderMutation() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","name":"Anna"},{"id":"B","name":"Ben"}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"B","name":"Ben"},{"id":"C","name":"Clara"}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileDelete","profileCreate"])
    }
    func testOrderFollowsMembershipMutationsAndIncludesAllCurrentProfiles() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","name":"Anna"},{"id":"B","name":"Ben"},{"id":"D","name":"David"}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"B","name":"Ben"},{"id":"C","name":"Clara"},{"id":"A","name":"Anna"}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileDelete","profileCreate","profileOrder"])
        XCTAssertEqual(operations.last?.payload,try JSONValue.parse(#"{"profileIDs":["b","c","a"]}"#))
    }
    func testLocalSelectionChangeNeverCreatesProfileOrder() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A"},{"id":"B"}],"activeProfileIDs":["A"]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A"},{"id":"B"}],"activeProfileIDs":["B"],"hasChosenViewers":true}"#)
        XCTAssertTrue(SnapshotChanges.operations(from:old,to:new).isEmpty)
    }
    func testAppStoreSubscriptionRequiresDedicatedVerificationInsteadOfClientGrant() throws {
        let old=try JSONValue.parse(#"{"profiles":[],"account":{"subscription":null}}"#)
        let new=try JSONValue.parse(#"{"profiles":[],"account":{"subscription":{"plan":"familie","source":"appStore","started":1,"renews":2,"trial":false}}}"#)
        XCTAssertTrue(SnapshotChanges.operations(from:old,to:new).isEmpty)
    }
    func testUnverifiedAppStoreChangeCannotBlockOtherOutboxMutations() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","watchlist":[]}],"account":{"subscription":{"plan":"solo","source":"appStore"}}}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","watchlist":["film"]}],"account":{"subscription":{"plan":"familie","source":"appStore"}}}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["watchlistAdd"])
        XCTAssertEqual(operations.first?.filmID,"film")
    }
    func testDemoSubscriptionStillUsesExplicitMutation() throws {
        let old=try JSONValue.parse(#"{"profiles":[],"account":{"subscription":null}}"#)
        let new=try JSONValue.parse(#"{"profiles":[],"account":{"subscription":{"plan":"duo","source":"demo"}}}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["subscriptionSet"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"subscription":{"plan":"duo","source":"demo"}}"#))
    }
}
