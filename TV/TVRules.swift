import Foundation

enum TVViewerSelection {
    static func normalized(_ selected: [UUID], available: [UUID], allowsTogether: Bool) -> [UUID] {
        var seen = Set<UUID>()
        let valid = selected.filter { available.contains($0) && seen.insert($0).inserted }
        return allowsTogether ? valid : Array(valid.prefix(1))
    }
}

enum TVPlaybackPolicy {
    static func canStart(subscriptionActive: Bool, viewersAllow: [Bool], comingSoon: Bool) -> Bool {
        subscriptionActive && !comingSoon && !viewersAllow.isEmpty && viewersAllow.allSatisfy { $0 }
    }
}

/// A failed source or closing a preview must never advance the selected episode.
struct TVPlaybackCompletion {
    private(set) var recorded = false
    mutating func shouldRecord(sourceLoaded: Bool, ended: Bool, explicitlyCompleted: Bool) -> Bool {
        guard sourceLoaded, ended || explicitlyCompleted, !recorded else { return false }
        recorded = true
        return true
    }
}

/// Screens containing a title or its review use the strictest current viewer.
enum TVContentPolicy {
    static func isVisible(viewersAllow: [Bool]) -> Bool {
        !viewersAllow.isEmpty && viewersAllow.allSatisfy { $0 }
    }
}

enum TVRatingPolicy {
    static func participants(pending: [UUID], active: [UUID], viewersAllow: [Bool]) -> [UUID] {
        guard active.count == viewersAllow.count, TVContentPolicy.isVisible(viewersAllow: viewersAllow) else { return [] }
        return active.filter { pending.contains($0) }
    }
}


enum TVFilmRemoteAction { case left, right, up, down, play, navigation }

enum TVFilmPanPolicy {
    static func action(x: CGFloat, y: CGFloat) -> TVFilmRemoteAction? {
        guard max(abs(x), abs(y)) >= 70 else { return nil }
        if abs(x) > abs(y) { return x < 0 ? .left : .right }
        return y < 0 ? .up : .down
    }
}


/// Prepared items and exact undo snapshots; moving through the deck never ranks films.
struct TVPreparedDeck<Item: Identifiable> where Item.ID: Hashable {
    private(set) var items: [Item] = []
    private var history: [[Item]] = []
    mutating func replace(_ items: [Item]) { self.items = items; history = [] }
    @discardableResult mutating func advance() -> Item? {
        guard !items.isEmpty else { return nil }
        history.append(items)
        if history.count > 20 { history.removeFirst() }
        return items.removeFirst()
    }
    @discardableResult mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        items = previous
        return true
    }
    mutating func append(_ incoming: [Item]) {
        var known = Set(items.map(\.id)).union(history.compactMap { $0.first?.id })
        for item in incoming where known.insert(item.id).inserted { items.append(item) }
    }
}
