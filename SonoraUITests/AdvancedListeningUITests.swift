import XCTest

final class AdvancedListeningUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testListeningSettingsTimerAndAdaptiveModePersistInBothThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche", "-listeningSettings", "", "-sleepTimer", ""]; app.launch()
        XCTAssertTrue(app.buttons["Ajustes"].waitForExistence(timeout: 15)); app.buttons["Ajustes"].tap(); app.buttons["Escucha"].tap()
        app.buttons["normalizationMode"].tap(); app.buttons["Por álbum"].tap()
        let balance = app.sliders["listeningBalance"]
        balance.adjust(toNormalizedSliderPosition: 0.75)
        let value = balance.value as? String
        app.buttons["Pausar después de…"].tap()
        XCTAssertTrue(app.buttons["15 minutos"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["15 minutos"].tap()
        XCTAssertTrue(app.buttons["Cancelar temporizador"].exists)
        capture("listening-noche", app)
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["Ajustes"].tap(); app.buttons["Escucha"].tap()
        XCTAssertEqual(app.sliders["listeningBalance"].value as? String, value)
        XCTAssertTrue(app.buttons["Cancelar temporizador"].exists)
        XCTAssertTrue(app.staticTexts["Por álbum"].exists)
        app.buttons["Cancelar temporizador"].tap(); app.buttons["Al terminar esta canción"].tap()
        XCTAssertTrue(app.buttons["Cancelar temporizador"].exists)
        capture("sleep-at-track-end", app)
        app.buttons["Cancelar temporizador"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Entre canciones"].tap()
        app.buttons["Mezcla automática (beta)"].tap()
        XCTAssertTrue(app.sliders["crossfadeDuration"].isEnabled)
        capture("adaptive-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Papel"].tap(); app.buttons["Escucha"].tap()
        capture("listening-papel", app)
        app.buttons["Centrar balance"].tap()
        app.buttons["normalizationMode"].tap(); app.buttons["Desactivada"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["Entre canciones"].tap(); app.buttons["Continua"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Listo"].tap()
    }
}
