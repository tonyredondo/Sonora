import XCTest

/// Uses only the marked synthetic Sonora QA folder seeded by seed-simulator.py.
final class MetadataLyricsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    @MainActor func testWriteTitleAndEmbeddedLyricsThenRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.startDemoPlayback()
        app.buttons["miniTransport"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["Letra"].waitForExistence(timeout: 5)); app.buttons["Opciones de canción"].tap(); app.buttons["Letra"].tap()
        XCTAssertTrue(app.buttons["lyricLine1"].waitForExistence(timeout: 5))
        capture("lyrics-noche-sidecar", app)
        app.buttons["lyricLine1"].tap(); app.buttons["Listo"].tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:05")
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        let title = app.textFields["metadata-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        capture("metadata-noche", app)
        replace(title, with: "Luz editada QA")
        let editLyrics = app.buttons["editLyrics"]
        for _ in 0..<8 where !editLyrics.isHittable { app.swipeUp() }
        XCTAssertTrue(editLyrics.isHittable); editLyrics.tap()
        let editor = app.textViews["metadata-lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        replace(editor, with: "[00:00]Verso incrustado\n[00:05]Segundo verso\n[00:10]Tercer verso")
        capture("lyrics-editor-noche", app)
        app.navigationBars["Editar texto"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["metadataSave"].isEnabled, "Returning from lyrics must preserve unsaved edits")
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["Opciones de canción"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Luz editada QA"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(app.staticTexts["playerTitle"].label, "Luz editada QA")
        app.buttons["Opciones de canción"].tap(); app.buttons["Letra"].tap()
        XCTAssertTrue(app.buttons["Verso incrustado"].waitForExistence(timeout: 5))
        capture("lyrics-noche-embedded", app)
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap()
        app.buttons["Ajustes"].tap(); app.buttons["Papel"].tap(); app.buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap(); app.buttons["Opciones de canción"].tap(); app.buttons["Letra"].tap()
        capture("lyrics-papel-embedded", app)
        app.buttons["editLyricsText"].tap()
        XCTAssertTrue(app.textViews["metadata-lyrics"].waitForExistence(timeout: 5))
        capture("metadata-papel", app)
    }
}
