import XCTest
@testable import SonoraCore

final class MusicToolsTests: XCTestCase {
    func testTempoConsensusRejectsSilenceAndSparseIntroductions() {
        let beat = BeatGrid(period: 0.5, anchor: 0, confidence: 0.95)
        XCTAssertNil(TempoEstimate.combine([nil, nil]).bpm)
        XCTAssertNil(TempoEstimate.combine([beat, nil, nil, nil]).bpm)
        let stable = TempoEstimate.combine([beat, beat, beat, nil])
        XCTAssertEqual(stable.bpm!, 120, accuracy: 0.1)
        XCTAssertEqual(stable.confidence, 0.7125, accuracy: 0.01)
        let variable = TempoEstimate.combine([beat, beat, BeatGrid(period: 0.4, anchor: 0, confidence: 0.9)])
        XCTAssertTrue(variable.variable)
    }
    func testIndependentRatePitchAndInvalidSettings() {
        XCTAssertEqual(PlaybackAdjustment(rate: 1.5, semitones: -3).validated, PlaybackAdjustment(rate: 1.5, semitones: -3))
        XCTAssertEqual(PlaybackAdjustment(rate: .nan, semitones: .infinity).validated, PlaybackAdjustment())
        XCTAssertEqual(PlaybackAdjustment(rate: 20, semitones: -50).validated, PlaybackAdjustment(rate: 2, semitones: -12))
    }
    func testMarkersKeepStableIdentityAndRejectInvalidPositions() throws {
        let a = SongMarker(time: 20, title: "  Solo  "), b = SongMarker(time: 2, title: "Intro")
        let annotations = try SongAnnotations(bpm: 125, markers: [a,b]).validated(duration: 30)
        XCTAssertEqual(annotations.markers.map(\.id), [b.id,a.id]); XCTAssertEqual(annotations.markers.last?.title, "Solo")
        for time in [-1, 30, Double.nan] { XCTAssertThrowsError(try SongAnnotations(markers: [SongMarker(time: time, title: "X")]).validated(duration: 30)) }
        XCTAssertThrowsError(try SongAnnotations(markers: [a,a]).validated(duration: 30))
        XCTAssertThrowsError(try SongAnnotations(bpm: 0).validated(duration: 30))
    }
    func testTapTempoRequiresStableMeasuredIntervals() {
        XCTAssertEqual(TapTempo.bpm(taps: [1,1.5,2,2.5])!, 120, accuracy: 0.01)
        XCTAssertNil(TapTempo.bpm(taps: [1,1.5,2]))
        XCTAssertNil(TapTempo.bpm(taps: [1,1.5,2,4]))
        XCTAssertNil(TapTempo.bpm(taps: [1,1,1,1]))
    }
    func testTranslationPreservesRepeatedLinesAndRequiresCompleteMapping() throws {
        let document = LyricsDocument(text: "[00:01.00]Hello\n[00:04.00]Hello\n[00:06.00]\n[00:07.00]World")
        let translation = try LyricTranslation(lines: [3:"Mundo",1:"Hola",0:"Hola"], document: document)
        XCTAssertEqual(translation.lines[1], "Hola")
        XCTAssertEqual(document.lines[1].time, 4)
        XCTAssertThrowsError(try LyricTranslation(lines: [0:"Hola"], document: document))
        XCTAssertThrowsError(try LyricTranslation(lines: [3:"Mundo",1:"",0:"Hola"], document: document))
        XCTAssertThrowsError(try LyricTranslation(lines: [3:"Mundo",1:"Hola",0:"Hola",9:"Extra"], document: document))
    }
}
