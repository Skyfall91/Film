import XCTest
@testable import Film

final class AppStoreRegressionTests: XCTestCase {
    @MainActor func testCloudSnapshotOmitsDeviceSelectionAndKeepsLocalViewer() throws {
        let store=AppStore(ephemeral:true)
        let a=Profile(name:"A",colorIndex:0,avatar:"scifi-0"), b=Profile(name:"B",colorIndex:1,avatar:"scifi-0")
        store.profiles=[a,b];store.activeProfileIDs=[b.id]
        let data=try JSONEncoder().encode(AppStore.Snapshot(profiles:[a,b],activeProfileIDs:[a.id],onboardingDone:true,pendingRatings:[],account:nil,signedIn:nil))
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        wire.removeValue(forKey:"activeProfileIDs")
        try store.applyCloudSnapshot(JSONSerialization.data(withJSONObject:wire))
        XCTAssertEqual(store.activeProfileIDs,[b.id])
        XCTAssertEqual(store.profiles.map(\.name),["A","B"])
    }
    @MainActor func testRuntimeRangeAllowsOnlyFilmsBetweenBounds() {
        let range = RuntimeFilter(min: 90, max: 120)
        XCTAssertFalse(range.allows(89)); XCTAssertTrue(range.allows(90)); XCTAssertTrue(range.allows(120)); XCTAssertFalse(range.allows(121))
        XCTAssertEqual(range.label, "1,5 bis 2 Std.")
        XCTAssertEqual(RuntimeFilter(minutes: 105, atLeast: true).label, "ab 1:45 Std.")
        XCTAssertEqual(RuntimeFilter(minutes: 120).label, "bis 2 Std.")
    }
    @MainActor func testSearchForActorShowsOnlyTheirFilms() async {
        for text in ["Leonardo DiCaprio", "dicaprio", "lustige Filme mit DiCaprio"] {
            let result = await MoodSearch.search(text, profiles: [])
            XCTAssertFalse(result.films.isEmpty, text)
            XCTAssertTrue(result.films.allSatisfy { $0.film.cast.contains("Leonardo DiCaprio") }, text)
        }
        XCTAssertEqual(MoodSearch.people(in: "etwas Lustiges"), [])
        XCTAssertEqual(MoodSearch.people(in: "leonardo"), ["Leonardo DiCaprio"])
        XCTAssertEqual(MoodSearch.people(in: "Brad Pitt"), ["Brad Pitt"])
    }
    @MainActor func testQuickSearchReturnsPersonAndRuntimeResults() {
        let person = MoodSearch.quickSearch("lustige Filme mit DiCaprio", profiles: [])
        XCTAssertFalse(person.films.isEmpty)
        XCTAssertEqual(person.people, ["Leonardo DiCaprio"])
        XCTAssertTrue(person.films.allSatisfy { $0.film.cast.contains("Leonardo DiCaprio") })
        XCTAssertFalse(person.usedAppleIntelligence)

        let short = MoodSearch.quickSearch("lustig unter 90 Minuten", profiles: [])
        XCTAssertFalse(short.films.isEmpty)
        XCTAssertTrue(short.films.allSatisfy { $0.film.runtime <= 90 })
        XCTAssertFalse(short.usedAppleIntelligence)
    }
    @MainActor func testOwnSyncConfirmationKeepsUndoAndDeck() throws {
        let store=AppStore(ephemeral:true)
        let profile=Profile(name:"A",colorIndex:0,avatar:"scifi-0")
        store.profiles=[profile];store.activeProfileIDs=[profile.id]
        let film=try XCTUnwrap(FilmIndex.film("dune"))
        store.apply(.notToday,to:film)
        XCTAssertTrue(store.canUndo)
        // Der Server bestätigt den eigenen Swipe und liefert den Stand leicht anders normalisiert zurück.
        var confirmed=store.profiles[0];confirmed.weights=[:]
        let snapshot=AppStore.Snapshot(profiles:[confirmed],activeProfileIDs:[],onboardingDone:true,pendingRatings:[],account:nil,signedIn:nil)
        let revision=store.tasteRevision
        try store.applyCloudSnapshot(JSONEncoder().encode(snapshot),fromOtherDevice:false)
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(store.tasteRevision,revision)
    }
    @MainActor func testRemoteProfileChangeInvalidatesBroadUndo() throws {
        let store=AppStore(ephemeral:true)
        let profile=Profile(name:"A",colorIndex:0,avatar:"scifi-0")
        store.profiles=[profile];store.activeProfileIDs=[profile.id]
        let film=try XCTUnwrap(FilmIndex.film("dune"))
        store.apply(.watchlist,to:film)
        XCTAssertTrue(store.canUndo)
        var remote=store.profiles[0];remote.name="Vom anderen Gerät"
        let snapshot=AppStore.Snapshot(profiles:[remote],activeProfileIDs:[],onboardingDone:true,pendingRatings:[],account:nil,signedIn:nil)
        try store.applyCloudSnapshot(JSONEncoder().encode(snapshot))
        XCTAssertFalse(store.canUndo)
        store.undo()
        XCTAssertEqual(store.profiles.first?.name,"Vom anderen Gerät")
        XCTAssertTrue(store.profiles[0].watchlist.contains(film.id))
    }
    @MainActor func testPartialRatingKeepsOtherParticipantsPending() throws {
        let store=AppStore(ephemeral:true)
        let a=Profile(name:"A",colorIndex:0,avatar:"scifi-0"),b=Profile(name:"B",colorIndex:1,avatar:"scifi-0")
        store.profiles=[a,b];store.activeProfileIDs=[a.id]
        let pending=PendingRating(filmID:"dune",profileIDs:[a.id,b.id],date:.now)
        store.pendingRatings=[pending]
        store.rate(pending,ratings:[a.id:.ratedUp],reviews:[:])
        XCTAssertEqual(store.pendingRatings.first?.profileIDs,[b.id])
        XCTAssertEqual(store.profiles[0].interactions["dune"],.ratedUp)
        XCTAssertNil(store.profiles[1].interactions["dune"])
    }
    @MainActor func testPlaybackPositionsSeparateEpisodesAndIgnoreInvalidValues() {
        let store=AppStore(ephemeral:true)
        let a=Profile(name:"A",colorIndex:0,avatar:"scifi-0")
        store.profiles=[a];store.activeProfileIDs=[a.id]
        let episode=EpisodeRef(season:1,episode:2)
        store.savePlaybackPosition(filmID:"serie-dark",episode:episode,seconds:135)
        store.savePlaybackPosition(filmID:"serie-dark",episode:episode,seconds:Double.nan)
        XCTAssertEqual(store.playbackPosition(filmID:"serie-dark",episode:episode),135)
        XCTAssertNil(store.playbackPosition(filmID:"serie-dark",episode:EpisodeRef(season:1,episode:3)))
    }
    @MainActor func testOnlineSnapshotDoesNotExportPasswordOrSignedIn() throws {
        let store=AppStore(ephemeral:true)
        store.account=Account(email:"test@example.com",passwordHash:"secret-hash",salt:"secret-salt",created:.now,consented:.now)
        store.signedIn=true
        let data=try store.onlineSnapshotData()
        let text=String(decoding:data,as:UTF8.self)
        XCTAssertFalse(text.contains("secret-hash"));XCTAssertFalse(text.contains("secret-salt"))
        let wire=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertNil(wire["signedIn"])
    }
}

final class ChildProtectionRegressionTests: XCTestCase {
    @MainActor func testMixedGroupFiltersWatchlistAndContinueWatchingWithoutDeletingEntries() throws {
        let store = AppStore(ephemeral: true)
        var adult = Profile(name: "Erwachsen", colorIndex: 0)
        let child = Profile(name: "Kind", colorIndex: 1, maxFSK: 6)
        adult.watchlist = ["prisoners", "shrek"]
        adult.progress = ["serie-dark": EpisodeRef(season: 1, episode: 1),
                          "serie-bluey": EpisodeRef(season: 1, episode: 1)]
        store.profiles = [adult, child]
        store.activeProfileIDs = [adult.id]
        XCTAssertEqual(Set(store.watchlist.map(\.id)), ["prisoners", "shrek"])
        XCTAssertEqual(Set(store.continueWatching.map(\.film.id)), ["serie-dark", "serie-bluey"])
        store.activeProfileIDs = [adult.id, child.id]
        XCTAssertEqual(store.watchlist.map(\.id), ["shrek"])
        XCTAssertEqual(store.continueWatching.map(\.film.id), ["serie-bluey"])
        store.activeProfileIDs = [adult.id]
        XCTAssertEqual(Set(store.watchlist.map(\.id)), ["prisoners", "shrek"])
        XCTAssertEqual(Set(store.continueWatching.map(\.film.id)), ["serie-dark", "serie-bluey"])
    }

    @MainActor func testBlockedFilmCannotBePlayedOrAddedToChildProfile() throws {
        let store = AppStore(ephemeral: true)
        let child = Profile(name: "Kind", colorIndex: 1, maxFSK: 6)
        store.profiles = [child]; store.activeProfileIDs = [child.id]
        let blocked = try XCTUnwrap(FilmIndex.film("prisoners"))
        store.play(blocked)
        store.apply(.alreadySeen, to: blocked)
        store.toggleWatchlist(blocked)
        store.importRatings(profile: child.id, ratings: [(blocked, .liked)])
        XCTAssertNil(store.profiles[0].interactions[blocked.id])
        XCTAssertFalse(store.profiles[0].watchlist.contains(blocked.id))
        XCTAssertTrue(store.pendingRatings.isEmpty)
    }

    @MainActor func testOldRatingCannotRevealOrChangeARestrictedTitle() throws {
        let store = AppStore(ephemeral: true)
        let adult = Profile(name: "Erwachsen", colorIndex: 0)
        let child = Profile(name: "Kind", colorIndex: 1, maxFSK: 6)
        let pending = PendingRating(filmID: "prisoners", profileIDs: [adult.id], date: .now)
        store.profiles = [adult, child]; store.activeProfileIDs = [adult.id, child.id]
        store.pendingRatings = [pending]
        XCTAssertTrue(store.visiblePendingRatings.isEmpty)
        store.rate(pending, ratings: [adult.id: .ratedUp], reviews: [:])
        XCTAssertNil(store.profiles[0].interactions["prisoners"])
        XCTAssertEqual(store.pendingRatings.count, 1)
        store.activeProfileIDs = [adult.id]
        XCTAssertEqual(store.visiblePendingRatings.map(\.filmID), ["prisoners"])
    }

    @MainActor func testUndoCannotRevertAChangedChildAgeLimit() throws {
        let store = AppStore(ephemeral: true)
        let adult = Profile(name: "Erwachsen", colorIndex: 0)
        let child = Profile(name: "Kind", colorIndex: 1, maxFSK: 12)
        store.profiles = [adult, child]; store.activeProfileIDs = [adult.id]
        store.apply(.watchlist, to: try XCTUnwrap(FilmIndex.film("shrek")))
        store.editProfile(child.id, name: child.name, avatar: AvatarArt.all[0], maxFSK: 6, littleKid: false)
        store.undo()
        XCTAssertEqual(store.profiles.first(where: { $0.id == child.id })?.maxFSK, 6)
    }

    @MainActor func testUnknownAgeRatingDoesNotPassForChildren() throws {
        let original = try XCTUnwrap(FilmIndex.film("shrek"))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        fields["fsk"] = -1
        let unknown = try JSONDecoder().decode(Film.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(Profile(name: "Kind", colorIndex: 0, maxFSK: 6).allows(unknown))
        XCTAssertTrue(Profile(name: "Erwachsen", colorIndex: 0, maxFSK: 18).allows(unknown))
    }
}

final class CatalogPosterRegressionTests: XCTestCase {

    @MainActor func testBrokenCachedPosterIsRemovedForRetry() async throws {
        let folder = URL.cachesDirectory.appending(path: "Posters", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "broken-cache-test-" + UUID().uuidString
        let file = folder.appending(path: "\(id).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an image".utf8).write(to: file)
        PosterCache.warmUp([id])
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "An invalid cached image must not prevent a later successful download")
    }

    @MainActor func testSimultaneousPosterRequestsShareOneDownload() async {
        let probe = PosterFetchProbe()
        let key = UUID().uuidString
        let first = Task { await PosterCache.coalescedDownload(key) { await probe.fetch() } }
        let second = Task { await PosterCache.coalescedDownload(key) { await probe.fetch() } }
        let values = await [first.value, second.value]
        XCTAssertEqual(values[0], Data([42]))
        XCTAssertEqual(values[1], Data([42]))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "A visible poster and prefetch must share the same network request")
    }

    @MainActor func testLargePosterIsDownsampledForDisplay() async throws {
        let folder = URL.cachesDirectory.appending(path: "Posters", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "large-cache-test-" + UUID().uuidString
        let file = folder.appending(path: "\(id).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 2700), format: format).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1800, height: 2700))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.7)).write(to: file)
        PosterCache.warmUp([id])
        var poster: UIImage?
        for _ in 0..<100 {
            if let loaded = PosterCache.poster(id) { poster = loaded; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cg = try XCTUnwrap(poster?.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 1600,
                                 "Oversized posters should not waste full-resolution memory")
        XCTAssertGreaterThan(cg.width, 900, "The poster should still be sharp on an iPhone")
    }
    @MainActor func testVisiblePosterSurvivesCachePressure() async throws {
        let folder = URL.cachesDirectory.appending(path: "Posters", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.5))
        let ids = (0..<60).map { "cache-test-\(UUID().uuidString)-\($0)" }
        defer { for id in ids { try? FileManager.default.removeItem(at: folder.appending(path: "\(id).jpg")) } }
        for id in ids { try data.write(to: folder.appending(path: "\(id).jpg")) }
        let first = try XCTUnwrap(ids.first)
        PosterCache.warmUp([first])
        PosterCache.retainVisible(first)
        defer { PosterCache.releaseVisible(first) }
        var firstImage: UIImage?
        for _ in 0..<100 {
            if let image = PosterCache.poster(first) { firstImage = image; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let visibleImage = try XCTUnwrap(firstImage)
        for id in ids.dropFirst() { PosterCache.warmUp([id]) }
        // Wait for the remaining covers to enter the cache before checking eviction.
        let last = try XCTUnwrap(ids.last)
        var loadedLast = false
        for _ in 0..<200 {
            if PosterCache.poster(last) != nil { loadedLast = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(loadedLast)
        XCTAssertTrue(PosterCache.poster(first) === visibleImage, "A visible catalog cover must not turn back into a placeholder")
    }
}

final class InteractionPerformanceRegressionTests: XCTestCase {

    @MainActor func testResponsiveImportPreservesEveryRating() async {
        let profile = Profile(name: "Import", colorIndex: 0)
        let bulk = AppStore(ephemeral: true)
        let responsive = AppStore(ephemeral: true)
        bulk.profiles = [profile]
        responsive.profiles = [profile]
        let ratings: [(Film, Interaction)] = FilmIndex.all.prefix(80).enumerated().map {
            ($0.element, $0.offset.isMultiple(of: 2) ? .ratedUp : .ratedDown)
        }
        bulk.importRatings(profile: profile.id, ratings: ratings, unmatched: 3)
        let finished = await responsive.importRatingsResponsively(profile: profile.id, ratings: ratings, unmatched: 3)
        XCTAssertTrue(finished)
        XCTAssertEqual(responsive.profiles.first, bulk.profiles.first)
    }

    @MainActor func testBulkImportMatchesIndividualRatings() throws {
        let original = Profile(name: "Import", colorIndex: 0)
        let individual = AppStore(ephemeral: true)
        individual.profiles = [original]
        let bulk = AppStore(ephemeral: true)
        bulk.profiles = [original]
        let films = Array(FilmIndex.all.filter { !$0.isSeries && !$0.comingSoon }.prefix(320))
        XCTAssertEqual(films.count, 320)
        var ratings: [(Film, Interaction)] = films.enumerated().map {
            ($0.element, $0.offset.isMultiple(of: 3) ? .disliked : .liked)
        }
        ratings.append((films[2], .loved))
        ratings.append((films[3], .unseen))
        for (film, rating) in ratings { individual.calibrate(profile: original.id, film: film, rating) }
        individual.update(original.id) { $0.importedCount += 4 }
        individual.save()
        let start = CFAbsoluteTimeGetCurrent()
        bulk.importRatings(profile: original.id, ratings: ratings, unmatched: 4)
        print("PERF batch-import-320 ms=\((CFAbsoluteTimeGetCurrent() - start) * 1000)")
        XCTAssertEqual(bulk.profiles, individual.profiles)
        XCTAssertEqual(bulk.tasteRevision, 1, "The import should trigger one save/sync, not one per row")
    }

    @MainActor func testImportReadsCSVFromFile() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ratings-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("Name,Year,Rating\nDune,2021,4\n".utf8).write(to: file)
        let read = await LibraryImport.readRows(from: file)
        let rows = try XCTUnwrap(read)
        let result = try XCTUnwrap(LibraryImport.parseRows(rows))
        XCTAssertEqual(result.matched.map { $0.0.id }, ["dune"])
        XCTAssertEqual(result.matched.map { $0.1 }, [.liked])
    }

    @MainActor func testImportedRatingsMatchTitleYearAndIMDbID() throws {
        let csv = "Const,Title,Year,Your Rating\ntt0369610,Wrong title,2015,8\n,die UNGLAUBLICHEN 2,2018,9\n,Unknown,2020,5\n"
        let result = try XCTUnwrap(LibraryImport.parse(Data(csv.utf8)))
        XCTAssertEqual(result.source, "IMDb")
        XCTAssertEqual(result.totalRows, 3)
        XCTAssertEqual(result.matched.map { $0.0.id }, ["jurassic-world", "incredibles-2"])
        XCTAssertEqual(result.matched.map { $0.1 }, [.liked, .loved])
        XCTAssertEqual(result.unmatchedCount, 1)
    }
    @MainActor func testRidgeSolverPreservesSolutionAndFallback() {
        // A * [1,2,3] = [9,7,7]; SPD fixture, independent of the production solver.
        let solved = TasteModel.solveRidge([[4, 1, 1, 9], [1, 3, 0, 7], [1, 0, 2, 7]])
        for (actual, expected) in zip(solved, [1.0, 2.0, 3.0]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-10)
        }
        XCTAssertEqual(TasteModel.solveRidge([]), [])
        // Indefinite input uses pivoting fallback: x=2, y=1.
        XCTAssertEqual(TasteModel.solveRidge([[0, 1, 1], [1, 0, 2]]), [2, 1])
    }

    @MainActor func testRidgeSolverMatchesOriginalForCorrelatedHistory() {
        let n = 60
        let vectors = (0..<n).map { i in (0..<12).map { j in sin(Double(i * 3 + j)) } }
        let system = (0..<n).map { i in
            (0..<n).map { j in
                zip(vectors[i], vectors[j]).reduce(0.0) { $0 + $1.0 * $1.1 } + (i == j ? 3 : 0)
            } + [Double(i % 3) - 1]
        }
        for (actual, expected) in zip(TasteModel.solveRidge(system), TasteModel.solve(system)) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
    }
    // A synchronous cubic refit blocks swipe/undo and sync projection on the main actor.
    @MainActor func testLargeHistoryRefitStaysWithinMainActorBudget() {
        let samples = FilmIndex.all.prefix(200).enumerated().map {
            Profile.Sample(filmID: $0.element.id, target: $0.offset.isMultiple(of: 3) ? -1 : 1)
        }
        _ = TasteModel.fit(samples: Array(samples.prefix(6)), hints: [:])
        var durations: [Double] = []
        for _ in 0..<3 {
            let begin = CFAbsoluteTimeGetCurrent()
            let weights = TasteModel.fit(samples: samples, hints: [:])
            durations.append(CFAbsoluteTimeGetCurrent() - begin)
            XCTAssertFalse(weights.isEmpty)
            XCTAssertTrue(weights.values.allSatisfy(\.isFinite))
        }
        let median = durations.sorted()[1]
        print("PERF refit-200 median-ms=\(median * 1000)")
        XCTAssertLessThan(median, 0.08, "A 200-rating refit must not monopolize the UI actor")
    }

    @MainActor func testDetailCloseInterruptsOpeningInsteadOfWaitingForLanding() async throws {
        let hero = HeroCoordinator()
        let film = try XCTUnwrap(FilmIndex.film("dune"))
        hero.show(film, from: "test")
        hero.detailFrame = CGRect(x: 0, y: 0, width: 100, height: 150)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(hero.open)
        hero.close()
        await Task.yield()
        XCTAssertFalse(hero.open, "Closing must react immediately, even during the opening animation")
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNil(hero.film, "A stale opening task must not reopen the detail")
    }

    @MainActor func testDetailClosedBeforeLayoutCannotReappear() async throws {
        let hero = HeroCoordinator()
        hero.show(try XCTUnwrap(FilmIndex.film("dune")), from: "test")
        hero.close()
        XCTAssertNil(hero.film)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(hero.film)
        XCTAssertFalse(hero.open)
    }

    @MainActor func testGhostReturnKeepsQueuedNextDetail() async throws {
        let hero = HeroCoordinator()
        let first = try XCTUnwrap(FilmIndex.film("dune"))
        let second = try XCTUnwrap(FilmIndex.all.first { $0.id != first.id })
        hero.sources[HeroCoordinator.key(first.id, "test")] = .init(
            frame: CGRect(x: 10, y: 20, width: 100, height: 150), radius: 12)
        hero.show(first, from: "test")
        hero.detailFrame = CGRect(x: 0, y: 0, width: 200, height: 300)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNotNil(hero.ghost)
        hero.close()
        XCTAssertFalse(hero.open)
        hero.show(second, from: "next")
        // Der Rückflug dauert 560 ms, erst danach öffnet der vorgemerkte Film.
        try await Task.sleep(for: .milliseconds(640))
        XCTAssertEqual(hero.film?.id, second.id)
        hero.detailFrame = CGRect(x: 0, y: 0, width: 200, height: 300)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(hero.open)
        hero.close()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(hero.film)
    }

    @MainActor func testSwipeUndoRestoresLargeHistoryExactly() throws {
        let store = AppStore(ephemeral: true)
        var profile = Profile(name: "Performance", colorIndex: 0)
        profile.samples = FilmIndex.all.prefix(200).map { .init(filmID: $0.id, target: 1) }
        profile.refit()
        store.profiles = [profile]; store.activeProfileIDs = [profile.id]
        let film = try XCTUnwrap(FilmIndex.film("dune"))
        let begin = CFAbsoluteTimeGetCurrent()
        store.apply(.watchlist, to: film)
        store.undo()
        let elapsed = CFAbsoluteTimeGetCurrent() - begin
        print("PERF swipe-plus-undo-200 ms=\(elapsed * 1000)")
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertTrue(store.pendingRatings.isEmpty)
        XCTAssertFalse(store.canUndo)
        XCTAssertLessThan(elapsed, 0.12)
    }

    @MainActor func testReasonsNameSomethingConcrete() throws {
        var p = Profile(name: "A", colorIndex: 0)
        for (id, i) in [("dune", Interaction.loved), ("interstellar", .loved), ("inception", .liked), ("get-out", .liked)] {
            let f = try XCTUnwrap(FilmIndex.film(id)); p.learn(f, i); p.interactions[id] = i
        }
        let arrival = try XCTUnwrap(FilmIndex.film("arrival"))
        XCTAssertTrue(RecommendationEngine.reason(for: arrival, profiles: [p]).hasPrefix("Gleiche Regie wie „Dune“"))
        for rec in RecommendationEngine.recommendations(profiles: [p], runtime: nil, skipped: [], limit: 20) {
            XCTAssertFalse(rec.reason.hasPrefix("Weil du"), rec.reason)
            XCTAssertFalse(rec.reason.isEmpty)
            // Gleiche Eingabe, gleicher Grund: sonst springt der Text auf der Karte.
            XCTAssertEqual(rec.reason, RecommendationEngine.reason(for: rec.film, profiles: [p]))
        }
    }
    @MainActor func testWatchlistComesBackAndCanBeLetGo() throws {
        let store = AppStore(ephemeral: true)
        var p = Profile(name: "A", colorIndex: 0)
        p.watchlist = ["prisoners"]; p.interactions["prisoners"] = .watchlist
        store.profiles = [p]; store.activeProfileIDs = [p.id]
        let film = try XCTUnwrap(FilmIndex.film("prisoners"))
        let deck = store.recommendations(limit: 4)
        XCTAssertEqual(deck[1].id, "prisoners")
        XCTAssertEqual(deck[1].watchlistNote, "Auf deiner Liste")
        for _ in 0..<3 { store.skippedToday = []; store.apply(.notToday, to: film) }
        XCTAssertEqual(store.watchlistQuestion, "prisoners")
        // Überspringen von der Liste verlernt nichts.
        XCTAssertNil(store.profiles[0].affinity["m:düster"])
        store.letGo(film)
        XCTAssertTrue(store.profiles[0].watchlist.isEmpty)
        XCTAssertNil(store.watchlistQuestion)
        XCTAssertFalse(store.recommendations(limit: 10).contains { $0.id == "prisoners" })
        XCTAssertEqual(AppStore.sinceText(.now.addingTimeInterval(-38 * 86_400)), "seit 5 Wochen")
    }
    @MainActor func testServerWithoutOnboardingFlagKeepsFinishedDevice() throws {
        let store = AppStore(ephemeral: true)
        let p = Profile(name: "A", colorIndex: 0)
        store.profiles = [p]; store.activeProfileIDs = [p.id]; store.onboardingDone = true
        // So antwortet der Server nach einer Chat-Antwort für ein Profil ohne `onboardingComplete`.
        let data = try JSONEncoder().encode(AppStore.Snapshot(profiles: [p], activeProfileIDs: [], onboardingDone: false,
                                                              pendingRatings: [], account: nil, signedIn: nil))
        try store.applyCloudSnapshot(data)
        XCTAssertTrue(store.onboardingDone)
        let empty = try JSONEncoder().encode(AppStore.Snapshot(profiles: [], activeProfileIDs: [], onboardingDone: false,
                                                               pendingRatings: [], account: nil, signedIn: nil))
        try store.applyCloudSnapshot(empty)
        XCTAssertFalse(store.onboardingDone)
    }

    @MainActor func testFilmCountsAsWatchedOnlyFromNinetyPercent() throws {
        let store = AppStore(ephemeral: true)
        let p = Profile(name: "A", colorIndex: 0, avatar: "scifi-0")
        store.profiles = [p]; store.activeProfileIDs = [p.id]
        let film = try XCTUnwrap(FilmIndex.all.first { !$0.isSeries })
        XCTAssertFalse(store.stoppedPlaying(film, episode: nil, seconds: 40, duration: 100))
        XCTAssertEqual(store.resumeShare(film) ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(store.playLabel(film), "Weiterschauen")
        XCTAssertTrue(store.pendingRatings.isEmpty)
        XCTAssertNil(store.undoPlayedFilm)

        XCTAssertTrue(store.stoppedPlaying(film, episode: nil, seconds: 92, duration: 100))
        XCTAssertNil(store.resumeShare(film))
        XCTAssertEqual(store.pendingRatings.last?.filmID, film.id)
        XCTAssertEqual(store.undoPlayedFilm, film.id)

        // Zurücknehmen holt den Film zurück und nimmt die offene Bewertung mit.
        store.undo()
        XCTAssertTrue(store.pendingRatings.isEmpty)
        XCTAssertNil(store.activeProfiles.first?.interactions[film.id])
    }


    @MainActor func testCatalogTitlesWithoutMovieLensDataRemainEligibleForCalibration() throws {
        let ids = ["the-lord-of-the-rings-the-two-towers", "harry-potter-and-the-prisoner-of-azkaban",
                   "star-wars-return-of-the-jedi", "jurassic-world", "incredibles-2"]
        for id in ids {
            let film = try XCTUnwrap(FilmIndex.film(id), "Missing catalog film: \(id)")
            XCTAssertFalse(film.synopsis.isEmpty)
            XCTAssertFalse(film.hook.isEmpty)
            XCTAssertFalse(film.voices?.isEmpty ?? true)
            XCTAssertFalse(film.trailers.isEmpty)
            XCTAssertNotNil(film.poster)
            XCTAssertNil(film.mlFactors, "Untrained factors must not be presented as real data")
            XCTAssertGreaterThan(FilmIndex.familiarity[id] ?? 0, 0, "Missing popularity data must not exclude a film")
        }
    }



}

private actor PosterFetchProbe {
    private(set) var calls = 0
    func fetch() async -> Data? {
        calls += 1
        try? await Task.sleep(for: .milliseconds(50))
        return Data([42])
    }
}
