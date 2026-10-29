import SwiftUI
import UIKit
import CoreImage

enum BackdropBlur {
    private static var cache: [String: UIImage] = [:]
    private static var pending: Set<String> = []
    /// Die Karten im Stapel: nur für sie lohnt sich das Vorrechnen, und sie fliegen nie aus dem Speicher.
    private static var wanted: Set<String> = []
    nonisolated private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(_ filmID: String) -> UIImage? {
        if let cached = cache[filmID] { return cached }
        guard let thumb = FilmIndex.film(filmID)?.posterThumbnail, let cg = thumb.cgImage else { return nil }
        let image = blur(cg).map(UIImage.init(cgImage:)) ?? thumb
        remember(filmID, image)
        return image
    }

    /// Hintergründe der nächsten Karten schon vorher im Hintergrund rechnen. Sonst passiert das
    /// genau beim Nachrücken auf dem Hauptthread und die Animation verliert Bilder.
    static func warmUp(_ ids: [String]) {
        wanted = Set(ids)
        prepare(ids)
    }

    /// Ein Vorschaubild ist gerade fertig geworden: vorrechnen, falls es zu einer Karte im Stapel gehört.
    static func thumbnailReady(_ id: String) {
        if wanted.contains(id) { prepare([id]) }
    }

    private static func prepare(_ ids: [String]) {
        for id in ids where cache[id] == nil && !pending.contains(id) {
            guard let cg = FilmIndex.film(id)?.posterThumbnail?.cgImage else { continue }
            pending.insert(id)
            let input = cg
            Task.detached(priority: .utility) {
                let out = blur(input)
                await MainActor.run {
                    pending.remove(id)
                    if let out { remember(id, UIImage(cgImage: out)) }
                }
            }
        }
    }

    private static func remember(_ id: String, _ image: UIImage) {
        if cache.count > 40 { cache = cache.filter { wanted.contains($0.key) } }
        cache[id] = image
    }

    nonisolated private static func blur(_ cg: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cg)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(input.extent.width) / 14)
            .cropped(to: input.extent)
        return context.createCGImage(blurred, from: input.extent)
    }
}

/// Die Farbe eines Posters, wie bei Apple Music: Die Detailseite bekommt den Ton ihres Covers.
/// Gewonnen aus dem winzigen Vorschaubild, darum fast kostenlos und einmal je Film.
enum PosterTint {
    private static var cache: [String: Color] = [:]

    static func color(_ filmID: String) -> Color? {
        if let cached = cache[filmID] { return cached }
        guard let cg = FilmIndex.film(filmID)?.posterThumbnail?.cgImage, let tint = dominant(cg) else { return nil }
        cache[filmID] = tint
        return tint
    }

    /// Kräftigster Farbton des Posters, unten stärker gewichtet (dort läuft das Cover in die Seite aus).
    /// Abgedunkelt, damit weiße Schrift darauf gut lesbar bleibt.
    nonisolated static func dominant(_ image: CGImage) -> Color? {
        let width = 20, height = 30
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let bins = 12
        var weight = [Double](repeating: 0, count: bins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        var all = (r: 0.0, g: 0.0, b: 0.0, w: 0.0)
        for y in 0..<height {
            // Zeile 0 ist oben im Bild.
            let rowWeight = 0.5 + Double(y) / Double(height)
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                all.r += r * rowWeight; all.g += g * rowWeight; all.b += b * rowWeight; all.w += rowWeight
                let (h, s, v) = hsv(r, g, b)
                guard s > 0.2, v > 0.15 else { continue }
                let bin = min(Int(h * Double(bins)), bins - 1)
                let w = s * v * rowWeight
                weight[bin] += w
                sums[bin].r += r * w; sums[bin].g += g * w; sums[bin].b += b * w
            }
        }
        guard all.w > 0 else { return nil }
        let best = weight.indices.max { weight[$0] < weight[$1] }!
        // Kaum Farbe im Bild (Schwarz-Weiß-Poster): dann der gedämpfte Durchschnitt.
        let colorful = weight[best] > all.w * 0.04
        let (r, g, b) = colorful
            ? (sums[best].r / weight[best], sums[best].g / weight[best], sums[best].b / weight[best])
            : (all.r / all.w, all.g / all.w, all.b / all.w)
        let (h, s, v) = hsv(r, g, b)
        return Color(hue: h, saturation: colorful ? min(s * 1.15, 0.8) : min(s, 0.12),
                     brightness: min(max(v * 0.85, 0.26), 0.52))
    }

    nonisolated private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        guard delta > 0 else { return (0, 0, maxC) }
        var h: Double
        if maxC == r { h = (g - b) / delta } else if maxC == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return (h, delta / maxC, maxC)
    }
}
