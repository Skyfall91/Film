import SwiftUI

/// Langsam scrollende Wand aus Postern, grau, ein Poster leuchtet (wie das App-Icon).
struct PosterWall: View {
    /// Zwölf Poster reichen für die bewegte Wand und entlasten den ersten Start.
    private static let columns: [[Film]] = {
        let films = Array(FilmIndex.all.filter { !$0.niche && !$0.isSeries && !$0.comingSoon }.shuffled().prefix(12))
        return (0..<3).map { c in films.enumerated().filter { $0.offset % 3 == c }.map(\.element) }
    }()

    /// Das eine Poster, das gerade in Farbe leuchtet. Der Fokus springt durchs Bild:
    /// links, rechts, Mitte, oben, unten, aber immer auf ein Poster, das gerade gut zu sehen ist.
    private struct Focus: Equatable {
        var column: Int
        var filmID: String
    }
    @State private var focus: Focus?
    @State private var size: CGSize = .zero
    /// Die Spalten laufen als eine endlose Core-Animation-Bewegung: Die Oberfläche wird dafür
    /// nicht 30-mal pro Sekunde neu aufgebaut, das Verschieben übernimmt der Render-Server.
    @State private var running = false
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let speeds = [14.0, 9.0, 12.0]
    private enum Spot { case any, top, bottom }
    /// Spalte (nil = eine andere als zuletzt) und welches der gut sichtbaren Poster darin.
    private static let spots: [(column: Int?, spot: Spot)] = [(0, .any), (2, .any), (1, .any), (nil, .top), (nil, .bottom)]

    var body: some View {
        GeometryReader { geo in
            let w = Self.tileWidth(geo.size.width)
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { c in
                    let total = Self.cycle(c, width: geo.size.width)
                    column(c, w: w, h: w * 1.5, viewportHeight: geo.size.height)
                        // Spalte 0 und 2 laufen von -total nach 0, die mittlere von 0 nach -total.
                        .offset(y: running ? (c == 1 ? -total : 0) : (c == 1 ? 0 : -total))
                        .animation(running ? Animation.linear(duration: Double(total) / Self.speeds[c]).repeatForever(autoreverses: false) : nil,
                                   value: running)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
            size = new
            if !running, !reduceMotion, new.width > 30 {
                start = .now
                running = true
            }
        }
        .onAppear { PosterCache.warmUp(Self.columns.flatMap { $0 }.map(\.id), size: .small) }
        .task {
            var step = 0
            while !Task.isCancelled {
                if size.width > 0 {
                    let spot = Self.spots[step % Self.spots.count]
                    let c = spot.column ?? [0, 1, 2].filter { $0 != focus?.column }.randomElement()!
                    if let next = film(spot.spot, column: c, t: running ? Date.now.timeIntervalSince(start) : 0) { focus = next }
                    step += 1
                }
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }

    private static func tileWidth(_ width: CGFloat) -> CGFloat { max(1, (width - 24) / 3) }

    /// Höhe eines Durchlaufs einer Spalte: danach wiederholt sich das Bild nahtlos.
    private static func cycle(_ c: Int, width: CGFloat) -> CGFloat {
        (tileWidth(width) * 1.5 + 12) * CGFloat(columns[c].count)
    }

    /// Senkrechte Verschiebung einer Spalte `t` Sekunden nach dem Start, wie sie die Animation gerade zeigt.
    private func offset(_ c: Int, t: Double, width: CGFloat) -> CGFloat {
        let total = Self.cycle(c, width: width)
        let shift = CGFloat((t * Self.speeds[c]).truncatingRemainder(dividingBy: Double(total)))
        return c == 1 ? -shift : shift - total
    }

    /// Ein Poster in Spalte `c`, das gerade (und die nächsten Sekunden) gut zu sehen ist:
    /// unter der Statusleiste und über dem Text, der ab etwa 45 % der Höhe beginnt.
    private func film(_ spot: Spot, column c: Int, t: Double) -> Focus? {
        let h = Self.tileWidth(size.width) * 1.5
        let pitch = h + 12
        let band = 50.0...(size.height * 0.45)
        let off = offset(c, t: t, width: size.width)
        let drift = (c == 1 ? -1.0 : 1.0) * Self.speeds[c] * 2   // Bewegung während der Fokuszeit
        let list = Self.columns[c] + Self.columns[c]
        let visible = list.indices.compactMap { i -> (i: Int, top: CGFloat, share: CGFloat)? in
            let top = off + CGFloat(i) * pitch + drift / 2
            let shown = min(top + h, band.upperBound) - max(top, band.lowerBound)
            guard shown > 0, list[i].id != focus?.filmID else { return nil }
            return (i, top, shown / h)
        }
        let good = visible.filter { $0.share > 0.75 }
        let pick: (i: Int, top: CGFloat, share: CGFloat)? = switch spot {
        case .any: visible.max { $0.share < $1.share }
        case .top: good.min { $0.top < $1.top } ?? visible.max { $0.share < $1.share }
        case .bottom: good.max { $0.top < $1.top } ?? visible.max { $0.share < $1.share }
        }
        return pick.map { Focus(column: c, filmID: list[$0.i].id) }
    }

    private func column(_ c: Int, w: CGFloat, h: CGFloat, viewportHeight: CGFloat) -> some View {
        // Repeat just enough to cover tall iPhones even at the end of a scrolling cycle.
        let cycleHeight = max(1, CGFloat(Self.columns[c].count) * (h + 12))
        let repetitions = max(2, Int(ceil(viewportHeight / cycleHeight)) + 1)
        let films = (0..<repetitions).flatMap { _ in Self.columns[c] }
        return VStack(spacing: 12) {
            ForEach(Array(films.enumerated()), id: \.offset) { _, film in
                let highlight = focus == Focus(column: c, filmID: film.id)
                PosterView(film: film, cornerRadius: 12, size: .small)
                    .frame(width: w, height: h)
                    .saturation(highlight ? 1 : 0)
                    .opacity(highlight ? 1 : 0.38)
                    .animation(.easeInOut(duration: 0.9), value: highlight)
            }
        }
    }
}
