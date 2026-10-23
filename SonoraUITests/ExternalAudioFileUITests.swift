import XCTest

/// Only opens the marked synthetic files from seed-open-audio-simulator.py.
final class ExternalAudioFileUITests: XCTestCase {
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor private func openFromFiles(_ name: String, files: XCUIApplication) {
        files.activate()
        let browse = files.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        let local = files.staticTexts["On My iPhone"].firstMatch
        if local.exists { local.tap() }
        if !files.staticTexts["Sonora Open QA"].exists {
            let sonora = files.cells.containing(.staticText, identifier: "Sonora").firstMatch
            XCTAssertTrue(sonora.waitForExistence(timeout: 5), files.debugDescription)
            sonora.images.firstMatch.tap()
        }
        let folder = files.cells.containing(.staticText, identifier: "Sonora Open QA").firstMatch
        let file = files.cells.containing(.staticText, identifier: name).firstMatch
        if !file.exists {
            XCTAssertTrue(folder.waitForExistence(timeout: 15), files.debugDescription)
            folder.images.firstMatch.tap()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 10), files.debugDescription)
        file.press(forDuration: 1)
        capture("files-open-with-menu", app: files)
        let open = files.buttons["Open With"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), files.debugDescription)
        open.tap()
        let target = files.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sonora")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), files.debugDescription)
        target.tap()
    }
    @MainActor func testColdOpenFromFilesPresentsPlayerWithMetadata() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "noche", "-prepareQueueAudio", "NO", "-prepareQueueCharacter", "NO",
                               "-prepareQueueTranslation", "NO", "-prepareQueueMeaning", "NO"]
        app.launch(); app.assertLibraryHome(); app.terminate()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        openFromFiles("First", files: files)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let title = app.staticTexts["playerTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); XCTAssertEqual(title.label, "Desde Archivos")
        XCTAssertEqual(app.staticTexts["playerArtist"].label, "Sonora Open QA")
        XCTAssertEqual(app.staticTexts["playerAlbum"].label, "Prueba externa")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Pausar")
        capture("files-open-cold-player", app: app)
    }
    @MainActor func testWarmOpenFromFilesDismissesSettingsAndReplacesOnlyQueue() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch(); app.assertLibraryHome()
        app.buttons["Ajustes"].tap()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.terminate(); files.launch()
        openFromFiles("Second", files: files)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let title = app.staticTexts["playerTitle"]
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Otro archivo"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        capture("files-open-warm-player", app: app)
        app.buttons["playerQueue"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue-track:"))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.firstMatch.identifier.hasSuffix("Second.WAV"))
    }
}
