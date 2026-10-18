import XCTest

final class ListeningToolsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testCrossfadeSelectionDurationAndPersistenceInBothThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-transitionSettings", ""]
        app.launch(); app.buttons["Ajustes"].tap(); app.buttons["Noche"].tap()
        app.openSoundTool("Transiciones entre canciones")
        let duration = app.sliders["crossfadeDuration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertFalse(duration.isEnabled, "Continuous is the default mode")
        app.buttons["Crossfade"].tap()
        XCTAssertTrue(duration.isEnabled)
        duration.adjust(toNormalizedSliderPosition: 0.8)
        let saved = try XCTUnwrap(duration.value as? String)
        XCTAssertNotEqual(saved, "5 segundos")
        capture("crossfade-noche", app: app)
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["Ajustes"].tap(); app.openSoundTool("Transiciones entre canciones")
        XCTAssertTrue(app.sliders["crossfadeDuration"].isEnabled)
        XCTAssertEqual(app.sliders["crossfadeDuration"].value as? String, saved)
        app.returnToSettings()
        app.buttons["Papel"].tap(); app.openSoundTool("Transiciones entre canciones")
        capture("crossfade-papel", app: app)
        app.buttons["Continua"].tap()
        XCTAssertFalse(app.sliders["crossfadeDuration"].isEnabled)
        capture("continuous-papel", app: app)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.buttons["Ajustes"].tap(); app.openSoundTool("Transiciones entre canciones")
        app.buttons["Crossfade"].tap()
        let largeSlider = app.sliders["crossfadeDuration"]
        for _ in 0..<6 where !largeSlider.isHittable { app.swipeUp() }
        XCTAssertTrue(largeSlider.isHittable)
        capture("crossfade-papel-accessibility", app: app)
    }

    @MainActor
    func testEqualizerControlsThemesAndSavedManualCurve() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-equalizerSettings", ""]
        app.launch()
        app.buttons["Ajustes"].tap()
        app.buttons["Noche"].tap()
        XCTAssertTrue(app.buttons["Sonido"].waitForExistence(timeout: 5))
        app.openSoundTool("Ecualizador")
        let enabled = app.switches["equalizerEnabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertEqual(enabled.value as? String, "0")
        let nativeSwitch = enabled.switches.firstMatch
        (nativeSwitch.exists ? nativeSwitch : enabled).tap()
        XCTAssertEqual(enabled.value as? String, "1")
        app.buttons["equalizerPreset"].tap()
        app.buttons["Graves"].tap()
        XCTAssertTrue(app.staticTexts["Graves"].exists)
        capture("eq-noche-bass", app: app)
        let mid = app.sliders["eqBand5"]
        XCTAssertTrue(mid.isHittable)
        XCTAssertTrue(mid.isEnabled)
        // XCTest's normalized slider helper drags horizontally even after rotation.
        mid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: mid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(app.staticTexts["Personalizado"].waitForExistence(timeout: 3))
        let manualValue = mid.value as? String
        capture("eq-noche-manual", app: app)
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["Ajustes"].tap(); app.openSoundTool("Ecualizador")
        XCTAssertEqual(app.switches["equalizerEnabled"].value as? String, "1")
        XCTAssertEqual(app.sliders["eqBand5"].value as? String, manualValue)
        app.returnToSettings()
        app.buttons["Papel"].tap(); app.openSoundTool("Ecualizador")
        capture("eq-papel-manual", app: app)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.buttons["Ajustes"].tap(); app.openSoundTool("Ecualizador")
        XCTAssertTrue(app.switches["equalizerEnabled"].isHittable)
        let band = app.sliders["eqBand9"]
        // Drag the scroll gutter slowly. A full-screen fling can skip the target
        // row at AX5; starting on a band can also adjust it instead of scrolling.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.80))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.28))
        for _ in 0..<5 where !band.isHittable {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(band.isHittable)
        capture("eq-papel-accessibility", app: app)
    }
}
