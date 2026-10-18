import XCTest

/// Writes only to the marked synthetic Sonora QA fixtures.
final class CollectionUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testFavoritesPlaylistSearchAndBatchAlbumPersist() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        let playlistName = "Sesión QA " + String(UUID().uuidString.prefix(4))
        app.addDemoSourceFromFiles()
        app.openMusicSource(refresh: true)
        XCTAssertTrue(app.buttons["options-song:01 - Luz de madrugada.flac"].waitForExistence(timeout: 10))
        app.closeMusicSource()
        app.buttons["Canciones"].tap()
        let options = app.buttons["Opciones de Luz de madrugada"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        if app.buttons["Quitar de favoritos"].exists {
            app.buttons["Quitar de favoritos"].tap(); options.tap()
        }
        app.buttons["Marcar como favorita"].tap()
        options.tap(); app.buttons["Añadir a lista"].tap(); app.buttons["Nueva lista"].tap()
        let name = app.textFields["playlistName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(playlistName)
        XCTAssertTrue(app.buttons["Crear"].isEnabled); app.buttons["Crear"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        capture("collection-songs-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Listas"].tap()
        XCTAssertTrue(app.staticTexts[playlistName].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", playlistName)).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Luz de madrugada"].exists)
        capture("collection-playlist-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Biblioteca"].tap()
        let favorites = app.buttons["Favoritos"]
        for _ in 0..<5 where !favorites.isHittable { app.swipeUp() }
        favorites.tap()
        XCTAssertTrue(app.staticTexts["Luz de madrugada"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.openMusicSource()
        app.buttons["Seleccionar"].tap(); app.buttons["Seleccionar todo"].tap()
        app.buttons["editSelectedSongs"].tap()
        let albumToggle = app.switches["bulk-apply-album"]
        for _ in 0..<5 where !albumToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(albumToggle.waitForExistence(timeout: 10))
        albumToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(albumToggle.value as? String, "1")
        let album = app.textFields["bulk-field-album"]
        XCTAssertTrue(album.waitForExistence(timeout: 5)); album.tap()
        let previous = album.value as? String ?? ""
        album.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + "Álbum editado QA")
        capture("collection-batch-noche", app)
        app.navigationBars.buttons["Guardar"].tap(); app.buttons["Guardar en todos los archivos"].tap()
        XCTAssertTrue(app.staticTexts["bulkResult"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["bulkResult"].label, "Guardados 3 de 3")
        capture("collection-batch-saved", app)
        app.navigationBars["Información"].buttons["Listo"].tap()
        app.terminate(); app.launchArguments = []; app.launch()
        app.assertLibraryHome()
        app.buttons["Álbumes"].tap()
        XCTAssertTrue(app.staticTexts["Álbum editado QA"].waitForExistence(timeout: 10))
        capture("collection-albums-noche", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Buscar"].tap(); app.searchFields.firstMatch.tap(); app.searchFields.firstMatch.typeText("Sonora Tests")
        XCTAssertTrue(app.staticTexts["Papel y tinta"].waitForExistence(timeout: 5))
        capture("collection-search-noche", app)
    }
}
