import StoreKit
import SwiftUI

struct TVAccountView: View {
    @Environment(AppStore.self) private var store
    @State private var plans = false
    @State private var signOutConfirm = false
    @State private var cancelConfirm = false
    @State private var companion: TVCompanionRequest?
    @State private var status: String?
    @State private var restoring = false

    var body: some View {
        TVScreen(title: "Konto & Abo", subtitle: store.account?.email) {
            HStack(alignment: .top, spacing: 95) {
                VStack(alignment: .leading, spacing: 28) {
                    Text(store.subscription?.plan.name ?? "Noch kein Tarif").font(.system(size: 42, weight: .bold))
                    Text(store.subscription?.statusText ?? "Trailer, Katalog und Empfehlungen sind verfügbar. Abspielen schaltest du mit einem Tarif frei.")
                        .font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 630, alignment: .leading)
                    if let subscription = store.subscription {
                        Text(subscription.source == .demo ? "Demo-Abo: keine Abbuchung, kein echter Kauf." : "Abo über den App Store. Verwaltung und Kündigung erfolgen beim App Store.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(subscription.plan.maxProfiles) Profile · \(subscription.plan.streams) Geräte gleichzeitig · \(subscription.plan.quality)")
                    }
                    Button("Tarif wählen oder wechseln") { plans = true }
                    Button(restoring ? "Wird wiederhergestellt …" : "Käufe wiederherstellen") { Task { await restore() } }.disabled(restoring)
                    if let subscription = store.subscription {
                        if subscription.source == .demo {
                            Button(subscription.canceled ? "Demo-Abo fortsetzen" : "Demo-Abo kündigen") { cancelConfirm = true }
                        } else {
                            Button("Abo auf iPhone verwalten") {
                                companion = TVCompanionRequest(kind: "externalLink", title: "Abo verwalten", payload: "https://apps.apple.com/account/subscriptions")
                            }
                        }
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                    if !store.syncStatus.isEmpty { Text(store.syncStatus).font(.caption).foregroundStyle(.secondary) }
                    SyncConflictView()
                }
                VStack(alignment: .leading, spacing: 28) {
                    Text("Auf diesem Apple TV").font(.system(size: 32, weight: .semibold))
                    Text("Deine Profile, Merkliste und Bewertungen gehören zu deinem Konto. Aktive Zuschauer und TV-Fokus bleiben auf diesem Gerät.")
                        .font(.system(size: 26)).foregroundStyle(.secondary).frame(width: 590, alignment: .leading)
                    Button("Abmelden und TV-Zugang entfernen") { signOutConfirm = true }
                    Button("Konto löschen", role: .destructive) {
                        companion = TVCompanionRequest(kind: "deleteAccount", title: "Konto endgültig löschen")
                    }
                    Text("SharePlay-Vorschau").font(.system(size: 32, weight: .semibold)).padding(.top, 15)
                    Text("Film zeigt hier die Idee eines gemeinsamen Filmabends. Es gibt noch keinen aktiven SharePlay-Dienst und keine synchronisierte Wiedergabe mit anderen Geräten.")
                        .font(.system(size: 24)).foregroundStyle(.secondary).frame(width: 590, alignment: .leading)
                }
            }
        }
        .task { await store.purchases.load(); await store.syncSubscription() }
        .sheet(isPresented: $plans) { TVPlanPicker() }
        .sheet(item: $companion) { TVCompanionView(store: store, request: $0) }
        .confirmationDialog("Dieses Konto auf dem Apple TV abmelden? Der TV-Zugang wird entfernt. Eine neue Anmeldung erfordert einen neuen Code.", isPresented: $signOutConfirm, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { store.signOut() }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(store.subscription?.canceled == true ? "Demo-Abo fortsetzen?" : "Demo-Abo zum Ende des Zeitraums kündigen?", isPresented: $cancelConfirm, titleVisibility: .visible) {
            Button(store.subscription?.canceled == true ? "Fortsetzen" : "Kündigen") { store.setCanceled(!(store.subscription?.canceled ?? false)) }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func restore() async {
        guard !restoring else { return }
        restoring = true; defer { restoring = false }
        do {
            try await AppStoreSync.restore()
            await store.purchases.load()
            if let subscription = await store.purchases.currentSubscription() {
                store.subscribe(subscription); status = "App-Store-Abo wiederhergestellt."
            } else { status = "Kein aktives App-Store-Abo gefunden. Demo-Abos werden über dein Film-Konto übernommen." }
        } catch { status = "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)" }
    }
}

/// Avoids the model type's name colliding with StoreKit.AppStore.
private enum AppStoreSync {
    static func restore() async throws { try await StoreKit.AppStore.sync() }
}

struct TVPlanPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Plan?
    @State private var busy = false
    @State private var status: String?
    @State private var confirm = false
    @State private var success = false

    var body: some View {
        TVScreen(title: "Dein Tarif", subtitle: store.purchases.storeKitAvailable ? "Käufe erfolgen über den App Store. Sieben Tage Testphase nach verfügbarer Angebotsberechtigung." : "Demo-Tarife: sieben Tage Testphase, keine Abbuchung.") {
            HStack(alignment: .top, spacing: 42) {
                ForEach(Plan.allCases) { plan in
                    VStack(alignment: .leading, spacing: 24) {
                        Text(plan.name).font(.system(size: 40, weight: .bold))
                        Text(plan.tagline).font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("\(store.purchases.displayPrice(plan)) / Monat").font(.system(size: 32, weight: .semibold))
                        ForEach(plan.features, id: \.self) { feature in Label(feature, systemImage: "checkmark").font(.system(size: 24)) }
                        Text(store.subscription?.plan == plan ? "Dein aktueller Tarif" : "").font(.caption).foregroundStyle(.secondary)
                        Button(store.purchases.storeKitAvailable ? "\(plan.name) wählen" : "\(plan.name) als Demo wählen") {
                            chosen = plan; confirm = true
                        }.disabled(busy || store.subscription?.plan == plan && store.subscription?.isActive == true)
                    }.padding(32).frame(width: 450, alignment: .leading)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
                }
            }
            if let chosen, store.profiles.count > chosen.maxProfiles {
                Text("Beim Wechsel auf \(chosen.name) werden \(store.profiles.count - chosen.maxProfiles) Profile pausiert. Bewertungen und Merklisten bleiben gespeichert.").foregroundStyle(.secondary)
            }
            if let status { Text(status).font(.system(size: 26)).foregroundStyle(success ? .green : .secondary) }
            Button(success ? "Fertig" : "Schließen") { dismiss() }.disabled(busy)
        }
        .task { await store.purchases.load() }
        .confirmationDialog(confirmationTitle, isPresented: $confirm, titleVisibility: .visible) {
            Button(store.purchases.storeKitAvailable ? "Zum App-Store-Kauf" : "Demo-Tarif aktivieren") { Task { await buy() } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var confirmationTitle: String {
        guard let chosen else { return "Tarif wählen" }
        var text = store.purchases.storeKitAvailable ? "\(chosen.name) für \(store.purchases.displayPrice(chosen)) pro Monat wählen?" : "\(chosen.name) als Demo aktivieren? Es wird kein Geld abgebucht."
        if store.profiles.count > chosen.maxProfiles { text += " Überzählige Profile werden pausiert und behalten ihre Daten." }
        if !chosen.allowsTogether && store.activeProfileIDs.count > 1 { text += " Gemeinsam schauen endet; das erste Profil bleibt aktiv." }
        return text
    }
    private func buy() async {
        guard !busy, let chosen else { return }
        busy = true; status = nil; defer { busy = false }
        switch await store.purchases.purchase(chosen) {
        case .purchased(let subscription): store.subscribe(subscription); success = true; status = subscription.source == .demo ? "Demo-Tarif aktiviert. Keine Abbuchung." : "Tarif aktiviert."
        case .cancelled: status = "Kauf abgebrochen."
        case .failed(let error): status = error
        }
    }
}
