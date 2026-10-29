import LocalAuthentication
import PassKit
import StoreKit
import SwiftUI

// MARK: - Einstieg: Willkommen → Registrieren / Anmelden

struct AuthFlow: View {
    enum Step { case welcome, register, login }
    @Environment(AppStore.self) private var store
    @State private var step: Step

    init(start: Step = .welcome) { _step = State(initialValue: start) }

    var body: some View {
        NavigationFrame { content }
    }

    private var content: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PosterWall().opacity(step == .welcome ? 1 : 0.35)
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.7), location: 0.4),
                                   .init(color: .black, location: 0.72)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            switch step {
            case .welcome:
                welcome.transition(.opacity.combined(with: .offset(y: 20)))
            case .register:
                RegisterForm(switchToLogin: { go(.login) }, back: { go(.welcome) })
                    .transition(.opacity.combined(with: .offset(y: 20)))
            case .login:
                LoginForm(switchToRegister: { go(.register) }, back: { go(.welcome) })
                    .transition(.opacity.combined(with: .offset(y: 20)))
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if (store.account != nil || !store.savedAccounts.isEmpty) && step == .welcome { step = .login } }
    }

    private func go(_ next: Step) { withAnimation(.smooth(duration: 0.45)) { step = next } }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Ein Film.\nGenau deiner.")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .lineSpacing(-4)
            Text("Statt endlos zu scrollen, zeigen wir dir genau einen Film, der zu dir passt. Dafür lernen wir dich in einer Minute kennen, besser, als du denkst.")
                .foregroundStyle(.secondary)
            Button { go(.register) } label: {
                Text("Konto erstellen").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .padding(.top, 8)
            Button { go(.login) } label: {
                Text("Ich habe schon ein Konto").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(24)
    }
}

/// Gemeinsamer Rahmen für Registrieren und Anmelden: Titel, Glaskarte, Haupt-Button unten.
private struct AuthCard<Fields: View>: View {
    var title: String
    var subtitle: String
    var back: () -> Void
    @ViewBuilder var fields: () -> Fields

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.weight(.heavy))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                fields()
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Zurück", systemImage: "chevron.left", action: back).tint(.white) }
        }
    }
}

private struct FieldRow: View {
    var symbol: String
    var placeholder: String
    @Binding var text: String
    var secure = false
    var content: UITextContentType
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Group {
                if secure && !reveal {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textContentType(content)
            .keyboardType(content == .emailAddress ? .emailAddress : .default)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reveal ? "Passwort verbergen" : "Passwort zeigen")
            }
        }
        .padding(.horizontal, 18).frame(minHeight: 54)
    }
}

private struct RegisterForm: View {
    @Environment(AppStore.self) private var store
    var switchToLogin: () -> Void
    var back: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var consent = false
    @State private var error: String?
    @State private var busy = false

    private var rules: [(String, Bool)] {
        [("Mindestens 8 Zeichen", password.count >= 8),
         ("Mindestens eine Zahl", password.contains { $0.isNumber })]
    }
    private var valid: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && rules.allSatisfy(\.1) && consent }

    var body: some View {
        AuthCard(title: "Konto erstellen", subtitle: "Ein Konto für deinen Haushalt, Profile legst du gleich danach an.", back: back) {
            VStack(spacing: 0) {
                FieldRow(symbol: "envelope", placeholder: "E-Mail", text: $email, content: .emailAddress)
                Divider().padding(.leading, 52)
                FieldRow(symbol: "lock", placeholder: "Passwort", text: $password, secure: true, content: .newPassword)
            }
            .glassEffect(in: .rect(cornerRadius: 24))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(rules, id: \.0) { rule in
                    Label(rule.0, systemImage: rule.1 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.1 ? Color.green : Color.secondary.opacity(0.7))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.footnote)
            .animation(.snappy, value: password)

            Toggle(isOn: $consent) {
                Text("Ich akzeptiere die Nutzungsbedingungen und habe die Datenschutzhinweise gelesen.")
                    .font(.footnote)
            }
            .toggleStyle(CheckToggle())

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }

            Button {
                busy = true
                Task {
                    do { try await store.register(email: email, password: password) }
                    catch { withAnimation { self.error = error.localizedDescription } }
                    busy = false
                }
            } label: {
                ZStack {
                    Text("Konto erstellen").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.black) }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(!valid || busy)

            Button("Schon ein Konto? Anmelden", action: switchToLogin)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .tint(.secondary)

            Text("Konten liegen online bei Supabase (Server in Frankfurt). Ausgedachte E-Mail-Adressen reichen, es wird nichts verschickt.")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

private struct LoginForm: View {
    @Environment(AppStore.self) private var store
    var switchToRegister: () -> Void
    var back: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var forgot = false
    @State private var busy = false
    @State private var saved: [String] = []

    var body: some View {
        AuthCard(title: "Anmelden", subtitle: "Willkommen zurück.", back: back) {
            if !saved.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Konten auf diesem Gerät").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(saved, id: \.self) { mail in
                                Button { withAnimation(.snappy) { email = mail } } label: {
                                    Label(mail, systemImage: email == mail ? "checkmark.circle.fill" : "person.crop.circle")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(email == mail ? .regular.tint(.white.opacity(0.25)).interactive() : .regular.interactive(),
                                             in: .capsule)
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            VStack(spacing: 0) {
                FieldRow(symbol: "envelope", placeholder: "E-Mail", text: $email, content: .emailAddress)
                Divider().padding(.leading, 52)
                FieldRow(symbol: "lock", placeholder: "Passwort", text: $password, secure: true, content: .password)
            }
            .glassEffect(in: .rect(cornerRadius: 24))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .transition(.opacity)
            }

            Button {
                busy = true
                Task {
                    do { try await store.signIn(email: email, password: password) }
                    catch { withAnimation { self.error = error.localizedDescription } }
                    busy = false
                }
            } label: {
                ZStack {
                    Text("Anmelden").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.black) }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(email.isEmpty || password.isEmpty || busy)

            HStack {
                Button("Passwort vergessen?") { forgot = true }
                Spacer()
                Button("Konto erstellen", action: switchToRegister)
            }
            .font(.subheadline.weight(.semibold))
            .tint(.secondary)
        }
        .onAppear {
            saved = store.savedAccounts
            if email.isEmpty { email = store.account?.email ?? saved.first ?? "" }
        }
        .onChange(of: email) { error = nil }
        .onChange(of: password) { error = nil }
        .alert("Passwort vergessen?", isPresented: $forgot) {
            Button("Neues Konto erstellen", action: switchToRegister)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Ein Link per E-Mail kommt später. Bis dahin kannst du einfach ein neues Konto erstellen.")
        }
    }
}

/// Runde Checkbox statt Schalter, für Zustimmungen.
struct CheckToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: configuration.isOn)
    }
}

// MARK: - Abo wählen

struct PlanPicker: View {
    enum Mode: Equatable {
        /// Nach dem Geschmacksprofil: erst den Wert zeigen, dann bezahlen.
        case onboarding
        /// Abspielen ohne aktives Abo.
        case unlock
        /// Mehr Profile, als der Tarif erlaubt.
        case upgrade
        /// Aus den Kontoeinstellungen.
        case change
    }

    @Environment(AppStore.self) private var store
    var mode: Mode
    var onDone: (Bool) -> Void

    @State private var selected: Plan = .duo
    @State private var busy = false
    @State private var error: String?
    @State private var demoCheckout = false
    @State private var celebrating: Subscription?

    private var current: Subscription? { store.subscription }
    private var isFirstPurchase: Bool { current == nil }

    var body: some View {
        plans.toolbar {
            if mode != .onboarding {
                ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { onDone(false) }.tint(.white) }
            }
        }
    }

    private var plans: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.largeTitle.weight(.heavy))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Plan.allCases) { plan in card(plan) }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(isFirstPurchase
                         ? "7 Tage kostenlos, danach \(store.purchases.displayPrice(selected)) pro Monat. Jederzeit kündbar, auch in der Testphase."
                         : "Der neue Preis gilt ab der nächsten Abrechnung. Jederzeit kündbar.")
                    Text(store.purchases.storeKitAvailable
                         ? "Bezahlt wird über den App Store. In dieser Testumgebung wird nichts abgebucht."
                         : "Demo-Kauf: Es werden keine Zahlungsdaten abgefragt und nichts abgebucht.")
                }
                .font(.footnote).foregroundStyle(.secondary)
                if store.purchases.storeKitAvailable {
                    Button("Käufe wiederherstellen") { Task { await restore() } }
                        .font(.footnote.weight(.semibold)).tint(.secondary)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button { Task { await buy() } } label: {
                ZStack {
                    Text(cta).opacity(busy ? 0 : 1)
                    if busy { ProgressView() }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(busy || (current?.plan == selected && current?.canceled == false))
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await store.purchases.load()
            if let current, mode == .change || mode == .upgrade {
                selected = Plan.allCases.first { $0.maxProfiles > current.plan.maxProfiles } ?? current.plan
            } else if store.profiles.count > 1 {
                selected = store.profiles.count > Plan.duo.maxProfiles ? .familie : .duo
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .sheet(isPresented: $demoCheckout) {
            DemoCheckout(plan: selected, trial: isFirstPurchase) {
                var sub = Subscription.trial(selected, source: .demo)
                if let current { sub.started = current.started; sub.renews = current.renews; sub.trial = current.trial }
                celebrate(sub)
            }
        }
        .overlay {
            if let celebrating {
                PurchaseCelebration(subscription: celebrating) {
                    withAnimation(.smooth) { store.subscribe(celebrating) }
                    onDone(true)
                }
                .transition(.opacity)
            }
        }
    }

    /// Erst feiern, dann übernehmen, sonst springt die App sofort weiter und der Moment ist weg.
    private func celebrate(_ sub: Subscription) {
        withAnimation(.smooth(duration: 0.35)) { celebrating = sub }
    }

    private var title: String {
        switch mode {
        case .onboarding: "Dein Film wartet"
        case .unlock: "Abo starten"
        case .upgrade: "Mehr Profile"
        case .change: "Abo ändern"
        }
    }

    private var subtitle: String {
        switch mode {
        case .onboarding: "Wähle ein Abo, um loszuschauen. Trailer, Vorschläge und dein Profil bleiben immer frei."
        case .unlock: "Zum Abspielen brauchst du ein aktives Abo. Trailer kannst du jederzeit ansehen."
        case .upgrade: "Dein Tarif \(current?.plan.name ?? "") erlaubt \(current?.plan.maxProfiles ?? 1) Profil(e). Für ein weiteres brauchst du einen größeren Tarif."
        case .change: "Wechsle jederzeit. Profile bleiben erhalten."
        }
    }

    private var cta: String {
        if isFirstPurchase { return "7 Tage kostenlos testen" }
        if current?.plan == selected { return current?.canceled == true ? "Abo fortsetzen" : "Dein aktueller Tarif" }
        return "Zu \(selected.name) wechseln"
    }

    private func card(_ plan: Plan) -> some View {
        let on = selected == plan
        let tooSmall = plan.maxProfiles < store.profiles.count
        return Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = plan } } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(plan.name).font(.title2.weight(.heavy))
                            if plan == .duo {
                                Text("Beliebt").font(.caption2.weight(.heavy))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.tint, in: .capsule)
                            }
                            if current?.plan == plan {
                                Text("Aktuell").font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.white.opacity(0.15), in: .capsule)
                            }
                        }
                        Text(plan.tagline).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(store.purchases.displayPrice(plan)).font(.title3.weight(.bold)).monospacedDigit()
                        Text("pro Monat").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                WrapLayout(spacing: 6) {
                    ForEach(plan.features, id: \.self) { f in
                        Label(f, systemImage: "checkmark")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.white.opacity(on ? 0.12 : 0.06), in: .capsule)
                    }
                }
                if tooSmall {
                    Text("Ihr habt \(store.profiles.count) Profile, in \(plan.name) \(plan.maxProfiles == 1 ? "ist eines" : "sind \(plan.maxProfiles)") aktiv. Die übrigen werden pausiert, gelöscht wird nichts.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.tint.opacity(on ? 1 : 0), lineWidth: 2))
        .scaleEffect(on ? 1 : 0.98)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func buy() async {
        busy = true; error = nil
        defer { busy = false }
        if let current, current.plan == selected, current.canceled {
            store.setCanceled(false); onDone(true); return
        }
        if !store.purchases.storeKitAvailable { demoCheckout = true; return }
        switch await store.purchases.purchase(selected) {
        case .purchased(var sub):
            // Tarifwechsel während der Testphase: Testphase läuft weiter.
            if let current, sub.source == .demo { sub.started = current.started; sub.renews = current.renews; sub.trial = current.trial }
            celebrate(sub)
        case .cancelled: break
        case .failed(let message): error = message
        }
    }

    private func restore() async {
        busy = true
        defer { busy = false }
        try? await StoreKit.AppStore.sync()
        if let sub = await store.purchases.currentSubscription() { store.subscribe(sub); onDone(true) }
        else { error = "Kein aktives Abo gefunden." }
    }
}

// MARK: - Nach dem Kauf

/// Der Moment nach dem Kauf, wie bei Apple Pay: Das Häkchen zeichnet sich, dazu ein kurzer
/// Erfolgs-Haptik-Impuls. Danach erscheint in Ruhe, was jetzt dazugehört, und ein Button.
struct PurchaseCelebration: View {
    let subscription: Subscription
    var done: () -> Void

    @State private var checkShown = false
    @State private var textIn = false
    @State private var featuresIn = 0
    @State private var haptic = 0

    private let symbols = ["person.2.fill", "play.tv.fill", "4k.tv.fill", "person.3.sequence.fill"]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .tint)
                .symbolEffect(.drawOn, isActive: !checkShown)
                .symbolEffect(.bounce, value: checkShown)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Willkommen bei \(subscription.plan.name)")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(subscription.trial ? "Die nächsten 7 Tage sind kostenlos." : "Dein Tarif ist aktiv.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .opacity(textIn ? 1 : 0)
            .offset(y: textIn ? 0 : 10)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(subscription.plan.features.enumerated()), id: \.offset) { i, feature in
                    Label {
                        Text(feature).font(.body.weight(.medium))
                    } icon: {
                        Image(systemName: symbols[min(i, symbols.count - 1)])
                            .foregroundStyle(.tint)
                            .frame(width: 32)
                    }
                    .opacity(featuresIn > i ? 1 : 0)
                    .offset(y: featuresIn > i ? 0 : 8)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.top, 36)
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button(action: done) {
                Text("Los geht's").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.bottom, 8)
            .opacity(featuresIn >= subscription.plan.features.count ? 1 : 0)
        }
        .sensoryFeedback(trigger: haptic) { _, new in
            new == 1 ? .success : .impact(weight: .light, intensity: 0.5)
        }
        .task { await play() }
    }

    private func play() async {
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation { checkShown = true }
        haptic = 1
        try? await Task.sleep(for: .milliseconds(650))
        withAnimation(.smooth(duration: 0.5)) { textIn = true }
        try? await Task.sleep(for: .milliseconds(300))
        for i in 1...subscription.plan.features.count {
            withAnimation(.smooth(duration: 0.35)) { featuresIn = i }
            haptic += 1
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

// MARK: - Demo-Kauf

/// Bestätigungsblatt im Stil des System-Kaufblatts, ausdrücklich als Demo gekennzeichnet.
/// Es werden keine Zahlungsdaten abgefragt und nichts abgebucht.
private struct DemoCheckout: View {
    let plan: Plan
    let trial: Bool
    var confirmed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase = 0   // 0 bereit, 1 bestätigt …, 2 fertig
    /// Das Blatt ist genau so hoch wie sein Inhalt, der Button sitzt unten wie bei Apple Pay.
    @State private var height: CGFloat = 470
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                // Der Hinweis zum Demo-Kauf steckt hinter der Markierung, die Kasse bleibt ruhig.
                Button { showInfo = true } label: {
                    Label("Demo-Kauf", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: .capsule)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo) {
                    Text("Face ID ist echt, der Kauf nicht, es wird nichts abgebucht. Im fertigen Dienst läuft die Zahlung über Apple Pay bzw. den App Store.")
                        .font(.footnote)
                        .frame(width: 260)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(.white)
                .disabled(phase > 0)
                .accessibilityLabel("Abbrechen")
            }
            HStack(spacing: 14) {
                // Mini-Version des App-Icons: dunkle Fläche, ein leuchtendes Cover.
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(white: 0.05))
                    .frame(width: 58, height: 58)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3).fill(.white)
                            .frame(width: 19, height: 29)
                            .shadow(color: .white.opacity(0.8), radius: 6)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Film: \(plan.name)").font(.headline)
                    Text("Abo · monatlich").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                row("Heute", trial ? "0,00 €" : plan.priceText)
                Divider()
                row(trial ? "Ab \(Date.now.addingTimeInterval(7 * 86_400).formatted(.dateTime.day().month(.abbreviated)))" : "Danach",
                    "\(plan.priceText) / Monat")
                Divider()
                row("Zahlungsart", "Apple Pay")
            }
            .padding(.horizontal, 16)
            .glassEffect(in: .rect(cornerRadius: 20))

            // Echter Apple-Pay-Button von PassKit. Bezahlt wird nicht: Ein echtes Apple Pay bräuchte
            // eine Händler-ID und einen Zahlungsdienstleister. Face ID ist aber echt.
            ZStack {
                switch phase {
                case 0:
                    PayWithApplePayButton(trial ? .subscribe : .buy, action: confirm)
                        .payWithApplePayButtonStyle(.white)
                        .frame(height: 54)
                        .clipShape(.capsule)
                        .transition(.opacity)
                case 1:
                    Label("Mit Face ID bestätigen …", systemImage: "faceid")
                        .symbolEffect(.pulse, options: .repeating)
                        .transition(.opacity)
                default:
                    Label("Fertig", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: phase)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .sensoryFeedback(.success, trigger: phase == 2)

        }
        .padding(22)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(phase > 0)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.subheadline)
        .padding(.vertical, 13)
    }

    private func confirm() {
        withAnimation(.snappy) { phase = 1 }
        Task {
            guard await authenticate() else {
                withAnimation(.snappy) { phase = 0 }
                return
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { phase = 2 }
            try? await Task.sleep(for: .milliseconds(800))
            dismiss()
            try? await Task.sleep(for: .milliseconds(250))
            confirmed()
        }
    }

    /// Echte Bestätigung mit Face ID (oder Code). Ohne eingerichtete Sperre, etwa im
    /// Simulator, geht es mit einer kurzen Pause weiter, damit die Demo trotzdem läuft.
    private func authenticate() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            try? await Task.sleep(for: .milliseconds(900))
            return true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: "Abo „Film: \(plan.name)“ bestätigen")) ?? false
    }
}

// MARK: - Konto & Abo verwalten

struct AccountView: View {
    @Environment(AppStore.self) private var store
    @State private var changing = false
    @State private var pairing = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false
    @State private var manageSheet = false
    @State private var deletionError: String?
    @State private var deleting = false

    var body: some View {
        List {
            if let account = store.account {
                Section {
                    LabeledContent("E-Mail", value: account.email)
                    LabeledContent("Gespeichert", value: store.isOnline ? "Online (Supabase, Frankfurt)" : "Nur auf diesem Gerät")
                    LabeledContent("Mitglied seit", value: account.created.formatted(.dateTime.month(.wide).year()))
                }
                Section("Fernseher") {
                    Button("Apple TV verbinden", systemImage: "appletv.fill") { pairing = true }
                    NavigationLink("Verbundene TVs & Aufgaben", destination: PhoneCompanionView(store: store))
                    if !store.syncStatus.isEmpty { Text(store.syncStatus).font(.caption).foregroundStyle(.secondary) }
                    SyncConflictView()
                }
                Section("Abo") {
                    if let sub = account.subscription {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(sub.plan.name).font(.title3.weight(.bold))
                                if sub.trial && !sub.canceled {
                                    Text("Testphase").font(.caption2.weight(.heavy))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.white, in: .capsule)
                                }
                                Spacer()
                                Text("\(store.purchases.displayPrice(sub.plan)) / Monat").foregroundStyle(.secondary)
                            }
                            Text(sub.statusText).font(.subheadline)
                                .foregroundStyle(sub.canceled ? Color.orange : .secondary)
                            Text(sub.plan.features.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        LabeledContent("Profile", value: store.pausedProfileIDs.isEmpty
                                       ? "\(store.profiles.count) von \(sub.plan.maxProfiles)"
                                       : "\(sub.plan.maxProfiles) aktiv, \(store.pausedProfileIDs.count) pausiert")
                        LabeledContent("Zahlung", value: sub.source == .appStore ? "App Store" : "Demo-Kauf (ohne Abbuchung)")
                        Button("Tarif ändern", systemImage: "arrow.up.arrow.down") { changing = true }
                        if sub.canceled {
                            Button("Abo fortsetzen", systemImage: "arrow.clockwise") { store.setCanceled(false) }
                        } else {
                            Button("Abo kündigen", systemImage: "xmark.circle", role: .destructive) {
                                if sub.source == .appStore { manageSheet = true } else { confirmCancel = true }
                            }
                        }
                    } else {
                        Text("Kein aktives Abo. Vorschläge und Trailer gehen trotzdem.").foregroundStyle(.secondary)
                        Button("Abo wählen", systemImage: "play.rectangle") { changing = true }
                    }
                }
                Section {
                    Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right") {
                        withAnimation(.smooth) { store.signOut() }
                    }
                    Button("Konto löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(store.isOnline ? "Löschen entfernt Konto, Profile, Bewertungen und importierte Daten online und von diesem Gerät." : "Löschen entfernt Konto, Profile, Bewertungen und importierte Daten von diesem Gerät.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .disabled(deleting)
        .alert("Konto konnte nicht gelöscht werden", isPresented: Binding(get:{deletionError != nil},set:{if !$0 {deletionError=nil}})) {Button("OK"){deletionError=nil}} message:{Text(deletionError ?? "")}
        .sheet(isPresented: $pairing) {
            TVPairingSheet(accountEmail: store.account?.email ?? "", accessToken: { try await store.currentPhoneSessionToken() })
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $changing) {
            NavigationFrame { PlanPicker(mode: store.subscription == nil ? .unlock : .change) { _ in changing = false } }
        }
        .manageSubscriptionsSheet(isPresented: $manageSheet)
        .onChange(of: manageSheet) { _, open in if !open { Task { await store.syncSubscription() } } }
        .confirmationDialog("Abo kündigen?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Kündigen", role: .destructive) { store.setCanceled(true) }
        } message: {
            Text("Du kannst bis \(store.subscription?.renews.formatted(.dateTime.day().month(.wide)) ?? "zum Ende des Zeitraums") weiterschauen.")
        }
        .confirmationDialog("Konto wirklich löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Konto und alle Daten löschen", role: .destructive) {
                deleting=true
                Task { do { try await store.deleteAccountConfirmed() } catch { deletionError=error.localizedDescription }; deleting=false }
            }
        } message: {
            Text("Das lässt sich nicht rückgängig machen.")
        }
    }
}
