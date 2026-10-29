@preconcurrency import AVKit
import MediaPlayer
import SwiftUI
@preconcurrency import YouTubeKit

/// Was abgespielt werden soll. `sourceID` ist die View, aus der der Player herausmorpht.
extension View {
    /// Vollbild-Player, der per Zoom-Übergang aus `sourceID` heraus aufgeht
    /// und sich nach unten wegwischen lässt.
    func filmPlayer(_ request: Binding<PlaybackRequest?>, in namespace: Namespace.ID) -> some View {
        fullScreenCover(item: request) { req in
            PlayerGate(request: req)
                .navigationTransition(.zoom(sourceID: req.sourceID, in: namespace))
        }
    }
}

/// Abspielen braucht ein aktives Abo, Trailer nicht. Ohne Abo erscheint statt des Players die Tarifwahl.
private struct PlayerGate: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: PlaybackRequest

    var body: some View {
        if !store.signedIn || !store.allowsForViewers(request.film) {
            ContentUnavailableView {
                Label("Titel nicht freigegeben", systemImage: "lock")
            } description: {
                Text("Dieser Titel ist für die aktuellen Profile nicht freigegeben.")
            } actions: {
                Button("Schließen") { dismiss() }
            }
        } else if request.countsAsWatched && !store.canPlay {
            NavigationFrame { PlanPicker(mode: .unlock) { _ in dismiss() } }
        } else {
            PlayerScreen(request: request)
        }
    }
}

// MARK: - Player-Screen

/// Der Trailer steht für den Film. Der YouTube-Trailer wird in eine direkte
/// Stream-URL aufgelöst und im nativen iOS-Player (AVPlayerViewController) gezeigt.
struct PlayerScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let request: PlaybackRequest

    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var showVideo = false
    @State private var closed = false
    @State private var viewersAtStart: [UUID] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Platzhalter: das Poster füllt den Screen, solange der Stream lädt, // so wirkt der Zoom aus der Karte nahtlos.
            if !showVideo {
                ZStack {
                    if let image = request.film.posterImage {
                        Color.clear.overlay {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                        .clipped()
                        .overlay(Color.black.opacity(0.45))
                    }
                    VStack(spacing: 14) {
                        if failed {
                            Text("Der Film konnte gerade nicht geladen werden.").font(.headline)
                            Button {
                                openURL(URL(string: "https://www.youtube.com/watch?v=\(request.videoID)")!)
                            } label: { Label("Auf YouTube ansehen", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.glassProminent)
                        } else {
                            ProgressView().controlSize(.large).tint(.white)
                            Text(loadingTitle).font(.headline).multilineTextAlignment(.center)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding()
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            if let player {
                SystemPlayer(player: player)
                    .ignoresSafeArea()
                    .opacity(showVideo ? 1 : 0)
                // Unterdrückt das System-Lautstärke-Popup, der Player zeigt seine eigene Anzeige.
                SystemVolumeHUDSuppressor()
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            // Embedded AVPlayer controls can hide automatically; the app's exit must not.
            Button { close() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("Schließen")
            .accessibilityIdentifier("player.close")
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { viewersAtStart = store.activeProfileIDs }
        .task { await load() }
        .onChange(of: store.activeProfileIDs) { _, _ in close() }
        // Film zu Ende → Player schließen, zurück ins Hochformat.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            if (note.object as? AVPlayerItem) === player?.currentItem { close() }
        }
        .onDisappear {
            closed = true
            player?.pause()
            AppDelegate.allowLandscape = false
            PlayerOrientation.rotate(to: .portrait)
            if request.countsAsWatched, store.signedIn, store.activeProfileIDs == viewersAtStart,
               store.allowsForViewers(request.film), let player {
                let before = store.pendingRatings.count
                // Erst ab 90 % zählt es als gesehen, sonst merkt sich die App die Stelle fürs Weiterschauen.
                let watched = store.stoppedPlaying(request.film, episode: request.episode,
                                                   seconds: player.currentTime().seconds,
                                                   duration: player.currentItem?.duration.seconds ?? .nan)
                guard watched else { return }
                // Erst drehen, dann bewerten, ein Sheet mitten in der Drehung hält sonst das Querformat fest.
                // Serien werden nur nach der ersten Folge bewertet.
                let pending = store.pendingRatings.count > before || !request.film.isSeries ? store.pendingRatings.last : nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    PlayerOrientation.rotate(to: .portrait)
                    store.ratingToPresent = pending
                }
            }
        }
    }

    private var loadingTitle: String {
        if let trailer = request.trailer { return trailer.title }
        if let ref = request.episode, let ep = request.film.episode(ref) {
            return "\(request.film.title)\n\(ref.short) · \(ep.title)"
        }
        return request.film.title
    }

    /// Schließen: zuerst ins Hochformat zurück, dann der Zoom zurück in die Karte.
    private func close() {
        guard !closed else { return }
        closed = true
        player?.pause()
        AppDelegate.allowLandscape = false
        PlayerOrientation.rotate(to: .portrait)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            dismiss()
        }
    }

    private func load() async {
        guard store.signedIn, store.allowsForViewers(request.film) else { return }
        do {
            let item = try await TrailerLoader.playerItem(for: request)
            guard !closed, !Task.isCancelled, store.signedIn, store.allowsForViewers(request.film),
                  store.activeProfileIDs == viewersAtStart else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            // Angefangen: dort weiter, wo zuletzt geschlossen wurde.
            if request.countsAsWatched, let at = store.resumeSeconds(request.film, episode: request.episode) {
                await player.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            }
            self.player = player
            player.play()
            withAnimation(.smooth(duration: 0.5)) { showVideo = true }
            // Wie bei Netflix: nach dem Aufzoomen ins Querformat drehen, // aber nicht mehr, wenn der Player in der Zwischenzeit geschlossen wurde.
            try? await Task.sleep(for: .milliseconds(250))
            guard !closed, !Task.isCancelled else { return }
            AppDelegate.allowLandscape = true
            PlayerOrientation.rotate(to: .landscapeRight)
        } catch {
            withAnimation { failed = true }
        }
    }
}

/// Der native iOS-Player, eingebettet in SwiftUI. Schließen per Wischen nach unten
/// (Zoom-Übergang) oder über die Systemsteuerung.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

/// Solange ein MPVolumeView sichtbar im Fenster liegt, blendet iOS sein eigenes
/// Lautstärke-Popup aus. So erscheint nur die Anzeige des Players.
struct SystemVolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.showsVolumeSlider = true
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

enum PlayerOrientation {
    static func rotate(to mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var vc = scene.keyWindow?.rootViewController
        while let current = vc {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

// MARK: - Stream auflösen
