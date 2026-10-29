import SwiftUI

@main
struct FilmTVApp: App {
    @State private var store: AppStore
    init() {
        let initial = AppStore()
        if !ProcessInfo.processInfo.arguments.contains("-seedDemo") { initial.signedIn = false }
        _store = State(initialValue: initial)
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TVRootView(store: store)
                .environment(store)
                .preferredColorScheme(.dark)
                .task(priority: .utility) { await PosterCache.prefetchAll(FilmIndex.all.map(\.id)) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.deviceSync?.wake() } else { store.flush() }
                }
        }
    }
}

struct TVRootView: View {
    @Bindable var store: AppStore
    @State private var connection: TVConnectionModel
    @Environment(\.scenePhase) private var phase

    init(store: AppStore) {
        self.store = store
        _connection = State(initialValue: TVConnectionModel(store: store))
    }

    var body: some View {
        ZStack {
            TVTheme.background.ignoresSafeArea()
            if !store.signedIn {
                TVLoginView(connection: connection)
            } else if store.profiles.isEmpty {
                TVProfileEditor(isFirst: true) { _ in }
            } else if !store.onboardingDone, let profile = store.profiles.first {
                TVCalibrationView(profileID: profile.id) { store.finishOnboarding(profile: profile.id) }
            } else if !store.hasChosenViewers || store.activeProfiles.isEmpty {
                TVViewerPicker(required: true)
            } else {
                TVHomeView()
            }
        }
        .onChange(of: phase) { _, phase in connection.advertiseNearby(phase == .active) }
        .buttonStyle(.glass)
        .tint(.white)
        .task {
            if !ProcessInfo.processInfo.arguments.contains("-seedDemo") { await connection.restore() }
        }
    }
}

struct TVLoginView: View {
    @Bindable var connection: TVConnectionModel
    @State private var alternative = false

    var body: some View {
        HStack(spacing: 100) {
            VStack(alignment: .leading, spacing: 30) {
                Text("Ein Film.\nGenau deiner.").font(Theme.recommendationTitle(size: 64))
                Text("Öffne Film auf deinem iPhone und wähle „Fernseher“. Richte die Kamera auf die sechs Ziffern oder gib sie ein. Bestätige danach diesen Apple TV.")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: 630)
                Text("Mit „Alternativ anmelden“ kannst du stattdessen einen QR-Code scannen.")
                    .font(.system(size: 21)).foregroundStyle(.white.opacity(0.65))
            }
            VStack(spacing: 16) {
                if let code = connection.code {
                    Group {
                        if alternative {
                            TVQRCodeView(code: code).frame(width: 280, height: 280)
                                .frame(width: 500, height: 340)
                        } else {
                            TVPairingParticles(code: code).frame(width: 500, height: 340)
                        }
                    }
                    Text(code).font(.system(size: 62, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Anmeldecode: \(code.map(String.init).joined(separator: ", "))")
                    if let expiresAt = connection.expiresAt {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let remaining = max(0, Int(expiresAt.timeIntervalSince(timeline.date)))
                            Text(remaining == 0 ? "Code abgelaufen · bitte neu erstellen" : "Noch \(remaining / 60):\(String(format: "%02d", remaining % 60)) gültig")
                                .font(.caption)
                                .accessibilityLabel(remaining == 0 ? "Anmeldecode abgelaufen" : "Anmeldecode noch \(remaining) Sekunden gültig")
                        }
                    } else { Text("Einmaliger Code · höchstens fünf Minuten gültig").font(.caption) }
                } else {
                    Image(systemName: "tv.badge.wifi").font(.system(size: 120)).frame(height: 270)
                }
                Text(connection.status).font(.system(size: 25, weight: .medium)).multilineTextAlignment(.center)
                if let error = connection.error { Text(error).foregroundStyle(.red).font(.caption) }
                Button(connection.code == nil ? "Code erstellen" : "Neuer Code") {
                    Task { await connection.start() }
                }.filmPrimaryAction()
                if connection.code != nil {
                    Button(alternative ? "Zur Lichtansicht" : "Alternativ anmelden") {
                        alternative.toggle()
                    }
                    Button("Abbrechen") { Task { await connection.cancel() } }
                }
            }.frame(width: 500)
        }
        .padding(.horizontal, 100)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { BlurredBackdrop(film: FilmIndex.film("dune")).ignoresSafeArea() }
        .task {
            if connection.code == nil { await connection.start() }
            // This task lives only while the login is visible. Server failures
            // remain explicit rather than retrying in an uncontrolled loop.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if let expiry = connection.expiresAt, expiry <= .now {
                    await connection.start()
                } else if connection.code == nil, connection.status.hasPrefix("Code abgelaufen") {
                    await connection.start()
                }
            }
        }
    }
}

struct TVHomeView: View {
    @Environment(AppStore.self) private var store
    @State private var viewers = false

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack { TVForYouView() }.tabItem { Label(FilmSection.forYou.title, systemImage: FilmSection.forYou.symbol) }.tag(0)
            NavigationStack { TVWatchlistView() }.tabItem { Label(FilmSection.watchlist.title, systemImage: FilmSection.watchlist.symbol) }.tag(1)
            NavigationStack { TVCatalogView() }.tabItem { Label(FilmSection.catalog.title, systemImage: FilmSection.catalog.symbol) }.tag(2)
            NavigationStack { TVProfilesView() }.tabItem { Label(FilmSection.profile.title, systemImage: FilmSection.profile.symbol) }.tag(3)
            NavigationStack { TVSearchView() }.tabItem { Label(FilmSection.search.title, systemImage: FilmSection.search.symbol) }.tag(4)
        }
        .sheet(item: $store.ratingToPresent) { pending in TVRatingView(pending: pending) }
    }
}


/// Native particle study inspired by Octoglow. The digits are read by Vision;
/// the particles are visual identity, not the legacy grid's optical payload.
private struct TVPairingParticles: View {
    let code: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let points: [SIMD3<Double>] = (0..<1400).map { index in
        let y = 1 - 2 * (Double(index) + 0.5) / 1400
        let radius = sqrt(1 - y * y)
        let angle = Double(index) * 2.399963229728653
        return SIMD3(cos(angle) * radius, y, sin(angle) * radius)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let seed = Double(Int(code) ?? 0) * 0.0001
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let angle = time * 0.14 + seed
                let radius = min(size.width, size.height) * 0.37
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.blendMode = .plusLighter
                for (index, point) in Self.points.enumerated() {
                    let phase = Double(index) * 0.37
                    let wave = 1 + 0.08 * sin(point.y * 6 + time * 0.65 + seed)
                    let x = (point.x * cos(angle) - point.z * sin(angle)) * wave
                    let z = point.x * sin(angle) + point.z * cos(angle)
                    let depth = (z + 1) / 2
                    let spread = index % 9 == 0 ? 1.15 + 0.18 * sin(time * 0.4 + phase) : 1
                    let px = center.x + x * radius * spread
                    let py = center.y + point.y * radius * wave * spread
                    let dot = 0.8 + depth * 1.7
                    let opacity = 0.2 + depth * 0.65
                    let color = Color(hue: 0.56 + 0.08 * sin(phase + time * 0.08), saturation: 0.75, brightness: 1)
                    context.fill(Path(ellipseIn: CGRect(x: px - dot * 2, y: py - dot * 2, width: dot * 4, height: dot * 4)), with: .color(color.opacity(opacity * 0.08)))
                    context.fill(Path(ellipseIn: CGRect(x: px - dot / 2, y: py - dot / 2, width: dot, height: dot)), with: .color(color.opacity(opacity)))
                }
            }
        }.accessibilityHidden(true)
    }
}
