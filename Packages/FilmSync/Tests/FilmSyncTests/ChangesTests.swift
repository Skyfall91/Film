import XCTest
@testable import FilmSync
final class ChangesTests: XCTestCase {
    func testSeparateFilmsCreateSeparateGranularOperations() throws {
        let old = try JSONValue.parse(#"{"profiles":[{"id":"A","watchlist":["old"],"interactions":{},"samples":[]}],"account":{"passwordHash":"secret","salt":"private"}}"#)
        let new = try JSONValue.parse(#"{"profiles":[{"id":"A","watchlist":["new"],"interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"affinity":{"g:Drama":2},"signalN":1,"signalTotal":1}],"account":{"passwordHash":"secret","salt":"private"}}"#)
        let ops = SnapshotChanges.operations(from: old, to: new)
        XCTAssertEqual(Set(ops.map(\.kind)), ["watchlistAdd","watchlistRemove","ratingSet"])
        XCTAssertEqual(ops.first{ $0.kind == "ratingSet" }?.payload["learning"]?["signalN"], .number(1))
        XCTAssertEqual(ops.first{ $0.kind == "ratingSet" }?.payload["learning"]?["samples"]?.array?.first?["delta"], .number(1))
    }
    func testLocalCredentialsAndSelectionNeverEnterOperations() throws {
        let old = try JSONValue.parse(#"{"profiles":[],"activeProfileIDs":[],"account":{"email":"a","passwordHash":"old","salt":"old"}}"#)
        let new = try JSONValue.parse(#"{"profiles":[],"activeProfileIDs":["X"],"account":{"email":"a","passwordHash":"new","salt":"new"},"signedIn":true}"#)
        XCTAssertTrue(SnapshotChanges.operations(from:old,to:new).isEmpty)
    }
    func testDeletedProfileCannotBeSentAsWholeAccountReplacement() throws {
        let old = try JSONValue.parse(#"{"profiles":[{"id":"A","name":"old"}],"account":{}}"#)
        let new = try JSONValue.parse(#"{"profiles":[],"account":{}}"#)
        let ops=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(ops.map(\.kind), ["profileDelete"])
        XCTAssertEqual(ops.first?.profileID,"a")
    }
    func testTwoNewReviewsAndProgressRemainGranular() throws {
        let old = try JSONValue.parse(#"{"profiles":[{"id":"A","reviews":[],"progress":{}}]}"#)
        let new = try JSONValue.parse(#"{"profiles":[{"id":"A","reviews":[{"filmID":"a","rating":"ratedUp","text":"Gut","date":1}],"progress":{"series":{"season":1,"episode":2}}}]}"#)
        XCTAssertEqual(Set(SnapshotChanges.operations(from:old,to:new).map(\.kind)),["reviewSet","progressSet"])
    }
    func testRepeatedDiffDoesNotGenerateDifferentMutationIDOnOutboxRetry() throws {
        let op = SyncOperation(id:UUID(),kind:"watchlistAdd",profileID:"a",filmID:"x",payload:.object([:]))
        let encoded=try JSONEncoder().encode(op)
        XCTAssertEqual(try JSONDecoder().decode(SyncOperation.self,from:encoded),op)
    }
}

final class JSONValueParsingTests: XCTestCase {
    func testFastParserMatchesDecodable() throws {
        let text = #"{"a":true,"b":false,"c":0,"d":1,"e":0.1,"f":-2.5e-3,"g":"x","h":null,"i":[1,"2",{"j":[]}],"k":{},"l":1792655537.167705,"m":12345678901234}"#
        let fast = try JSONValue.decode(Data(text.utf8))
        let slow = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(fast, slow)
    }
}
