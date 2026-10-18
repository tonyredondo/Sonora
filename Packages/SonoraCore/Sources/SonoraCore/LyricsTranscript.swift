import Foundation

/// An independent audio analysis, shared by missing-lyrics and repair flows.
/// `words == nil` denotes a reusable older analysis with phrase timing only.
public struct LyricsTranscript: Equatable, Sendable {
    /// Start and end may coincide when the provider resolves a word to one instant.
    public struct Word: Codable, Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }
    public let plainText: String
    public let syncedText: String
    public let duration: Double
    public let words: [Word]?
    public init(plainText: String, syncedText: String, duration: Double, words: [Word]? = nil) {
        self.plainText = plainText; self.syncedText = syncedText; self.duration = duration; self.words = words
    }
    func validateWords() throws {
        guard let words else { return }
        var previous = 0.0
        var bytes = 0
        for word in words {
            bytes += word.text.utf8.count
            guard bytes <= 262_144, !word.text.contains("\0"), !LyricsSynchronizationResult.normalized(word.text).isEmpty,
                  word.start.isFinite, word.end.isFinite, word.start >= previous,
                  word.start >= 0, word.start <= duration, word.end >= word.start, word.end <= duration + 0.05 else {
                throw LyricsSynchronizationError.invalidAlignment
            }
            previous = word.start
        }
        guard LyricsSynchronizationResult.normalized(words.map(\.text).joined()) == LyricsSynchronizationResult.normalized(plainText) else {
            throw LyricsSynchronizationError.invalidAlignment
        }
    }
}
