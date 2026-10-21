import Foundation

public enum RepeatMode: String, CaseIterable, Sendable { case off, all, one }

public struct PlaybackQueue: Sendable {
    public private(set) var tracks: [AudioTrack] = []
    public private(set) var currentIndex: Int? = nil
    public var current: AudioTrack? { currentIndex.flatMap { tracks.indices.contains($0) ? tracks[$0] : nil } }
    public init() {}
    @discardableResult public mutating func replace(with tracks: [AudioTrack]) -> Bool {
        guard !tracks.isEmpty else { return false }
        self.tracks = tracks
        currentIndex = 0
        return true
    }
    public mutating func select(index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
    }
    public mutating func insert(_ items: [AudioTrack], afterCurrent: Bool) {
        let selected = current?.id
        var seen: Set<String> = []
        let unique = items.filter { seen.insert($0.id).inserted && (!afterCurrent || $0.id != selected) }
        if afterCurrent {
            let moving = Set(unique.map(\.id))
            tracks.removeAll { moving.contains($0.id) }
            let destination = selected.flatMap { id in tracks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            tracks.insert(contentsOf: unique, at: destination)
        } else {
            let existing = Set(tracks.map(\.id))
            tracks.append(contentsOf: unique.filter { !existing.contains($0.id) })
        }
        currentIndex = selected.flatMap { id in tracks.firstIndex { $0.id == id } } ?? (tracks.isEmpty ? nil : 0)
    }
    public func nextIndex(repeatMode: RepeatMode) -> Int? {
        guard let currentIndex else { return nil }
        if repeatMode == .one { return currentIndex }
        if tracks.indices.contains(currentIndex + 1) { return currentIndex + 1 }
        return repeatMode == .all && !tracks.isEmpty ? 0 : nil
    }
    public mutating func move(fromOffsets: IndexSet, toOffset: Int) {
        let currentID = current?.id
        let indices = fromOffsets.filter { tracks.indices.contains($0) }
        let moving = indices.map { tracks[$0] }
        for index in indices.reversed() { tracks.remove(at: index) }
        let destination = min(tracks.count, max(0, toOffset - indices.filter { $0 < toOffset }.count))
        tracks.insert(contentsOf: moving, at: destination)
        currentIndex = tracks.firstIndex { $0.id == currentID }
    }
    public mutating func remove(atOffsets: IndexSet) {
        let currentID = current?.id
        let oldIndex = currentIndex ?? 0
        let indices = atOffsets.filter { tracks.indices.contains($0) }
        let successorIndex = oldIndex - indices.filter { $0 < oldIndex }.count
        for index in indices.reversed() { tracks.remove(at: index) }
        currentIndex = tracks.firstIndex { $0.id == currentID } ?? (tracks.isEmpty ? nil : min(successorIndex, tracks.count - 1))
    }
}
