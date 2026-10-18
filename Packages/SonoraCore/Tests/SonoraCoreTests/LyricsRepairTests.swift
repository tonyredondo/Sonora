import Foundation
import XCTest
@testable import SonoraCore

final class LyricsRepairTests: XCTestCase {
    private func transcript(_ lrc: String, duration: Double = 8) -> LyricsTranscript {
        LyricsTranscript(plainText: LyricsDocument(text:lrc).lines.map(\.text).joined(separator:"\n"),syncedText:lrc,duration:duration)
    }
    func testCorrectionAndMissingVerseCanBeReviewedIndependently() throws {
        let original = "[ar:Example]\n[00:00.10]Bright roan\n[00:03.10]We return"
        let review = try LyricsRepair(original:original,transcript:transcript("[00:00.10]Bright road\n[00:01.40]Walk beside me\n[00:03.10]We return"))
        XCTAssertEqual(review.proposals.filter { $0.kind == .correction }.count,1)
        XCTAssertEqual(review.proposals.filter { $0.kind == .completion }.count,1)
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.filter { $0.kind != .unrecognized }.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let result = try review.applying(edits)
        XCTAssertEqual(LyricsDocument(text:result).lines.map(\.text),["Bright road","Walk beside me","We return"])
        XCTAssertEqual(LyricsDocument(text:result).lines.map(\.time),[0.1,1.4,3.1])
        XCTAssertTrue(result.contains("[ar:Example]")); XCTAssertTrue(LyricsDocument(text:result).isAIRepaired)
        let additionsOnly = try review.applying(edits,onlyCompletions:true)
        XCTAssertEqual(LyricsDocument(text:additionsOnly).lines.map(\.text),["Bright roan","Walk beside me","We return"])
    }
    func testAnOmittedPhraseNeverDisappearsWithoutAnExplicitManualEdit() throws {
        let original = "Bright road\nKeep this chorus\nWe return"
        let review = try LyricsRepair(original:original,transcript:transcript("[00:00.10]Bright road\n[00:03.10]We return"))
        XCTAssertEqual(try review.applying([:]),original)
        let omitted = try XCTUnwrap(review.proposals.first { $0.kind == .unrecognized })
        XCTAssertTrue(omitted.original.contains("Keep this chorus"))
        XCTAssertEqual(try review.applying([omitted.id:.init(text:omitted.original)]),original)
    }
    func testUnrecognizedBlockCanBeAuditionedThroughItsLastOriginalLine() throws {
        let original = "[00:01.00]Bright road\n[00:05.00]Listen to this verse\n[00:14.00]It carries on for longer\n[00:30.00]We return"
        let review = try LyricsRepair(original:original,transcript:transcript("[00:01.00]Bright road\n[00:30.00]We return",duration:40))
        let omitted = try XCTUnwrap(review.proposals.first { $0.kind == .unrecognized })
        XCTAssertEqual(omitted.start,5)
        XCTAssertEqual(omitted.end,30)

        let tail = try LyricsRepair(original:"[00:01.00]Bright road\n[00:05.00]Keep the final verse\n[00:14.00]And its final line",transcript:transcript("[00:01.00]Bright road",duration:40))
        let ending = try XCTUnwrap(tail.proposals.first { $0.kind == .unrecognized })
        XCTAssertEqual(ending.start,5)
        XCTAssertEqual(ending.end,40)
    }
    func testWordCorrectionsCannotDeleteNeighboringUnrecognizedVerses() throws {
        for wordTiming in [false,true] {
          for timed in [false,true] {
            for leading in [false,true] {
                let originalLines = leading ? ["Keep this verse","And this line","Dull road","We return"] : ["Bright roan","Keep this verse","And this line","We return"]
                let original = originalLines.enumerated().map { (timed ? String(format:"[00:%02d.00]",$0.offset+1) : "") + $0.element }.joined(separator:"\n")
                let legacy = transcript("[00:\(leading ? "03" : "01").00]Bright road\n[00:04.00]We return")
                let start = leading ? 3.0 : 1.0
                let words: [LyricsTranscript.Word]? = wordTiming ? [.init(text:"Bright",start:start,end:start+0.2),.init(text:"road",start:start+0.3,end:start+0.5),.init(text:"We",start:4,end:4.2),.init(text:"return",start:4.3,end:4.5)] : nil
                let source = LyricsTranscript(plainText:legacy.plainText,syncedText:legacy.syncedText,duration:legacy.duration,words:words)
                let review = try LyricsRepair(original:original,transcript:source)
                let correction = try XCTUnwrap(review.proposals.first { $0.kind == .correction })
                XCTAssertEqual(correction.original,leading ? "Dull" : "roan")
                XCTAssertTrue(review.proposals.contains { $0.kind == .unrecognized && $0.original.contains("Keep this verse") })
                let written = try review.applying([correction.id:.init(text:correction.suggested)])
                XCTAssertEqual(LyricsDocument(text:written).lines.map(\.text),originalLines.map { $0.replacingOccurrences(of:leading ? "Dull" : "roan",with:leading ? "Bright" : "road") })
            }
          }
        }
    }
    func testMissingWordsWithinAPhraseCanBeCompletedWithoutReplacingIt() throws {
        let review = try LyricsRepair(original:"Bright road",transcript:transcript("[00:00.10]Bright open road"))
        let addition = try XCTUnwrap(review.proposals.first)
        XCTAssertEqual(addition.kind,.completion)
        let output = try review.applying([addition.id:.init(text:"quiet ")],onlyCompletions:true)
        XCTAssertEqual(LyricsDocument(text:output).lines.map(\.text),["Bright quiet road"])
        XCTAssertFalse(LyricsDocument(text:output).isTimed)
    }
    func testTranscriptLineBreaksCannotMoveAnInsertionBeforeItsOriginalPhrase() throws {
        let review = try LyricsRepair(original:"Bright road We return",transcript:transcript("[00:00.10]Bright road\n[00:01.40]Walk beside me\n[00:03.10]We return"))
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let result = try review.applying(edits,onlyCompletions:true)
        XCTAssertEqual(LyricsDocument(text:result).lines.map(\.text),["Bright road Walk beside me We return"])
    }
    func testAmbiguousSourceLineOwnershipCannotDuplicateAMissingVerse() throws {
        let review = try LyricsRepair(original:"alpha bad ugly\nomega",transcript:transcript("[00:00.10]alpha good\n[00:01.40]missing verse\n[00:03.10]pretty omega"))
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.filter { $0.kind != .unrecognized }.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let result = LyricsDocument(text:try review.applying(edits)).lines.map(\.text).joined(separator:" ")
        XCTAssertEqual(result,"alpha good missing verse pretty omega")
    }
    func testAdditionsAcrossAPhraseBoundaryStayIndependentAndInOrder() throws {
        let review = try LyricsRepair(original:"Bright road\nWe return",transcript:transcript("[00:01.00]Bright road again\n[00:03.00]Walk beside me\n[00:05.00]Now We return"))
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let written = try review.applying(edits,onlyCompletions:true)
        XCTAssertEqual(LyricsDocument(text:written).lines.map(\.text),["Bright road again","Walk beside me","Now We return"])
        for proposal in review.proposals {
            let single = try review.applying([proposal.id:.init(text:proposal.suggested)],onlyCompletions:true)
            let text = LyricsDocument(text:single).lines.map(\.text).joined(separator:" ")
            XCTAssertLessThanOrEqual(text.components(separatedBy:"Walk beside me").count,2)
        }
    }
    func testBoundaryAdditionsStayIndependentFromTheNeighboringWordCorrection() throws {
        for trailing in [false,true] {
          for middle in [false,true] {
            for detailed in [false,true] {
              for timed in [false,true] {
                let original = timed ? "[00:01.00]Bright road\n[00:05.00]We return" : "Bright road\nWe return"
                let first = trailing ? "Bright road again" : "Bright path"
                let last = trailing ? "Now return" : "Now We return"
                let lines: [(Double,String)] = [(1,first)] + (middle ? [(3,"Walk beside me")] : []) + [(5,last)]
                let source = lines.map { String(format:"[00:%02d.00]",Int($0.0)) + $0.1 }.joined(separator:"\n")
                let words = lines.flatMap { start,text in text.split(separator:" ").enumerated().map { LyricsTranscript.Word(text:String($0.element),start:start + Double($0.offset) * 0.3,end:start + Double($0.offset) * 0.3 + 0.2) } }
                let review = try LyricsRepair(original:original,transcript:.init(plainText:lines.map(\.1).joined(separator:"\n"),syncedText:source,duration:8,words:detailed ? words : nil))
                XCTAssertEqual(review.proposals.filter { $0.kind == .correction }.count,1)
                XCTAssertEqual(review.proposals.filter { $0.kind == .completion }.count,middle ? 2 : 1)
                let edits = Dictionary(uniqueKeysWithValues:review.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
                let written = LyricsDocument(text:try review.applying(edits))
                XCTAssertEqual(written.lines.map(\.text),lines.map(\.1))
                XCTAssertEqual(written.lines.map(\.time),timed ? lines.map { Optional($0.0) } : Array(repeating:nil,count:lines.count))
                let completed = LyricsDocument(text:try review.applying(edits,onlyCompletions:true))
                XCTAssertEqual(completed.lines.map(\.text),[trailing ? first : "Bright road"] + (middle ? ["Walk beside me"] : []) + [trailing ? "We return" : last])
              }
            }
          }
        }
    }
    func testWordRepairsPreserveInstrumentalPauseCues() throws {
        let review = try LyricsRepair(original:"[00:01.00]Bright roan\n[00:02.00]\n[00:05.00]We return",transcript:transcript("[00:01.00]Bright road\n[00:05.00]We return"))
        let proposal = try XCTUnwrap(review.proposals.first)
        let written = LyricsDocument(text:try review.applying([proposal.id:.init(text:proposal.suggested)]))
        XCTAssertEqual(written.lines.map(\.text),["Bright road","","We return"])
        XCTAssertEqual(written.lines.map(\.time),[1,2,5])
    }
    func testSeveralNewVersesCanBeInsertedOnEitherSideOfAPause() throws {
        for first in ["Bright road", "Bright roan", "bad phrase"] {
            let review = try LyricsRepair(original:"[00:01.00]\(first)\n[00:03.00]\n[00:05.00]We return",transcript:transcript("[00:01.00]Bright road\n[00:02.00]New first verse\n[00:02.50]New second verse\n[00:04.00]New third verse\n[00:05.00]We return"))
            let edits = Dictionary(uniqueKeysWithValues:review.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
            let written = LyricsDocument(text:try review.applying(edits))
            XCTAssertEqual(written.lines.map(\.time),[1,2,2.5,3,4,5])
            XCTAssertEqual(written.lines.map(\.text),["Bright road","New first verse","New second verse","","New third verse","We return"])
        }
    }
    func testBlockCorrectionsPreservePauseCuesInsideTheReplacedRange() throws {
        let review = try LyricsRepair(original:"[00:01.00]bad phrase\n[00:02.00]\n[00:05.00]wrong song",transcript:transcript("[00:01.00]good words\n[00:05.00]right tune"))
        let proposal = try XCTUnwrap(review.proposals.first)
        let written = LyricsDocument(text:try review.applying([proposal.id:.init(text:proposal.suggested)]))
        XCTAssertEqual(written.lines.map(\.text),["good words","","right tune"])
        XCTAssertEqual(written.lines.map(\.time),[1,2,5])
    }
    func testAdditionalManuallyEditedLinesReuseTheLastKnownTime() throws {
        let review = try LyricsRepair(original:"[00:01.00]bad phrase\n[00:05.00]wrong song",transcript:transcript("[00:01.00]good words\n[00:05.00]right tune"))
        let proposal = try XCTUnwrap(review.proposals.first)
        let written = LyricsDocument(text:try review.applying([proposal.id:.init(text:"good words\nright tune\nmore words")]))
        XCTAssertEqual(written.lines.map(\.time),[1,5,5])
        XCTAssertEqual(written.lines.map(\.text),["good words","right tune","more words"])
    }
    func testManualCorrectionsOfUnrecognizedTextPreserveOriginalLineTimes() throws {
        let review = try LyricsRepair(original:"[00:01.00]Bright road\n[00:02.00]lost first\n[00:03.00]lost second\n[00:05.00]We return",transcript:transcript("[00:01.00]Bright road\n[00:05.00]We return"))
        let proposal = try XCTUnwrap(review.proposals.first { $0.kind == .unrecognized })
        let written = LyricsDocument(text:try review.applying([proposal.id:.init(text:"my words\n\nother words")]))
        XCTAssertEqual(written.lines.map(\.time),[1,2,3,5])
        XCTAssertEqual(written.lines.map(\.text),["Bright road","my words","other words","We return"])
    }
    func testInvalidPauseCuesCannotSurviveAsUncheckedTimestamps() {
        XCTAssertThrowsError(try LyricsRepair(original:"[00:01.00]Bright road\n[00:25.00]\n[00:05.00]We return",transcript:transcript("[00:01.00]Bright road\n[00:05.00]We return")))
    }
    func testPreflightSharesTimingTextAndSizeValidationWithTheComparison() throws {
        try LyricsRepair.validateOriginal("[00:01.00]Bright road\n[00:02.00]\n[00:05.00]We return",duration:8)
        try LyricsRepair.validateOriginal("Bright road\nWe return",duration:8)
        for text in ["", "[by:Example]", "[00:01.00]Bright road\nUntimed words", "[00:01.00]\nUntimed words", "[00:25.00]Beyond audio", String(repeating:"word ",count:12_001)] {
            XCTAssertThrowsError(try LyricsRepair.validateOriginal(text,duration:8))
        }
        for duration in [0,601,Double.nan] { XCTAssertThrowsError(try LyricsRepair.validateOriginal("Bright road",duration:duration)) }
    }
    func testIndependentChangesAndBoundaryInsertionsKeepTheirOrder() throws {
        let review = try LyricsRepair(original:"Bright roan and quiet niht",transcript:transcript("[00:00.10]A Bright road and quiet night falls"))
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        XCTAssertEqual(LyricsDocument(text:try review.applying(edits)).lines.map(\.text),["A Bright road and quiet night falls"])
    }
    func testManualInsertionTimesMustStayInsideTheAudioAndBetweenNeighboringLines() throws {
        let review = try LyricsRepair(original:"[00:01.00]Bright road\n[00:05.00]We return",transcript:transcript("[00:01.00]Bright road\n[00:03.00]Walk beside me\n[00:05.00]We return"))
        let proposal = try XCTUnwrap(review.proposals.first)
        for time in [-1,6,9,Double.nan,Double.infinity] {
            XCTAssertThrowsError(try review.applying([proposal.id:.init(text:proposal.suggested,startTime:time)]))
        }
        let written = try review.applying([proposal.id:.init(text:proposal.suggested,startTime:2.5)])
        XCTAssertEqual(LyricsDocument(text:written).lines.map(\.time),[1,2.5,5])
        XCTAssertEqual(LyricsDocument(text:written).sliced(from:1,duration:5).attribution,"Reparada con IA · ElevenLabs")
    }
    func testPunctuationCaseAndUnicodeAreComparedWithoutDamagingOriginalText() throws {
        let original = "[ar:Álvaro]\n[00:01.00]¡Sí, corazón!"
        let review = try LyricsRepair(original:original,transcript:transcript("[00:01.00]sí corazón"))
        XCTAssertTrue(review.proposals.isEmpty)
        XCTAssertEqual(try review.applying([:]),original)
    }
    func testOffsetAndUnaffectedTimesSurviveAWordCorrection() throws {
        let original = "[offset:500]\n[00:01.00]Bright roan\n[00:03.00]We return"
        let review = try LyricsRepair(original:original,transcript:transcript("[00:00.50]Bright road\n[00:02.50]We return"))
        let change = try XCTUnwrap(review.proposals.first)
        let output = try review.applying([change.id:.init(text:change.suggested)])
        XCTAssertEqual(LyricsDocument(text:output).lines.map(\.time),[0.5,2.5])
    }
    func testRepairUsesTheSameOffsetTagAsTheReader() throws {
        for header in ["[offset:invalid]\n[offset:500]","[offſet:500]","[oﬀset:500]","[OFFSET:+500]"] {
            let original = "[ar:Example]\n" + header + "\n[00:01.00]Bright roan\n[00:03.00]We return"
            XCTAssertNoThrow(try LyricsRepair.validateOriginal(original,duration:2.8),header)
            let review = try LyricsRepair(original:original,transcript:transcript("[00:00.50]Bright road\n[00:02.50]We return"))
            let edits = Dictionary(uniqueKeysWithValues:review.proposals.filter { $0.kind != .unrecognized }.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
            do {
                let text = try review.applying(edits), written = LyricsDocument(text:text)
                XCTAssertEqual(written.lines.map(\.text),["Bright road","We return"],header)
                XCTAssertEqual(written.lines.map(\.time),[0.5,2.5],header)
                XCTAssertTrue(text.contains("[ar:Example]"))
            } catch { XCTFail("Unexpected draft failure for \(header): \(error)") }
        }
    }
    func testCompoundHeadersRetainMetadataWithoutApplyingTheOffsetTwice() throws {
        for header in ["[ar:Example][offset:200]","[offset:200][ar:Example]","[ar:Example] [offſet:200]","[offset:invalid][ar:Example][OFFSET:+200]","[ar:Example][oﬀset:200]","[offset:200][ar:Example][offset:800]"] {
            let original = header + "\n[00:01.30]Bright roan\n[00:03.30]We return"
            try LyricsRepair.validateOriginal(original,duration:5)
            let review = try LyricsRepair(original:original,transcript:transcript("[00:01.10]Bright road\n[00:03.10]We return",duration:5))
            let change = try XCTUnwrap(review.proposals.first { $0.kind == .correction })
            do {
                let text = try review.applying([change.id:.init(text:change.suggested)])
                XCTAssertTrue(text.contains("[ar:Example]"),header)
                XCTAssertEqual(LyricsDocument(text:text).lines.map(\.text),["Bright road","We return"],header)
                XCTAssertEqual(LyricsDocument(text:text).lines.map(\.time),[1.1,3.1],header)
            } catch { XCTFail("Compound header failed: \(header): \(error)") }
        }
    }
    func testTimedRepeatedChorusesAreMatchedToTheirOwnOccurrence() throws {
        let original = "[00:01.00]Bright road\n[00:05.00]We return"
        let source = LyricsTranscript(plainText:"Bright road\nWe return\nWe return",syncedText:"[00:01.00]Bright road\n[00:03.00]We return\n[00:05.00]We return",duration:8,
            words:[.init(text:"Bright",start:1,end:1.2),.init(text:"road",start:1.3,end:1.5),.init(text:"We",start:3,end:3.2),.init(text:"return",start:3.3,end:3.5),.init(text:"We",start:5,end:5.2),.init(text:"return",start:5.3,end:5.5)])
        let review = try LyricsRepair(original:original,transcript:source)
        let addition = try XCTUnwrap(review.proposals.first { $0.kind == .completion })
        XCTAssertEqual(addition.start,3)
        let output = try review.applying([addition.id:.init(text:addition.suggested)])
        XCTAssertEqual(LyricsDocument(text:output).lines.map(\.time),[1,3,5])
    }
    func testLegacyPhraseTimesKeepRepeatedChorusesInTheirOwnIntervals() throws {
        let original = "[00:10.00]We sing softly\n[00:20.00]Come home\n[00:30.00]Come home"
        let source = "[00:10.00]We sing brightly\n[00:15.00]home come home\n[00:20.00]Come back\n[00:30.00]Come back"
        let review = try LyricsRepair(original:original,transcript:transcript(source,duration:40))
        XCTAssertTrue(review.usesPhraseTiming)
        let edits = Dictionary(uniqueKeysWithValues:review.proposals.filter { $0.kind != .unrecognized }.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let written = LyricsDocument(text:try review.applying(edits))
        XCTAssertEqual(written.lines.map(\.text),["We sing brightly","home come home","Come back","Come back"])
        XCTAssertEqual(written.lines.map(\.time),[10,15,20,30])
        let completed = LyricsDocument(text:try review.applying(edits,onlyCompletions:true))
        XCTAssertEqual(completed.lines.map(\.text),["We sing softly","home come home","Come home","Come home"])
        XCTAssertEqual(completed.lines.map(\.time),[10,15,20,30])
    }
    func testLegacyPhraseGroupingPreservesTheOriginalLineTimes() throws {
        let original = "[00:01.00]Bright road\n[00:02.00]Walk with me\n[00:03.00]We return"
        let merged = try LyricsRepair(original:original,transcript:transcript("[00:01.00]Bright road Walk with you We return"))
        let edits = Dictionary(uniqueKeysWithValues:merged.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let written = LyricsDocument(text:try merged.applying(edits))
        XCTAssertEqual(written.lines.map(\.text),["Bright road","Walk with you","We return"])
        XCTAssertEqual(written.lines.map(\.time),[1,2,3])

        let split = try LyricsRepair(original:"[00:01.00]Bright road Walk with me We return",transcript:transcript("[00:01.00]Bright road\n[00:02.00]Walk with you\n[00:03.00]We return"))
        let splitEdits = Dictionary(uniqueKeysWithValues:split.proposals.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
        let splitResult = LyricsDocument(text:try split.applying(splitEdits))
        XCTAssertEqual(splitResult.lines.map(\.text),["Bright road Walk with you We return"])
        XCTAssertEqual(splitResult.lines.map(\.time),[1])
    }
    func testOffsetsCannotChangeLegacyPhraseMatching() throws {
        let source = "[00:01.10]We sing brightly\n[00:01.60]home come home\n[00:02.10]Come back\n[00:03.10]Come back"
        let originals = [
            "[00:01.10]We sing softly\n[00:02.10]Come home\n[00:03.10]Come home",
            "[offset:200]\n[00:01.30]We sing softly\n[00:02.30]Come home\n[00:03.30]Come home",
            "[offset:-200]\n[00:00.90]We sing softly\n[00:01.90]Come home\n[00:02.90]Come home"
        ]
        for original in originals {
            let review = try LyricsRepair(original:original,transcript:transcript(source,duration:4))
            for only in [false,true] {
                let edits = Dictionary(uniqueKeysWithValues:review.proposals.filter { $0.kind != .unrecognized }.map { ($0.id,LyricsRepair.Edit(text:$0.suggested)) })
                do {
                    let written = LyricsDocument(text:try review.applying(edits,onlyCompletions:only))
                    XCTAssertEqual(written.lines.map(\.text),only ? ["We sing softly","home come home","Come home","Come home"] : ["We sing brightly","home come home","Come back","Come back"])
                    XCTAssertEqual(written.lines.map(\.time),[1.1,1.6,2.1,3.1])
                } catch { XCTFail("Equivalent offset timeline failed: \(original), complete only: \(only): \(error)") }
            }
        }
    }
    func testMixedTimingIsRejectedInsteadOfDroppingUntimedWords() {
        XCTAssertThrowsError(try LyricsRepair(original:"[00:01.00]Bright road\nKeep these words",transcript:transcript("[00:01.00]Bright road")))
    }
    func testUnknownSelectionsAndInsertedLrcControlsAreRejected() throws {
        let review = try LyricsRepair(original:"Bright roan",transcript:transcript("[00:01.00]Bright road"))
        XCTAssertThrowsError(try review.applying([999:.init(text:"other")]))
        let change = try XCTUnwrap(review.proposals.first)
        XCTAssertThrowsError(try review.applying([change.id:.init(text:"[offset:9999]road")]))
    }
    func testEditsCannotFormControlsWithSurroundingOriginalText() throws {
        let cases = [
            ("[00:bad]\nWe sing","[00:01.00]00 twenty\n[00:03.00]We sing","bad","20"),
            ("[Singer:Guest]\nWe sing","[00:01.00]Artist Guest\n[00:03.00]We sing","Singer","ar"),
            ("[ar:Guest] wrong\nWe sing","[00:01.00]ar Guest\n[00:03.00]We sing","wrong",""),
            ("[00:01.00][off:20000]We sing\n[00:03.00]We return","[00:01.00]offish 20000 We sing\n[00:03.00]We return","off","offset")
        ]
        for (original,source,word,edit) in cases {
            let review = try LyricsRepair(original:original,transcript:transcript(source))
            let change = try XCTUnwrap(review.proposals.first { $0.original == word })
            XCTAssertThrowsError(try review.applying([change.id:.init(text:edit)]),original) { error in
                guard case LyricsRepairError.invalidSelection = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }
    func testUnchangedLiteralBracketsRemainVisibleWhenOtherWordsAreRepaired() throws {
        for literal in ["[00:99]","[ar:Guest]"] {
            let review = try LyricsRepair(original:literal + " wrong\nWe sing",transcript:transcript("[00:01.00]" + literal.replacingOccurrences(of:"[",with:"").replacingOccurrences(of:"]",with:"") + " right\n[00:03.00]We sing"))
            let change = try XCTUnwrap(review.proposals.first { $0.original == "wrong" })
            let written = LyricsDocument(text:try review.applying([change.id:.init(text:"right")]))
            XCTAssertEqual(written.lines.map(\.text),[literal + " right","We sing"])
            XCTAssertFalse(written.isTimed)
        }
    }
}
