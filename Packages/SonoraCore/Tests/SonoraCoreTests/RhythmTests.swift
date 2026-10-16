import XCTest
@testable import SonoraCore

final class RhythmTests: XCTestCase {
    private func energy(bpm: Double, phase: Double = 0.25, duration: Double = 8) -> [Double] {
        let period = 60 / bpm
        return (0..<Int(duration * 100)).map { index in
            let time = Double(index) / 100
            let beat = phase + ((time - phase) / period).rounded() * period
            return 0.02 + 0.3 * exp(-pow((time - beat) / 0.008, 2))
        }
    }
    func testSteadyPulsesEstimateTempoAndPhaseAndRejectSilenceOrIrregularMaterial() throws {
        for bpm in [60.0, 90, 105, 120, 128, 150, 180] {
            let grid = try XCTUnwrap(RhythmAnalyzer.estimate(energy: energy(bpm: bpm)), "\(bpm) BPM")
            XCTAssertEqual(grid.bpm, bpm, accuracy: 0.8)
            XCTAssertEqual(grid.nextBeat(at: 2.1), 0.25 + ceil((2.1 - 0.25) / (60 / bpm)) * (60 / bpm), accuracy: 0.03)
            XCTAssertGreaterThan(grid.confidence, 0.65)
        }
        XCTAssertNil(RhythmAnalyzer.estimate(energy: Array(repeating: 0, count: 800)))
        XCTAssertNil(RhythmAnalyzer.estimate(energy: (0..<800).map { 0.02 + 0.01 * sin(Double($0) * sqrt(Double($0 + 1))) }))
        XCTAssertNil(RhythmAnalyzer.estimate(energy: energy(bpm: 120, duration: 2)))
        var changingTempo = Array(repeating: 0.02, count: 800), beat = 0.1
        while beat < 8 {
            for index in max(0, Int(beat * 100) - 2)...min(799, Int(beat * 100) + 2) {
                changingTempo[index] += 0.3 * exp(-pow((Double(index) / 100 - beat) / 0.008, 2))
            }
            beat += 60 / (90 + beat * 10)
        }
        XCTAssertNil(RhythmAnalyzer.estimate(energy: changingTempo), "A strongly accelerating tempo must not be treated as a stable beat grid")
    }
    func testAdaptivePlanAlignsBeatsBoundsDriftAndRejectsUnsuitablePairs() throws {
        let outgoing = BeatGrid(period: 0.5, anchor: 4.1, confidence: 0.95)
        let incoming = BeatGrid(period: 0.5, anchor: 0.25, confidence: 0.95)
        let decision = AdaptiveMixPlanner.plan(outgoing: outgoing, incoming: incoming, end: 12.3, earliestStart: 7.3, incomingPosition: 0, incomingDuration: 20, maximumOverlap: 5)
        guard case .matched(let plan) = decision else { return XCTFail("Compatible pulses must get an adaptive plan") }
        XCTAssertEqual(plan.fadeStart, 7.6, accuracy: 0.001)
        XCTAssertEqual(plan.incomingSkip, 0.25, accuracy: 0.001)
        XCTAssertEqual(plan.duration, 4.7, accuracy: 0.001)
        XCTAssertLessThanOrEqual(plan.duration, 5)
        for candidate in [BeatGrid(period: 60 / 95.0, anchor: 0.2, confidence: 0.9), BeatGrid(period: 0.5, anchor: 4.25, confidence: 0.9), BeatGrid(period: 0.5, anchor: 0.25, confidence: 0.2)] {
            if case .matched = AdaptiveMixPlanner.plan(outgoing: outgoing, incoming: candidate, end: 12.3, earliestStart: 7.3, incomingPosition: 0, incomingDuration: 20, maximumOverlap: 5) { XCTFail("Unsuitable rhythm/intro/confidence must fall back") }
        }
    }
}
