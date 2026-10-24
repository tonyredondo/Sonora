import XCTest

/// Requires seed-open-audio-simulator.py and seed-generated-artwork-simulator.py.
final class GeneratedArtworkUITests: XCTestCase {
    @MainActor func testCachedGeneratedCoverRestoresOffline() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "noche", "-metadata.offline", "YES", "-prepareQueueArtwork", "NO", "-nowPlayingPage", "0"]
        app.launch(); app.assertLibraryHome()
        let player = app.buttons["openNowPlaying"]
        XCTAssertTrue(player.waitForExistence(timeout: 10)); player.tap()
        XCTAssertEqual(app.staticTexts["playerTitle"].label, "Otro archivo")
        let cover = app.descendants(matching: .any).matching(identifier: "playerArtwork").firstMatch
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Portada disponible"), object: cover)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "native-generated-cover-noche"
        attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
    }
}
