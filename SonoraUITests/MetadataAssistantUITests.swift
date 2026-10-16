import XCTest

/// Synthetic metadata and original demo audio only; the HTTP fixture runs on localhost:18089.
final class MetadataAssistantUITests: XCTestCase {
    private let recordingID = "11111111-1111-4111-8111-111111111111"
    private let releaseID = "22222222-2222-4222-8222-222222222222"
    @MainActor private func replace(_ field: XCUIElement, _ value: String) {
        field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func setSwitch(_ control: XCUIElement, to enabled: Bool) {
        let value = enabled ? "1" : "0"
        if control.value as? String != value {
            // SwiftUI exposes the whole labelled row as the switch frame. Tap its control at the trailing edge.
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(control.value as? String, value)
    }
    @MainActor private func showConnection(_ app: XCUIApplication) {
        app.buttons["Ajustes"].tap()
        let connection = app.buttons["metadataAssistantSettings"]
        for _ in 0..<4 where !connection.isHittable { app.swipeUp() }
        connection.tap()
    }
    @MainActor private func showAssistant(_ app: XCUIApplication) {
        app.buttons["openNowPlaying"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        let complete = app.buttons["completeMetadata"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.tap()
        // iOS can offer Passwords after leaving a SecureField. Decline the fixture token.
        if app.buttons["Not Now"].waitForExistence(timeout: 2) { app.buttons["Not Now"].tap() }
        XCTAssertTrue(app.buttons["metadataSearch"].waitForExistence(timeout: 10))
    }

    @MainActor func testUnsavedTokenRequiresSaveAndAuthenticationFailureIsVisible() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch(); showConnection(app)
        let offline = app.switches["metadataOffline"]
        setSwitch(offline, to: false)
        replace(app.textFields["metadataEndpoint"], "http://127.0.0.1:18089")
        replace(app.secureTextFields["metadataToken"], "wrong-ui-fixture-token")
        XCTAssertFalse(app.buttons["testMetadataConnection"].isEnabled, "The test must not verify a previously saved token while displaying an unsaved one")
        app.buttons["saveMetadataConnection"].tap(); app.buttons["testMetadataConnection"].tap()
        let message = app.staticTexts["metadataConnectionMessage"]
        let rejected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in message.label.contains("rechazado") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rejected], timeout: 10), .completed)
        capture("assistant-invalid-token", app)
    }
    @MainActor private func chooseEdition(_ app: XCUIApplication) {
        app.buttons["metadataSearch"].tap()
        let recording = app.buttons["recording:\(recordingID)"]
        _ = recording.waitForExistence(timeout: 2)
        for _ in 0..<5 where !recording.isHittable { app.swipeUp() }
        XCTAssertTrue(recording.waitForExistence(timeout: 10), app.debugDescription); recording.tap()
        let release = app.buttons["release:\(releaseID)"]
        XCTAssertTrue(release.waitForExistence(timeout: 10)); release.tap()
        XCTAssertTrue(app.switches["metadataOnlyMissing"].waitForExistence(timeout: 15))
    }
    @MainActor private func applyAll(_ app: XCUIApplication) {
        setSwitch(app.switches["metadataOnlyMissing"], to: false)
        XCTAssertEqual(app.switches["metadataOnlyMissing"].value as? String, "0")
        XCTAssertEqual(app.switches["suggestion-title"].value as? String, "1")
        capture("assistant-replacements-selected", app)
        let apply = app.buttons["applyMetadataSuggestions"]
        for _ in 0..<12 where !apply.isHittable { app.swipeUp() }
        XCTAssertTrue(apply.isEnabled); apply.tap()
    }

    @MainActor private func openDemoFolder(_ app: XCUIApplication) {
        app.buttons["playFolder"].tap()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 30))
        if !app.staticTexts["Sonora QA"].exists && !app.staticTexts["En directo"].exists {
            app.buttons["Browse"].tap()
            let local = app.staticTexts["On My iPhone"]
            XCTAssertTrue(local.waitForExistence(timeout: 10)); local.tap(); app.staticTexts["Sonora"].tap()
        }
        if !app.staticTexts["En directo"].exists {
            let folder = app.cells.containing(.staticText, identifier: "Sonora QA").firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.images.firstMatch.tap()
        }
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(app.buttons["track:01 - Luz de madrugada.flac"].waitForExistence(timeout: 15))
        if app.buttons["Pausar"].exists { app.buttons["miniTransport"].tap() }
    }

    @MainActor func testReviewBeforeSaveAndOfflineReuseAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche", "-folderSnapshot", ""]; app.launch()
        XCTAssertTrue(app.buttons["playFolder"].waitForExistence(timeout: 15)); openDemoFolder(app)
        showConnection(app)
        let offline = app.switches["metadataOffline"]
        setSwitch(offline, to: false)
        replace(app.textFields["metadataEndpoint"], "http://127.0.0.1:18089")
        replace(app.secureTextFields["metadataToken"], "sonora-ui-fixture-token")
        app.buttons["saveMetadataConnection"].tap()
        app.buttons["testMetadataConnection"].tap()
        let message = app.staticTexts["metadataConnectionMessage"]
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in message.label.contains("Conexión comprobada") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed)
        capture("assistant-connection-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap()
        let original = app.staticTexts["playerTitle"].label
        app.buttons["Cerrar reproductor"].tap()
        showAssistant(app); chooseEdition(app)
        XCTAssertEqual(app.switches["metadataOnlyMissing"].value as? String, "1")
        capture("assistant-preview-noche", app)
        applyAll(app)
        XCTAssertEqual(app.textFields["metadata-title"].value as? String, "Luz sugerida QA")
        app.buttons["Cancelar"].tap()
        XCTAssertEqual(app.staticTexts["playerTitle"].label, original, "Applying suggestions must not write the file")
        app.buttons["Cerrar reproductor"].tap()
        showConnection(app); setSwitch(app.switches["metadataOffline"], to: true)
        capture("assistant-offline-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 where !app.buttons["Papel"].isHittable { app.swipeDown() }
        app.buttons["Papel"].tap(); app.buttons["Listo"].tap()
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        showAssistant(app)
        XCTAssertEqual(app.textFields["lookupTitle"].value as? String, original)
        chooseEdition(app)
        XCTAssertTrue(app.staticTexts["metadataCachedResult"].exists)
        capture("assistant-preview-papel-offline", app)
        applyAll(app)
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.staticTexts["Luz sugerida QA"].waitForExistence(timeout: 10))
        app.buttons["Letra"].tap()
        XCTAssertTrue(app.buttons["Letra encontrada QA"].waitForExistence(timeout: 5))
        capture("assistant-saved-lyrics-papel", app)
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap()
        showConnection(app); setSwitch(app.switches["metadataOffline"], to: false)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 where !app.buttons["Noche"].isHittable { app.swipeDown() }
        app.buttons["Noche"].tap(); app.buttons["Listo"].tap()
    }
}
