import SwiftUI
import FilmSync

/// Ein Film, der geschaut wurde und noch bewertet werden soll („Wie war's gestern?“).
struct PendingRating: Codable, Hashable, Identifiable, Sendable {
    var filmID: String
    var profileIDs: [UUID]
    var date: Date
    var id: String { filmID + date.description }
}

enum SwipeAction: CaseIterable {
    case notToday, watchlist, alreadySeen, details

    var title: String {
        switch self {
        case .notToday: "Heute nicht"
        case .watchlist: "Merken"
        case .alreadySeen: "Schon gesehen"
        case .details: "Details"
        }
    }
    var symbol: String {
        switch self {
        case .notToday: "xmark"
        case .watchlist: "bookmark.fill"
        case .alreadySeen: "eye.fill"
        case .details: "info"
        }
    }
    var color: Color {
        switch self {
        case .notToday: Color(red: 1, green: 0.27, blue: 0.3)
        case .watchlist: Color(red: 0.2, green: 0.85, blue: 0.5)
        case .alreadySeen: Color(red: 0.62, green: 0.45, blue: 1)
        case .details: Color(red: 0.3, green: 0.6, blue: 1)
        }
    }
}

enum AuthError: LocalizedError {
    case invalidEmail, weakPassword, noAccount, unknownEmail, wrongPassword, emailTaken, wrongCredentials, offline
    case server(String)

    var errorDescription: String? {
        switch self {
        case .wrongCredentials: "E-Mail oder Passwort stimmt nicht."
        case .offline: "Keine Verbindung zum Server. Ohne Netz geht nur ein Konto, das auf diesem Gerät schon angemeldet war."
        case .server(let message): "Der Server meldet: \(message)"
        case .emailTaken: "Zu dieser E-Mail gibt es schon ein Konto. Melde dich damit an."
        case .invalidEmail: "Das sieht nicht nach einer E-Mail-Adresse aus."
        case .weakPassword: "Das Passwort braucht mindestens 8 Zeichen und eine Zahl."
        case .noAccount: "Auf diesem Gerät gibt es noch kein Konto. Erstelle zuerst eins."
        case .unknownEmail: "Zu dieser E-Mail gibt es auf diesem Gerät kein Konto."
        case .wrongPassword: "Das Passwort stimmt nicht."
        }
    }

    static func looksLikeEmail(_ mail: String) -> Bool {
        let parts = mail.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !mail.contains(" ")
    }
}

@Observable
final class AppStore {
    @ObservationIgnored private let suppressPersistence: Bool
    @ObservationIgnored var deviceSync: DeviceStateSync?
    var companionMoodQuery: MoodQuery?
    var syncStatus = ""
    var sessionEpoch = UUID()
    var profiles: [Profile] = []
    var activeProfileIDs: [UUID] = [] {
        didSet { if activeProfileIDs != oldValue { undoStack.removeAll() } }
    }
    /// Konto des Haushalts (Registrierung/Login), getrennt von den Profilen, die es enthält.
    var account: Account?
    var signedIn = false
    let purchases = PurchaseService()
    var onboardingDone = false
    var pendingRatings: [PendingRating] = []
    /// Zählt jede gespeicherte Änderung (Swipes, Chat, Kalibrierung), damit „Für dich“ sofort neu sortiert.
    private(set) var tasteRevision = 0
    /// Bewertung, die als Sheet angezeigt werden soll (nach dem Schauen).
    var ratingToPresent: PendingRating?
    /// Zählt Swipes auf der Startseite, die Gesten-Legende verschwindet nach ein paar Swipes.
    var homeSwipeCount = UserDefaults.standard.integer(forKey: "homeSwipeCount") {
        didSet { UserDefaults.standard.set(homeSwipeCount, forKey: "homeSwipeCount") }
    }

    /// „Heute nicht“ gilt bis Mitternacht, auch über einen Neustart hinweg, und für jede Runde
    /// (wer gerade schaut) getrennt. Wechselt die Runde, kommen ihre eigenen Skips zurück.
    var skippedToday: Set<String> = [] { didSet { storeSkipped() } }

    private static let skippedKey = "skippedToday"
    private var viewerGroup: String { activeProfileIDs.map(\.uuidString).sorted().joined(separator: ",") }
    private static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    private func storedSkips() -> [String: [String]] {
        guard !suppressPersistence, let saved = UserDefaults.standard.dictionary(forKey: Self.skippedKey),
              saved["day"] as? String == Self.today else { return [:] }
        return saved["groups"] as? [String: [String]] ?? [:]
    }

    private func storeSkipped() {
        guard !suppressPersistence else { return }
        var groups = storedSkips()
        groups[viewerGroup] = skippedToday.isEmpty ? nil : Array(skippedToday)
        UserDefaults.standard.set(["day": Self.today, "groups": groups], forKey: Self.skippedKey)
    }

    /// Die heutigen Skips der aktuellen Runde wiederherstellen.
    private func restoreSkipped() {
        let saved = Set(storedSkips()[viewerGroup] ?? [])
        if saved != skippedToday { skippedToday = saved }
    }

    private func forgetSkipped() {
        if !suppressPersistence { UserDefaults.standard.removeObject(forKey: Self.skippedKey) }
        skippedToday = []
    }

    // Sitzungszustand (nicht gespeichert)
    var runtimeFilter: RuntimeFilter? = nil
    var kindFilter: KindFilter = .all
    var hasChosenViewers = false
    /// Aktiver Tab (damit z. B. „Profile verwalten“ direkt zum Profil-Tab springt).
    var selectedTab = UserDefaults.standard.integer(forKey: "startTab")
    /// `played`: Der Schritt war „Abspielen“ dieses Films, nicht ein Wischen. „Für dich“ holt die Karte dann zurück.
    private var undoStack: [(profiles: [Profile], skipped: Set<String>, pending: [PendingRating], marks: [String: [String: WatchlistMark]], played: String?)] = []

    // MARK: Weiterschauen

    /// Erst ab diesem Anteil zählt ein Film (oder eine Folge) als gesehen. Davor bleibt er stehen
    /// und „Abspielen“ wird zu „Weiterschauen“ mit Fortschrittsbalken.
    static let watchedShare = 0.9
    private static let resumeKey = "resume"
    /// Angefangene Filme und Folgen: Sekunde und Anteil, auf diesem Gerät.
    private(set) var resume: [String: [Double]] = UserDefaults.standard.dictionary(forKey: AppStore.resumeKey) as? [String: [Double]] ?? [:] {
        didSet { if !suppressPersistence { UserDefaults.standard.set(resume, forKey: Self.resumeKey) } }
    }

    private func resumeKey(_ film: Film, _ episode: EpisodeRef?) -> String {
        episode.map { "\(film.id)|\($0.short)" } ?? film.id
    }

    /// Wie weit der Film (bei Serien die nächste Folge) schon geschaut ist, falls angefangen.
    func resumeShare(_ film: Film) -> Double? { resume[resumeKey(film, upNext(film))]?.last }
    func resumeSeconds(_ film: Film, episode: EpisodeRef?) -> Double? { resume[resumeKey(film, episode)]?.first }

    /// Player geschlossen: Ab `watchedShare` zählt es als gesehen, sonst merken, wo es weitergeht.
    /// Gibt zurück, ob es als gesehen zählt.
    @discardableResult
    func stoppedPlaying(_ film: Film, episode: EpisodeRef?, seconds: Double, duration: Double) -> Bool {
        let key = resumeKey(film, episode)
        guard duration.isFinite, duration > 0, seconds.isFinite else { return false }
        let share = min(seconds / duration, 1)
        if share >= Self.watchedShare {
            resume[key] = nil
            play(film, episode: episode)
            return true
        }
        if seconds > 3 { resume[key] = [seconds, share] }
        return false
    }

    // MARK: Watchlist abarbeiten

    /// Seit wann ein Titel gemerkt ist und wie oft er seitdem übersprungen wurde, je Profil.
    /// Liegt nur auf diesem Gerät, der Sync kennt die Felder nicht.
    struct WatchlistMark: Codable, Equatable {
        var added: Date?
        var passes = 0
    }
    private static let marksKey = "watchlistMarks"
    var watchlistMarks: [String: [String: WatchlistMark]] = {
        guard let data = UserDefaults.standard.data(forKey: AppStore.marksKey) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: WatchlistMark]].self, from: data)) ?? [:]
    }() {
        didSet {
            guard !suppressPersistence, let data = try? JSONEncoder().encode(watchlistMarks) else { return }
            UserDefaults.standard.set(data, forKey: Self.marksKey)
        }
    }
    /// Jede wievielte Karte von der Watchlist kommt.
    static let watchlistEvery = 5
    /// Karten seit der letzten Watchlist-Karte. Startet so, dass gleich die zweite Karte eine ist.
    var swipesSinceWatchlist = AppStore.watchlistEvery - 2
    /// Dreimal übersprungen: Die Startseite fragt, ob der Titel noch auf die Liste gehört.
    var watchlistQuestion: String?

    var activeProfiles: [Profile] { profiles.filter { activeProfileIDs.contains($0.id) } }
    /// The strictest active profile governs every shared content surface and playback.
    func allowsForViewers(_ film: Film) -> Bool {
        let viewers = activeProfiles
        return !viewers.isEmpty && viewers.allSatisfy { $0.allows(film) }
    }

    func ratingParticipants(_ pending: PendingRating) -> [Profile] {
        guard let film = FilmIndex.film(pending.filmID), allowsForViewers(film) else { return [] }
        return activeProfiles.filter { pending.profileIDs.contains($0.id) }
    }

    var visiblePendingRatings: [PendingRating] {
        pendingRatings.filter { !ratingParticipants($0).isEmpty }
    }
    var accent: Color { Theme.accent(for: activeProfiles.first) }

    // MARK: - Konto & Abo

    var subscription: Subscription? { account?.subscription }
    /// Abspielen braucht ein aktives Abo (auch in der Testphase). Trailer sind frei.
    var canPlay: Bool { subscription?.isActive == true }
    var profileLimit: Int { subscription?.plan.maxProfiles ?? Plan.familie.maxProfiles }
    var canAddProfile: Bool { profiles.count < profileLimit }
    /// Nach einem Wechsel in einen kleineren Tarif: Profile über dem Limit bleiben mit allem
    /// erhalten, sind aber pausiert, bis wieder Platz ist. Aktiv sind die ersten in der Liste.
    var pausedProfileIDs: Set<UUID> { Set(profiles.dropFirst(profileLimit).map(\.id)) }
    func isPaused(_ id: UUID) -> Bool { pausedProfileIDs.contains(id) }

    /// Pausiertes Profil aktiv schalten, dafür wird `replacing` pausiert (tauschen die Plätze).
    func unpause(_ id: UUID, replacing other: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == id }),
              let j = profiles.firstIndex(where: { $0.id == other }) else { return }
        profiles.swapAt(i, j)
        activeProfileIDs = activeProfileIDs.map { $0 == other ? id : $0 }
        save()
    }

    /// Neues Konto, online bei Supabase, damit es auf jedem Gerät klappt.
    /// Ohne Netz wird es erst nur auf diesem Gerät angelegt und beim nächsten Anmelden online nachgeholt.
    func register(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard AuthError.looksLikeEmail(mail) else { throw AuthError.invalidEmail }
        guard password.count >= 8, password.contains(where: \.isNumber) else { throw AuthError.weakPassword }
        guard db.record(mail) == nil else { throw AuthError.emailTaken }
        var session: CloudAccounts.Session?
        do { session = try await CloudAccounts.signUp(email: mail, password: password) }
        catch CloudAccounts.CloudError.alreadyRegistered { throw AuthError.emailTaken }
        catch CloudAccounts.CloudError.offline { session = nil }
        catch CloudAccounts.CloudError.server(let message) { throw AuthError.server(message) }
        // Ein anderes Konto war geladen: Es liegt sicher in der Datenbank, das neue fängt leer an.
        if account != nil { pushNow(); clearSession() }
        sessionEpoch = UUID()
        deviceSync?.stop(); deviceSync = nil
        cloudSession = session
        purchases.accountToken = session.flatMap { UUID(uuidString: $0.userID) }
        let salt = UUID().uuidString
        account = Account(email: mail, passwordHash: Account.hash(password, salt: salt), salt: salt,
                          created: .now, consented: .now, subscription: nil)
        signedIn = true
        #if !os(tvOS)
        beginPhoneSyncAfterLogin()
        #endif
        save(signedInNow: true)
    }

    /// Anmelden online bei Supabase und den Stand dieses Kontos laden, auf jedem Gerät.
    /// Ohne Netz zählt das Konto, das schon auf diesem Gerät gespeichert ist.
    func signIn(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespaces).lowercased()
        let local = db.record(mail)
        let localMatches = local.map { Account.hash(password, salt: $0.salt) == $0.passwordHash } ?? false
        var session: CloudAccounts.Session?
        var remote: Snapshot?
        do {
            let s = try await CloudAccounts.signIn(email: mail, password: password)
            session = s
            if let data = try await CloudAccounts.loadState(s) { remote = try? JSONDecoder().decode(Snapshot.self, from: data) }
        } catch CloudAccounts.CloudError.invalidCredentials {
            // Konto aus der Zeit vor den Online-Konten, nur auf diesem Gerät: jetzt einmal online anlegen.
            guard localMatches else { throw AuthError.wrongCredentials }
            session = try? await CloudAccounts.signUp(email: mail, password: password)
        } catch CloudAccounts.CloudError.offline {
            guard local != nil else { throw AuthError.offline }
            guard localMatches else { throw AuthError.wrongPassword }
        } catch CloudAccounts.CloudError.server(let message) {
            throw AuthError.server(message)
        }
        if account?.email != mail { pushNow(); clearSession() }
        // Online-Stand zuerst, sonst der Stand auf diesem Gerät, sonst ein frisches Konto.
        if let remote {
            apply(remote)
        } else if account?.email != mail, let local, let snap = try? JSONDecoder().decode(Snapshot.self, from: local.state) {
            apply(snap)
        }
        if account?.email != mail {
            account = Account(email: mail, passwordHash: "", salt: "", created: .now, consented: .now, subscription: nil)
        }
        // Online liegt kein Passwort-Hash, für das Anmelden ohne Netz bekommt das Gerät einen eigenen.
        let salt = UUID().uuidString
        account?.salt = salt
        account?.passwordHash = Account.hash(password, salt: salt)
        sessionEpoch = UUID()
        deviceSync?.stop(); deviceSync = nil
        cloudSession = session
        purchases.accountToken = session.flatMap { UUID(uuidString: $0.userID) }
        signedIn = true
        hasChosenViewers = profiles.count <= 1
        #if !os(tvOS)
        beginPhoneSyncAfterLogin()
        #endif
        save(signedInNow: true)
    }

    /// E-Mails aller Konten auf diesem Gerät, zum schnellen Zurückwechseln beim Anmelden.
    var savedAccounts: [String] { db.emails }

    /// Gerade online angemeldet (sonst nur auf dem Gerät).
    var isOnline: Bool { cloudSession != nil }

    func signOut() {
        pushNow()
        sessionEpoch = UUID()
        deviceSync?.stop(); deviceSync = nil
        #if os(tvOS)
        TVSessionStore.revokeCurrent()
        #endif
        cloudSession = nil
        CloudAccounts.signOut()
        signedIn = false
        hasChosenViewers = false
        undoStack = []; forgetSkipped()
        save()
    }

    /// DSGVO: Konto samt aller Profile, Bewertungen und Importe löschen, online und auf dem Gerät.
    func deleteAccount() {
        Task { do { try await deleteAccountConfirmed() } catch { syncStatus=error.localizedDescription } }
    }

    func deleteAccountConfirmed() async throws {
        let epoch=sessionEpoch
        guard signedIn, let session=cloudSession else { throw AuthError.offline }
        guard let fresh=await CloudAccounts.valid(session),epoch==sessionEpoch else { throw AuthError.wrongCredentials }
        try await CloudAccounts.deleteAccount(fresh)
        guard epoch==sessionEpoch else { return }
        sessionEpoch=UUID()
        deviceSync?.purge();deviceSync=nil
        cloudSession=nil
        if let email=account?.email { db.delete(email) }
        account=nil; signedIn=false
        resetAll()
    }

    /// Profile und Sitzung leeren (beim Wechsel zu einem anderen Konto).
    private func clearSession() {
        profiles = []; activeProfileIDs = []; onboardingDone = false; pendingRatings = []
        undoStack = []; runtimeFilter = nil; kindFilter = .all; hasChosenViewers = false; forgetSkipped()
    }

    func subscribe(_ sub: Subscription) {
        account?.subscription = sub
        // Weniger Profile im neuen Tarif: nichts löschen. Überzählige Profile werden pausiert,
        // und wer nicht mehr zusammen schauen darf, schaut allein weiter.
        activeProfileIDs.removeAll { isPaused($0) }
        if !sub.plan.allowsTogether, activeProfileIDs.count > 1 { activeProfileIDs = Array(activeProfileIDs.prefix(1)) }
        if activeProfileIDs.isEmpty, let first = profiles.first { activeProfileIDs = [first.id] }
        save()
        if sub.source == .appStore { Task { do { try await self.verifyStoreKitEntitlement() } catch { self.syncStatus = error.localizedDescription } } }
    }

    func setCanceled(_ canceled: Bool) {
        account?.subscription?.canceled = canceled
        save()
    }

    /// Abo mit dem App Store abgleichen (Kündigung oder Wechsel im Systemblatt).
    func syncSubscription() async {
        await purchases.load()
        guard purchases.storeKitAvailable, subscription?.source != .demo else { return }
        if let current = await purchases.currentSubscription() { subscribe(current) }
    }

    func chooseViewers(_ ids: [UUID]) {
        activeProfileIDs = profiles.map(\.id).filter { ids.contains($0) && !isPaused($0) }
        hasChosenViewers = true
        restoreSkipped()
        save()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    /// Ist der nächste Rückgängig-Schritt ein Abspielen, welcher Film?
    var undoPlayedFilm: String? { undoStack.last?.played }

    init(ephemeral: Bool = false) {
        suppressPersistence = ephemeral
        db = AccountDatabase(inMemory: ephemeral)
        if ephemeral { watchlistMarks = [:]; resume = [:]; return }
        load()
        if ProcessInfo.processInfo.arguments.contains("-seedDemo") { seedDemo() }
        if let k = UserDefaults.standard.string(forKey: "kind").flatMap(KindFilter.init) { kindFilter = k }
    }

    /// Startparameter `-seedDemo`: ein fertiges Profil, für Demos und Screenshots.
    func seedDemo() {
        cloudSession = nil
        resetAll()
        var demo = Profile(name: "Demo", colorIndex: 1, avatar: "scifi-0")
        for (id, i) in [("dune", Interaction.loved), ("interstellar", .loved), ("inception", .liked), ("the-batman", .liked),
                        ("barbie", .disliked), ("la-la-land", .disliked), ("parasite", .liked), ("mad-max-fury-road", .liked),
                        ("shrek", .unseen), ("joker", .liked), ("get-out", .liked), ("paddington-2", .disliked)] {
            if let f = FilmIndex.film(id) { demo.learn(f, i); demo.interactions[id] = i }
        }
        demo.progress["serie-dark"] = EpisodeRef(season: 1, episode: 4)
        // Eine Watchlist, die schon eine Weile wartet.
        watchlistMarks = [:]
        for (id, days) in [("prisoners", 150.0), ("arrival", 38.0), ("her", 9.0)] {
            demo.watchlist.append(id); demo.interactions[id] = .watchlist
            watchlistMarks[demo.id.uuidString, default: [:]][id] = WatchlistMark(added: .now.addingTimeInterval(-days * 86_400))
        }
        swipesSinceWatchlist = Self.watchlistEvery - 2
        profiles = [demo]
        let salt = "demo"
        account = Account(email: "demo@film.example", passwordHash: Account.hash("film-demo", salt: salt), salt: salt,
                          created: .now.addingTimeInterval(-40 * 86_400), consented: .now.addingTimeInterval(-40 * 86_400),
                          subscription: Subscription(plan: .familie, started: .now.addingTimeInterval(-40 * 86_400),
                                                     renews: .now.addingTimeInterval(20 * 86_400), trial: false, source: .demo))
        signedIn = true
        onboardingDone = true
        if DemoScreen.current == "who" { hasChosenViewers = false; activeProfileIDs = [demo.id]; save(); return }
        hasChosenViewers = true
        let args = ProcessInfo.processInfo.arguments
        activeProfileIDs = [demo.id]
        if args.contains("-pendingRating") {
            pendingRatings = [PendingRating(filmID: "dune-part-two", profileIDs: activeProfileIDs, date: .now.addingTimeInterval(-86_400))]
        }
        save()
    }

    // MARK: - Empfehlungen

    var recommendations: [Recommendation] { recommendations(limit: 3) }

    /// Dazwischen jede fünfte Karte von der Watchlist, die älteste zuerst. Sonst wird sie nur länger,
    /// weil immer etwas Neues besser passt.
    func recommendations(limit: Int) -> [Recommendation] {
        var recs = RecommendationEngine.recommendations(profiles: activeProfiles, runtime: runtimeFilter, kind: kindFilter,
                                                        skipped: skippedToday, limit: limit)
        let slot = max(0, Self.watchlistEvery - 1 - swipesSinceWatchlist)
        if slot < limit, let pick = watchlistPick(excluding: Set(recs.map(\.id))) {
            recs.insert(pick, at: min(slot, recs.count))
            recs = Array(recs.prefix(limit))
        }
        return recs
    }

    func recommendation(for film: Film) -> Recommendation {
        let profs = activeProfiles
        return Recommendation(
            film: film,
            match: RecommendationEngine.matchPercent(RecommendationEngine.groupScore(film, profiles: profs)),
            reason: RecommendationEngine.reason(for: film, profiles: profs),
            watchlistNote: watchlistNote(film))
    }

    func apply(_ action: SwipeAction, to film: Film) {
        guard action != .details, allowsForViewers(film) else { return }
        undoStack.append((profiles, skippedToday, pendingRatings, watchlistMarks, nil))
        if undoStack.count > 20 { undoStack.removeFirst() }
        let fromList = isOnWatchlist(film)
        swipesSinceWatchlist = fromList ? 0 : swipesSinceWatchlist + 1
        switch action {
        case .notToday:
            skippedToday.insert(film.id)
            if fromList {
                // Von der eigenen Liste übersprungen: Das zählt, aber es verlernt nichts.
                let passes = markWatchlist(film) { $0.passes += 1 }
                if passes >= 3 { watchlistQuestion = film.id }
            } else {
                record(film, .notToday, scale: 1 / Double(max(activeProfileIDs.count, 1)))
            }
        case .watchlist where fromList:
            // „Merken“ auf einer Karte von der Liste heißt: bleibt drauf, nur heute nicht.
            skippedToday.insert(film.id)
            markWatchlist(film) { $0.passes = 0 }
        case .watchlist:
            record(film, .watchlist)
            for id in activeProfileIDs { update(id) { if !$0.watchlist.contains(film.id) { $0.watchlist.insert(film.id, at: 0) } } }
            markWatchlist(film) { $0 = WatchlistMark(added: .now) }
        case .alreadySeen:
            record(film, .alreadySeen)
            for id in activeProfileIDs { update(id) { $0.watchlist.removeAll { $0 == film.id } } }
            pendingRatings.append(PendingRating(filmID: film.id, profileIDs: activeProfileIDs, date: .now))
        case .details: break
        }
        save()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        profiles = last.profiles
        skippedToday = last.skipped
        pendingRatings = last.pending
        watchlistMarks = last.marks
        if let q = watchlistQuestion, watchlistMarks.values.allSatisfy({ ($0[q]?.passes ?? 0) < 3 }) { watchlistQuestion = nil }
        save()
    }

    /// „Abspielen“: zählt für alle gerade schauenden Profile und erzeugt eine offene Bewertung.
    func play(_ film: Film, episode: EpisodeRef? = nil) {
        guard allowsForViewers(film) else { return }
        // Auch Abspielen lässt sich zurücknehmen: Der Film kommt dann wieder nach vorn.
        undoStack.append((profiles, skippedToday, pendingRatings, watchlistMarks, film.id))
        if undoStack.count > 20 { undoStack.removeFirst() }
        if film.isSeries {
            let ref = episode ?? nextEpisode(of: film) ?? film.firstEpisode
            let firstTime = activeProfiles.allSatisfy { $0.interactions[film.id] == nil }
            for id in activeProfileIDs {
                update(id) { p in
                    if let ref { p.progress[film.id] = film.episode(after: ref) ?? ref }
                    p.watchlist.removeAll { $0 == film.id }
                }
            }
            record(film, .played)
            // Bewertet wird die Serie einmal, nach der ersten Folge, nicht jede Folge.
            if firstTime { pendingRatings.append(PendingRating(filmID: film.id, profileIDs: activeProfileIDs, date: .now)) }
            save()
            return
        }
        record(film, .played)
        for id in activeProfileIDs { update(id) { $0.watchlist.removeAll { $0 == film.id } } }
        pendingRatings.removeAll { $0.filmID == film.id }
        pendingRatings.append(PendingRating(filmID: film.id, profileIDs: activeProfileIDs, date: .now))
        save()
    }

    func rate(_ pending: PendingRating, ratings: [UUID: Interaction], reviews: [UUID: String]) {
        guard let film = FilmIndex.film(pending.filmID) else { return }
        let participants = Set(ratingParticipants(pending).map(\.id))
        let permittedRatings = ratings.filter { participants.contains($0.key) }
        guard !permittedRatings.isEmpty else { return }
        for (pid, rating) in permittedRatings {
            update(pid) {
                $0.learn(film, rating)
                $0.interactions[film.id] = rating
                let text = reviews[pid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                $0.reviews.removeAll { $0.filmID == film.id }
                $0.reviews.insert(Review(filmID: film.id, rating: rating, text: text, date: .now), at: 0)
            }
        }
        let ratedIDs=Set(permittedRatings.keys)
        if let index=pendingRatings.firstIndex(where:{$0.id==pending.id}) {
            pendingRatings[index].profileIDs.removeAll { ratedIDs.contains($0) }
            if pendingRatings[index].profileIDs.isEmpty { pendingRatings.remove(at:index) }
        }
        save()
    }

    func dismissRating(_ pending: PendingRating) {
        pendingRatings.removeAll { $0.id == pending.id }
        save()
    }

    func toggleWatchlist(_ film: Film) {
        guard allowsForViewers(film) else { return }
        let inList = activeProfiles.contains { $0.watchlist.contains(film.id) }
        for id in activeProfileIDs {
            update(id) {
                if inList { $0.watchlist.removeAll { $0 == film.id } }
                else if !$0.watchlist.contains(film.id) { $0.watchlist.insert(film.id, at: 0); $0.learn(film, .watchlist) }
            }
        }
        if !inList { markWatchlist(film) { $0 = WatchlistMark(added: .now) } }
        save()
    }

    /// Nächste Folge für die gerade schauenden Profile (das erste Profil mit Fortschritt zählt).
    func nextEpisode(of film: Film) -> EpisodeRef? {
        activeProfiles.lazy.compactMap { $0.progress[film.id] }.first
    }

    /// Folge, die „Abspielen“ startet: weiterschauen oder ganz vorne anfangen.
    func upNext(_ film: Film) -> EpisodeRef? {
        film.isSeries ? (nextEpisode(of: film) ?? film.firstEpisode) : nil
    }

    func playLabel(_ film: Film) -> String {
        guard let ref = upNext(film) else { return resumeShare(film) == nil ? "Abspielen" : "Weiterschauen" }
        return nextEpisode(of: film) == nil ? "Ansehen · \(ref.short)" : "Weiterschauen · \(ref.short)"
    }

    /// Angefangene Serien der aktiven Profile, für „Weiterschauen“.
    var continueWatching: [(film: Film, next: EpisodeRef)] {
        var seen = Set<String>()
        return activeProfiles.flatMap { p in p.progress.map { ($0.key, $0.value) } }
            .compactMap { id, ref in
                guard seen.insert(id).inserted, let f = FilmIndex.film(id), allowsForViewers(f) else { return nil }
                return (f, ref)
            }
            .sorted { $0.film.title < $1.film.title }
    }

    func isOnWatchlist(_ film: Film) -> Bool { activeProfiles.contains { $0.watchlist.contains(film.id) } }

    /// Ändert die Markierung bei allen aktiven Profilen, die den Titel gemerkt haben. Gibt die höchste Zahl Überspringer zurück.
    @discardableResult
    private func markWatchlist(_ film: Film, _ change: (inout WatchlistMark) -> Void) -> Int {
        var most = 0
        for p in activeProfiles where p.watchlist.contains(film.id) {
            var mark = watchlistMarks[p.id.uuidString]?[film.id] ?? WatchlistMark()
            change(&mark)
            watchlistMarks[p.id.uuidString, default: [:]][film.id] = mark
            most = max(most, mark.passes)
        }
        return most
    }

    /// „Behalten“: Der Titel bleibt, die Zählung beginnt neu.
    func keepOnWatchlist(_ film: Film) {
        markWatchlist(film) { $0.passes = 0 }
        watchlistQuestion = nil
    }

    /// „Loslassen“: runter von allen Listen der Runde. Er kommt auch im Stapel nicht wieder.
    func letGo(_ film: Film) {
        for p in activeProfiles where p.watchlist.contains(film.id) {
            update(p.id) { $0.watchlist.removeAll { $0 == film.id } }
            watchlistMarks[p.id.uuidString]?[film.id] = nil
        }
        watchlistQuestion = nil
        save()
    }

    /// Seit wann der Titel bei den aktiven Profilen gemerkt ist (der früheste Eintrag zählt).
    /// Ohne Datum (vor dieser Funktion oder auf einem anderen Gerät gemerkt) gilt er als alt.
    func watchlistSince(_ film: Film) -> Date? {
        activeProfiles.filter { $0.watchlist.contains(film.id) }
            .compactMap { watchlistMarks[$0.id.uuidString]?[film.id]?.added }
            .min()
    }

    /// „Auf deiner Liste, seit 5 Wochen“, in der Runde „Auf Tubas Liste“ oder „Auf eurer Liste“.
    func watchlistNote(_ film: Film) -> String? {
        let owners = activeProfiles.filter { $0.watchlist.contains(film.id) }
        guard !owners.isEmpty else { return nil }
        let whose: String
        if activeProfiles.count == 1 { whose = "deiner" }
        else if owners.count == activeProfiles.count { whose = "eurer" }
        else {
            let name = owners[0].name
            whose = ["s", "x", "z", "ß"].contains(name.suffix(1).lowercased()) ? name + "’" : name + "s"
        }
        guard let since = watchlistSince(film) else { return "Auf \(whose) Liste" }
        return "Auf \(whose) Liste, \(Self.sinceText(since))"
    }

    static func sinceText(_ date: Date, now: Date = .now) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "seit heute"
        case 1: return "seit gestern"
        case ..<14: return "seit \(days) Tagen"
        case ..<61: return "seit \(days / 7) Wochen"
        case ..<365: return "seit \(days / 30) Monaten"
        case ..<730: return "seit über einem Jahr"
        default: return "seit über \(days / 365) Jahren"
        }
    }

    /// Der Titel, der als Nächstes von der Watchlist kommt: der am längsten gemerkte, der jetzt passt.
    func watchlistPick(excluding: Set<String> = []) -> Recommendation? {
        let group = activeProfiles
        guard !group.isEmpty else { return nil }
        let fits = Set(group.flatMap(\.watchlist)).compactMap(FilmIndex.film).filter { film in
            !film.comingSoon && !skippedToday.contains(film.id) && !excluding.contains(film.id)
                && group.allSatisfy { $0.allows(film) } && kindFilter.allows(film)
                && (runtimeFilter?.allows(film.runtime) ?? true)
                && !group.contains { $0.interactions[film.id].map { $0.excludesFromDeck && $0 != .watchlist } ?? false }
        }
        let scored = fits.map { ($0, watchlistSince($0) ?? .distantPast, RecommendationEngine.groupScore($0, profiles: group)) }
        guard let pick = scored.min(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 > $1.2 }) else { return nil }
        return Recommendation(film: pick.0, match: RecommendationEngine.matchPercent(pick.2),
                              reason: RecommendationEngine.reason(for: pick.0, profiles: group),
                              watchlistNote: watchlistNote(pick.0))
    }

    var watchlist: [Film] {
        var seen = Set<String>()
        return activeProfiles.flatMap(\.watchlist).filter { seen.insert($0).inserted }
            .compactMap(FilmIndex.film).filter(allowsForViewers)
    }

    private func record(_ film: Film, _ interaction: Interaction, scale: Double = 1) {
        for id in activeProfileIDs {
            update(id) {
                $0.learn(film, interaction, scale: scale)
                if interaction != .notToday { $0.interactions[film.id] = interaction }
            }
        }
    }

    // MARK: - Profile

    func update(_ id: UUID, _ change: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
    }

    @discardableResult
    func addProfile(name: String, colorIndex: Int, maxFSK: Int = 18, littleKid: Bool = false, avatar: String? = nil) -> UUID {
        undoStack.removeAll()
        var p = Profile(name: name, colorIndex: colorIndex, maxFSK: maxFSK, avatar: avatar)
        p.littleKid = littleKid
        profiles.append(p)
        save()
        return p.id
    }

    /// Name, Bild und Altersstufe ändern, der gelernte Geschmack bleibt.
    func editProfile(_ id: UUID, name: String, avatar: AvatarArt, maxFSK: Int, littleKid: Bool) {
        undoStack.removeAll()
        update(id) {
            $0.name = name; $0.avatar = avatar.id; $0.colorIndex = avatar.colorIndex
            $0.maxFSK = maxFSK; $0.littleKid = littleKid
        }
        save()
    }

    /// Das letzte Profil bleibt, ohne Profil gäbe es niemanden, für den die App vorschlägt.
    var canDeleteProfile: Bool { profiles.count > 1 }

    func deleteProfile(_ id: UUID) {
        undoStack.removeAll()
        profiles.removeAll { $0.id == id }
        activeProfileIDs.removeAll { $0 == id }
        if activeProfileIDs.isEmpty, let first = profiles.first { activeProfileIDs = [first.id] }
        save()
    }

    func calibrate(profile id: UUID, film: Film, _ interaction: Interaction) {
        guard let profile = profiles.first(where: { $0.id == id }), profile.allows(film) else { return }
        update(id) {
            $0.learn(film, interaction)
            $0.interactions[film.id] = interaction
        }
        save()
    }

    /// Import all ratings with the same learning rules, then refit and sync once.
    func importRatings(profile id: UUID, ratings: [(Film, Interaction)], unmatched: Int = 0) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), !ratings.isEmpty || unmatched > 0 else { return }
        var profile = profiles[index]
        let permittedRatings = ratings.filter { profile.allows($0.0) }
        guard !permittedRatings.isEmpty || unmatched > 0 else { return }
        let sync = deviceSync
        sync?.beginLocalBatch()
        defer { sync?.endLocalBatch() }
        var needsRefit = false
        for (film, interaction) in permittedRatings {
            profile.learn(film, interaction, refitImmediately: false)
            profile.interactions[film.id] = interaction
            needsRefit = needsRefit || interaction.signal != 0
            if let sync {
                profiles[index] = profile
                sync.captureLocalChanges()
            }
        }
        if needsRefit { profile.refit() }
        profile.importedCount += unmatched
        profiles[index] = profile
        sync?.captureLocalChanges()
        save()
    }

    /// Keep synced imports responsive and durable by yielding between small batches.
    func importRatingsResponsively(profile id: UUID, ratings: [(Film, Interaction)], unmatched: Int = 0) async -> Bool {
        let epoch = sessionEpoch
        guard profiles.contains(where: { $0.id == id }) else { return false }
        if ratings.isEmpty {
            importRatings(profile: id, ratings: [], unmatched: unmatched)
            return true
        }
        let batchSize = 16
        for start in stride(from: 0, to: ratings.count, by: batchSize) {
            guard !Task.isCancelled, epoch == sessionEpoch,
                  profiles.contains(where: { $0.id == id }) else { return false }
            let end = min(start + batchSize, ratings.count)
            importRatings(profile: id, ratings: Array(ratings[start..<end]),
                          unmatched: end == ratings.count ? unmatched : 0)
            if end < ratings.count {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
            }
        }
        return true
    }

    func finishOnboarding(profile id: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == id }) { profiles[index].onboardingComplete = true }
        onboardingDone = true
        activeProfileIDs = [id]
        hasChosenViewers = true
        save()
    }

    func resetAll() {
        profiles = []; activeProfileIDs = []; onboardingDone = false; pendingRatings = []
        if account == nil { signedIn = false }
        undoStack = []; runtimeFilter = nil; kindFilter = .all; hasChosenViewers = false; forgetSkipped()
        save()
    }


    func onlineSnapshotData() throws -> Data {
        let snap = Snapshot(profiles: profiles, activeProfileIDs: [], onboardingDone: onboardingDone,
                            pendingRatings: pendingRatings, account: account, signedIn: nil)
        return Self.onlineState(try JSONEncoder().encode(snap))
    }

    /// `fromOtherDevice: false` heißt: Der Server bestätigt nur, was dieses Gerät selbst geschickt hat.
    /// Dann bleiben „Rückgängig“ und der Kartenstapel unangetastet, sonst springt nach jedem Swipe alles.
    func applyCloudSnapshot(_ data: Data, fromOtherDevice: Bool = true) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let selection = activeProfileIDs, localAccount = account
        // Nur zuweisen, was sich wirklich geändert hat: Jede Zuweisung baut alle Ansichten neu auf,
        // die davon lesen, und der Abgleich läuft regelmäßig, meist ohne Neuigkeiten.
        let profilesChanged = profiles != snapshot.profiles
        if fromOtherDevice, profilesChanged { undoStack = [] }
        if profilesChanged { profiles = snapshot.profiles }
        if pendingRatings != snapshot.pendingRatings { pendingRatings = snapshot.pendingRatings }
        // Der Server leitet „fertig“ nur aus `onboardingComplete` ab, das ältere Profile nicht haben.
        // Ein fertiges Gerät mit Profilen fällt deshalb nie zurück ins Onboarding.
        let done = snapshot.onboardingDone || profiles.contains(where: \.onboardingComplete)
            || (onboardingDone && !profiles.isEmpty)
        let doneChanged = onboardingDone != done
        if doneChanged { onboardingDone = done }
        var merged = snapshot.account ?? localAccount
        if merged?.email == localAccount?.email {
            merged?.passwordHash = localAccount?.passwordHash ?? ""
            merged?.salt = localAccount?.salt ?? ""
        }
        if account != merged { account = merged }
        var viewers = selection.filter { id in profiles.contains { $0.id == id } && !isPaused(id) }
        if viewers.isEmpty, let first = profiles.first { viewers = [first.id] }
        if activeProfileIDs != viewers { activeProfileIDs = viewers }
        if activeProfileIDs.isEmpty { hasChosenViewers = false }
        let changed = profilesChanged || doneChanged || account != localAccount
        if fromOtherDevice && profilesChanged { tasteRevision += 1 }
        if !suppressPersistence && (changed || fromOtherDevice) { persistWithoutPush() }
    }

    private func persistWithoutPush() {
        let snap = Snapshot(profiles:profiles,activeProfileIDs:activeProfileIDs,onboardingDone:onboardingDone,pendingRatings:pendingRatings,account:account,signedIn:signedIn)
        guard let data=try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try? data.write(to:fileURL,options:.atomic)
        if let account { db.upsert(account,state:data,cloudUserID:cloudSession?.userID) }
    }

    func currentPhoneSessionToken() async throws -> String {
        guard signedIn, let session=cloudSession, account?.email == session.email else { throw AuthError.offline }
        let epoch=sessionEpoch
        guard let fresh=await CloudAccounts.valid(session), epoch==sessionEpoch, signedIn, account?.email==fresh.email else { throw AuthError.wrongCredentials }
        cloudSession=fresh
        return fresh.accessToken
    }

    var syncBaseRevision: Int? { deviceSync?.revision }

    #if !os(tvOS)
    /// Offline password login can identify an existing cloud account without
    /// possessing a currently usable credential. Authorization is still checked
    /// by currentPhoneSessionToken before every eventual network request.
    private func makePhoneSync() -> DeviceStateSync? {
        guard signedIn, let email = account?.email,
              let userID = cloudSession?.userID ?? db.record(email)?.cloudUserID else { return nil }
        purchases.accountToken = UUID(uuidString: userID)
        return DeviceStateSync(store: self, userID: userID, token: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.currentPhoneSessionToken()
        })
    }

    private func beginPhoneSyncAfterLogin() {
        guard !suppressPersistence, deviceSync == nil, let sync = makePhoneSync() else { return }
        deviceSync = sync
        sync.startRetrying()
        Task { try? await sync.start() }
    }
    #endif

    func installCloudSync() async throws {
        guard !suppressPersistence,signedIn else { return }
        if deviceSync != nil { return }
        #if os(tvOS)
        guard let credential=TVSessionStore.load() else { throw AuthError.wrongCredentials }
        let sync=DeviceStateSync(store:self,userID:credential.userID,token:{
            guard let active=TVSessionStore.load(),active.userID==credential.userID else { throw AuthError.wrongCredentials }
            return active.token
        })
        #else
        guard let sync = makePhoneSync() else { throw AuthError.offline }
        #endif
        deviceSync=sync
        do { try await sync.start() } catch {
            syncStatus = "Offline · Änderungen bleiben für dieses Konto vorgemerkt"
            sync.startRetrying()
            throw error
        }
    }

    func syncNow() async throws {
        if deviceSync==nil { try await installCloudSync() }
        guard let deviceSync else { throw AuthError.server("Der Fernseher-Dienst ist noch nicht erreichbar.") }
        deviceSync.captureLocalChanges()
        try await deviceSync.flush()
    }

    func refreshCloudState() async throws { try await syncNow(); try await deviceSync?.refresh() }

    func adoptTVAccount(_ data:Data,email:String) throws {
        sessionEpoch=UUID(); deviceSync?.stop();deviceSync=nil
        account=Account(email:email,passwordHash:"",salt:"",created:.now,consented:.now,subscription:nil)
        signedIn=true
        try applyCloudSnapshot(data)
        hasChosenViewers=profiles.count<=1
    }

    private func playbackKey(_ filmID:String,_ episode:EpisodeRef?) -> String {
        episode.map { "\(filmID)|\($0.season)|\($0.episode)" } ?? "\(filmID)|film"
    }
    func savePlaybackPosition(filmID:String,episode:EpisodeRef?,seconds:Double) {
        guard seconds.isFinite,seconds>=0 else { return }
        let key=playbackKey(filmID,episode)
        for id in activeProfileIDs { if let i=profiles.firstIndex(where:{$0.id==id}) {profiles[i].playbackPositions[key]=seconds} }
        save()
    }
    func playbackPosition(filmID:String,episode:EpisodeRef?) -> Double? {
        let key=playbackKey(filmID,episode)
        return activeProfiles.compactMap { $0.playbackPositions[key] }.max()
    }

    // MARK: - Persistenz
    // Der aktuelle Stand liegt als JSON-Datei vor (schneller Start), jedes Konto zusätzlich
    // in der Konten-Datenbank, damit man per Anmeldung zu ihm zurückkehren kann.

    private let db: AccountDatabase
    /// Online-Sitzung des angemeldeten Kontos (nil = nur auf dem Gerät, z. B. ohne Netz oder im Demo-Modus).
    private var cloudSession: CloudAccounts.Session?
    private var pushTask: Task<Void, Never>?

    struct Snapshot: Codable {
        var profiles: [Profile]
        var activeProfileIDs: [UUID]
        var onboardingDone: Bool
        var pendingRatings: [PendingRating]
        var account: Account?
        var signedIn: Bool?
        enum CodingKeys: String, CodingKey { case profiles, activeProfileIDs, onboardingDone, pendingRatings, account, signedIn }
        init(profiles:[Profile],activeProfileIDs:[UUID],onboardingDone:Bool,pendingRatings:[PendingRating],account:Account?,signedIn:Bool?) {
            self.profiles=profiles;self.activeProfileIDs=activeProfileIDs;self.onboardingDone=onboardingDone
            self.pendingRatings=pendingRatings;self.account=account;self.signedIn=signedIn
        }
        init(from decoder:any Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            profiles=try c.decode([Profile].self,forKey:.profiles)
            activeProfileIDs=try c.decodeIfPresent([UUID].self,forKey:.activeProfileIDs) ?? []
            onboardingDone=try c.decodeIfPresent(Bool.self,forKey:.onboardingDone) ?? false
            pendingRatings=try c.decodeIfPresent([PendingRating].self,forKey:.pendingRatings) ?? []
            account=try c.decodeIfPresent(Account.self,forKey:.account)
            signedIn=try c.decodeIfPresent(Bool.self,forKey:.signedIn)
        }
    }

    private var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "state.json")
    }

    /// Änderungen wirken sofort (tasteRevision), geschrieben wird kurz gesammelt danach.
    /// So hakt beim Wischen nichts, weil Datei und Datenbank nicht mitten in der Animation schreiben.
    func save(signedInNow: Bool = false) {
        tasteRevision += 1
        guard !suppressPersistence else { return }
        deviceSync?.captureLocalChanges()
        schedulePersist(signedInNow: signedInNow)
    }

    /// Wer gerade schaut: nur auf diesem Gerät, darum ohne Sync und ohne neuen Geschmacksstand.
    /// Die heutigen „Heute nicht“ dieser Runde kommen mit.
    func setViewers(_ ids: [UUID]) {
        activeProfileIDs = profiles.map(\.id).filter(ids.contains)
        restoreSkipped()
        guard !suppressPersistence else { return }
        schedulePersist()
    }

    private func schedulePersist(signedInNow: Bool = false) {
        persistTask?.cancel()
        if signedInNow { persist(signedInNow: true); return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Sofort schreiben, was noch aussteht (z. B. wenn die App in den Hintergrund geht).
    func flush() {
        guard !suppressPersistence else { return }
        guard let task = persistTask, !task.isCancelled else { return }
        task.cancel()
        persist()
    }

    private var persistTask: Task<Void, Never>?

    private func persist(signedInNow: Bool = false) {
        persistTask = nil
        let snap = Snapshot(profiles: profiles, activeProfileIDs: activeProfileIDs,
                            onboardingDone: onboardingDone, pendingRatings: pendingRatings,
                            account: account, signedIn: signedIn)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        if let account { db.upsert(account, state: data, signedInNow: signedInNow, cloudUserID: cloudSession?.userID) }
        if deviceSync == nil { schedulePush(data) }
    }

    /// Online speichern, kurz gesammelt: Viele Swipes hintereinander ergeben einen Upload.
    /// Der Upload gehört fest zu der Sitzung, in der gespeichert wurde, auch wenn danach das Konto wechselt.
    private func schedulePush(_ data: Data) {
        guard let session = cloudSession, signedIn else { return }
        pushTask?.cancel()
        let state = Self.onlineState(data)
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await self?.push(state, with: session)
        }
    }

    /// Sofort hochladen (vor Abmelden oder Kontowechsel).
    private func pushNow() {
        flush()
        if let deviceSync { deviceSync.captureLocalChanges(); Task { try? await deviceSync.flush() }; return }
        guard let session = cloudSession, account != nil,
              let data = try? JSONEncoder().encode(Snapshot(profiles: profiles, activeProfileIDs: activeProfileIDs,
                                                            onboardingDone: onboardingDone, pendingRatings: pendingRatings,
                                                            account: account, signedIn: true)) else { return }
        pushTask?.cancel()
        let state = Self.onlineState(data)
        Task { await push(state, with: session) }
    }

    private func push(_ state: Data, with session: CloudAccounts.Session) async {
        guard let fresh = await CloudAccounts.valid(session) else { return }
        if cloudSession?.email == fresh.email { cloudSession = fresh }
        try? await CloudAccounts.saveState(state, session: fresh)
    }

    /// Online liegt kein Passwort-Hash, das Passwort prüft Supabase selbst.
    private static func onlineState(_ data: Data) -> Data {
        guard var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return data }
        snap.account?.passwordHash = ""
        snap.account?.salt = ""
        snap.signedIn = nil
        return (try? JSONEncoder().encode(snap)) ?? data
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        apply(snap)
        // Wer schon ein eingerichtetes Profil hat, gehört nicht ins Onboarding (auch nicht, wenn ein
        // älterer Serverstand „nicht fertig“ gespeichert hat).
        if !onboardingDone && profiles.contains(where: { $0.signalCount >= 6 }) { onboardingDone = true }
        // Ältere Profile kennen `onboardingComplete` noch nicht: nachtragen, damit auch der Server es weiß.
        if onboardingDone {
            for i in profiles.indices where !profiles[i].onboardingComplete && profiles[i].signalCount > 0 {
                profiles[i].onboardingComplete = true
            }
        }
        signedIn = snap.signedIn ?? false
        // Online-Sitzung nach einem Neustart weiterverwenden, aber nur für genau dieses Konto.
        if signedIn, let s = CloudAccounts.storedSession, s.email == account?.email { cloudSession = s }
        // Älterer Stand von vor der Datenbank: Konto einmal übernehmen.
        if let account, db.record(account.email) == nil || cloudSession != nil {
            db.upsert(account, state: data, cloudUserID: cloudSession?.userID)
        }
    }

    private func apply(_ snap: Snapshot) {
        profiles = snap.profiles
        activeProfileIDs = snap.activeProfileIDs
        onboardingDone = snap.onboardingDone
        pendingRatings = snap.pendingRatings
        account = snap.account
        restoreSkipped()
        // Beim Start wählt man wie bei Netflix, wer schaut, außer es gibt nur ein Profil.
        hasChosenViewers = profiles.count <= 1
    }
}
