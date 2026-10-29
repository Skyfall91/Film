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
