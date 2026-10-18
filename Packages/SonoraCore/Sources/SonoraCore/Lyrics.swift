import Foundation

public struct LyricsDocument: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: Int
        public let time: Double?
        public let text: String
    }
    public let lines: [Line]
    /// Persisted inside LRC so attribution survives tag writes, sidecars and offline reloads.
    public static let aiTranscriptionMarker = "[by:Sonora AI transcription - ElevenLabs]"
    public static let aiRepairMarker = "[by:Sonora AI repair - ElevenLabs]"
    public let isAITranscribed: Bool
    public let isAIRepaired: Bool
    public var attribution: String? { isAITranscribed && !isAIRepaired ? "Transcrita por IA · ElevenLabs" : nil }
    public var isTimed: Bool { lines.contains { $0.time != nil } }
    private init(lines: [Line], isAITranscribed: Bool, isAIRepaired: Bool) { self.lines = lines; self.isAITranscribed = isAITranscribed; self.isAIRepaired = isAIRepaired }

    public func sliced(from start: Double, duration: Double) -> LyricsDocument {
        guard isTimed, start.isFinite, duration.isFinite else { return self }
        let selected = lines.filter { ($0.time ?? -1) >= start && ($0.time ?? .infinity) < start + duration }
        return LyricsDocument(lines: selected.enumerated().map { Line(id: $0.offset, time: $0.element.time.map { $0 - start }, text: $0.element.text) }, isAITranscribed: isAITranscribed, isAIRepaired:isAIRepaired)
    }

    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let information = try! NSRegularExpression(pattern: #"^\[(ar|al|ti|au|by|re|ve|length|offset):.*\]$"#, options: .caseInsensitive)
    private static let fileOffset = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)

    /// Retain the recognized tag so line-level readers can apply the same global
    /// adjustment, including Unicode case folding and ignored malformed tags.
    static func timingOffset(in text: String) -> (tag: String, seconds: Double)? {
        guard let match = fileOffset.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),
              let tag = Range(match.range,in:text), let value = Range(match.range(at:1),in:text) else { return nil }
        return (String(text[tag]),(Double(text[value]) ?? 0) / 1000)
    }

    /// Remove LRC metadata before deciding whether text exists or aligning words.
    /// Preserve lyric spelling and blank lines between verses.
    public static func removingInformation(from text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return information.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
        }.joined(separator: "\n")
    }

    public init(text: String) {
        isAITranscribed = text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == Self.aiTranscriptionMarker }
        isAIRepaired = text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == Self.aiRepairMarker }
        let offset = Self.timingOffset(in:text)?.seconds ?? 0
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if Self.information.firstMatch(in: line, range: range) != nil { continue }
            let matches = Self.timestamp.matches(in: line, range: range)
            let times = matches.compactMap { match -> Double? in
                func value(_ group: Int) -> String? { Range(match.range(at: group), in: line).map { String(line[$0]) } }
                guard let minutes = value(1).flatMap(Double.init), let seconds = value(2).flatMap(Double.init), seconds < 60 else { return nil }
                let fraction = value(3).flatMap { Double("0." + $0) } ?? 0
                return max(0, minutes * 60 + seconds + fraction - offset)
            }
            if times.isEmpty { plain.append(line) }
            else {
                let content = Self.timestamp.stringByReplacingMatches(in: line, range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
                timed.append(contentsOf: times.map { ($0, content) })
            }
        }
        if timed.isEmpty { lines = plain.enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) } }
        else {
            lines = timed.enumerated().sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
                .enumerated().map { Line(id: $0.offset, time: $0.element.element.0, text: $0.element.element.1) }
        }
    }

    /// Highlights anticipate adjusted timestamps by 250 ms. Positive user offset delays
    /// the lyrics; LRC file offsets are applied while parsing. Line times stay unchanged.
    public func activeLine(at time: Double, offset: Double = 0) -> Int? {
        guard isTimed, time.isFinite, offset.isFinite else { return nil }
        let displayTime = time - offset + 0.25
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if (lines[middle].time ?? .infinity) <= displayTime { low = middle + 1 }
            else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
