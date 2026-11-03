import SwiftUI

// MARK: - Farben und Zeichen für Genres und Stimmungen

enum GuideStyle {
    static func genreSymbol(_ genre: String) -> String {
        switch genre {
        case "Action": "flame.fill"
        case "Abenteuer": "map.fill"
        case "Animation": "paintpalette.fill"
        case "Komödie": "face.smiling.inverse"
        case "Krimi": "magnifyingglass"
        case "Thriller": "bolt.fill"
        case "Drama": "theatermasks.fill"
        case "Fantasy": "wand.and.stars"
        case "Science-Fiction": "sparkles"
        case "Horror": "moon.stars.fill"
        case "Romanze": "heart.fill"
        case "Mystery": "questionmark.circle.fill"
        case "Familie": "figure.2.and.child.holdinghands"
        case "Biografie": "person.fill"
        case "Historie": "building.columns.fill"
        case "Krieg": "shield.fill"
        case "Musik": "music.note"
        case "Sport": "figure.run"
        case "Musical": "music.mic"
        case "Dokumentarfilm": "video.fill"
        case "Western": "sun.dust.fill"
        default: "film.fill"
        }
    }

    static func genreColor(_ genre: String) -> Color {
        switch genre {
        case "Action": Color(red: 1.0, green: 0.45, blue: 0.2)
        case "Abenteuer": Color(red: 0.3, green: 0.75, blue: 0.4)
        case "Animation": Color(red: 1.0, green: 0.5, blue: 0.75)
        case "Komödie": Color(red: 1.0, green: 0.8, blue: 0.2)
        case "Krimi": Color(red: 0.5, green: 0.6, blue: 0.75)
        case "Thriller": Color(red: 0.95, green: 0.25, blue: 0.3)
        case "Drama": Color(red: 0.65, green: 0.45, blue: 0.95)
        case "Fantasy": Color(red: 0.55, green: 0.4, blue: 1.0)
        case "Science-Fiction": Color(red: 0.25, green: 0.8, blue: 0.95)
        case "Horror": Color(red: 0.6, green: 0.15, blue: 0.25)
        case "Romanze": Color(red: 1.0, green: 0.4, blue: 0.55)
        case "Mystery": Color(red: 0.35, green: 0.45, blue: 0.9)
        case "Familie": Color(red: 0.4, green: 0.85, blue: 0.7)
        case "Biografie": Color(red: 0.85, green: 0.65, blue: 0.45)
        case "Historie": Color(red: 0.75, green: 0.6, blue: 0.35)
        case "Krieg": Color(red: 0.5, green: 0.55, blue: 0.4)
        case "Musik", "Musical": Color(red: 0.9, green: 0.35, blue: 0.9)
        case "Sport": Color(red: 0.2, green: 0.65, blue: 1.0)
        default: Color(white: 0.6)
        }
    }

    static func moodSymbol(_ mood: String) -> String {
        switch mood {
        case "spannend": "bolt.fill"
        case "lustig": "face.smiling.inverse"
        case "gefühlvoll": "heart.fill"
        case "gruselig": "moon.stars.fill"
        case "nachdenklich": "brain.head.profile"
        case "gemütlich": "cup.and.saucer.fill"
        case "wendungsreich": "arrow.triangle.branch"
        case "bildgewaltig": "mountain.2.fill"
        case "romantisch": "heart.circle.fill"
        case "episch": "crown.fill"
        case "actionreich": "flame.fill"
        case "familienfreundlich": "figure.2.and.child.holdinghands"
        case "leicht": "cloud.sun.fill"
        case "intensiv": "waveform.path.ecg"
        case "inspirierend": "star.fill"
        case "schräg": "tornado"
        case "düster": "cloud.moon.fill"
        case "ruhig": "leaf.fill"
        case "bunt": "paintpalette.fill"
        case "musikalisch": "music.note"
        default: "sparkle"
        }
    }

    static func moodColor(_ mood: String) -> Color {
        switch mood {
        case "spannend", "actionreich", "intensiv": Color(red: 0.95, green: 0.3, blue: 0.25)
        case "lustig", "leicht": Color(red: 1.0, green: 0.78, blue: 0.2)
        case "gefühlvoll", "romantisch": Color(red: 1.0, green: 0.42, blue: 0.6)
        case "gruselig", "düster": Color(red: 0.5, green: 0.3, blue: 0.75)
        case "nachdenklich", "ruhig": Color(red: 0.35, green: 0.6, blue: 0.95)
        case "gemütlich", "familienfreundlich": Color(red: 0.95, green: 0.6, blue: 0.3)
        case "wendungsreich", "schräg": Color(red: 0.3, green: 0.8, blue: 0.75)
        case "bildgewaltig", "episch": Color(red: 0.4, green: 0.55, blue: 1.0)
        case "inspirierend", "bunt", "musikalisch": Color(red: 0.85, green: 0.45, blue: 0.95)
        default: Color(white: 0.6)
        }
    }
}

// MARK: - Onboarding

/// Kennenlernen in vier kurzen Schritten: Genres, ein paar Lieblingsfilme, die eigenen Dienste.
/// Daraus entstehen „Für dich“ und die Reihenfolge der Dienste auf jeder Titelseite.
struct GuideOnboarding: View {
    @Environment(GuideStore.self) private var store
    @State private var step = Step.welcome

    enum Step: Int, CaseIterable, Comparable {
        case welcome, genres, films, services, ready
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch step {
            case .welcome:
                GuideWelcome { go(.genres) }
                    .transition(.opacity)
            case .genres:
                GuideGenreStep { go(.films) }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .films:
                GuideFilmPickStep { go(.services) }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .services:
                GuideServiceStep { go(.ready) }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .ready:
                GuideReadyStep {
                    withAnimation(.smooth) { store.onboarded = true }
                }
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top) {
            if step != .welcome && step != .ready {
                HStack(spacing: 14) {
                    Button {
                        if let previous = Step(rawValue: step.rawValue - 1) { go(previous) }
                    } label: {
                        Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Zurück")
                    progress
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach([Step.genres, .films, .services], id: \.self) { s in
                Capsule()
                    .fill(s <= step ? Color.white : Color.white.opacity(0.18))
                    .frame(height: 5)
            }
        }
        .animation(.smooth, value: step)
    }

    private func go(_ next: Step) {
        withAnimation(.smooth(duration: 0.45)) { step = next }
    }
}

/// Großer Knopf unten auf jedem Schritt.
private struct OnboardingButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white.opacity(enabled ? 1 : 0.35), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: enabled)
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }
}

// MARK: Willkommen

private struct GuideWelcome: View {
    let next: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            PosterWall()
            LinearGradient(stops: [.init(color: .clear, location: 0.2),
                                   .init(color: .black.opacity(0.85), location: 0.55),
                                   .init(color: .black, location: 0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "popcorn.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.28))
                Text("Finde deinen\nnächsten Film.")
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Alle Filme und Serien an einem Ort, passend zu deinem Geschmack, und mit einem Tipp siehst du, wo sie laufen.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 92)
            .frame(maxWidth: .infinity, alignment: .leading)
            OnboardingButton(title: "Los geht's", action: next)
                .accessibilityIdentifier("onboarding.start")
        }
    }
}

// MARK: Genres

private struct GuideGenreStep: View {
    @Environment(GuideStore.self) private var store
    let next: () -> Void

    private static let genres = ["Action", "Komödie", "Drama", "Thriller", "Science-Fiction", "Fantasy", "Horror", "Romanze",
                                 "Krimi", "Abenteuer", "Animation", "Mystery", "Familie", "Biografie", "Historie", "Musik"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StepHeader(title: "Was schaust du gern?",
                               subtitle: "Tippe alles an, was dich reizt. Du kannst es später jederzeit ändern.")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Self.genres, id: \.self) { genre in
                            tile(genre)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            OnboardingButton(title: store.likedGenres.isEmpty ? "Überspringen" : "Weiter", action: next)
        }
    }

    private func tile(_ genre: String) -> some View {
        let selected = store.likedGenres.contains(genre)
        let color = GuideStyle.genreColor(genre)
        return Button {
            withAnimation(.snappy) { store.toggleGenre(genre) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: GuideStyle.genreSymbol(genre))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selected ? Color.black : color)
                    .frame(width: 28)
                Text(genre)
                    .font(.headline)
                    .foregroundStyle(selected ? Color.black : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(Color.black)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 60)
            .background(selected ? color : color.opacity(0.14), in: .rect(cornerRadius: 18))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Lieblingsfilme

private struct GuideFilmPickStep: View {
    @Environment(GuideStore.self) private var store
    @State private var pool: [Film] = []
    let next: () -> Void

    private var chosen: Int { pool.filter { store.isLiked($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StepHeader(title: "Welche davon magst du?",
                               subtitle: "Tippe ein paar Filme an, die dir gefallen haben. Je mehr, desto besser passen die Vorschläge.")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(pool) { film in
                            poster(film)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            OnboardingButton(title: chosen == 0 ? "Überspringen" : chosen < 3 ? "Weiter (\(chosen) gewählt)" : "Weiter", action: next)
        }
        .onAppear { if pool.isEmpty { pool = Self.makePool(genres: store.likedGenres) } }
    }

    private func poster(_ film: Film) -> some View {
        let selected = store.isLiked(film)
        return Button {
            withAnimation(.snappy) { store.toggleLiked(film) }
        } label: {
            PosterView(film: film, cornerRadius: 12, showsBadge: false, size: .small)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(selected ? 0.35 : 0))
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "heart.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 30, height: 30)
                            .background(Color(red: 1.0, green: 0.35, blue: 0.5), in: .circle)
                            .padding(6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: selected ? 3 : 0)
                }
                .scaleEffect(selected ? 0.95 : 1)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel(film.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Bekannte Filme zuerst, die gewählten Genres bevorzugt, quer durch die Jahrzehnte.
    static func makePool(genres: Set<String>) -> [Film] {
        let films = FilmIndex.all.filter { !$0.isSeries && !$0.comingSoon && !$0.niche }
        let scored = films.map { film -> (Film, Double) in
            let known = FilmIndex.familiarity[film.id] ?? 0.5
            let match = Double(film.genres.filter { genres.contains($0) }.count)
            return (film, known * (1 + 0.7 * match) * Double.random(in: 0.8...1.2))
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(30).map(\.0))
    }
}

// MARK: Dienste

private struct GuideServiceStep: View {
    @Environment(GuideStore.self) private var store
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StepHeader(title: "Wo schaust du?",
                               subtitle: "Deine Dienste stehen auf jeder Titelseite ganz oben, und du kannst nach ihnen filtern.")
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(WatchProvider.allCases) { provider in
                            tile(provider)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
            OnboardingButton(title: store.services.isEmpty ? "Überspringen" : "Weiter", action: next)
        }
    }

    private func tile(_ provider: WatchProvider) -> some View {
        let selected = store.services.contains(provider)
        return Button {
            withAnimation(.snappy) { store.toggleService(provider) }
        } label: {
            HStack(spacing: 10) {
                GuideProviderMark(provider: provider, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(provider.kindNote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.3))
            }
            .foregroundStyle(Color.white)
            .padding(12)
            .background(Color.white.opacity(selected ? 0.18 : 0.07), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(selected ? 0.5 : 0), lineWidth: 1.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Fertig

private struct GuideReadyStep: View {
    @Environment(GuideStore.self) private var store
    @State private var shown = false
    let done: () -> Void

    var body: some View {
        let picks = Array(store.forYou(limit: 3))
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, film in
                    PosterView(film: film, cornerRadius: 16, showsBadge: false)
                        .frame(width: 150)
                        .cardShadow(cornerRadius: 16)
                        .rotationEffect(.degrees(shown ? Double(index - 1) * 12 : 0))
                        .offset(x: shown ? CGFloat(index - 1) * 70 : 0, y: shown ? abs(CGFloat(index - 1)) * 18 : 0)
                        .zIndex(index == 1 ? 1 : 0)
                }
            }
            .frame(height: 260)
            VStack(spacing: 10) {
                Text("Dein Guide ist bereit")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                Text(store.liked.isEmpty && store.likedGenres.isEmpty
                     ? "Wir starten mit den besten Titeln. Mit jedem Herz lernt der Guide dazu."
                     : "Wir haben schon ein paar Vorschläge für dich. Mit jedem Herz werden sie besser.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            OnboardingButton(title: "Zum Guide", action: done)
                .accessibilityIdentifier("onboarding.done")
        }
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.35).delay(0.15)) { shown = true }
        }
    }
}
