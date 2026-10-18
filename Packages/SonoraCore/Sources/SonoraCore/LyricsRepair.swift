import Foundation

public enum LyricsRepairError: LocalizedError {
    case invalidText, mixedTiming, tooLong, invalidSelection, invalidTiming
    public var errorDescription: String? {
        switch self {
        case .invalidText: "La revisión necesita una letra válida y una transcripción del mismo audio."
        case .mixedTiming: "La letra mezcla líneas con tiempos y sin tiempos. Unifica su formato en Editar letra antes de repararla; así conservaremos todas las frases."
        case .tooLong: "La letra supera el límite de esta revisión: 65 KB o 12.000 palabras entre ambos textos."
        case .invalidSelection: "La selección ya no corresponde a esta revisión, o incluye controles LRC. Revisa el texto antes de aplicarlo."
        case .invalidTiming: "Un fragmento nuevo queda fuera de orden o del audio. Ajusta su inicio antes de aplicarlo."
        }
    }
}

/// Immutable comparison. Decisions are applied to its original snapshot, never to
/// an already modified draft. Unrecognized original text is retained by default.
public struct LyricsRepair: Sendable {
    public enum Kind: String, Sendable { case correction, completion, unrecognized }
    public struct Proposal: Identifiable, Sendable {
        public let id: Int
        public let kind: Kind
        public let original: String
        public let suggested: String
        public let context: String
        public let start: Double?
        public let end: Double?
        public let insertsLines: Bool
        fileprivate let anchor: Anchor
        fileprivate let times: [Double]
    }
    public struct Edit: Sendable {
        public let text: String
        public let startTime: Double?
        public init(text: String, startTime: Double? = nil) { self.text = text; self.startTime = startTime }
    }
    fileprivate struct Anchor: Sendable {
        let first: Int, start: Int, last: Int, end: Int
        let insert: Bool, separate: Bool
    }
    private struct Line: Sendable, Equatable { var text: String; var time: Double? }
    private struct Original { let lines: [Line]; let headers: [String]; let isTimed: Bool }
    private struct Token { let text: String, key: String; let line: Int, start: Int, end: Int; var time: Double?; var finish: Double? }
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)
    private static let controls = try! NSRegularExpression(pattern: #"\[(?:\d{1,3}:\d{2}|(?:ar|al|ti|au|by|re|ve|length|offset)\s*:)"#, options: .caseInsensitive)
    private static let offsetInformation = try! NSRegularExpression(pattern: #"^\[offset:"#, options: .caseInsensitive)
    public let original: String
    public let proposals: [Proposal]
    public let usesPhraseTiming: Bool
    public let isTimed: Bool
    private let lines: [Line]
    private let headers: [String]
    private let duration: Double

    public init(original: String, transcript: LyricsTranscript) throws {
        guard original.utf8.count <= 65_536, transcript.plainText.utf8.count <= 65_536 else { throw LyricsRepairError.tooLong }
        guard !original.contains("\0"), transcript.duration.isFinite, (1...600).contains(transcript.duration),
              LyricsSynchronizationResult.catalog(text:transcript.syncedText,existing:transcript.plainText,duration:transcript.duration) != nil else { throw LyricsRepairError.invalidText }
        try transcript.validateWords()
        let state = try Self.parseOriginal(original,duration:transcript.duration)
        let parsed = state.lines, timed = state.isTimed
        self.original = original; self.lines = parsed; self.isTimed = timed; self.duration = transcript.duration
        self.headers = state.headers
        usesPhraseTiming = transcript.words == nil
        let sourceLines = LyricsDocument(text:transcript.syncedText).lines.map { Line(text:$0.text,time:$0.time) }
        let base = Self.tokens(parsed)
        var source = Self.tokens(sourceLines)
        guard base.count + source.count <= 12_000 else { throw LyricsRepairError.tooLong }
        if let words = transcript.words {
            var wordIndex = 0, wordOffset = 0, position = 0
            let lengths = words.map { LyricsSynchronizationResult.normalized($0.text).unicodeScalars.count }
            for index in source.indices {
                while wordIndex + 1 < words.count, wordOffset + lengths[wordIndex] <= position { wordOffset += lengths[wordIndex]; wordIndex += 1 }
                let end = position + source[index].key.unicodeScalars.count
                var last = wordIndex, endOffset = wordOffset + lengths[wordIndex]
                while last + 1 < words.count, endOffset < end { last += 1; endOffset += lengths[last] }
                source[index].time = words[wordIndex].start; source[index].finish = words[last].end; position = end
            }
        }
        let useClock = timed && transcript.words != nil
        let timedLines = parsed.enumerated().compactMap { index,line in line.time.map { (index,$0) } }
        func sourceOwner(_ token: Token) -> Int { timedLines.last { $0.1 <= (token.time ?? 0) + 0.03 }?.0 ?? -1 }
        // Older caches still have phrase starts. Shared starts keep repeated
        // words in their own interval without assuming word timing or requiring
        // both texts to split the intervening phrases into the same lines.
        let sharedPhraseTimes = timed && transcript.words == nil
            ? Set(timedLines.map(\.1)).intersection(sourceLines.compactMap(\.time)).sorted() : []
        func phraseWindow(_ token: Token) -> Int { sharedPhraseTimes.lastIndex { $0 <= (token.time ?? 0) } ?? -1 }
        let baseKeys = base.map { $0.key + (timed ? "\0\(useClock ? $0.line : phraseWindow($0))" : "") }
        let sourceKeys = source.map { $0.key + (timed ? "\0\(useClock ? sourceOwner($0) : phraseWindow($0))" : "") }
        // The standard library diff avoids retaining a quadratic alignment matrix.
        let difference = sourceKeys.difference(from:baseKeys)
        let removed = Set(difference.removals.map { change -> Int in if case .remove(let offset,_,_) = change { return offset }; return -1 })
        let inserted = Set(difference.insertions.map { change -> Int in if case .insert(let offset,_,_) = change { return offset }; return -1 })
        let baseKept = base.indices.filter { !removed.contains($0) }, sourceKept = source.indices.filter { !inserted.contains($0) }
        let matches = Array(zip(baseKept,sourceKept))
        var sourceOwners: [Int:Set<Int>] = [:], matchedLines: Set<Int> = []
        let sourceCounts = Dictionary(grouping:source,by:\.line).mapValues(\.count)
        for (a,b) in matches { sourceOwners[source[b].line,default:[]].insert(base[a].line); matchedLines.insert(base[a].line) }
        var result: [Proposal] = []
        func add(_ kind:Kind, _ anchor:Anchor, _ text:String, _ suggested:String, _ targets:[Int]) {
            let first = targets.first.map { source[$0] }, last = targets.last.map { source[$0] }
            let context = anchor.first < parsed.count ? parsed[anchor.first...min(anchor.last,parsed.count-1)].map(\.text).joined(separator:"\n") : "Final de la letra"
            let times = targets.reduce(into:[(Int,Double)]()) { values,index in
                if values.last?.0 != source[index].line, let time = source[index].time { values.append((source[index].line,time)) }
            }.map(\.1)
            // Missing transcript words have no provider end. Audition their
            // original block until the next cue, including a final omitted verse.
            let end = kind == .unrecognized && timed
                ? parsed.dropFirst(anchor.last + 1).first(where:{ $0.time != nil })?.time ?? transcript.duration
                : last?.finish ?? first?.time.map { min(transcript.duration,$0 + 4) }
            result.append(Proposal(id:result.count,kind:kind,original:text,suggested:suggested,context:context,start:first?.time ?? parsed[safe:anchor.first]?.time,end:end,insertsLines:anchor.separate,anchor:anchor,times:times))
        }
        let boundaries = [(-1,-1)] + matches + [(base.count,source.count)]
        for index in 1..<boundaries.count {
            let previous = boundaries[index-1], next = boundaries[index]
            let a = (previous.0+1)..<next.0, b = (previous.1+1)..<next.1
            guard !a.isEmpty || !b.isEmpty else { continue }
            let affected = Set(a.map { base[$0].line })
            var rest = Array(b)
            // A whole unmatched transcript line beside an anchored correction is
            // its own insertion, so "complete only" cannot also change that word.
            let previousLine = base[safe:previous.0]?.line, nextLine = base[safe:next.0]?.line
            let neighborsShareLine = previousLine != nil && previousLine == nextLine
            if a.isEmpty {
                // One insertion can span the suffix of one phrase, whole new
                // verses and the prefix of the next. Give each source line its
                // own anchor instead of slicing across detached verse text.
                for lineIndex in Set(b.map { source[$0].line }).sorted() {
                    let group = b.filter { source[$0].line == lineIndex }
                    let owners = sourceOwners[lineIndex,default:[]]
                    if !neighborsShareLine && owners.isEmpty && group.count == sourceCounts[lineIndex] {
                        let before = nextLine ?? parsed.count
                        add(.completion,Anchor(first:before,start:0,last:before,end:0,insert:true,separate:true),"",sourceLines[lineIndex].text,Array(group))
                    } else {
                        let owner = nextLine.flatMap { owners.contains($0) ? $0 : nil } ?? previousLine.flatMap { owners.contains($0) ? $0 : nil }
                        let line = owner ?? nextLine ?? previousLine ?? 0
                        let offset = line == nextLine ? base[next.0].start : parsed[line].text.utf16.count
                        add(.completion,Anchor(first:line,start:offset,last:line,end:offset,insert:true,separate:false),"",Self.fragment(source,indices:Array(group),lines:sourceLines),Array(group))
                    }
                }
                continue
            }
            let canSeparateAdditions = !neighborsShareLine && affected.count == 1 && affected.isSubset(of:matchedLines)
            if canSeparateAdditions {
                // An unchanged neighbor can own a suffix/prefix in the same diff
                // gap as this correction. Keep it on that neighbor, at its time.
                for lineIndex in Set(rest.map { source[$0].line }).sorted() {
                    let owners = sourceOwners[lineIndex,default:[]]
                    guard owners.count == 1, let owner = owners.first, !affected.contains(owner),
                          owner == previousLine || owner == nextLine else { continue }
                    let group = rest.filter { source[$0].line == lineIndex }
                    let offset = owner == nextLine ? base[next.0].start : parsed[owner].text.utf16.count
                    add(.completion,Anchor(first:owner,start:offset,last:owner,end:offset,insert:true,separate:false),"",Self.fragment(source,indices:group,lines:sourceLines),group)
                    rest.removeAll { source[$0].line == lineIndex }
                }
            }
            // Detach whole additions only while the remaining matched context
            // stays inside this phrase; ambiguous replacements stay together.
            let staysInsidePhrase = rest.allSatisfy { sourceOwners[source[$0].line,default:[]].isSubset(of:affected) }
            if canSeparateAdditions && staysInsidePhrase {
                for lineIndex in Set(rest.map { source[$0].line }).sorted() where sourceOwners[lineIndex,default:[]].isEmpty {
                    let group = rest.filter { source[$0].line == lineIndex }
                    guard group.count == sourceCounts[lineIndex] else { continue }
                    let following = matches.first { $0.1 > (group.last ?? -1) }
                    let before = following.map { base[$0.0].line } ?? parsed.count
                    add(.completion,Anchor(first:before,start:0,last:before,end:0,insert:true,separate:true),"",sourceLines[lineIndex].text,Array(group))
                    rest.removeAll { source[$0].line == lineIndex }
                }
            }
            var originalRest = Array(a)
            let anchored = affected.intersection(matchedLines)
            if anchored.count == 1, let owner = anchored.first, !rest.isEmpty,
               rest.allSatisfy({ sourceOwners[source[$0].line,default:[]] == [owner] }) {
                // A correction with uniquely matched context must not swallow
                // whole neighboring verses that the provider did not recognize.
                for omitted in [affected.filter { $0 < owner }, affected.filter { $0 > owner }] {
                    guard let first = omitted.min(), let last = omitted.max() else { continue }
                    let text = parsed[first...last].map(\.text).joined(separator:"\n")
                    add(.unrecognized,Anchor(first:first,start:0,last:last,end:parsed[last].text.utf16.count,insert:false,separate:false),text,text,[])
                }
                originalRest.removeAll { base[$0].line != owner }
            }
            if let firstIndex = originalRest.first, let lastIndex = originalRest.last {
                let first = base[firstIndex], last = base[lastIndex]
                let anchor = Anchor(first:first.line,start:first.start,last:last.line,end:last.end,insert:false,separate:false)
                let text = Self.fragment(base,indices:originalRest,lines:parsed)
                add(rest.isEmpty ? .unrecognized : .correction,anchor,text,rest.isEmpty ? text : Self.fragment(source,indices:rest,lines:sourceLines),rest)
            }
        }
        proposals = result
    }

    /// Only explicit decisions change the original; completing skips corrections.
    public func applying(_ edits: [Int:Edit], onlyCompletions: Bool = false) throws -> String {
        guard edits.keys.allSatisfy({ proposals.indices.contains($0) }) else { throw LyricsRepairError.invalidSelection }
        var output = lines, changed = false
        let selected = proposals.filter { edits[$0.id] != nil && (!onlyCompletions || $0.kind == .completion) }.sorted {
            let a = $0.anchor, b = $1.anchor
            if a.first != b.first { return a.first > b.first }
            if a.start != b.start { return a.start > b.start }
            if a.separate != b.separate { return !a.separate }
            return $0.id > $1.id
        }
        for proposal in selected {
            let edit = edits[proposal.id]!, a = proposal.anchor
            let text = edit.text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard text.utf8.count <= 65_536, !text.contains("\0"), Self.controls.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) == nil else { throw LyricsRepairError.invalidSelection }
            if text == proposal.original.trimmingCharacters(in:.whitespacesAndNewlines) { continue }
            if a.separate {
                guard !text.isEmpty else { continue }
                let start = edit.startTime ?? proposal.start
                guard !isTimed || start.map({ $0.isFinite && (0...duration).contains($0) }) == true else { throw LyricsRepairError.invalidTiming }
                let delta = (start ?? 0) - (proposal.start ?? 0)
                let added = editedLines(text,firstTime:start,times:proposal.times.map { $0 + delta })
                output.insert(contentsOf:added,at:a.first)
            } else {
                let first = output[a.first], last = output[a.last]
                let originalRange = Array(output[a.first...a.last])
                let prefix = String(first.text.prefix(utf16:a.start)), suffix = String(last.text.suffix(fromUTF16:a.end))
                var replacement = text
                if a.insert {
                    if let p = prefix.last, !p.isWhitespace, !replacement.isEmpty { replacement = " " + replacement }
                    if let s = suffix.first, !s.isWhitespace, !replacement.isEmpty { replacement += " " }
                }
                let times = proposal.kind == .unrecognized ? originalRange.filter { !$0.text.trimmingCharacters(in:.whitespaces).isEmpty }.compactMap(\.time) : proposal.times
                var added = editedLines(prefix + replacement + suffix,firstTime:first.time,times:times)
                // Pause cues have no tokens, so a word-level replacement can span
                // them without showing a separate proposal. Preserve those cues.
                for pause in originalRange where pause.text.isEmpty {
                    guard let time = pause.time else { continue }
                    let index = added.indices.dropFirst().first { (added[$0].time ?? .infinity) >= time } ?? added.endIndex
                    added.insert(pause,at:index)
                }
                output.replaceSubrange(a.first...a.last,with:added)
            }
            changed = true
        }
        guard changed else { return original }
        var previous = 0.0
        if isTimed {
            output = Self.orderingCues(output)
            for line in output where line.time != nil || !line.text.trimmingCharacters(in:.whitespaces).isEmpty {
                guard let time = line.time, time.isFinite, time >= previous, time <= duration else { throw LyricsRepairError.invalidTiming }
                previous = time
            }
        }
        let rendered = output.map { line -> String in
            guard isTimed, let time = line.time else { return line.text }
            let ticks = Int((time * 100).rounded())
            return String(format:"[%02d:%02d.%02d]",ticks / 6000,ticks / 100 % 60,ticks % 100) + line.text
        }
        let result = ([LyricsDocument.aiRepairMarker] + headers + rendered).joined(separator:"\n")
        guard result.utf8.count <= 65_536 else { throw LyricsRepairError.tooLong }
        try verifyRendering(result,lines:output)
        return result
    }

    /// Safe replacement words can form LRC controls with an unchanged prefix or
    /// suffix. Verify the complete draft through the reader before it can be saved.
    private func verifyRendering(_ text: String, lines: [Line]) throws {
        let visible = LyricsDocument(text:text).lines
        let expected = lines.filter { $0.time != nil || !$0.text.trimmingCharacters(in:.whitespaces).isEmpty }
        guard visible.count == expected.count else { throw LyricsRepairError.invalidSelection }
        for (actual,line) in zip(visible,expected) {
            guard actual.text == line.text.trimmingCharacters(in:.whitespaces) else { throw LyricsRepairError.invalidSelection }
            let time = isTimed ? line.time.map { ($0 * 100).rounded() / 100 } : nil
            switch (actual.time,time) {
            case (nil,nil): break
            case let (actual?,expected?) where abs(actual - expected) < 0.000_001: break
            default: throw LyricsRepairError.invalidSelection
            }
        }
    }

    /// Tokenless cues can sit between two word anchors. Merge those cues by time
    /// after applying edits, keeping every word-bearing line in its chosen order.
    /// Sorting all lines would conceal an invalid manual timestamp instead.
    private static func orderingCues(_ lines: [Line]) -> [Line] {
        let cues = lines.enumerated().filter { _,line in
            line.time?.isFinite == true && wordPattern.firstMatch(in:line.text,range:NSRange(line.text.startIndex...,in:line.text)) == nil
        }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time! < $1.element.time!
        }
        guard !cues.isEmpty else { return lines }
        let cueIndices = Set(cues.map(\.offset))
        var result: [Line] = [], next = 0
        for (index,line) in lines.enumerated() where !cueIndices.contains(index) {
            if let time = line.time {
                while next < cues.count {
                    let cue = cues[next], cueTime = cue.element.time!
                    guard cueTime < time || cueTime == time && cue.offset < index else { break }
                    result.append(cue.element); next += 1
                }
            }
            result.append(line)
        }
        result.append(contentsOf:cues.dropFirst(next).map(\.element))
        return result
    }

    /// Blank paragraph lines do not consume a phrase timestamp. Extra edited
    /// lines reuse the previous known time, never jumping back to the first one.
    private func editedLines(_ text: String, firstTime: Double?, times: [Double]) -> [Line] {
        var contentIndex = 0, previous = firstTime
        var result = text.components(separatedBy:.newlines).map { line -> Line in
            guard !line.trimmingCharacters(in:.whitespaces).isEmpty else { return Line(text:line,time:nil) }
            let time = isTimed ? (contentIndex == 0 ? firstTime : times[safe:contentIndex] ?? previous) : nil
            contentIndex += 1; previous = time
            return Line(text:line,time:time)
        }
        if isTimed && contentIndex == 0 { result[0].time = firstTime }
        return result
    }

    /// Preflight the file before an opt-in analysis can upload audio or use credits.
    /// The comparison uses this same parser, including instrumental pause cues.
    public static func validateOriginal(_ text: String, duration: Double) throws {
        guard duration.isFinite, (1...600).contains(duration) else { throw LyricsSynchronizationError.unsupportedDuration }
        let state = try parseOriginal(text,duration:duration)
        guard tokens(state.lines).count <= 12_000 else { throw LyricsRepairError.tooLong }
    }

    private static func parseOriginal(_ text: String, duration: Double) throws -> Original {
        guard text.utf8.count <= 65_536 else { throw LyricsRepairError.tooLong }
        guard !text.contains("\0") else { throw LyricsRepairError.invalidText }
        let raw = text.components(separatedBy:.newlines)
        let metadata = raw.filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty && LyricsDocument.removingInformation(from:$0).isEmpty }
        let metadataLines = Set(metadata)
        let offset = LyricsDocument.timingOffset(in:text)?.tag ?? ""
        var parsed: [Line] = [], expanded = false
        for rawLine in raw {
            if metadataLines.contains(rawLine) { continue }
            if rawLine.trimmingCharacters(in:.whitespaces).isEmpty { parsed.append(Line(text:rawLine,time:nil)); continue }
            let values = LyricsDocument(text:offset + "\n" + rawLine).lines
            expanded = expanded || values.count > 1
            parsed.append(contentsOf:values.map { Line(text:$0.text,time:$0.time) })
        }
        let content = parsed.filter { !$0.text.trimmingCharacters(in:.whitespaces).isEmpty }
        guard !content.isEmpty else { throw LyricsRepairError.invalidText }
        let timed = parsed.contains { $0.time != nil }
        guard !timed || content.allSatisfy({ $0.time != nil }) else { throw LyricsRepairError.mixedTiming }
        if timed {
            let timedLines = parsed.filter { $0.time != nil }
            guard timedLines.allSatisfy({ $0.time!.isFinite && (0...duration).contains($0.time!) }) else { throw LyricsRepairError.invalidTiming }
            if expanded || zip(timedLines,timedLines.dropFirst()).contains(where:{ $0.time! > $1.time! }) {
                parsed = parsed.enumerated().sorted { ($0.element.time ?? .infinity,$0.offset) < ($1.element.time ?? .infinity,$1.offset) }.map(\.element)
            }
        }
        let headers = metadata.filter {
            let line = $0.trimmingCharacters(in:.whitespaces)
            // String.range case folding differs from the reader's regex matching.
            return Self.offsetInformation.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)) == nil
                && line != LyricsDocument.aiRepairMarker
        }
        return Original(lines:parsed,headers:headers,isTimed:timed)
    }

    private static func tokens(_ lines: [Line]) -> [Token] {
        lines.enumerated().flatMap { index,line in
            wordPattern.matches(in:line.text,range:NSRange(line.text.startIndex...,in:line.text)).map { match in
                let text = (line.text as NSString).substring(with:match.range)
                return Token(text:text,key:LyricsSynchronizationResult.normalized(text),line:index,start:match.range.location,end:match.range.location+match.range.length,time:line.time,finish:lines[safe:index+1]?.time)
            }
        }
    }
    private static func fragment(_ tokens:[Token], indices:[Int], lines:[Line]) -> String {
        guard let firstIndex = indices.first, let lastIndex = indices.last else { return "" }
        let first = tokens[firstIndex], last = tokens[lastIndex]
        if first.line == last.line {
            return (lines[first.line].text as NSString).substring(with:NSRange(location:first.start,length:last.end-first.start))
        }
        return ([String(lines[first.line].text.suffix(fromUTF16:first.start))] + lines[(first.line+1)..<last.line].map(\.text) + [String(lines[last.line].text.prefix(utf16:last.end))]).joined(separator:"\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
private extension String {
    func prefix(utf16 count: Int) -> Substring { self[..<String.Index(utf16Offset:count,in:self)] }
    func suffix(fromUTF16 offset: Int) -> Substring { self[String.Index(utf16Offset:offset,in:self)...] }
}
