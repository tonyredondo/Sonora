import Foundation

/// An editable view of LRC that retains untimed phrases, repeated cues and headers.
/// Merely opening a draft never rewrites its source text.
public struct LyricsDraft: Sendable {
    public struct Line: Identifiable, Sendable {
        public let id: String
        public let text: String
        public let time: Double?
        fileprivate let source: Int
    }
    public let text: String
    public let lines: [Line]
    private let rawLines: [String]
    private static let cue = try! NSRegularExpression(pattern: #"^\[(\d{1,3}):([0-5]\d)(?:[.:](\d{1,3}))?\]"#)
    private static let offsetInformation = try! NSRegularExpression(pattern: #"\[offset:[^\]]*\]"#, options: .caseInsensitive)
    private static let header = try! NSRegularExpression(pattern: #"^\[(ar|al|ti|au|by|re|ve|length|offset):.*\]$"#, options: .caseInsensitive)

    public init(text: String) {
        self.text = text
        rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        let offset = LyricsDocument.timingOffset(in: text)?.seconds ?? 0
        var result: [Line] = []
        for (index, raw) in rawLines.enumerated() {
            var content = raw.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, Self.header.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) == nil else { continue }
            var times: [Double] = []
            while let match = Self.cue.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                func value(_ i: Int) -> String { Range(match.range(at: i), in: content).map { String(content[$0]) } ?? "0" }
                let time = (Double(value(1)) ?? 0) * 60 + (Double(value(2)) ?? 0) + (Double("0." + value(3)) ?? 0)
                times.append(max(0, time - offset))
                content = String(content.dropFirst(match.range.length))
            }
            if times.isEmpty { result.append(Line(id: "\(index)-0", text: raw, time: nil, source: index)) }
            else {
                for (occurrence, time) in times.enumerated() {
                    result.append(Line(id: "\(index)-\(occurrence)", text: content.trimmingCharacters(in: .whitespaces), time: time, source: index))
                }
            }
        }
        lines = result
    }

    /// Existing times are input annotations, never words sent to forced alignment.
    public var alignmentText: String {
        if lines.allSatisfy({ $0.time == nil }) { return LyricsDocument.removingInformation(from: text) }
        let ordered = lines.allSatisfy { $0.time != nil }
            ? lines.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time! < $1.element.time! }.map(\.element)
            : lines
        if ordered.map(\.id) != lines.map(\.id) { return ordered.map(\.text).joined(separator: "\n") }
        let grouped = Dictionary(grouping: lines, by: \.source)
        return rawLines.enumerated().compactMap { index, raw -> String? in
            if let entries = grouped[index] { return entries.map(\.text).joined(separator: "\n") }
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? raw : nil
        }.joined(separator: "\n")
    }

    /// The playback LRC reader cannot follow a mixture of timed and plain rows.
    /// Keep such intermediate edits in the draft until every phrase has a cue.
    public func validateForPlayback() throws {
        if lines.contains(where: { $0.time != nil }), let missing = lines.first(where: { $0.time == nil }) {
            throw MusicTextError.invalid("La frase «\(String(missing.text.prefix(100)))» no tiene inicio. Asígnale un tiempo en Frases o sincroniza el borrador antes de guardarlo.")
        }
    }

    /// Clean phrase edges at import/save boundaries, keeping LRC cues and line endings intact.
    public static func trimmingPhraseWhitespace(in text: String) -> String {
        func trimLine(_ raw: Substring) -> String {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil else { return String(raw) }
            var phrase = line
            var cues = ""
            while let match = cue.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
                  let range = Range(match.range, in: phrase) {
                cues += phrase[range]
                phrase = String(phrase[range.upperBound...])
            }
            return cues + phrase.trimmingCharacters(in: .whitespaces)
        }
        var result = ""
        var start = text.startIndex
        for index in text.indices where text[index].isNewline {
            result += trimLine(text[start..<index])
            result.append(text[index])
            start = text.index(after: index)
        }
        result += trimLine(text[start...])
        return result
    }

    public func replacing(_ id: String, text replacement: String, time: Double?, duration: Double) throws -> String {
        guard let target = lines.first(where: { $0.id == id }), !replacement.contains("\n"), !replacement.contains("\r"), !replacement.contains("\0"), duration.isFinite, duration > 0,
              Self.cue.firstMatch(in: replacement, range: NSRange(replacement.startIndex..., in: replacement)) == nil,
              Self.header.firstMatch(in: replacement, range: NSRange(replacement.startIndex..., in: replacement)) == nil else { throw LyricsRepairError.invalidSelection }
        if let time, !time.isFinite || time < 0 || time >= duration { throw LyricsRepairError.invalidTiming }
        // Normalize the file offset into each cue when editing; otherwise a new
        // absolute start would be shifted twice. Other information tags survive.
        var result: [String] = []
        let grouped = Dictionary(grouping: lines, by: \.source)
        for (index, raw) in rawLines.enumerated() {
            let entries = grouped[index] ?? []
            if entries.isEmpty {
                let header = Self.offsetInformation.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                if !header.trimmingCharacters(in: .whitespaces).isEmpty || raw.trimmingCharacters(in: .whitespaces).isEmpty { result.append(header) }
                continue
            }
            for entry in entries {
                let value = entry.id == target.id ? replacement : entry.text
                let start = entry.id == target.id ? time : entry.time
                result.append(start.map(Self.timestamp).map { $0 + value } ?? value)
            }
        }
        return result.joined(separator: "\n")
    }

    public static func timestamp(_ time: Double) -> String {
        guard time.isFinite, abs(time) <= 604800 else { return "—" }
        let ticks = Int((max(0, time) * 1000).rounded())
        return String(format: "[%02d:%02d.%03d]", ticks / 60000, ticks / 1000 % 60, ticks % 1000)
    }
}
