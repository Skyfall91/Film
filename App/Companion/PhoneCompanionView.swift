#if os(iOS)
import CryptoKit
import FilmSync
import LightCode
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct PhoneCompanionJob: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let profileID: String?
    let payload: JSONValue
    let status: String
    let version: Int
    let expiresAt: String
    let result: JSONValue?
    let claimant: String?
    var profileUUID: UUID? { profileID.flatMap(UUID.init(uuidString:)) }
    var filmID: String? { payload["filmID"]?.string }
    var title: String {
        switch kind {
        case "import": "Bewertungen importieren"
        case "taste": "Geschmack beschreiben"
        case "mood": "Stimmung für den Filmabend"
        case "review": "Review schreiben"
        case "externalLink": "Link vom Fernseher öffnen"
        case "subscription": "Tarif verwalten"
        case "deleteAccount": "Konto löschen"
        default: "Auftrag vom Fernseher"
        }
    }
}

nonisolated struct PhoneTVSession: Codable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let createdAt: String
    let lastSeenAt: String?
    let expiresAt: String
}

@Observable
private final class PhoneJobsModel {
    var jobs: [PhoneCompanionJob] = []
    var active: PhoneCompanionJob?
    var sessions: [PhoneTVSession] = []
    var devicesBusy = false
    var error: String?
    var message: String?
    var busy = false
    let store: AppStore
    let email: String?
    let epoch: UUID
    let claimant: String
    private var pendingResult: JSONValue?
    private var pendingResultJobID: String?
    private var client: PairingClient { PairingClient(baseURL: CloudAccounts.backendURL, publishableKey: CloudAccounts.pairingPublishableKey) }

    init(store: AppStore) {
        self.store = store; email = store.account?.email; epoch = store.sessionEpoch
        let key = "film.companion.phoneID"
        claimant = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(claimant, forKey: key)
    }
    func ownsClaim(_ job: PhoneCompanionJob) -> Bool { PhoneClaimPolicy.owns(serverClaimant: job.claimant, rawPhoneID: claimant) }
    var hasPendingCompletion: Bool { pendingResult != nil }
    private var current: Bool { store.signedIn && store.sessionEpoch == epoch && store.account?.email == email && email != nil }
    private func checkContext() throws {
        try Task.checkCancellation()
        guard current else { throw AuthError.server("Das Konto hat sich geändert. Öffne den Fernseherbereich erneut.") }
    }
    private func post<T: Decodable & Sendable>(_ route: String, _ body: JSONValue, as type: T.Type) async throws -> T {
        try checkContext()
        let token = try await store.currentPhoneSessionToken()
        try checkContext()
        let response = try await client.post(route: route, body: body, bearerToken: token, as: type)
        try checkContext()
        return response
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            nonisolated struct Response: Decodable, Sendable { let jobs: [PhoneCompanionJob] }
            let response = try await post("listJobs", .object([:]), as: Response.self)
            jobs = response.jobs.filter { ["pending", "claimed"].contains($0.status) }
            if let active, let updated = jobs.first(where: { $0.id == active.id }) {
                self.active = updated
            } else if active != nil { active = nil; message = "Der Auftrag ist abgeschlossen, abgebrochen oder abgelaufen." }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func claim(_ job: PhoneCompanionJob) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await store.syncNow()
            try checkContext()
            let claimed: PhoneCompanionJob
            if job.status == "claimed", ownsClaim(job) { claimed = job }
            else { claimed = try await post("claimJob", .object(["id": .string(job.id), "version": .number(Double(job.version)), "claimant": .string(claimant)]), as: PhoneCompanionJob.self) }
            guard claimed.status == "claimed", ownsClaim(claimed) else { throw PairingClientError.invalidResponse }
            active = claimed; pendingResult = nil; pendingResultJobID = nil; message = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func complete(_ result: JSONValue) async -> Bool {
        guard !busy, let job = active else { return false }
        busy = true; defer { busy = false }
        do {
            try checkContext()
            guard ownsClaim(job) else { throw PairingClientError.invalidResponse }
            let final: JSONValue
            if pendingResultJobID == job.id, let pendingResult { final = pendingResult }
            else {
                try await store.syncNow()
                nonisolated struct StateVersion: Decodable, Sendable { let revision: Int }
                let state = try await post("readState", .object([:]), as: StateVersion.self)
                var values = result.object ?? [:]
                values["baseRevision"] = .number(Double(state.revision))
                final = .object(values); pendingResult = final; pendingResultJobID = job.id
            }
            let completed = try await post("completeJob", .object(["id": .string(job.id), "version": .number(Double(job.version)), "claimant": .string(claimant), "result": final]), as: PhoneCompanionJob.self)
            guard completed.status == "completed" else { throw PairingClientError.invalidResponse }
            try await store.refreshCloudState()
            message = "\(job.title) abgeschlossen. Der Fernseher übernimmt das Ergebnis beim nächsten Abruf."
            jobs.removeAll { $0.id == job.id }; active = nil; pendingResult = nil; pendingResultJobID = nil; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func cancel() async {
        guard !busy, let job = active else { return }
        busy = true; defer { busy = false }
        do {
            let _: PhoneCompanionJob = try await post("cancelJob", .object(["id": .string(job.id), "version": .number(Double(job.version))]), as: PhoneCompanionJob.self)
            jobs.removeAll { $0.id == job.id }; active = nil; pendingResult = nil; pendingResultJobID = nil
            message = "Auftrag abgebrochen."; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func refreshDevices() async {
        guard !devicesBusy else { return }
        devicesBusy = true; defer { devicesBusy = false }
        do {
            nonisolated struct Response: Decodable, Sendable { let sessions: [PhoneTVSession] }
            let reply = try await post("listSessions", .object([:]), as: Response.self)
            sessions = reply.sessions; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ device: PhoneTVSession) async {
        guard !devicesBusy else { return }
        devicesBusy = true; defer { devicesBusy = false }
        do {
            let reply = try await post("revokeSession", .object(["id": .string(device.id)]), as: PairingStatusResponse.self)
            guard reply.status == "revoked" else { throw PairingClientError.invalidResponse }
            sessions.removeAll { $0.id == device.id }; error = nil
            message = "Der Zugang von \(device.deviceName) wurde entfernt. Eine neue Anmeldung erfordert einen neuen Code."
        } catch { self.error = error.localizedDescription }
    }
    func invalidate() { jobs = []; active = nil; sessions = []; pendingResult = nil; pendingResultJobID = nil; error = "Das Konto hat sich geändert. Öffne diesen Bereich erneut." }
}

struct PhoneCompanionView: View {
    @Bindable private var store: AppStore
    @State private var model: PhoneJobsModel
    @State private var pairing = false
    @State private var showImporter = false
    @State private var parsedImport: ImportResult?
    @State private var fingerprint: String?
    @State private var localError: String?
    @State private var moodText = ""
    @State private var moodResult: MoodResult?
    @State private var interpreting = false
    @State private var reviewText = ""
    @State private var reviewRating = Interaction.ratedUp
    @State private var tasteDraft: AppStore?
    @State private var tasteBaseline: Profile?
    @State private var tasteOperations: [SyncOperation] = []
    @State private var tasteSheet = false
    @State private var plans = false
    @State private var deleteConfirm = false
    @State private var subscriptionChanged = false
    @State private var deviceToRevoke: PhoneTVSession?

    init(store: AppStore) {
        self.store = store; _model = State(initialValue: PhoneJobsModel(store: store))
    }
    private var activeProfile: Profile? { model.active?.profileUUID.flatMap { id in store.profiles.first { $0.id == id } } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dein Apple TV").font(.largeTitle.bold())
                Text("Verbinde deinen Fernseher oder erledige einen Auftrag, den du auf dem Fernseher gestartet hast.").foregroundStyle(.secondary)
                Button("Fernseher verbinden") { pairing = true }.buttonStyle(.borderedProminent)
                if let active = model.active { activeJob(active) }
                else { jobList }
                devicesSection
                if model.busy { ProgressView("Auftrag wird aktualisiert …") }
                if let message = model.message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error = localError ?? model.error { Text(error).foregroundStyle(.red) }
                Button("Aufträge aktualisieren") { Task { await model.refresh() } }.disabled(model.busy)
            }.padding(24)
        }
        .navigationTitle("Fernseher")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh(); await model.refreshDevices() }
        .onChange(of: store.account?.email) { _, _ in model.invalidate(); tasteSheet = false }
        .onChange(of: store.sessionEpoch) { _, _ in model.invalidate(); tasteSheet = false }
        .onChange(of: store.signedIn) { _, signedIn in if !signedIn { model.invalidate(); tasteSheet = false } }
        .onChange(of: model.active?.id) { _, _ in resetDraft() }
        .sheet(isPresented: $pairing) {
            TVPairingSheet(accountEmail: store.account?.email ?? "", accessToken: { try await store.currentPhoneSessionToken() })
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { readCSV($0) }
        .sheet(isPresented: $tasteSheet, onDismiss: collectTaste) {
            if let draft = tasteDraft, let id = tasteBaseline?.id { TasteChatView(profileID: id).environment(draft) }
        }
        .sheet(isPresented: $plans) {
            NavigationFrame { PlanPicker(mode: .change) { changed in subscriptionChanged = changed; plans = false } }.environment(store)
        }
        .confirmationDialog("Den Zugang dieses Apple TV entfernen? Die Daten deines Kontos bleiben erhalten. Der Fernseher muss danach neu verbunden werden.", isPresented: Binding(get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }), titleVisibility: .visible) {
            if let device = deviceToRevoke {
                Button("Zugang von \(device.deviceName) entfernen", role: .destructive) { Task { await model.revoke(device); deviceToRevoke = nil } }
            }
            Button("Abbrechen", role: .cancel) { deviceToRevoke = nil }
        }
        .confirmationDialog("Konto samt allen Profilen, Bewertungen, Imports und Merklisten endgültig löschen? Alle TV-Zugänge werden widerrufen.", isPresented: $deleteConfirm, titleVisibility: .visible) {
            Button("Konto endgültig löschen", role: .destructive) { Task { await deleteAccount() } }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Verbundene Fernseher").font(.title2.bold())
            if model.sessions.isEmpty { Text("Keine verbundenen Fernseher gefunden.").foregroundStyle(.secondary) }
            ForEach(model.sessions) { device in
                VStack(alignment: .leading, spacing: 12) {
                    Label(device.deviceName, systemImage: "tv").font(.headline)
                    if let created = PairingClient.date(device.createdAt) { Text("Verbunden seit \(created.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                    if let raw = device.lastSeenAt, let date = PairingClient.date(raw) { Text("Zuletzt genutzt: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    if let expiry = PairingClient.date(device.expiresAt) { Text("Zugang gültig bis \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    Button("TV-Zugang entfernen", role: .destructive) { deviceToRevoke = device }.disabled(model.devicesBusy)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            }
            Button(model.devicesBusy ? "Geräte werden aktualisiert …" : "Geräte aktualisieren") { Task { await model.refreshDevices() } }.disabled(model.devicesBusy)
        }.padding(.top, 16)
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Aufträge vom Fernseher").font(.title2.bold())
            if model.jobs.isEmpty {
                ContentUnavailableView("Keine offenen Aufträge", systemImage: "tv", description: Text("Starte am Fernseher zum Beispiel einen Import, einen Geschmacksdialog oder einen Review."))
            }
            ForEach(model.jobs) { job in
                Button { Task { await model.claim(job) } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.title).font(.headline)
                        if let id = job.profileUUID, let profile = store.profiles.first(where: { $0.id == id }) { Text("Profil: \(profile.name)").font(.subheadline) }
                        Text(job.status == "claimed" && !model.ownsClaim(job) ? "Wird bereits auf einem anderen iPhone bearbeitet" : "Auftrag ansehen und annehmen")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.buttonStyle(.bordered).disabled(model.busy || job.status == "claimed" && !model.ownsClaim(job))
            }
        }
    }

    @ViewBuilder private func activeJob(_ job: PhoneCompanionJob) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(job.title).font(.title2.bold())
            if let profile = activeProfile { Label(profile.name, systemImage: "person.crop.circle").font(.headline) }
            Text("Konto: \(store.account?.email ?? "")").font(.footnote).foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let expiry = PairingClient.date(job.expiresAt) ?? .distantPast
                Text(expiry > timeline.date ? "Gültig bis \(expiry.formatted(date: .omitted, time: .shortened))" : "Auftrag abgelaufen. Starte am Fernseher einen neuen Auftrag.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
            switch job.kind {
            case "import": importEditor(job)
            case "taste": tasteEditor(job)
            case "mood": moodEditor(job)
            case "review": reviewEditor(job)
            case "externalLink": linkEditor(job)
            case "subscription":
                Text("Wähle einen Tarif oder verwalte dein bestehendes App-Store-Abo.")
                Button("Tarife öffnen") { plans = true }.buttonStyle(.borderedProminent)
                if subscriptionChanged { Button("Änderung am TV bestätigen") { Task { _ = await model.complete(.object(["summary": .string("Tarif aktualisiert")])) } } }
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") { Link("App-Store-Abos verwalten", destination: url) }
            case "deleteAccount":
                Text("Die Löschung betrifft das gesamte Konto und alle Geräte. Sie kann nicht rückgängig gemacht werden.").foregroundStyle(.red)
                Button("Konto löschen …", role: .destructive) { deleteConfirm = true }.buttonStyle(.bordered)
            default:
                Text("Diese App-Version unterstützt den Auftrag nicht. Aktualisiere beide Apps oder brich den Auftrag ab.")
            }
            }.disabled(model.hasPendingCompletion)
            if model.hasPendingCompletion {
                Text("Der vorbereitete Abschluss wird unverändert erneut gesendet. So entstehen keine doppelten Bewertungen.").font(.caption).foregroundStyle(.secondary)
                Button("Abschluss erneut senden") { Task { _ = await model.complete(.object([:])) } }
            }
            Button("Auftrag abbrechen", role: .destructive) { Task { await model.cancel() } }.disabled(model.busy)
        }
        .padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .disabled(model.busy)
    }

    @ViewBuilder private func importEditor(_ job: PhoneCompanionJob) -> some View {
        Text("Wähle ratings.csv oder watched.csv aus dem Letterboxd-Export, oder den CSV-Export „Your Ratings“ von IMDb. Die Datei bleibt auf diesem Gerät.")
        Button("CSV-Datei auswählen") { showImporter = true }.buttonStyle(.borderedProminent)
        if let parsedImport {
            Text("\(parsedImport.source): \(parsedImport.matched.count) von \(parsedImport.totalRows) Einträgen im Filmkatalog erkannt.")
            if parsedImport.unmatchedCount > 0 { Text("\(parsedImport.unmatchedCount) Einträge liegen außerhalb des verfügbaren Katalogs, der Altersfreigabe oder sind doppelt. Sie werden ausgelassen.").font(.caption).foregroundStyle(.secondary) }
            Button("Bewertungen übernehmen und TV informieren") { Task { await applyImport(job) } }.disabled(parsedImport.matched.isEmpty)
        }
    }

    @ViewBuilder private func tasteEditor(_ job: PhoneCompanionJob) -> some View {
        Text("Beschreibe deinen Geschmack im Dialog. Erst mit „Ergebnis übernehmen“ wird er für dein Konto gespeichert.")
        Button("Geschmacksdialog öffnen") { openTaste() }.buttonStyle(.borderedProminent).disabled(activeProfile == nil)
        if tasteBaseline != nil {
            Text("\(tasteOperations.count) bestätigte Änderungen vorbereitet.").foregroundStyle(.secondary)
            Button("Ergebnis übernehmen und TV informieren") { Task {
                    do { _ = await model.complete(try result(summary: "Geschmack aktualisiert", operations: tasteOperations)) }
                    catch { localError = error.localizedDescription }
                } }
        }
    }

    @ViewBuilder private func moodEditor(_ job: PhoneCompanionJob) -> some View {
        TextField("Zum Beispiel: eine gemütliche Komödie, höchstens 90 Minuten", text: $moodText, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .onChange(of: moodText) { _, _ in moodResult = nil }
        Button(interpreting ? "Wunsch wird gelesen …" : "Wunsch auswerten") { Task { await interpretMood() } }
            .buttonStyle(.borderedProminent).disabled(interpreting || moodText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let moodResult {
            Text(moodResult.query.summary).font(.headline)
            Text(interpreting ? "Erste Stichworttreffer · Wunsch wird genauer verstanden …" : (moodResult.usedAppleIntelligence ? "Mit Apple Intelligence interpretiert." : "Mit Stichwörtern interpretiert. Apple Intelligence ist nicht verfügbar oder hat keine Antwort geliefert."))
                .font(.caption).foregroundStyle(.secondary)
            Text((moodResult.query.moods + moodResult.query.genres).joined(separator: ", "))
            if moodResult.query.maxRuntimeMinutes > 0 { Text("Höchstens \(moodResult.query.maxRuntimeMinutes) Minuten") }
            Button("Diese Stimmung auf dem TV verwenden") {
                Task {
                    do {
                        let query = try JSONValue.decode(JSONEncoder().encode(moodResult.query))
                        _ = await model.complete(.object(["summary": .string(moodResult.query.summary), "query": query, "usedAppleIntelligence": .bool(moodResult.usedAppleIntelligence)]))
                    } catch { localError = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder private func reviewEditor(_ job: PhoneCompanionJob) -> some View {
        if let filmID = job.filmID, let film = FilmIndex.film(filmID), let profile = activeProfile, profile.allows(film) {
            Text(film.title).font(.headline)
            Picker("Deine Bewertung", selection: $reviewRating) {
                Text("Nicht meins").tag(Interaction.ratedDown)
                Text("War okay").tag(Interaction.ratedOkay)
                Text("Mag ich").tag(Interaction.ratedUp)
                Text("Liebe ich").tag(Interaction.ratedLove)
            }.pickerStyle(.menu)
            TextField("Optionaler Review", text: $reviewText, axis: .vertical).lineLimit(4...10).textFieldStyle(.roundedBorder)
            Text("\(reviewText.count) / 5000 Zeichen").font(.caption).foregroundStyle(.secondary)
            Button("Bewertung und Review speichern") { Task { await applyReview(job, film: film, profile: profile) } }
                .buttonStyle(.borderedProminent).disabled(reviewText.count > 5000)
        } else { Text("Titel oder Profil ist nicht mehr verfügbar oder die Altersfreigabe passt nicht. Starte den Auftrag erneut.") }
    }

    @ViewBuilder private func linkEditor(_ job: PhoneCompanionJob) -> some View {
        if let url = safeURL(job.payload["url"]?.string ?? job.payload.string) {
            Text(url.host ?? "Externer Link").font(.headline)
            Text("Dieser Link öffnet eine externe Seite auf deinem iPhone.").foregroundStyle(.secondary)
            Button("Link öffnen") {
                UIApplication.shared.open(url) { opened in
                    Task { @MainActor in
                        if opened { _ = await model.complete(.object(["summary": .string("Link auf iPhone geöffnet")])) }
                        else { localError = "Der Link konnte nicht geöffnet werden." }
                    }
                }
            }.buttonStyle(.borderedProminent)
        } else { Text("Dieser Auftrag enthält keinen gültigen HTTPS-Link.").foregroundStyle(.red) }
    }

    private func resetDraft() {
        parsedImport = nil; fingerprint = nil; localError = nil; moodResult = nil
        moodText = model.active?.payload["query"]?.string ?? ""
        reviewText = ""; reviewRating = .ratedUp
        tasteDraft = nil; tasteBaseline = nil; tasteOperations = []; subscriptionChanged = false
        if let job = model.active, let filmID = job.filmID, let review = activeProfile?.reviews.first(where: { $0.filmID == filmID }) {
            reviewText = review.text; reviewRating = review.rating
        }
    }
    private func readCSV(_ selection: Result<URL, Error>) {
        do {
            let url = try selection.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 8_000_000 else { localError = "Die CSV-Datei ist zu groß. Verwende einen Bewertungen-Export unter 8 MB."; return }
            let data = try Data(contentsOf: url)
            guard let parsed = LibraryImport.parse(data) else { localError = "Die Datei wurde nicht erkannt. Erwartet wird eine CSV-Datei von Letterboxd oder IMDb mit Titel und Jahr."; return }
            guard let profile = activeProfile else { localError = "Das Profil ist nicht mehr vorhanden."; return }
            var distinct: [String: (Film, Interaction)] = [:]
            for (film, action) in parsed.matched where profile.allows(film) { distinct[film.id] = (film, action) }
            parsedImport = ImportResult(source: parsed.source, totalRows: parsed.totalRows, matched: distinct.keys.sorted().compactMap { distinct[$0] })
            fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            localError = nil
        } catch { localError = error.localizedDescription }
    }
    private func applyImport(_ job: PhoneCompanionJob) async {
        guard let parsedImport, let fingerprint, let profile = activeProfile, profile.id == job.profileUUID else { return }
        var draft = profile
        for (film, interaction) in parsedImport.matched { draft.learn(film, interaction, refitImmediately: false); draft.interactions[film.id] = interaction }
        var learning: [String: JSONValue] = [:]
        func deltas(_ before: [String: Double], _ after: [String: Double]) -> JSONValue {
            var result: [String: JSONValue] = [:]
            for key in Set(before.keys).union(after.keys) {
                let difference = (after[key] ?? 0) - (before[key] ?? 0)
                if difference != 0 { result[key] = .number(difference) }
            }
            return .object(result)
        }
        learning["affinity"] = deltas(profile.affinity, draft.affinity)
        learning["exposure"] = deltas(profile.exposure, draft.exposure)
        learning["signalTotal"] = .number(draft.signalTotal - profile.signalTotal)
        learning["signalN"] = .number(Double(draft.signalN - profile.signalN))
        let ratings = parsedImport.matched.map { film, action in JSONValue.object(["filmID": .string(film.id), "rating": .string(action.rawValue)]) }
        let operation = SyncOperation(kind: "importApply", profileID: profile.id.uuidString.lowercased(), payload: .object(["fingerprint": .string(fingerprint), "ratings": .array(ratings), "learning": .object(learning)]))
        do { _ = await model.complete(try result(summary: "\(parsedImport.matched.count) \(parsedImport.source)-Bewertungen übernommen", operations: [operation])) }
        catch { localError = error.localizedDescription }
    }
    private func openTaste() {
        guard let profile = activeProfile else { return }
        if tasteDraft == nil {
            let draft = AppStore(ephemeral: true)
            draft.profiles = [profile]; draft.activeProfileIDs = [profile.id]; draft.account = store.account
            draft.onboardingDone = true; draft.hasChosenViewers = true
            tasteDraft = draft; tasteBaseline = profile
        }
        tasteSheet = true
    }
    private func collectTaste() {
        guard let baseline = tasteBaseline, let profile = tasteDraft?.profiles.first else { return }
        do { tasteOperations = try changes(from: baseline, to: profile) }
        catch { localError = error.localizedDescription }
    }
    private func interpretMood() async {
        guard !interpreting, let job = model.active else { return }
        interpreting = true; defer { interpreting = false }
        let email = store.account?.email
        let profiles = activeProfile.map { [$0] } ?? store.activeProfiles
        let query = moodText
        moodResult = MoodSearch.quickSearch(query, profiles: profiles)
        guard MoodSearch.isAppleIntelligenceAvailable else { return }
        let response = await MoodSearch.search(query, profiles: profiles)
        guard !Task.isCancelled, email == store.account?.email, model.active?.id == job.id,
              store.signedIn, moodText == query else { return }
        moodResult = response
    }
    private func applyReview(_ job: PhoneCompanionJob, film: Film, profile: Profile) async {
        guard profile.id == job.profileUUID, profile.allows(film), reviewText.count <= 5000 else { return }
        var draft = profile
        draft.learn(film, reviewRating); draft.interactions[film.id] = reviewRating
        draft.reviews.removeAll { $0.filmID == film.id }
        draft.reviews.insert(Review(filmID: film.id, rating: reviewRating, text: reviewText.trimmingCharacters(in: .whitespacesAndNewlines), date: .now), at: 0)
        do { _ = await model.complete(try result(summary: "Bewertung und Review gespeichert", operations: try changes(from: profile, to: draft))) }
        catch { localError = error.localizedDescription }
    }
    private func changes(from before: Profile, to after: Profile) throws -> [SyncOperation] {
        let a = try JSONValue.decode(JSONEncoder().encode(before))
        let b = try JSONValue.decode(JSONEncoder().encode(after))
        return SnapshotChanges.operations(from: .object(["profiles": .array([a]), "pendingRatings": .array([])]), to: .object(["profiles": .array([b]), "pendingRatings": .array([])]))
    }
    private func result(summary: String, operations: [SyncOperation]) throws -> JSONValue {
        let encoded = try JSONValue.decode(JSONEncoder().encode(operations))
        return .object(["summary": .string(summary), "operations": encoded])
    }
    private func safeURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    private func deleteAccount() async {
        guard model.active?.kind == "deleteAccount", !model.busy else { return }
        if await model.complete(.object(["summary": .string("Kontolöschung auf angemeldetem iPhone bestätigt"), "confirmed": .bool(true)])) {
            do { try await store.deleteAccountConfirmed() }
            catch { localError = "Das Konto wurde nicht gelöscht: \(error.localizedDescription)" }
        }
    }
}
#endif
