@preconcurrency import AVKit
@preconcurrency import YouTubeKit
import Foundation

struct PlaybackRequest: Identifiable, Hashable {
    let id = UUID()
    let film: Film
    var trailer: Trailer? = nil
    /// Serien: welche Folge (stellvertretend läuft der Trailer).
    var episode: EpisodeRef? = nil
    /// „Abspielen“ zählt als gesehen (danach Bewertung), „Trailer“ nicht.
    var countsAsWatched: Bool
    var sourceID: String

    var videoID: String { trailer?.id ?? film.youtubeID }
}

enum TrailerLoader {
    /// Wo ein Video liegt. Das Auflösen (YouTube-Abfrage, Signatur, Spuren laden) dauert ein bis
    /// zwei Sekunden, darum wird es für die oberste Karte schon vorab erledigt und kurz gemerkt.
    private enum Source {
        case hls(URL)
        case composed(AVComposition)
        case url(URL)
    }

    private struct Entry {
        let task: Task<PlaybackUnchecked<Source>, any Error>
        let created: Date
    }

    /// Stream-Adressen von YouTube laufen nach einigen Stunden ab, gemerkt wird deutlich kürzer.
    private static let lifetime: TimeInterval = 20 * 60
    private static var resolved: [String: Entry] = [:]

    /// Schon auflösen, bevor jemand auf „Abspielen“ tippt. Danach startet der Player fast sofort.
    static func prefetch(_ videoID: String) {
        guard !videoID.isEmpty else { return }
        _ = source(for: videoID)
    }

    static func playerItem(for request: PlaybackRequest) async throws -> AVPlayerItem {
        let source: Source
        do {
            source = try await Self.source(for: request.videoID).task.value.value
        } catch {
            // Fehlschläge nicht merken: Beim nächsten Versuch wird neu aufgelöst.
            resolved[request.videoID] = nil
            throw error
        }
        switch source {
        case .hls(let url):
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 8
            return decorate(item, request)
        case .composed(let composition):
            return decorate(AVPlayerItem(asset: composition), request)
        case .url(let url):
            return decorate(AVPlayerItem(url: url), request)
        }
    }

    private static func source(for videoID: String) -> Entry {
        if let entry = resolved[videoID], -entry.created.timeIntervalSinceNow < lifetime { return entry }
        if resolved.count > 12 { resolved = resolved.filter { -$0.value.created.timeIntervalSinceNow < lifetime } }
        let entry = Entry(task: Task(priority: .userInitiated) { PlaybackUnchecked(value: try await resolve(videoID)) }, created: .now)
        resolved[videoID] = entry
        return entry
    }

    private static func resolve(_ videoID: String) async throws -> Source {
        let youtube = YouTube(videoID: videoID, methods: [.local, .remote])

        // 1. HLS: das Format, für das AVPlayer gebaut ist, adaptive Qualität, sauberes Puffern.
        if let hls = try? await youtube.livestreams.first(where: { $0.streamType == .hls }) {
            return .hls(hls.url)
        }

        let streams = try await youtube.streams.filter { $0.isNativelyPlayable }

        // 2. Getrennte Video- (bis 1080p) und Tonspur, zusammengesetzt.
        if let video = streams.filterVideoOnly().filter({ $0.fileExtension == .mp4 })
                .filter(byResolution: { ($0 ?? 0) <= 1080 }).highestResolutionStream(),
           let audio = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a }).highestAudioBitrateStream(),
           let composed = try? await playbackWithTimeout(seconds: 8, { PlaybackUnchecked(value: try await compose(video: video.url, audio: audio.url)) }) {
            return .composed(composed.value)
        }

        // 3. Fallback: kombinierter Stream.
        guard let combined = streams.filterVideoAndAudio().highestResolutionStream() else {
            throw URLError(.resourceUnavailable)
        }
        return .url(combined.url)
    }

    private static func compose(video: URL, audio: URL) async throws -> AVComposition {
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        async let vTracks = videoAsset.loadTracks(withMediaType: .video)
        async let aTracks = audioAsset.loadTracks(withMediaType: .audio)
        async let vDuration = videoAsset.load(.duration)
        async let aDuration = audioAsset.load(.duration)
        guard let vTrack = try await vTracks.first, let aTrack = try await aTracks.first else {
            throw URLError(.cannotParseResponse)
        }
        let duration = try await min(vDuration, aDuration)
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: vTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: aTrack, at: .zero)
        return composition
    }

    /// Titel, Beschreibung und Poster für die Info-Leiste des Systemplayers.
    private static func decorate(_ item: AVPlayerItem, _ request: PlaybackRequest) -> AVPlayerItem {
        let film = request.film
        func meta(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            return m
        }
        let subtitle = (request.trailer.map { "\($0.title) · " } ?? "") + film.metaLine
        var items = [meta(.commonIdentifierTitle, film.title as NSString),
                     meta(.commonIdentifierDescription, film.synopsis as NSString),
                     meta(.iTunesMetadataTrackSubTitle, subtitle as NSString)]
        if let data = film.posterImage?.jpegData(compressionQuality: 0.8) {
            items.append(meta(.commonIdentifierArtwork, data as NSData))
        }
        item.externalMetadata = items
        return item
    }
}

/// Verpackt nicht-Sendable AVFoundation-Objekte für den Timeout-Wettlauf.
nonisolated struct PlaybackUnchecked<T>: @unchecked Sendable { let value: T }

nonisolated func playbackWithTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
