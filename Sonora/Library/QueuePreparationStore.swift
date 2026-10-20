import Foundation
import Observation
import SonoraCore

struct SongMetadataRefresh: Equatable {
    enum Step: String, CaseIterable, Identifiable {
        case audio, translation, meaning
        var id: String { rawValue }
        var title: String {
            switch self {
            case .audio: "BPM y forma de onda"
            case .translation: "Traducción"
            case .meaning: "Significado"
            }
        }
    }
    enum Status: Equatable {
        case waiting, running, updated, skipped(String), failed(String)
    }
    let trackID: String
    let title: String
    var isRunning = true
    var steps: [Step: Status] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .waiting) })
}

struct QueuePreparationPreferences: Equatable {
    let audio: Bool
    let translation: Bool
    let meaning: Bool
    let source: String
    let target: String
    let meaningLanguage: String

    init(defaults: UserDefaults) {
        audio = defaults.object(forKey: "prepareQueueAudio") == nil || defaults.bool(forKey: "prepareQueueAudio")
        translation = defaults.object(forKey: "prepareQueueTranslation") == nil || defaults.bool(forKey: "prepareQueueTranslation")
        meaning = defaults.object(forKey: "prepareQueueMeaning") == nil || defaults.bool(forKey: "prepareQueueMeaning")
        source = defaults.string(forKey: "lyricTranslationSource") ?? "auto"
        target = defaults.string(forKey: "lyricTranslationTarget") ?? "es"
        meaningLanguage = defaults.string(forKey: "lyricMeaningLanguage") ?? "es"
    }
}

/// Only the next song holds metadata/decoder resources. Queue edits replace
/// unstarted work; the active song finishes into the shared persistent caches.
@MainActor @Observable
final class QueuePreparationStore {
    struct Item {
        let track: AudioTrack
        let folder: ScopedFolder
        var id: String { Self.id(track, folder: folder) }
        static func id(_ track: AudioTrack, folder: ScopedFolder) -> String {
            track.url(in: folder.url).standardizedFileURL.absoluteString + ":" + track.localID
        }
    }
    private(set) var isRunning = false
    private(set) var pendingCount = 0
    private(set) var issues: [String: String] = [:]
    @ObservationIgnored private var items: [Item] = []
    @ObservationIgnored private var attempted: Set<String> = []
    @ObservationIgnored private var preferences: QueuePreparationPreferences?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let prepare: @MainActor (Item, QueuePreparationPreferences) async throws -> Void

    init(prepare: @escaping @MainActor (Item, QueuePreparationPreferences) async throws -> Void) { self.prepare = prepare }

    func update(_ items: [Item], preferences: QueuePreparationPreferences, retry: Bool = false) {
        if self.preferences != preferences || retry { attempted = []; issues = [:] }
        self.preferences = preferences
        var seen: Set<String> = []
        self.items = items.filter { seen.insert($0.id).inserted }
        attempted.formIntersection(seen)
        issues = issues.filter { seen.contains($0.key) }
        pendingCount = self.items.filter { !attempted.contains($0.id) }.count
        guard worker == nil, pendingCount > 0 else { return }
        worker = Task(priority: .utility) { [self] in
            defer { worker = nil; isRunning = false; pendingCount = 0 }
            isRunning = true
            while let preferences = self.preferences,
                  let item = self.items.first(where: { !attempted.contains($0.id) }) {
                attempted.insert(item.id)
                pendingCount = self.items.filter { !attempted.contains($0.id) }.count
                do { try await prepare(item, preferences) }
                catch {
                    if self.items.contains(where: { $0.id == item.id }) {
                        issues[item.id] = "\(item.track.filename): \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
