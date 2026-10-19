import XCTest
@testable import SonoraCore

final class LyricsDraftTests: XCTestCase {
    func testTrimPreservesCuesHeadersLineEndingsAndInternalWhitespace() {
        let source = " [by:Someone] \r\n[offset:200]\r\n[00:01.20][00:08.200] \tFirst  phrase\t \r\n\r\n[01:12:345]\tCanci\u{00f3}n \u{1f3b5} \r\n[01:13]  \r\n"
        let expected = " [by:Someone] \r\n[offset:200]\r\n[00:01.20][00:08.200]First  phrase\r\n\r\n[01:12:345]Canci\u{00f3}n \u{1f3b5}\r\n[01:13]\r\n"
        let trimmed = LyricsDraft.trimmingPhraseWhitespace(in: source)
        XCTAssertEqual(trimmed, expected)
        XCTAssertEqual(LyricsDraft(text: trimmed).lines.map(\.time), LyricsDraft(text: source).lines.map(\.time))
        XCTAssertEqual(LyricsDraft.trimmingPhraseWhitespace(in: trimmed), trimmed)
    }

    func testTrimKeepsStanzasAndDoesNotModifyDraftWhileTyping() {
        let source = "  First  phrase \t\n\n\tSecond\tphrase  \r  Last \n"
        let draft = LyricsDraft(text: source)
        XCTAssertEqual(draft.text, source)
        XCTAssertEqual(LyricsDraft.trimmingPhraseWhitespace(in: source), "First  phrase\n\nSecond\tphrase\rLast\n")
        XCTAssertEqual(LyricsDraft.trimmingPhraseWhitespace(in: ""), "")
        XCTAssertEqual(LyricsDraft.trimmingPhraseWhitespace(in: " \n\t\n"), " \n\t\n")
    }

    func testOpeningAndPreviewingPreservesSourceAndMixedUntimedLines() throws {
        let source = "[by:Someone]\r\n[offset:200]\r\n[00:01]First\r\nMissing time\r\n\r\n[00:03]Last"
        let draft = LyricsDraft(text: source)
        XCTAssertEqual(draft.text, source)
        XCTAssertEqual(draft.lines.map(\.text), ["First", "Missing time", "Last"])
        XCTAssertEqual(draft.lines.map(\.time), [0.8, nil, 2.8])
        XCTAssertEqual(draft.alignmentText, "First\nMissing time\n\nLast")
        let edited = try draft.replacing(draft.lines[1].id, text: "Corrected", time: 1.9, duration: 10)
        XCTAssertEqual(LyricsDocument(text: edited).lines.map(\.text), ["First", "Corrected", "Last"])
        XCTAssertEqual(LyricsDocument(text: edited).lines.map(\.time), [0.8, 1.9, 2.8])
        XCTAssertTrue(edited.contains("[by:Someone]")); XCTAssertFalse(edited.contains("[offset:"))
        XCTAssertEqual(draft.text, source, "Editing returns a new value, never mutates the original")
    }
    func testRepeatedCuesCanBeEditedIndividuallyAndAlignInSongOrder() throws {
        let draft = LyricsDraft(text: "[00:01][00:08]Chorus\n[00:04]Verse")
        XCTAssertEqual(draft.alignmentText, "Chorus\nVerse\nChorus")
        let changed = try draft.replacing(draft.lines[1].id, text: "Final chorus", time: 8.1, duration: 10)
        XCTAssertEqual(LyricsDocument(text: changed).lines.map(\.text), ["Chorus", "Verse", "Final chorus"])
        XCTAssertEqual(LyricsDocument(text: changed).lines.map(\.time), [1, 4, 8.1])
    }
    func testInvalidTimesAndInjectedControlsAreRejected() throws {
        let draft = LyricsDraft(text: "[00:01]Original")
        for time in [-1, 10, .infinity, .nan] {
            XCTAssertThrowsError(try draft.replacing("0-0", text: "Changed", time: time, duration: 10))
        }
        for text in ["New\nline", "[00:02]Wrong", "[offset:100]", "bad\0"] {
            XCTAssertThrowsError(try draft.replacing("0-0", text: text, time: 2, duration: 10))
        }
        XCTAssertThrowsError(try draft.replacing("stale-id", text: "Changed", time: 2, duration: 10))
    }
    func testAlignmentPreservesStanzasAndPunctuationWithoutTimingOrAttribution() {
        let original = "Hello, world!\n\nAgain"
        XCTAssertEqual(LyricsDraft(text: LyricsDocument.aiRepairMarker + "\n" + original).alignmentText, original)
        XCTAssertEqual(LyricsDraft(text: "[ar:Artist]\n[00:01]Hello, world!\n\n[00:03]Again").alignmentText, original)
    }
    func testSavingPartiallyTimedDraftIdentifiesThePhraseInsteadOfHidingIt() throws {
        XCTAssertNoThrow(try LyricsDraft(text: "First\nLast").validateForPlayback())
        XCTAssertNoThrow(try LyricsDraft(text: "[00:01]First\n[00:02]Last").validateForPlayback())
        XCTAssertThrowsError(try LyricsDraft(text: "[00:01]First\nMissing cue").validateForPlayback()) {
            XCTAssertTrue($0.localizedDescription.contains("Missing cue"))
        }
    }

}
