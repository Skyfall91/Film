import SwiftUI
import FoundationModels

/// Was das Modell aus einer Chat-Nachricht über den Geschmack lernt.
@Generable
struct TasteUpdate {
    @Guide(description: "Stimmungen oder Genres, die die Person MAG, nur aus der vorgegebenen Liste")
    var likes: [String]
    @Guide(description: "Stimmungen oder Genres, die die Person NICHT mag, nur aus der vorgegebenen Liste")
    var dislikes: [String]
    @Guide(description: "Kurze, freundliche deutsche Antwort in Du-Form (max. 2 Sätze), die bestätigt, was du gelernt hast. Keine Anrede, keine Begrüßung, keine gegenderten Personenbezeichnungen.")
    var reply: String
    @Guide(description: "Filmtitel, die die Person ausdrücklich nennt, so wie geschrieben. Leer, wenn keiner genannt wird.")
    var filmTitles: [String]
    @Guide(description: "Für jeden Filmtitel in derselben Reihenfolge: true, wenn die Person den Film mag, sonst false.")
    var filmLiked: [Bool]
}

/// Eine Vermutung, die die KI selbst formuliert.
@Generable
struct ChatGuess {
    @Guide(description: "Ein kurzer Satz auf Deutsch in Du-Form: eine Vermutung zur Stimmung, mit dem genannten Beispielfilm, plus eine knappe Rückfrage wie „Stimmt das?“. Keine anderen Filme, keine Anrede.")
    var text: String
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var fromUser: Bool
    var text: String
    var learned: [String] = []
    var question: TasteQuestion?
}

/// Dem Geschmacksprofil per Chat etwas beibringen: „Ich hasse Musicals, aber liebe ruhige Sci-Fi.“
struct TasteChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var thinking = false
    @State private var session: LanguageModelSession?
    @State private var lastUserText = ""
    /// Signal für Filme, die in der Antwort auf eine offene Frage genannt werden.
    @State private var lastFilmSignal: Interaction?
    /// Frage, die gerade auf Antwort wartet.
    @State private var openQuestion: TasteQuestion?
    @State private var multiSelection: Set<String> = []
    @State private var scaleValue: Double = 0
    /// Statt einer Kette von Entweder-oder-Fragen überlegt die KI selbst und stellt eine Vermutung auf.
    /// Höchstens drei pro Chat, nach zwei Fehlgriffen ist Schluss: Dann lieber selbst schreiben lassen.
    @State private var guesses = 0
    @State private var misses = 0
    @State private var rejectedMoods: Set<String> = []
    @FocusState private var focused: Bool

    private var profile: Profile? { store.profiles.first { $0.id == profileID } }
    private static let vocabulary = (FilmIndex.allMoods + FilmIndex.allGenres)

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            bubble(message)
                                .id(message.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }
                        if thinking {
                            HStack {
                                Image(systemName: "ellipsis")
                                    .symbolEffect(.variableColor.iterative, options: .repeating)
                                    .font(.title2)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .glassEffect(in: .capsule)
                                Spacer()
                            }
                            .id("thinking")
                            .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                // Neuer Inhalt (Nachricht, Antwortknöpfe, Tastatur) schiebt den Chat mit nach oben.
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: messages) { _, _ in scrollToBottom(proxy) }
                .onChange(of: openQuestion) { _, _ in scrollToBottom(proxy) }
                .onChange(of: thinking) { _, _ in scrollToBottom(proxy) }
                .onChange(of: focused) { _, isFocused in if isFocused { scrollToBottom(proxy, delay: 0.3) } }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Bring's mir bei")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .background(BlurredBackdrop(film: nil))
        }
        .onAppear(perform: start)
    }

    private func bubble(_ m: ChatMessage) -> some View {
        VStack(alignment: m.fromUser ? .trailing : .leading, spacing: 10) {
            HStack {
                if m.fromUser { Spacer(minLength: 50) }
                Text(m.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background {
                    if m.fromUser { RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.26)) }
                }
                .glassEffect(m.fromUser ? .identity : .regular, in: .rect(cornerRadius: 20))
                if !m.fromUser { Spacer(minLength: 50) }
            }
            if !m.learned.isEmpty {
                // Umbrechen statt quetschen: Jeder Chip bleibt eine Zeile, notfalls in mehreren Reihen.
                WrapLayout(spacing: 6) { ForEach(m.learned, id: \.self) { TagChip(text: $0).fixedSize() } }
                    .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
            }
            if let q = m.question, q == openQuestion {
                answerArea(q)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.fromUser ? .trailing : .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, delay: Double = 0.05) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder private func answerArea(_ q: TasteQuestion) -> some View {
        Group {
            switch q.kind {
            case .choice: answerButtons(q)
            case .multi: multiPicker(q)
            case .scale(let low, let high, _): scalePicker(q, low: low, high: high)
            case .open:
                HStack {
                    Label("Antworte unten im Textfeld", systemImage: "keyboard")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Überspringen") { skip(q) }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.glass)
                }
            }
        }
        .transition(.blurReplace)
    }

    /// Antworten untereinander über die volle Breite, alles lesbar, nichts abgeschnitten.
    private func answerButtons(_ q: TasteQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(q.answers) { a in
                Button { answer(q, a) } label: {
                    Text(a.label).font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }

    /// Mehrfachauswahl als umbrechende Chips.
    private func multiPicker(_ q: TasteQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WrapLayout(spacing: 8) {
                ForEach(q.answers) { a in
                    let on = multiSelection.contains(a.id)
                    Button {
                        withAnimation(.snappy) { if on { multiSelection.remove(a.id) } else { multiSelection.insert(a.id) } }
                    } label: {
                        Label(a.label, systemImage: on ? "checkmark" : "plus")
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .padding(.horizontal, 14).frame(minHeight: 40)
                            .foregroundStyle(on ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(on ? .regular.tint(store.accent).interactive() : .regular.interactive(), in: .capsule)
                }
            }
            Button {
                answerMulti(q)
            } label: {
                Text(multiSelection.isEmpty ? "Nichts davon" : "Weiter (\(multiSelection.count))")
                    .contentTransition(.numericText(value: Double(multiSelection.count)))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    /// Schieberegler zwischen zwei Polen.
    private func scalePicker(_ q: TasteQuestion, low: String, high: String) -> some View {
        VStack(spacing: 10) {
            Slider(value: $scaleValue, in: -1...1, step: 0.25)
                .sensoryFeedback(.selection, trigger: scaleValue)
            HStack {
                Text(low).opacity(scaleValue <= 0 ? 1 : 0.5)
                Spacer()
                Text(high).opacity(scaleValue >= 0 ? 1 : 0.5)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            Button {
                answerScale(q, low: low, high: high)
            } label: {
                Text("Passt so").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 22))
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Oder erzähl selbst, auch Namen …", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.headline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(store.accent)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func start() {
        guard messages.isEmpty else { return }
        let ai = MoodSearch.isAppleIntelligenceAvailable
        messages = [ChatMessage(fromUser: false, text: "Ein paar Fragen, dort, wo ich mir bei dir noch unsicher bin. Du kannst auch frei antworten.")]
        askNext()
        if ai {
            session = LanguageModelSession(instructions: """
                Du hilfst einem Film-Streamingdienst, den Geschmack einer Person zu lernen. \
                Ordne Aussagen ausschließlich diesen Begriffen zu: \(Self.vocabulary.joined(separator: ", ")). \
                Erfinde keine Filme. Antworte kurz auf Deutsch in Du-Form, ohne Anrede und ohne gegenderte Wörter.
                """)
        }
    }

    /// Nächste gezielte Frage, dort, wo das Profil am wenigsten weiß.
    /// Zuerst die vorbereiteten Fragen, danach eigene Vermutungen der KI statt Entweder-oder-Ketten.
    /// Gestellte Fragen werden pro Profil gemerkt, nichts wird doppelt gefragt.
    private func askNext() {
        guard let profile else { return }
        let history = TasteQuestions.asked(for: profileID)
        if let q = TasteQuestions.next(for: profile, asked: Set(history)) {
            present(q); return
        }
        guard misses < 2, guesses < 3 else { finish(); return }
        withAnimation(.smooth) { thinking = true }
        Task {
            let q = await makeGuess()
            withAnimation(.smooth) { thinking = false }
            if let q { present(q) } else { finish() }
        }
    }

    private func finish() {
        let text = misses >= 2
            ? "Okay, da lag ich daneben. Schreib mir einfach, worauf du Lust hast, dann lerne ich direkt daraus."
            : "Das war's von meiner Seite. Wenn dir noch was einfällt, schreib's einfach."
        guard messages.last?.text != text else { return }
        withAnimation(.smooth) {
            openQuestion = nil
            messages.append(ChatMessage(fromUser: false, text: text))
        }
    }

    /// Die KI überlegt selbst: Unter den besten Vorschlägen für dieses Profil die Stimmung,
    /// die am häufigsten vorkommt, über die das Profil aber noch nichts sicher weiß.
    /// Daraus wird eine Vermutung mit Beispielfilm, die man nur bestätigen oder verneinen muss.
    private func makeGuess() async -> TasteQuestion? {
        guard let profile else { return nil }
        let asked = Set(TasteQuestions.asked(for: profileID))
        let top = RecommendationEngine.recommendations(profiles: [profile], runtime: nil, skipped: [], limit: 15)
        var count: [String: Int] = [:]
        for r in top { for m in r.film.moods { count[m, default: 0] += 1 } }
        let open = count.keys.filter {
            !asked.contains("g:\($0)") && !rejectedMoods.contains($0) && abs(profile.affinity["m:\($0)"] ?? 0) < 1.2
        }
        guard let mood = open.max(by: { (count[$0]!, $1) < (count[$1]!, $0) }),
              let example = top.first(where: { $0.film.moods.contains(mood) })?.film else { return nil }
        let label = mood.moodLabel + "es"
        var text = "Ich glaube, dir liegt gerade etwas \(label), so wie „\(example.title)“. Stimmt das?"
        if let session, let r = try? await session.respond(
            to: "Formuliere eine Vermutung: Der Person liegt gerade etwas \(label). Beispielfilm: „\(example.title)“.",
            generating: ChatGuess.self).content, r.text.contains(example.title) {
            text = r.text.withoutDashes
        }
        guesses += 1
        return TasteQuestion(id: "g:\(mood)", text: text, answers: [
            .init(label: "Ja, genau", affinity: ["m:\(mood)": 1.2]),
            .init(label: "Eher nicht", affinity: ["m:\(mood)": -0.8])
        ])
    }

    private func present(_ q: TasteQuestion) {
        TasteQuestions.remember(q, for: profileID)
        withAnimation(.smooth) {
            openQuestion = q
            messages.append(ChatMessage(fromUser: false, text: q.text, question: q))
        }
    }

    private func answer(_ q: TasteQuestion, _ a: TasteQuestion.Answer) {
        if q.id.hasPrefix("g:") {
            if a.affinity.values.contains(where: { $0 < 0 }) {
                misses += 1
                rejectedMoods.insert(String(q.id.dropFirst(2)))
            } else {
                misses = 0
            }
        }
        commit(label: a.label, affinity: a.affinity)
    }

    private func answerMulti(_ q: TasteQuestion) {
        let chosen = q.answers.filter { multiSelection.contains($0.id) }
        let combined = chosen.reduce(into: [String: Double]()) { acc, a in
            for (k, v) in a.affinity { acc[k, default: 0] += v }
        }
        multiSelection = []
        commit(label: chosen.isEmpty ? "Nichts davon" : chosen.map(\.label).formatted(.list(type: .and)), affinity: combined)
    }

    private func answerScale(_ q: TasteQuestion, low: String, high: String) {
        guard case .scale(_, _, let weights) = q.kind else { return }
        let v = scaleValue
        let label = abs(v) < 0.2 ? "Irgendwo dazwischen" : (v < 0 ? low : high) + (abs(v) < 0.6 ? ", eher" : "")
        scaleValue = 0
        commit(label: label, affinity: weights.mapValues { $0 * v * 1.5 })
    }

    private func skip(_ q: TasteQuestion) {
        withAnimation(.smooth) { openQuestion = nil }
        askNext()
    }

    /// Antwort ins Profil schreiben, als Blase zeigen, nächste Frage stellen.
    private func commit(label: String, affinity: [String: Double]) {
        var chips: [String] = []
        store.update(profileID) { p in
            for (key, delta) in affinity {
                p.nudge(key, by: delta)
                if abs(delta) >= 0.9 { chips.append("\(delta > 0 ? "+" : "−") \(String(key.dropFirst(2)).moodLabel)") }
            }
        }
        store.save()
        withAnimation(.smooth) {
            openQuestion = nil
            messages.append(ChatMessage(fromUser: true, text: label, learned: chips.uniqued))
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            askNext()
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        input = ""
        lastUserText = text
        if case .open(let signal) = openQuestion?.kind { lastFilmSignal = signal } else { lastFilmSignal = nil }
        // Freie Antwort auf die offene Frage: Kontext mitgeben, damit „ja, total“ verstanden wird.
        let prompt = openQuestion.map { "Meine Frage war: „\($0.text)“ Antwort: \(text)" } ?? text
        withAnimation(.smooth) { openQuestion = nil; messages.append(ChatMessage(fromUser: true, text: text)); thinking = true }
        Task {
            let update = await interpret(prompt)
            var learned = apply(update)
            // Genannte Filme, die nicht im Katalog sind: bei Wikidata nachschlagen und trotzdem lernen.
            let unknown = unknownFilms(update)
            if !unknown.isEmpty {
                let found = await lookUp(unknown)
                learned += found
            }
            let reply = learned.isEmpty
                ? "Dazu habe ich nichts Konkretes gefunden. Nenn mir gern Genres, Stimmungen oder Namen aus Regie und Schauspiel."
                : (update.reply.isEmpty ? "Notiert. Das fließt ab jetzt in deine Vorschläge ein." : update.reply.withoutDashes)
            withAnimation(.smooth) {
                thinking = false
                messages.append(ChatMessage(fromUser: false, text: reply, learned: learned.uniqued))
            }
            try? await Task.sleep(for: .milliseconds(600))
            askNext()
        }
    }

    private func interpret(_ text: String) async -> TasteUpdate {
        if let session {
            if let r = try? await session.respond(to: text, generating: TasteUpdate.self).content,
               TasteWriter.isNeutral("Du " + r.reply) || r.reply.isEmpty {
                return r
            } else if let r = try? await session.respond(to: text, generating: TasteUpdate.self).content {
                return TasteUpdate(likes: r.likes, dislikes: r.dislikes, reply: "", filmTitles: r.filmTitles, filmLiked: r.filmLiked)
            }
        }
        return Self.keywordUpdate(text)
    }

    /// Wendet die Änderung aufs Profil an und liefert Chips wie „+ Ruhig“, „− Musical“.
    private func apply(_ update: TasteUpdate) -> [String] {
        let vocab = Dictionary(uniqueKeysWithValues: Self.vocabulary.map { ($0.lowercased(), $0) })
        func key(_ term: String) -> String? {
            guard let v = vocab[term.lowercased()] else { return nil }
            return FilmIndex.allGenres.contains(v) ? "g:\(v)" : "m:\(v)"
        }
        var chips: [String] = []
        // Namen aus Regie und Schauspiel direkt aus dem Text, unabhängig von der KI.
        let people = Self.peopleUpdate(lastUserText)
        // Bei offenen Fragen: genannte Filme mit dem Signal der Frage lernen.
        let films = lastFilmSignal.map { signal in TasteQuestions.films(in: lastUserText).map { ($0, signal) } } ?? []
        store.update(profileID) { p in
            for (film, signal) in films {
                p.learn(film, signal)
                p.interactions[film.id] = signal
                chips.append("\(signal.signal > 0 ? "+" : "−") \(film.title)")
            }
            for (key, name, delta) in people {
                p.nudge(key, by: delta)
                chips.append("\(delta > 0 ? "+" : "−") \(name)")
            }
            for term in update.likes { if let k = key(term) { p.nudge(k, by: 1.5); chips.append("+ \(term.moodLabel)") } }
            for term in update.dislikes { if let k = key(term) { p.nudge(k, by: -1.5); chips.append("− \(term.moodLabel)") } }
            p.importedCount += chips.count
        }
        store.save()
        return chips
    }

    /// Titel aus der Antwort, die der Katalog nicht kennt (mit „mag ich“ oder „mag ich nicht“).
    private func unknownFilms(_ update: TasteUpdate) -> [(String, Bool)] {
        let known = TasteQuestions.films(in: lastUserText)
        return update.filmTitles.enumerated().compactMap { i, title in
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, TasteQuestions.films(in: t).isEmpty,
                  !known.contains(where: { $0.title.localizedCaseInsensitiveContains(t) || t.localizedCaseInsensitiveContains($0.title) })
            else { return nil }
            let liked = i < update.filmLiked.count ? update.filmLiked[i] : (lastFilmSignal?.signal ?? 1) > 0
            return (t, liked)
        }
    }

    /// Wikidata fragen und den Film wie einen bewerteten Katalogfilm lernen.
    private func lookUp(_ films: [(String, Bool)]) async -> [String] {
        var chips: [String] = []
        for (title, liked) in films.prefix(3) {
            guard let film = await WikidataLookup.find(title) else {
                withAnimation(.smooth) {
                    messages.append(ChatMessage(fromUser: false, text: "„\(title)“ konnte ich gerade nirgends finden, magst du mir sagen, was dir daran gefällt?"))
                }
                continue
            }
            let signal: Interaction = liked ? (lastFilmSignal == .loved ? .loved : .liked) : .disliked
            store.update(profileID) { $0.learn(external: film, signal) }
            let traits = (film.moods.prefix(2).map(\.moodLabel) + film.genres.prefix(1)).map { "\(liked ? "+" : "−") \($0)" }
            chips.append("\(liked ? "+" : "−") \(film.title)")
            chips += traits
            if !film.director.isEmpty { chips.append("\(liked ? "+" : "−") \(film.director)") }
        }
        store.save()
        return chips
    }

    /// Personen pro Satzteil; Verneinung im selben Satzteil dreht das Vorzeichen.
    static func peopleUpdate(_ text: String) -> [(String, String, Double)] {
        let parts = text.split(whereSeparator: { ",.;!".contains($0) }).flatMap { $0.components(separatedBy: " aber ") }
        var result: [(String, String, Double)] = []
        for part in parts {
            let negative = ["nicht", "kein", "hasse", "nervt", "nerven", "langweil", "furchtbar"].contains { part.lowercased().contains($0) }
            for person in TasteQuestions.people(in: String(part)) where !result.contains(where: { $0.0 == person.key }) {
                result.append((person.key, person.name, negative ? -2.0 : 2.5))
            }
        }
        return result
    }

    /// Fallback ohne KI: Satzteile mit Verneinung → mag ich nicht, sonst → mag ich.
    static func keywordUpdate(_ text: String) -> TasteUpdate {
        var likes: [String] = [], dislikes: [String] = []
        let parts = text.lowercased().split(whereSeparator: { ",.;!".contains($0) }).flatMap { $0.components(separatedBy: " aber ") }
        for part in parts {
            let q = MoodSearch.keywordQuery(part)
            let terms = q.moods + q.genres
            let negative = ["nicht", "kein", "hasse", "nervt", "nerven", "langweil", "furchtbar", "mag ich nicht"].contains { part.contains($0) }
            if negative { dislikes += terms } else { likes += terms }
        }
        // Titel in Anführungszeichen gelten ohne KI als genannte Filme.
        let negativeWords = ["nicht", "kein", "hasse", "nervt", "langweil", "furchtbar"]
        var titles: [String] = [], liked: [Bool] = []
        for match in text.matches(of: /[„"“‚']([^„"“”‚'‘]{2,60})[“"”‘']/) {
            titles.append(String(match.1))
            liked.append(!negativeWords.contains { text.lowercased().contains($0) })
        }
        return TasteUpdate(likes: Array(Set(likes)), dislikes: Array(Set(dislikes)), reply: "", filmTitles: titles, filmLiked: liked)
    }
}

private extension Array where Element: Hashable {
    /// Reihenfolge behalten, Doppelte weglassen („+ Lustig“ nur einmal).
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
