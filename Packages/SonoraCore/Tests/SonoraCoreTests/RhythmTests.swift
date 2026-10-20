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

    func testReferenceTempoShapesTheFadeWithoutSkippingOrClaimingBeatAlignment() throws {
        let plan = try XCTUnwrap(AdaptiveMixPlanner.estimated(outgoingBPM: 100, incomingBPM: 135,
            end: 12, earliestStart: 7, incomingPosition: 0.25, incomingDuration: 20, maximumOverlap: 5))
        XCTAssertEqual(plan.bpm, 100)
        XCTAssertEqual(plan.duration, 4.8, accuracy: 0.001)
        XCTAssertEqual(plan.fadeStart, 7.2, accuracy: 0.001)
        XCTAssertEqual(plan.incomingSkip, 0)
        let short = try XCTUnwrap(AdaptiveMixPlanner.estimated(outgoingBPM: nil, incomingBPM: 40,
            end: 12, earliestStart: 11.5, incomingPosition: 19, incomingDuration: 20, maximumOverlap: 5))
        XCTAssertEqual(short.duration, 0.5)
        XCTAssertEqual(short.incomingSkip, 0)
        for bpm in [nil, Double.nan, .infinity, 0, 301] {
            XCTAssertNil(AdaptiveMixPlanner.estimated(outgoingBPM: bpm, incomingBPM: nil,
                end: 12, earliestStart: 7, incomingPosition: 0, incomingDuration: 20, maximumOverlap: 5))
        }
        for end in [Double.nan, .infinity, 6] {
            XCTAssertNil(AdaptiveMixPlanner.estimated(outgoingBPM: 120, incomingBPM: 120,
                end: end, earliestStart: 7, incomingPosition: 0, incomingDuration: 20, maximumOverlap: 5))
        }
    }

    func testAdaptivePlanAlignsUsefulEstimatesAndShortensOverlapForDrift() throws {
        let outgoing = BeatGrid(period: 60 / 108, anchor: 0.1, confidence: 0.55)
        let incoming = BeatGrid(period: 60 / 110.2, anchor: 0.25, confidence: 0.5)
        let decision = AdaptiveMixPlanner.plan(outgoing: outgoing, incoming: incoming,
            end: 12.3, earliestStart: 7.3, incomingPosition: 0, incomingDuration: 20, maximumOverlap: 5)
        guard case .matched(let plan) = decision else {
            return XCTFail("A useful estimate should align the entry, not always fall back to a fade")
        }
        XCTAssertEqual(plan.incomingSkip, 0.25, accuracy: 0.001)
        XCTAssertEqual(plan.fadeStart, outgoing.nextBeat(at: plan.fadeStart), accuracy: 0.001)
        XCTAssertGreaterThan(plan.duration, outgoing.period * 2)
        XCTAssertLessThan(plan.duration, 5, "Shorten the overlap instead of discarding a close tempo pair")
        let drift = plan.duration / outgoing.period * abs(outgoing.period - incoming.period)
        XCTAssertLessThanOrEqual(drift, min(0.1, outgoing.period * 0.15))
    }

    func testMixingEstimatesBeatPhaseDespiteOffbeatsAndHumanTiming() throws {
        for bpm in [100.0, 120, 150] {
            let period = 60 / bpm
            var values = [Double](repeating: 0.02, count: 800)
            for beat in 0..<Int(8 / period) {
                for (fraction, amplitude) in [(0.0, 0.4), (0.5, 0.22), (0.75, 0.11)] {
                    let time = 0.15 + Double(beat) * period + fraction * period + 0.025 * sin(Double(beat) * 1.7)
                    let center = Int(time * 100)
                    let lower = max(0, center - 4), upper = min(799, center + 4)
                    guard lower <= upper else { continue }
                    for i in lower...upper {
                        values[i] += amplitude * (0.8 + 0.2 * cos(Double(beat))) * exp(-pow((Double(i) / 100 - time) / 0.018, 2))
                    }
                }
            }
            if bpm == 120 { XCTAssertNil(RhythmAnalyzer.estimate(energy: values), "Exercise the formerly rejected phase") }
            let grid = try XCTUnwrap(RhythmAnalyzer.estimateForMixing(energy: values, start: 10), "\(bpm) BPM")
            XCTAssertEqual(grid.bpm, bpm, accuracy: 2)
            let expected = 10 + 0.15 + ceil((3 - 0.15) / period) * period
            XCTAssertEqual(grid.nextBeat(at: 13), expected, accuracy: 0.06, "The estimate must recover phase, not only tempo")
            XCTAssertGreaterThanOrEqual(grid.confidence, 0.35)
        }
        XCTAssertNil(RhythmAnalyzer.estimateForMixing(energy: Array(repeating: 0, count: 800)))
        XCTAssertNil(RhythmAnalyzer.estimateForMixing(energy: Array(repeating: 0.1, count: 800)))
        XCTAssertNil(RhythmAnalyzer.estimateForMixing(energy: energy(bpm: 120), start: .nan))
    }
}
