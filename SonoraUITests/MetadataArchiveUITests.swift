import XCTest

/// Only the marked, regenerable Sonora QA source. Offline overrides prevent provider calls.
final class MetadataArchiveUITests: XCTestCase {
    @MainActor private func editor(_ app: XCUIApplication) {
        app.buttons["openNowPlaying"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        XCTAssertTrue(app.navigationBars["Información"].waitForExistence(timeout:10))
        for _ in 0..<5 where !app.textFields["metadata-title"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout:10))
    }
    @MainActor private func replaceTitle(_ app: XCUIApplication, _ title: String) {
        let field = app.textFields["metadata-title"]; field.tap()
        field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:(field.value as? String ?? "").count) + title)
    }
    @MainActor private func save(_ app: XCUIApplication) {
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        let finished = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in app.buttons["Opciones de canción"].isHittable },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[finished],timeout:20),.completed)
        app.buttons["Cerrar reproductor"].tap()
    }
    @MainActor private func recover(_ app: XCUIApplication, _ title: String) {
        for _ in 0..<5 where !app.buttons["restoreMetadata"].isHittable { app.swipeDown() }
        app.buttons["restoreMetadata"].tap()
        XCTAssertTrue(app.navigationBars["Recuperar información"].waitForExistence(timeout:10))
        let copy = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ AND label CONTAINS %@","metadata-copy:",title)).firstMatch
        _ = copy.waitForExistence(timeout:2)
        for _ in 0..<8 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.waitForExistence(timeout:15),app.debugDescription); copy.tap()
        let onlyMissing = app.switches["archiveOnlyMissing"]
        XCTAssertTrue(onlyMissing.waitForExistence(timeout:10))
        let apply = app.buttons["applyArchivedMetadata"]
        for _ in 0..<8 {
            if onlyMissing.exists {
                let center = onlyMissing.frame.midY
                if center > app.navigationBars["Revisar copia"].frame.maxY && center < apply.frame.minY - 30 { break }
                if center <= app.navigationBars["Revisar copia"].frame.maxY { app.swipeDown() }
                else { app.swipeUp() }
            } else { app.swipeUp() }
        }
        if onlyMissing.value as? String == "1" { onlyMissing.coordinate(withNormalizedOffset:CGVector(dx:0.93,dy:0.5)).tap() }
        XCTAssertEqual(onlyMissing.value as? String,"0")
        XCTAssertTrue(apply.isEnabled)
        let image = XCTAttachment(screenshot:app.screenshot()); image.name = "confirmed-metadata-preview"; image.lifetime = .keepAlways; add(image)
        app.buttons["applyArchivedMetadata"].tap()
        for _ in 0..<5 where !app.textFields["metadata-title"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.textFields["metadata-title"].value as? String,title)
    }
    @MainActor func testOfflineRecoveryRequiresPreviewAndSaveInBothThemes() throws {
        continueAfterFailure = false
        let first = "Archive first QA", second = "Archive second QA"
        let app = XCUIApplication()
        app.launchArguments = ["-appearance","noche","-metadata.endpoint","","-metadata.offline","YES"]
        app.launch(); app.addDemoSourceFromFiles(); app.startDemoPlayback(); app.buttons["miniTransport"].tap()
        editor(app); replaceTitle(app,first); save(app)
        editor(app); replaceTitle(app,second); save(app)
        editor(app); recover(app,first)
        app.navigationBars["Información"].buttons["Cancelar"].tap()
        app.buttons["Cerrar reproductor"].tap()
        editor(app)
        XCTAssertEqual(app.textFields["metadata-title"].value as? String,second,"Applying a preview must leave the file untouched until Save")
        app.navigationBars["Información"].buttons["Cancelar"].tap(); app.buttons["Cerrar reproductor"].tap()
        app.terminate()
        app.launchArguments = ["-appearance","papel","-metadata.endpoint","","-metadata.offline","YES","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.assertLibraryHome()
        editor(app); recover(app,first); save(app)
        editor(app)
        XCTAssertEqual(app.textFields["metadata-title"].value as? String,first)
    }
}
