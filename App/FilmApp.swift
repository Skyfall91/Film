import SwiftUI

@main
struct FilmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LaunchExperience { RootView() }
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(store.accent)
                .task(priority: .utility) { await PosterCache.prefetchAll(FilmIndex.all.map(\.id)) }
                .task { try? await store.installCloudSync() }
                .onChange(of: store.signedIn) { _, ready in if ready { Task { try? await store.installCloudSync() } } }
                .onChange(of: scenePhase) { _, phase in if phase == .active { store.deviceSync?.wake() } else { store.flush() } }
        }
    }
}

/// Die App ist im Hochformat gebaut, nur der Player darf ins Querformat drehen.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var allowLandscape = false

    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Den Filmkatalog schon lesen, während das Fenster entsteht, statt danach auf dem Hauptthread.
        Task.detached(priority: .userInitiated) { _ = FilmIndex.all }
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return Self.allowLandscape ? .allButUpsideDown : .portrait
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if DemoScreen.current == "calibrate" || DemoScreen.current == "reveal", let id = store.profiles.first?.id {
                OnboardingFlow(start: DemoScreen.current == "calibrate" ? .calibrate : .reveal, profileID: id) { _ in }
            } else if DemoScreen.current == "editor" {
                OnboardingFlow(mode: .addProfile) { _ in }
            } else if DemoScreen.current == "plan" {
                PlanPicker(mode: .onboarding) { _ in }
            } else if DemoScreen.current == "register" || DemoScreen.current == "login" {
                AuthFlow(start: DemoScreen.current == "register" ? .register : .login)
            } else if store.account == nil || !store.signedIn {
                AuthFlow()
                    .transition(.opacity)
            } else if !store.onboardingDone {
                OnboardingFlow { id in
                    withAnimation(.smooth) { store.finishOnboarding(profile: id) }
                }
                .transition(.opacity)
            } else if store.subscription == nil {
                // Älterer Stand ohne Abo (oder Konto gelöscht und neu angelegt): erst Tarif wählen.
                PlanPicker(mode: .onboarding) { _ in }
                    .transition(.opacity)
            } else if !store.hasChosenViewers {
                WhoIsWatchingView()
                    .transition(.opacity)
            } else {
                MainTabs()
                    .transition(.opacity)
            }
        }
        .modifier(NearbyTVPairingPrompt())
        .animation(.smooth, value: store.onboardingDone)
        .animation(.smooth, value: store.hasChosenViewers)
        .animation(.smooth, value: store.signedIn)
        .animation(.smooth, value: store.subscription)
        .task {
            await store.syncSubscription()
            store.purchases.listen { sub in
                if let sub, store.subscription?.source != .demo { store.subscribe(sub) }
            }
        }
    }
}

struct MainTabs: View {
    @Environment(AppStore.self) private var store
    @State private var hero = HeroCoordinator()
    var body: some View {
        TabView(selection: Bindable(store).selectedTab) {
            Tab(FilmSection.forYou.title, systemImage: FilmSection.forYou.symbol, value: 0) { ForYouView() }
            Tab(FilmSection.watchlist.title, systemImage: FilmSection.watchlist.symbol, value: 1) { WatchlistView() }
            Tab(FilmSection.catalog.title, systemImage: FilmSection.catalog.symbol, value: 2) { CatalogView() }
            Tab(FilmSection.profile.title, systemImage: FilmSection.profile.symbol, value: 3) { ProfileTabView() }
            Tab(FilmSection.search.title, systemImage: FilmSection.search.symbol, value: 4, role: .search) { MoodSearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Solange Details offen sind, darf kein Tipper zu Knöpfen darunter durchrutschen
        // (z. B. Filtermenü genau unter dem Schließen-Knopf).
        .allowsHitTesting(hero.film == nil)
        .accessibilityHidden(hero.film != nil)
        .overlay { HeroOverlay() }
        .environment(hero)
        .sheet(item: Bindable(store).ratingToPresent) { RatingSheet(pending: $0) }
    }
}

/// Startparameter `-screen <name>` öffnet direkt einen Screen, für Screenshots.

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
