@preconcurrency import AVKit
import SwiftUI

struct TVPlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest
    @State private var player: AVPlayer?
    @State private var failed: String?
    @State private var loaded = false
    @State private var completion = TVPlaybackCompletion()
    @State private var recordedRating: PendingRating?
    @State private var companion: TVCompanionRequest?
    @State private var loadGeneration = 0
    @State private var closed = false
    @State private var lastPositionSave = Date.distantPast

    private var allowed: Bool {
        store.signedIn && TVPlaybackPolicy.canStart(
            subscriptionActive: !request.countsAsWatched || store.canPlay,
            viewersAllow: store.activeProfiles.map { $0.allows(request.film) },
            comingSoon: request.countsAsWatched && request.film.comingSoon)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player, failed == nil, allowed {
                    VideoPlayer(player: player)
                }
                if !loaded && failed == nil {
                    VStack(spacing: 25) {
                        ProgressView().controlSize(.large)
                        Text(allowed ? request.trailer?.title ?? request.film.title : "Wiedergabe beendet").font(.title2)
                        Text("Trailer wird geladen …").foregroundStyle(.secondary)
                    }
                }
                if let failed {
                    VStack(spacing: 26) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 70))
                        Text("Wiedergabe nicht verfügbar").font(.title)
                        Text(failed).font(.title3).foregroundStyle(.secondary).frame(maxWidth: 900)
                        HStack(spacing: 28) {
                            Button("Erneut laden") { loadGeneration += 1 }
                            Button("Auf iPhone ansehen") { companion = TVCompanionRequest(kind: "externalLink", title: "Trailer auf iPhone öffnen", filmID: request.film.id, payload: "https://www.youtube.com/watch?v=\(request.videoID)") }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(allowed ? request.film.title + (request.episode.map { " · \($0.short)" } ?? "") : "Wiedergabe beendet").font(.headline).lineLimit(1)
                    Text("Trailer-Vorschau · vollständige Filme sind noch nicht enthalten").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if request.countsAsWatched {
                    Button("Als angesehen abschließen") { finish(explicit: true) }.disabled(!loaded || failed != nil || !allowed)
                }
                Button("Schließen") { close() }
            }.padding(.horizontal, 50).padding(.vertical, 22).background(TVTheme.background)
        }
        .ignoresSafeArea()
        .task(id: loadGeneration) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard (notification.object as? AVPlayerItem) === player?.currentItem else { return }
            finish(explicit: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification)) { notification in
            guard (notification.object as? AVPlayerItem) === player?.currentItem else { return }
            savePosition(); player?.pause(); loaded = false; failed = "Der Stream wurde unterbrochen. Versuche es erneut oder öffne ihn auf deinem iPhone."
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !allowed { close() }
            else if Date.now.timeIntervalSince(lastPositionSave) >= 10 { savePosition(); lastPositionSave = .now }
        }
        .onChange(of: allowed) { _, permitted in if !permitted { close() } }
        .onChange(of: store.activeProfileIDs) { _, _ in close() }
        .onChange(of: store.signedIn) { _, signedIn in if !signedIn { close() } }
        .onExitCommand { close() }
        .onDisappear { savePosition(); closed = true; player?.pause() }
        .sheet(item: $companion) { TVCompanionView(store: store, request: $0) }
    }

    private func load() async {
        guard allowed else { failed = "Abo oder Altersfreigabe erlaubt diese Wiedergabe nicht."; return }
        player?.pause(); failed = nil; loaded = false
        do {
            let item = try await TrailerLoader.playerItem(for: request)
            guard !Task.isCancelled, !closed, allowed else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let next = AVPlayer(playerItem: item)
            player = next
            next.play()
            for _ in 0..<120 {
                guard !Task.isCancelled, !closed else { next.pause(); return }
                if item.status == .readyToPlay {
                    loaded = true
                    if request.countsAsWatched, let seconds = store.playbackPosition(filmID: request.film.id, episode: request.episode), seconds > 0 {
                        let duration = item.duration.seconds
                        if !duration.isFinite || seconds < duration - 2 {
                            await next.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                        }
                    }
                    return
                }
                if item.status == .failed { throw item.error ?? URLError(.cannotLoadFromNetwork) }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw URLError(.timedOut)
        } catch {
            guard !Task.isCancelled, !closed else { return }
            player?.pause()
            failed = "Der Trailer konnte gerade nicht geladen werden. Versuche es erneut oder nutze dein iPhone."
        }
    }

    private func finish(explicit: Bool) {
        guard !closed else { return }
        if request.countsAsWatched, allowed,
           completion.shouldRecord(sourceLoaded: loaded && failed == nil, ended: !explicit, explicitlyCompleted: explicit) {
            let prior = Set(store.pendingRatings.map(\.id))
            store.savePlaybackPosition(filmID: request.film.id, episode: request.episode, seconds: 0)
            store.play(request.film, episode: request.episode)
            recordedRating = store.pendingRatings.first { !prior.contains($0.id) && $0.filmID == request.film.id }
        }
        close()
    }

    private func savePosition() {
        guard !closed, loaded, request.countsAsWatched, allowed, let player else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite && seconds >= 0 {
            store.savePlaybackPosition(filmID: request.film.id, episode: request.episode, seconds: seconds)
        }
    }

    private func close() {
        guard !closed else { return }
        if !completion.recorded { savePosition() }
        closed = true; player?.pause(); dismiss()
        if let recordedRating {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                if store.signedIn { store.ratingToPresent = recordedRating }
            }
        }
    }
}

struct TVRatingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pending: PendingRating
    @State private var ratings: [UUID: Interaction] = [:]
    @State private var reviews: [UUID: String] = [:]
    @State private var companion: TVCompanionRequest?
    @State private var handedOffProfileID: UUID?
    @State private var priorReview: Review?
    private var film: Film? {
        guard let film = FilmIndex.film(pending.filmID), TVContentPolicy.isVisible(viewersAllow: store.activeProfiles.map { $0.allows(film) }) else { return nil }
        return film
    }
    private var profiles: [Profile] {
        guard let film else { return [] }
        let ids = TVRatingPolicy.participants(pending: pending.profileIDs, active: store.activeProfiles.map(\.id), viewersAllow: store.activeProfiles.map { $0.allows(film) })
        return store.activeProfiles.filter { ids.contains($0.id) }
    }
    static let choices: [Interaction] = [.ratedDown, .ratedOkay, .ratedUp, .ratedLove]
    static func label(_ interaction: Interaction) -> String {
        switch interaction {
        case .ratedDown, .disliked: "Nicht meins"
        case .ratedOkay: "War okay"
        case .ratedUp, .liked: "Mag ich"
        case .ratedLove, .loved: "Liebe ich"
        default: "Gesehen"
        }
    }

    var body: some View {
        TVScreen(title: "Wie war \(film?.title ?? "der Film")?", subtitle: "Jeder bewertet für sich. Ein Text ist optional.") {
            if film == nil { TVEmptyState(title: "Bewertung derzeit nicht verfügbar", message: "Der Titel ist für die aktuellen Zuschauer nicht freigegeben. Wähle passende Zuschauer, um ihn zu bewerten.", symbol: "lock") }
            ForEach(profiles) { profile in
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 22) { TVAvatarView(profile: profile, size: 65); Text(profile.name).font(.title2) }
                    HStack(spacing: 28) {
                        ForEach(Self.choices, id: \.rawValue) { rating in
                            Button {
                                ratings[profile.id] = rating
                            } label: {
                                Label(Self.label(rating), systemImage: ratings[profile.id] == rating ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                    TextField("Optional: dein Eindruck", text: Binding(get: { reviews[profile.id] ?? "" }, set: { reviews[profile.id] = $0 }))
                        .frame(maxWidth: 1200)
                    Button("Review bequem auf iPhone schreiben") {
                        handedOffProfileID = profile.id
                        priorReview = profile.reviews.first { $0.filmID == pending.filmID }
                        companion = TVCompanionRequest(kind: "review", title: "Review für \(profile.name)", profileID: profile.id, filmID: pending.filmID)
                    }
                }.padding(.vertical, 20)
            }
            HStack(spacing: 30) {
                Button("Bewertungen speichern") {
                    let permitted = Set(profiles.map(\.id))
                    guard !permitted.isEmpty, film != nil else { return }
                    store.rate(pending, ratings: ratings.filter { permitted.contains($0.key) }, reviews: reviews.filter { permitted.contains($0.key) }); dismiss()
                }.disabled(profiles.isEmpty || !profiles.allSatisfy { ratings[$0.id] != nil })
                Button("Später bewerten") { dismiss() }
                Button("Nicht mehr fragen") { store.dismissRating(pending); dismiss() }.disabled(profiles.isEmpty)
            }
        }
        .onAppear {
            for profile in profiles {
                if let review = profile.reviews.first(where: { $0.filmID == pending.filmID }) {
                    ratings[profile.id] = review.rating; reviews[profile.id] = review.text
                }
            }
        }
        .sheet(item: $companion, onDismiss: receiveReview) { TVCompanionView(store: store, request: $0) }
    }
    private func receiveReview() {
        guard let id = handedOffProfileID,
              let profile = profiles.first(where: { $0.id == id }),
              let review = profile.reviews.first(where: { $0.filmID == pending.filmID }),
              review != priorReview else { return }
        ratings[id] = review.rating; reviews[id] = review.text
        handedOffProfileID = nil; priorReview = nil
    }

}
