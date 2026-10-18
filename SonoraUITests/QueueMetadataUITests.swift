import XCTest

/// Edits only the marked three-song Sonora QA folder in Simulator.
final class QueueMetadataUITests: XCTestCase {
    private let artist = "Artista actualizado QA"
    private let trackIDs = ["01 - Luz de madrugada.flac", "02 - Papel y tinta.mp3", "En directo/03 - Horizonte.wav"]

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor private func checkSearchResults(_ app: XCUIApplication) {
        for id in trackIDs {
            let row = app.buttons["library-song:" + id]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.label.contains(artist), "Saved artist must be visible without playing this song: \(row.label)")
        }
        XCTAssertTrue(app.buttons["library-song:02 - Papel y tinta.mp3"].label.hasPrefix("Papel y tinta"))
    }

    @MainActor func testBatchEditRefreshesLibrarySearchAndQueueTitlesWithoutPlayingEachSong() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.startDemoPlayback(); app.buttons["miniTransport"].tap()
        app.openMusicSource()
        app.buttons["Seleccionar"].tap(); app.buttons["Seleccionar todo"].tap()
        XCTAssertTrue(app.staticTexts["3 seleccionadas"].exists, "The test must edit only the three synthetic demo songs")
        app.buttons["editSelectedSongs"].tap()
        let toggle = app.switches["bulk-apply-artist"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let field = app.textFields["bulk-field-artist"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + artist)
        app.navigationBars["Información"].buttons["Guardar"].tap()
        app.buttons["Guardar en todos los archivos"].tap()
        let result = app.staticTexts["bulkResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 20)); XCTAssertEqual(result.label, "Guardados 3 de 3")
        app.navigationBars["Información"].buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts[artist].firstMatch.waitForExistence(timeout: 10), "Library index must already show saved tags")
        app.closeMusicSource()
        app.buttons["miniQueue"].tap()
        let title = app.queueRow("02 - Papel y tinta.mp3")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.hasPrefix("Papel y tinta"), "Queue must keep embedded titles after editing another tag")
        capture("queue-after-batch-save-noche", app)
        app.buttons["Listo"].tap()
        app.tabBars.buttons["Buscar"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText(artist)
        checkSearchResults(app)
        capture("library-after-batch-save-noche", app)
        app.terminate(); app.launchArguments = ["-appearance", "papel"]; app.launch()
        app.assertLibraryHome()
        search.tap(); search.typeText(artist)
        checkSearchResults(app)
        capture("library-after-relaunch-papel", app)
        app.terminate()
    }
}
