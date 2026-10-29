import CoreImage
import SwiftUI

// MARK: - Haptik-Helfer

extension View {
    /// Schatten aus einer Form statt aus dem Karteninhalt: Den kann das System einmal
    /// berechnen, statt ihn beim Wischen in jedem Bild neu aus dem Poster abzuleiten.
    func cardShadow(cornerRadius: CGFloat = 28) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        }
    }
}

/// Unscharfer Poster-Hintergrund für Detail- und Startseiten.
/// Wechsel ohne dunkles Zwischenbild: Das neue Bild blendet *über* dem alten ein,
/// erst danach verschwindet das alte.
/// Unschärfe einmal vorab auf das kleine Vorschaubild rechnen statt live in jedem Frame.
/// Sonst muss die GPU beim Wischen zwei bildschirmgroße Ebenen gleichzeitig weichzeichnen.

// MARK: - Bewertungen (IMDb · Rotten Tomatoes · Metacritic)

struct ScoreBadges: View {
    let film: Film
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            if let imdb = film.imdbRating {
                HStack(spacing: 4) {
                    Text("IMDb")
                        .font(.system(size: compact ? 9 : 10, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: .rect(cornerRadius: 3))
                    Text(imdb, format: .number.precision(.fractionLength(1)))
                        .contentTransition(.numericText(value: imdb))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("IMDb \(imdb, format: .number.precision(.fractionLength(1)))")
            }
            if let rt = film.rottenTomatoes {
                HStack(spacing: 3) {
                    Text(rt >= 60 ? "🍅" : "🤢").font(.system(size: compact ? 11 : 13))
                    Text("\(rt) %")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rotten Tomatoes \(rt) Prozent")
            }
            if let mc = film.metascore, !compact {
                Text("\(mc)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 20)
                    .background(mc >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2) : mc >= 40 ? .yellow : .red, in: .rect(cornerRadius: 3))
                    .accessibilityLabel("Metascore \(mc)")
            }
        }
        .font((compact ? Font.caption : .subheadline).weight(.semibold))
        .monospacedDigit()
    }
}

// MARK: - Trailer-Auswahl

struct TrailerPicker: View {
    let film: Film
    var namespace: Namespace.ID
    var onPick: (Trailer) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(film.trailers) { trailer in
                    Button { onPick(trailer) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: trailer.thumbnailURL, transaction: Transaction(animation: .smooth)) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill().transition(.opacity)
                                } else {
                                    Rectangle().fill(.white.opacity(0.08))
                                }
                            }
                            .frame(width: 200, height: 112)
                            .clipShape(.rect(cornerRadius: 14))
                            .matchedTransitionSource(id: trailer.id, in: namespace)
                            .overlay {
                                Image(systemName: "play.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(in: .circle)
                            }
                            .overlay(alignment: .topLeading) {
                                Text(trailer.german ? "DE" : "OV")
                                    .font(.caption2.weight(.heavy))
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(.black.opacity(0.6), in: .capsule)
                                    .padding(8)
                            }
                            Text(trailer.title).font(.subheadline.weight(.semibold))
                            Text(trailer.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 200, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .scrollTransition(axis: .horizontal) { view, phase in
                        view.scaleEffect(phase.isIdentity ? 1 : 0.94).opacity(phase.isIdentity ? 1 : 0.6)
                    }
                }
            }
            .padding(.horizontal, 20)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .padding(.horizontal, -20)
    }
}

/// Altersfreigabe im Stil der FSK-Kennzeichen.
struct FSKBadge: View {
    let fsk: Int
    var color: Color {
        switch fsk {
        case 0: .white
        case 6: .yellow
        case 12: .green
        case 16: .blue
        default: .red
        }
    }
    var body: some View {
        Text("FSK \(fsk)")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1.2))
            .fixedSize()
    }
}

// MARK: - Profilwahl (wie Apple TV: Liquid-Glass-Menü aus dem Profil-Button)

struct ProfileMenu<MenuLabel: View>: View {
    @Environment(AppStore.self) private var store
    var onCreate: () -> Void
    var onManage: () -> Void
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            Section("Wer schaut?") {
                ForEach(store.profiles) { profile in
                    Toggle(isOn: binding(for: profile)) {
                        Label {
                            Text(profile.name)
                            Text(store.isPaused(profile.id) ? "Pausiert, nicht im Tarif enthalten"
                                 : profile.isKid ? profile.ageLabel : "\(profile.signalCount) Geschmackssignale")
                        } icon: {
                            Image(uiImage: AvatarImage.render(profile))
                        }
                    }
                    // Mehrere Profile hintereinander antippen, ohne dass das Menü zugeht.
                    .menuActionDismissBehavior(.disabled)
                    .disabled(store.isPaused(profile.id))
                }
            }
            Section {
                Button("Profil erstellen", systemImage: "plus", action: onCreate)
                Button("Profile verwalten", systemImage: "person.crop.circle", action: onManage)
            }
        } label: {
            label()
        }
        .sensoryFeedback(.selection, trigger: store.activeProfileIDs)
    }

    private func binding(for profile: Profile) -> Binding<Bool> {
        Binding(
            get: { store.activeProfileIDs.contains(profile.id) },
            set: { on in
                var ids = store.activeProfileIDs
                if on && store.subscription?.plan.allowsTogether == false {
                    ids = [profile.id]
                } else if on {
                    ids.append(profile.id)
                } else if ids.count > 1 {
                    ids.removeAll { $0 == profile.id }
                }
                // Einmal setzen: Jede Zwischenstufe würde den Stapel dahinter neu aufbauen.
                withAnimation(.smooth) { store.setViewers(ids) }
            })
    }
}

/// Avatar als Bild für Menüeinträge (Menüs nehmen nur Bilder, keine beliebigen Views).
enum AvatarImage {
    private static var cache: [String: UIImage] = [:]

    static func render(_ profile: Profile) -> UIImage {
        let key = "\(profile.id)-\(profile.colorIndex)-\(profile.name)-\(profile.maxFSK)-\(profile.littleKid)-\(profile.avatar ?? "")"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: AvatarView(profile: profile, size: 30))
        renderer.scale = 3
        let image = (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}

// MARK: - Bewertungen mit Links (Details)

/// Jede Bewertung ist ein Link zur Quelle: IMDb, Rotten Tomatoes, Metacritic, Letterboxd.
struct ScoreLinks: View {
    let film: Film

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if let imdb = film.imdbRating {
                        pill(url: "https://www.imdb.com/title/\(film.imdbID)/") {
                            Text("IMDb")
                                .font(.system(size: 10, weight: .black)).foregroundStyle(.black)
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: .rect(cornerRadius: 3))
                            Text(imdb, format: .number.precision(.fractionLength(1)))
                        }
                    }
                    if let rt = film.rottenTomatoes {
                        pill(url: "https://www.rottentomatoes.com/search?search=\(query)") {
                            Text(rt >= 60 ? "🍅" : "🤢")
                            Text("\(rt) %")
                        }
                    }
                    if let mc = film.metascore {
                        pill(url: "https://www.metacritic.com/search/\(query)/") {
                            Text("\(mc)")
                                .font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: 22, height: 20)
                                .background(mc >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2) : mc >= 40 ? .yellow : .red, in: .rect(cornerRadius: 3))
                            Text("Metacritic")
                        }
                    }
                    pill(url: "https://letterboxd.com/imdb/\(film.imdbID)/") {
                        HStack(spacing: 2) {
                            Circle().fill(.orange).frame(width: 7)
                            Circle().fill(.green).frame(width: 7)
                            Circle().fill(.blue).frame(width: 7)
                        }
                        Text("Letterboxd")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
        }
        // Gedrückte Glas-Pillen wachsen leicht, nicht oben/unten abschneiden.
        .scrollClipDisabled()
        .padding(.vertical, -6)
        .padding(.horizontal, -20)
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
    }

    private var query: String {
        film.originalTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? film.originalTitle
    }

    private func pill<Content: View>(url: String, @ViewBuilder content: () -> Content) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 6) {
                content()
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 36)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Umbrechendes Layout (Chips)

/// Legt Elemente nebeneinander und bricht in die nächste Zeile um, wenn der Platz ausgeht.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Rahmen für Vollbild-Seiten: Schließen und Zurück sind Apples eigene Buttons in der Leiste.
/// Leiste und Hintergrund bleiben durchsichtig, die Seite behält ihren eigenen Hintergrund.
struct NavigationFrame<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .containerBackground(.clear, for: .navigation)
        }
    }
}
