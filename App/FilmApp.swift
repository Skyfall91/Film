import SwiftUI

@main
struct FilmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Der Film-Guide braucht weder Konto noch Abo: Er startet direkt in den Katalog.
    @State private var guide = GuideStore()

    var body: some Scene {
        WindowGroup {
            LaunchExperience { GuideRoot() }
                .environment(guide)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task(priority: .utility) { await PosterCache.prefetchAll(FilmIndex.all.map(\.id)) }
        }
    }
}

/// Die App ist im Hochformat gebaut, nur der Player darf ins Querformat drehen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowLandscape = false

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Den Filmkatalog schon lesen, während das Fenster entsteht, statt danach auf dem Hauptthread.
        Task.detached(priority: .userInitiated) { _ = FilmIndex.all }
        // Antworten von TMDB/iTunes und Anbieter-Logos zwischenspeichern (der Standard hält nur wenige MB).
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024)
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return Self.allowLandscape ? .allButUpsideDown : .portrait
    }
}

/// A short SwiftUI introduction after the system's static launch screen.
/// The real root mounts immediately so its setup runs during the transition.
private struct LaunchExperience<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing = true
    @State private var revealed = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .accessibilityHidden(showing && !reduceMotion)
            if showing && !reduceMotion {
                ZStack {
                    Theme.background.ignoresSafeArea()
                    // Xcode renders this image directly from AppIcon.icon.
                    Image(uiImage: UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon76x76") ?? UIImage())
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .scaleEffect(revealed ? 1 : 0.88)
                        .opacity(revealed ? 1 : 0)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .task {
            guard showing else { return }
            guard !reduceMotion else { showing = false; return }
            withAnimation(.smooth(duration: 0.18)) { revealed = true }
            do {
                // Kurz halten: Die App steht darunter schon bereit, länger wäre nur Warten.
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                // Never leave an interrupted introduction covering the app.
                showing = false
                return
            }
            withAnimation(.easeOut(duration: 0.18)) { showing = false }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { showing = false }
        }
    }
}
