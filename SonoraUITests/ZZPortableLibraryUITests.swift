import XCTest

/// Uses only the marked folder created by seed-portable-simulator.py.
final class ZZPortableLibraryUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    @MainActor private func portableFolder(_ app: XCUIApplication, filePicker: Bool = false) {
        let picker = app.otherElements["Browse View (Picker)"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), app.debugDescription)
        if !filePicker { XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 10)) }
        if picker.buttons["Browse"].exists { picker.buttons["Browse"].tap() }
        if picker.staticTexts["On My iPhone"].exists {
            picker.staticTexts["On My iPhone"].tap()
            picker.staticTexts["Sonora"].tap()
        }
        if !picker.staticTexts["Concierto"].exists {
            let folder = picker.cells.containing(.staticText, identifier: "Sonora Portable QA").firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 8), app.debugDescription)
            folder.images.firstMatch.tap()
        }
        XCTAssertTrue(picker.staticTexts["Concierto"].waitForExistence(timeout: 8), app.debugDescription)
    }
    @MainActor func testM3UImportAndExportIncludesIndividualCueTracks() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome()
        app.tabBars.buttons["Listas"].tap(); app.buttons["Importar playlist"].tap()
        app.buttons["chooseM3U"].tap()
        portableFolder(app, filePicker: true)
        let picker = app.otherElements["Browse View (Picker)"].firstMatch
        let file = picker.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "Ruta", "Ruta.m3u8")).firstMatch
        XCTAssertTrue(file.exists, app.debugDescription)
        picker.cells.containing(.staticText, identifier: file.label).firstMatch.images.firstMatch.tap()
        if app.buttons["DOCPicker.actionButton"].exists && app.buttons["DOCPicker.actionButton"].isHittable { app.buttons["DOCPicker.actionButton"].tap() }
        XCTAssertTrue(app.buttons["Elegir carpeta de música"].waitForExistence(timeout: 10))
        app.buttons["Elegir carpeta de música"].tap(); portableFolder(app); app.buttons["DOCPicker.actionButton"].tap()
        let result = app.descendants(matching: .any)["playlistImportResult"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20)); XCTAssertTrue(result.label.contains("3 canciones"))
        XCTAssertFalse(app.staticTexts["Entradas no añadidas"].exists)
        capture("playlist-import-noche", app)
        app.navigationBars["Importar playlist"].buttons["Listo"].tap()
        app.staticTexts["Ruta"].firstMatch.tap()
        let songs = app.descendants(matching: .any)["collectionSongs"].firstMatch
        XCTAssertTrue(songs.staticTexts["Último acto"].waitForExistence(timeout: 10))
        XCTAssertTrue(songs.staticTexts["Primer acto"].exists)
        capture("playlist-cue-order-noche", app)
        app.buttons["Exportar playlist"].tap(); app.buttons["saveM3U"].tap()
        portableFolder(app); app.buttons["DOCPicker.actionButton"].tap()
        let exported = app.descendants(matching: .any)["playlistExportResult"].firstMatch
        XCTAssertTrue(exported.waitForExistence(timeout: 15)); XCTAssertTrue(exported.label.contains(".m3u8"))
        capture("playlist-export-noche", app)
    }
    @MainActor func testLocalCopyCuePlaybackAndPausedRestorationAtLargestTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "papel", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]; app.launch()
        app.assertLibraryHome()
        reveal(app.buttons["Disponible sin conexión"], in: app); app.buttons["Disponible sin conexión"].tap()
        reveal(app.buttons["importLocalFolder"], in: app); app.buttons["importLocalFolder"].tap()
        portableFolder(app); app.buttons["DOCPicker.actionButton"].tap()
        let completed = app.descendants(matching: .any)["localImportCompleted"].firstMatch
        reveal(completed, in: app); XCTAssertTrue(completed.exists)
        capture("local-copy-papel-largest", app)
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playLocalCopy:")).firstMatch
        reveal(play, in: app); play.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["miniQueue"].tap()
        let cue = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "queue-track:", "Primer acto")).firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 15)); reveal(cue, in: app); cue.tap()
        app.buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.staticTexts["playerTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["playerTitle"].label, "Primer acto")
        if app.buttons["playerTransport"].label == "Pausar" { app.buttons["playerTransport"].tap() }
        let viewport = app.windows.firstMatch.frame
        for id in ["playerTitle", "playerVolume", "playerOutput", "playerTransport"] {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists); XCTAssertTrue(viewport.contains(control.frame))
        }
        XCTAssertEqual(app.scrollViews.count, 0)
        capture("cue-player-papel-largest", app)
        app.terminate(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(app.staticTexts["playerTitle"].label, "Primer acto")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        capture("cue-restored-noche", app)
    }
}
