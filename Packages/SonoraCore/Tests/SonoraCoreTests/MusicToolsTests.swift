import XCTest
@testable import SonoraCore

final class MusicToolsTests: XCTestCase {
    func testTempoKeepsAnEstimateWhenWindowsAreUncertainOrVariable() throws {
        let windows = [98.0, 112, 126, 140].map { BeatGrid(period: 60 / $0, anchor: 0, confidence: 0.6) }
        let estimate = TempoEstimate.combine(windows)
        let bpm = try XCTUnwrap(estimate.bpm, "Uncertain rhythmic audio still needs a numeric estimate")
        XCTAssertTrue((98...140).contains(bpm))
        XCTAssertTrue(estimate.variable)
        XCTAssertGreaterThan(estimate.confidence, 0)
        XCTAssertLessThan(estimate.confidence, 0.6)
    }

    func testEstimatedTempoHandlesOffbeatsAndHumanTimingWithoutInventingAStableGrid() throws {
        for bpm in [85.0, 105, 120, 145, 170] {
            let energy = musicalEnergy(bpm: bpm)
            let estimate = TempoEstimate.estimate(energy: energy)
            XCTAssertEqual(try XCTUnwrap(estimate.bpm, "\(bpm) BPM"), bpm, accuracy: 2)
            XCTAssertGreaterThan(estimate.confidence, 0)
        }
        XCTAssertNil(RhythmAnalyzer.estimate(energy: musicalEnergy(bpm: 120)),
                     "The strict detector may reject a signal that still has a useful tempo estimate")
        for energy in [Array(repeating: 0.0, count: 2000), Array(repeating: 0.02, count: 2000),
                       [Double.nan] + Array(repeating: 0, count: 1999)] {
            XCTAssertNil(TempoEstimate.estimate(energy: energy).bpm)
        }
    }

    private func musicalEnergy(bpm: Double) -> [Double] {
        let period = 60 / bpm
        var energy = [Double](repeating: 0.02, count: 2000)
        for beat in 0..<Int(20 / period) {
            for (fraction, amplitude) in [(0.0, 0.4), (0.5, 0.22), (0.75, 0.11)] {
                let time = Double(beat) * period + fraction * period + 0.025 * sin(Double(beat) * 1.7)
                let center = Int(time * 100)
                for i in max(0, center - 4)...min(1999, center + 4) {
                    energy[i] += amplitude * (0.8 + 0.2 * cos(Double(beat))) * exp(-pow((Double(i) / 100 - time) / 0.018, 2))
                }
            }
        }
        return energy
    }

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
