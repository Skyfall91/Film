import CoreImage
import SwiftUI

// MARK: - Poster

struct PosterView: View {
    let film: Film
    var cornerRadius: CGFloat = 16
    var showsBadge = true
    var badgeScale: CGFloat = 1
    @State private var retainedPosterID: String?

    private func retainPoster() {
        guard retainedPosterID != film.id else { return }
        if let retainedPosterID { PosterCache.releaseVisible(retainedPosterID) }
        retainedPosterID = film.id
        PosterCache.retainVisible(film.id)
    }

    var body: some View {
        let image = film.posterImage
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else {
                    // Deckender Platzhalter, nie durchsichtig, auch wenn ein Poster fehlt.
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.1)], startPoint: .top, endPoint: .bottom)
                        .overlay(Text(film.title).font(.headline).multilineTextAlignment(.center).padding())
                }
            }
            // Frisch geladene Poster blenden weich ein statt aufzuploppen.
            .animation(.easeOut(duration: 0.3), value: image != nil)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .onAppear { retainPoster() }
            .onChange(of: film.id) { _, _ in retainPoster() }
            .onDisappear {
                if let retainedPosterID { PosterCache.releaseVisible(retainedPosterID) }
                retainedPosterID = nil
            }
        .overlay(alignment: .topLeading) {
            if film.isSeries && showsBadge {
                Text("SERIE").font(.system(size: 10 * badgeScale, weight: .heavy)).tracking(1.2)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .padding(8)
            }
        }
        .overlay {
            if film.comingSoon && showsBadge {
                VStack {
                    HStack {
                        Text("DEMNÄCHST").font(.system(size: 11 * badgeScale, weight: .heavy)).tracking(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .foregroundStyle(.black)
                            .background(.white, in: .capsule)
                        Spacer()
                    }
                    Spacer()
                }.padding(8)
            }
        }
    }
}

// MARK: - Profil-Avatar

struct AvatarView: View {
    let profile: Profile
    var size: CGFloat = 44
    var selected = true

    var body: some View {
        AvatarTile(art: profile.avatarArt, initial: profile.initial, color: profile.color, size: size, circle: true)
            .overlay(alignment: .bottomTrailing) {
                if profile.isKid {
                    Image(systemName: "figure.child")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .padding(size * 0.06)
                        .background(.black, in: .circle)
                        .offset(x: 2, y: 2)
                }
            }
            .opacity(selected ? 1 : 0.35)
            .saturation(selected ? 1 : 0)
    }
}

/// Überlappende Avatare aller Profile, die gerade zusammen schauen.
struct AvatarStack: View {
    let profiles: [Profile]
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(profiles) { p in
                AvatarView(profile: p, size: size)
                    .overlay(Circle().stroke(.black, lineWidth: 2))
            }
        }
    }
}

// MARK: - Chips

struct TagChip: View {
    let text: String
    var tint: Color = .white
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.16), in: .capsule)
            .foregroundStyle(tint == .white ? .white.opacity(0.9) : tint)
    }
}

struct MatchBadge: View {
    let match: Int
    var body: some View {
        Text("\(match) % Match")
            .contentTransition(.numericText(value: Double(match)))
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.match(match))
            .animation(.smooth, value: match)
    }
}

/// Match als Ring: füllt sich beim Erscheinen, Zahl zählt mit.
struct MatchRing: View {
    let match: Int
    /// Zielwert bestimmt die Farbe, damit sie beim Hochzählen nicht flackert.
    var target: Int? = nil
    var size: CGFloat = 50

    var body: some View {
        let color = Color.match(target ?? match)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(match) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(match)")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: Double(match)))
                Text("%").font(.system(size: size * 0.18, weight: .bold, design: .rounded))
            }
            .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(match) Prozent Match")
    }
}

extension Color {
    static func match(_ m: Int) -> Color {
        m >= 85 ? Color(red: 0.3, green: 0.9, blue: 0.55) : m >= 65 ? .yellow : .orange
    }
}


struct BlurredBackdrop: View {
    let film: Film?

    private struct Layer: Equatable {
        var filmID: String?
        var generation: Int
    }
    @State private var layer = Layer(filmID: nil, generation: 0)

    var body: some View {
        ZStack {
            Color.black
            ForEach([layer], id: \.generation) { l in
                if let id = l.filmID, let image = BackdropBlur.image(id) {
                    // Color.clear legt die Größe fest, das Bild darf das Layout nicht aufblähen.
                    // Jede Ebene ist deckend (Bild auf Schwarz), so verdeckt die neue die alte
                    // vollständig, und beim Entfernen der alten ändert sich nichts mehr.
                    Color.black.overlay {
                        Image(uiImage: image)
                            .resizable().interpolation(.high).scaledToFill()
                            .opacity(0.55)
                            .scaleEffect(1.3)
                    }
                    .clipped()
                    .zIndex(Double(l.generation))
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeInOut(duration: 0.45)),
                        removal: .opacity.animation(.easeOut(duration: 0.2).delay(0.45))))
                }
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .zIndex(1_000_000)
        }
        .ignoresSafeArea()
        .onChange(of: film?.id, initial: true) { old, new in
            guard new != layer.filmID else { return }
            let next = Layer(filmID: new, generation: layer.generation + 1)
            if layer.filmID == nil && old == new { layer = next } else { withAnimation { layer = next } }
        }
    }
}


/// Profilbilder nach Genres sortiert, wie die Avatar-Reihen bei Netflix, nur ohne fremde Figuren.
/// Jede Figur hat ihre eigene Farbe, sie wird zur Akzentfarbe des Profils.
struct AvatarTile: View {
    let art: AvatarArt?
    var initial = "?"
    var color: Color = Profile.palette[0]
    var size: CGFloat
    var circle = false

    var body: some View {
        let tint = art?.color ?? color
        let shape = circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        ZStack {
            LinearGradient(colors: [tint.mix(with: .black, by: 0.15), tint.mix(with: .black, by: 0.4)],
                           startPoint: .top, endPoint: .bottom)
            if let art {
                Text(art.emoji)
                    .font(.system(size: size * 0.56))
                    .shadow(color: .black.opacity(0.35), radius: size * 0.04, y: size * 0.03)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.14), lineWidth: max(0.5, size * 0.008)))
        .accessibilityHidden(true)
    }
}
