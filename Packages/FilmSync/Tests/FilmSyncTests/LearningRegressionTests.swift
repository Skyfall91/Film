import XCTest
@testable import FilmSync

final class LearningRegressionTests:XCTestCase {
    func testRepeatedNotTodayWithoutStoredInteractionKeepsLearningDelta() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[{"filmID":"film","target":-0.5}],"affinity":{"g:Drama":-0.4}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[{"filmID":"film","target":-1}],"affinity":{"g:Drama":-0.8}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.count,1)
        XCTAssertEqual(operations.first?.kind,"ratingSet")
        XCTAssertEqual(operations.first?.profileID,"a")
        XCTAssertEqual(operations.first?.filmID,"film")
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":null,"learning":{"affinity":{"g:Drama":-0.4},"samples":[{"filmID":"film","delta":-0.5}]}}"#))
    }
    func testRepeatedActionKeepsExistingRatingAndAccumulatesSamples() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"signalN":1,"signalTotal":1}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":2}],"signalN":2,"signalTotal":2}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["ratingSet"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":"liked","learning":{"signalN":1,"signalTotal":1,"samples":[{"filmID":"film","delta":1}]}}"#))
    }
    func testHintAffinityIsNotAppliedTwiceAlongsideRating() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[],"affinity":{"g:Drama":1},"hints":{"g:Drama":1}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"affinity":{"g:Drama":4},"hints":{"g:Drama":3}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["ratingSet","hintSet"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":"liked","learning":{"affinity":{"g:Drama":1},"samples":[{"filmID":"film","delta":1}]}}"#))
        XCTAssertEqual(operations.last?.payload,try JSONValue.parse(#"{"key":"g:Drama","value":2}"#))
    }
    func testZeroSignalRatingCarriesEmptyNativeSampleMarker() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[]}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"unseen"},"samples":[]}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["ratingSet"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":"unseen","learning":{"samples":[]}}"#))
    }
    func testRatingUndoUsesNullAndExactNegativeLearning() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"affinity":{"g:Drama":1},"signalN":1}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[],"affinity":{},"signalN":0}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":null,"learning":{"affinity":{"g:Drama":-1},"signalN":-1,"samples":[{"filmID":"film","delta":-1}]}}"#))
    }
    func testImportedCountResetStaysGranularAndExternalMetadataIncluded() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","importedCount":7,"external":{}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","importedCount":0,"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileUpdate"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"importedCountDelta":-7,"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}}}"#))
    }
    func testAllFilmRatingsInBatchUseOneAggregatedNativeLearningPayload() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[]}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"a":"unseen","b":"liked"},"samples":[{"filmID":"b","target":1}]}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.filmID),["a","b"])
        XCTAssertEqual(operations.first?.payload["learning"],try JSONValue.parse(#"{"samples":[{"filmID":"b","delta":1}]}"#))
        XCTAssertEqual(operations.last?.payload["learning"],try JSONValue.parse(#"{"samples":[]}"#))
    }
    func testPersistedOutboxRetryPreservesLiteralIDsAndNegativeDeltas() throws {
        let operationID=UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
        let operation=SyncOperation(id:operationID,kind:"ratingSet",profileID:"a",filmID:"film",payload:try JSONValue.parse(#"{"rating":null,"learning":{"samples":[{"filmID":"film","delta":-0.5}]}}"#))
        let stored=try JSONEncoder().encode([operation])
        let retry=try JSONDecoder().decode([SyncOperation].self,from:stored)
        let wire=try JSONValue.decode(JSONEncoder().encode(retry))
        XCTAssertEqual(retry.first?.id,operationID)
        XCTAssertEqual(wire.array?.first?["id"],.string("11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(retry.first?.payload,operation.payload)
    }
    func testLearningStillTravelsWhenSamplesAndRawRatingRemainUnchanged() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"affinity":{"g:Drama":0.5},"exposure":{"g:Drama":1},"signalN":1}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"film":"liked"},"samples":[{"filmID":"film","target":1}],"affinity":{"g:Drama":0.75},"exposure":{"g:Drama":3},"signalN":3}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["ratingSet"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"rating":"liked","learning":{"affinity":{"g:Drama":0.25},"exposure":{"g:Drama":2},"signalN":2,"samples":[]}}"#))
    }

    func testExternalOnlyLearningTravelsWithProfileMetadataWithoutCatalogRating() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[],"external":{},"affinity":{},"importedCount":0}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[{"filmID":"ext:Q1","target":1}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}},"affinity":{"g:Drama":1},"importedCount":1}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileUpdate"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}},"importedCountDelta":1,"learning":{"affinity":{"g:Drama":1},"samples":[{"filmID":"ext:Q1","delta":1}]}}"#))
    }
    func testRepeatedExternalLearningCreatesLearningOnlyProfileUpdate() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[{"filmID":"ext:Q1","target":1}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}},"affinity":{"g:Drama":1}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[{"filmID":"ext:Q1","target":2}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}},"affinity":{"g:Drama":2}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileUpdate"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"learning":{"affinity":{"g:Drama":1},"samples":[{"filmID":"ext:Q1","delta":1}]}}"#))
    }
    func testMixedCatalogAndExternalLearningUsesCatalogCarrierAndPreservesBothTargets() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{},"samples":[],"external":{}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"catalog-film":"liked"},"samples":[{"filmID":"catalog-film","target":1},{"filmID":"ext:Q1","target":2}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileUpdate","ratingSet"])
        XCTAssertEqual(operations.last?.filmID,"catalog-film")
        XCTAssertEqual(operations.last?.payload["learning"],try JSONValue.parse(#"{"samples":[{"filmID":"catalog-film","delta":1},{"filmID":"ext:Q1","delta":2}]}"#))
    }

    func testExternalOnlyChangeDoesNotRewriteUnrelatedCatalogRating() throws {
        let old=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"catalog-film":"liked"},"samples":[{"filmID":"catalog-film","target":1},{"filmID":"ext:Q1","target":1}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}}}]}"#)
        let new=try JSONValue.parse(#"{"profiles":[{"id":"A","interactions":{"catalog-film":"liked"},"samples":[{"filmID":"catalog-film","target":1},{"filmID":"ext:Q1","target":2}],"external":{"ext:Q1":{"id":"ext:Q1","title":"Importfilm","genres":[],"moods":[],"cast":[],"director":"Regie"}}}]}"#)
        let operations=SnapshotChanges.operations(from:old,to:new)
        XCTAssertEqual(operations.map(\.kind),["profileUpdate"])
        XCTAssertEqual(operations.first?.payload,try JSONValue.parse(#"{"learning":{"samples":[{"filmID":"ext:Q1","delta":1}]}}"#))
    }

}
