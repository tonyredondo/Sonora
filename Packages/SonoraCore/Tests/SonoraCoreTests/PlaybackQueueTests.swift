import XCTest
@testable import SonoraCore

final class PlaybackQueueTests: XCTestCase {
    func testEmptyReplacementPreservesExistingQueue() {
        var queue = PlaybackQueue()
        XCTAssertTrue(queue.replace(with: [AudioTrack(relativePath: "01.flac")!]))
        XCTAssertFalse(queue.replace(with: []))
        XCTAssertEqual(queue.current?.relativePath, "01.flac")
    }

    func testAdvanceStopsAtEndOrRepeatsAsRequested() {
        var queue = PlaybackQueue()
        queue.replace(with: ["01.flac", "02.flac"].map { AudioTrack(relativePath: $0)! })
        XCTAssertEqual(queue.nextIndex(repeatMode: .off), 1)
        queue.select(index: 1)
        XCTAssertNil(queue.nextIndex(repeatMode: .off))
        XCTAssertEqual(queue.nextIndex(repeatMode: .all), 0)
        XCTAssertEqual(queue.nextIndex(repeatMode: .one), 1)
    }

    func testReorderAndRemovalPreserveCurrentTrackIdentity() {
        var queue = PlaybackQueue()
        queue.replace(with: ["01.wav", "02.wav", "03.wav"].map { AudioTrack(relativePath: $0)! })
        queue.select(index: 1)
        queue.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(queue.current?.id, "02.wav")
        queue.remove(atOffsets: IndexSet(integer: 2))
        XCTAssertEqual(queue.current?.id, "02.wav")
        XCTAssertEqual(queue.tracks.count, 2)
    }
    func testRemovingCurrentAndEarlierEntriesSelectsTheNearestSurvivingSuccessor() {
        for (removed, expected) in [([0, 2], "D.wav"), ([0, 1, 2], "D.wav"), ([0, 2, 3], "E.wav"), ([0, 2, 3, 4], "B.wav")] {
            var queue = PlaybackQueue()
            queue.replace(with: ["A.wav", "B.wav", "C.wav", "D.wav", "E.wav"].map { AudioTrack(relativePath: $0)! })
            queue.select(index: 2)
            queue.remove(atOffsets: IndexSet(removed))
            XCTAssertEqual(queue.current?.relativePath, expected)
        }
    }

}
