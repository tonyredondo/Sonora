import XCTest

final class SourceFileDeletionUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func reveal(_ item: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.waitForExistence(timeout: 10)); XCTAssertTrue(item.isHittable)
    }
    @MainActor func testCueDeletionImmediatelyUpdatesTheSourceSongList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let name = "CUE Borrado QA"
        app.launchArguments = ["-appearance", "noche"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        app.beginLinkingFolder()
        app.selectSyntheticFolder(["Sonora Borrado QA", name])
        let source = app.buttons["source:" + name]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); reveal(source, in: app); source.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "library-song:borrar.flac").count, 2)
        app.buttons["browseSourceFiles"].tap()
        reveal(app.buttons["file-options:borrar.flac"], in: app)
        app.buttons["file-options:borrar.flac"].tap(); app.buttons["Eliminar archivo"].tap()
        app.alerts.firstMatch.buttons["Eliminar archivo"].tap()
        let issue = app.staticTexts["sourceFilesError"]
        XCTAssertTrue(issue.waitForExistence(timeout: 10)); XCTAssertTrue(issue.label.contains("CUE"))
        XCTAssertTrue(app.buttons["source-file:borrar.flac"].exists)
        app.buttons["Cerrar aviso"].tap()
        reveal(app.buttons["file-options:album.cue"], in: app)
        app.buttons["file-options:album.cue"].tap(); app.buttons["Eliminar archivo"].tap()
        app.alerts.firstMatch.buttons["Eliminar archivo"].tap()
        XCTAssertTrue(app.buttons["file-options:album.cue"].waitForNonExistence(timeout: 10))
        app.navigationBars[name].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons.matching(identifier: "library-song:borrar.flac").firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "library-song:borrar.flac").count, 1)
        capture("cue-deleted-source-updated", app)
        app.navigationBars[name].buttons.element(boundBy: 0).tap()
        app.buttons["source-options:" + name].tap(); app.buttons["Quitar de la biblioteca"].tap()
        app.alerts.firstMatch.buttons["Quitar de la biblioteca"].tap()
        XCTAssertTrue(source.waitForNonExistence(timeout: 10))
        app.terminate()
    }
    /// Run scripts/seed-file-deletion-simulator.py first. Deletes only its marked fixtures.
    @MainActor func testSourceBrowserConfirmsFileAndRecursiveFolderDeletionInBothThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for (theme, name) in [("noche", "Borrado Noche QA"), ("papel", "Borrado Papel QA")] {
            app.launchArguments = ["-appearance", theme]
            if theme == "papel" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
            app.beginLinkingFolder()
            app.selectSyntheticFolder(["Sonora Borrado QA", name])
            let source = app.buttons["source:" + name]
            XCTAssertTrue(source.waitForExistence(timeout: 15)); reveal(source, in: app)
            if theme == "papel" {
                app.buttons["source-options:" + name].tap(); app.buttons["Explorar archivos"].tap()
            } else {
                source.tap()
                let browse = app.buttons["browseSourceFiles"]
                XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.tap()
            }
            let file = app.buttons["source-file:borrar.flac"]
            reveal(file, in: app)
            file.tap()
            app.buttons["file-options:borrar.flac"].tap(); app.buttons["Eliminar archivo"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Archivos o iCloud Drive")).firstMatch.exists)
            capture("delete-original-confirmation-" + theme, app)
            alert.buttons["Cancelar"].tap()
            XCTAssertTrue(file.exists, "Cancel must keep the file")
            app.buttons["file-options:borrar.flac"].tap(); app.buttons["Eliminar archivo"].tap()
            app.alerts.firstMatch.buttons["Eliminar archivo"].tap()
            XCTAssertTrue(file.waitForNonExistence(timeout: 15))
            XCTAssertTrue(app.buttons["source-file:conservar.flac"].exists)
            let folder = app.buttons["source-file:Subcarpeta QA"]
            if !folder.isHittable { app.swipeDown() }
            folder.tap()
            XCTAssertTrue(app.buttons["source-file:Subcarpeta QA/Profunda"].waitForExistence(timeout: 5))
            app.navigationBars["Subcarpeta QA"].buttons.element(boundBy: 0).tap()
            app.buttons["file-options:Subcarpeta QA"].tap(); app.buttons["Eliminar carpeta"].tap()
            app.alerts.firstMatch.buttons["Eliminar carpeta"].tap()
            XCTAssertTrue(folder.waitForNonExistence(timeout: 15))
            capture("source-files-after-deletion-" + theme, app)
            app.navigationBars[name].buttons.element(boundBy: 0).tap()
            if theme == "noche" { app.navigationBars[name].buttons.element(boundBy: 0).tap() }
            app.buttons["source-options:" + name].tap(); app.buttons["Quitar de la biblioteca"].tap()
            app.alerts.firstMatch.buttons["Quitar de la biblioteca"].tap()
            XCTAssertTrue(source.waitForNonExistence(timeout: 10))
            app.terminate()
        }
    }
    @MainActor func testDownloadedCopyCanBeBrowsedAndDeletedWithoutRemovingOriginal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "noche"]
        app.launch(); app.assertLibraryHome(); reveal(app.buttons["Disponible sin conexión"], in: app); app.buttons["Disponible sin conexión"].tap()
        app.buttons["importLocalFolder"].tap()
        app.selectSyntheticFolder(["Sonora Borrado QA", "Descarga Borrado QA"])
        XCTAssertTrue(app.staticTexts["localImportCompleted"].waitForExistence(timeout: 20))
        let browse = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browseLocalCopy:")).matching(NSPredicate(format: "label == %@", "Explorar archivos"))
        // This fixture is the newest import and therefore the first copy.
        reveal(browse.firstMatch, in: app); browse.firstMatch.tap()
        let file = app.buttons["source-file:borrar.flac"]
        reveal(file, in: app)
        app.buttons["file-options:borrar.flac"].tap(); app.buttons["Eliminar archivo"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "copia guardada en Sonora")).firstMatch.waitForExistence(timeout: 5))
        capture("delete-local-file-confirmation", app)
        alert.buttons["Eliminar archivo"].tap()
        XCTAssertTrue(file.waitForNonExistence(timeout: 15))
        app.navigationBars["Descarga Borrado QA · Local"].buttons.element(boundBy: 0).tap()
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteLocalCopy:")).firstMatch
        reveal(remove, in: app); remove.tap(); app.buttons["Eliminar copia de Sonora"].tap()
        XCTAssertTrue(app.staticTexts["Descarga Borrado QA"].waitForNonExistence(timeout: 15))
        capture("local-copy-removed", app)
        // Import the untouched original again, then exercise the shortcut in Fuentes.
        reveal(app.buttons["importLocalFolder"], in: app); app.buttons["importLocalFolder"].tap()
        app.selectSyntheticFolder(["Sonora Borrado QA", "Descarga Borrado QA"])
        XCTAssertTrue(app.staticTexts["localImportCompleted"].waitForExistence(timeout: 20))
        app.navigationBars["Copias locales"].buttons.element(boundBy: 0).tap()
        app.buttons["Fuentes"].tap()
        let source = app.buttons["source:Descarga Borrado QA · Local"]
        reveal(source, in: app)
        app.buttons["source-options:Descarga Borrado QA · Local"].tap(); app.buttons["Eliminar copia de Sonora"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        capture("delete-copy-from-sources", app)
        app.alerts.firstMatch.buttons["Cancelar"].tap()
        XCTAssertTrue(source.exists)
        app.buttons["source-options:Descarga Borrado QA · Local"].tap(); app.buttons["Eliminar copia de Sonora"].tap()
        app.alerts.firstMatch.buttons["Eliminar copia de Sonora"].tap()
        XCTAssertTrue(source.waitForNonExistence(timeout: 15))
        app.terminate()
    }
}
