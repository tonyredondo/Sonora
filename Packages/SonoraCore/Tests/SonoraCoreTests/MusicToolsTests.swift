import XCTest
@testable import SonoraCore

final class MusicToolsTests: XCTestCase {
    func testEstimatedTempoPrefersHalfTimeAbove170IncludingExistingCache() throws {
        for (measured, expected) in [(90.0, 90.0), (170, 170), (170.1, 85.05), (180, 90), (239, 119.5), (300, 150)] {
            let json = Data("{\"bpm\":\(measured),\"confidence\":0.65,\"variable\":true}".utf8)
            let cached = try JSONDecoder().decode(TempoEstimate.self, from: json)
            XCTAssertEqual(try XCTUnwrap(cached.bpm), expected, accuracy: 0.0001)
            XCTAssertEqual(cached.confidence, 0.65)
            XCTAssertTrue(cached.variable)
            let restored = try JSONDecoder().decode(TempoEstimate.self, from: JSONEncoder().encode(cached))
            XCTAssertEqual(restored, cached, "Repeated cache reads must not halve the result again")
        }
        let consensus = TempoEstimate.combine(estimates: [
            .init(bpm: 180, confidence: 0.8, variable: false),
            .init(bpm: 90, confidence: 0.8, variable: false),
            .init(bpm: 181, confidence: 0.8, variable: false)
        ])
        XCTAssertEqual(try XCTUnwrap(consensus.bpm), 90 + 0.5 / 3, accuracy: 0.0001)
        XCTAssertFalse(consensus.variable, "Double-time detection is not a tempo change")
        XCTAssertEqual(try SongAnnotations(bpm: 180).validated(duration: 30).bpm, 180)
        XCTAssertEqual(try XCTUnwrap(TapTempo.bpm(taps: [0, 1.0 / 3, 2.0 / 3, 1])), 180, accuracy: 0.001)
        XCTAssertFalse(SongAnalysis(duration: 30, waveform: [0.1],
                                   tempo: .init(bpm: 301, confidence: 1, variable: false)).isValid)
    }

    func testWaveformPreservesQuietIntroSilenceAndWholeSongScale() {
        let analysis = SongAnalysis(duration: 8, waveform: [0, 0, 0.1, 0.1, 0.5, 0.5, 0.25, 0.25],
                                    tempo: TempoEstimate(bpm: nil, confidence: 0, variable: true))
        let levels = analysis.waveformLevels(count: 4)
        for (actual, expected) in zip(levels, [Float(0), 0.2, 1, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        let silence = SongAnalysis(duration: 8, waveform: [0, 0], tempo: analysis.tempo)
        XCTAssertEqual(silence.waveformLevels(count: 5), [0, 0, 0, 0, 0])
        let noise = SongAnalysis(duration: 8, waveform: [0.001], tempo: analysis.tempo)
        XCTAssertEqual(noise.waveformLevels(count: 1)[0], 0.02, accuracy: 0.0001)
    }

    func testWaveformAveragesEnergyAcrossBarBoundariesInsteadOfSelectingPeaks() {
        let analysis = SongAnalysis(duration: 3, waveform: [1, 0, 0],
                                    tempo: TempoEstimate(bpm: nil, confidence: 0, variable: true))
        let levels = analysis.waveformLevels(count: 2)
        XCTAssertEqual(levels[0], Float(sqrt(2.0 / 3)), accuracy: 0.0001)
        XCTAssertEqual(levels[1], 0)
        XCTAssertEqual(analysis.waveformLevels(count: 0), [])
        XCTAssertEqual(analysis.waveformLevels(count: 3000).count, 1024)
    }

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
    func testContextualPhrasesMustCoverOriginalLinesExactlyOnceInOrder() throws {
        let document = LyricsDocument(text: "[00:01]A red\n[00:04]car\n[00:06]\n[00:07]passes by.")
        typealias Phrase = LyricTranslation.Phrase
        let valid = try LyricTranslation(phrases: [Phrase(lineIDs: [0, 1], text: "Un coche rojo"), Phrase(lineIDs: [3], text: "pasa.")], document: document)
        XCTAssertEqual(valid.lines, [0: "Un coche rojo", 3: "pasa."])
        for ids in [[0, 3], [1, 0, 3], [0, 1, 1, 3], [0, 1, 2, 3], [0, 1, 9]] {
            XCTAssertThrowsError(try LyricTranslation(phrases: [Phrase(lineIDs: ids, text: "Texto")], document: document))
        }
        XCTAssertThrowsError(try LyricTranslation(phrases: [Phrase(lineIDs: [0, 1, 3], text: " ")], document: document))
        // The optional phrase field keeps existing independent-line cache files readable.
        let legacy = Data(#"{"lines":{"0":"Un","1":"coche","3":"pasa."}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LyricTranslation.self, from: legacy).validated(for: document).lines[1], "coche")
    }
}
