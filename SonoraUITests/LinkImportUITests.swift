import XCTest

final class LinkImportUITests: XCTestCase {
    @MainActor func testAddLinkRejectsInvalidAddressAndPreservesSourcesInBothThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for theme in ["noche", "papel"] {
            app.launchArguments = ["-appearance", theme]
            if theme == "papel" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
            let sourceCount = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source:")).count
            app.buttons["Añadir música"].tap()
            let addLink = app.buttons["addLinkSource"]
            XCTAssertTrue(addLink.waitForExistence(timeout: 5))
            for _ in 0..<5 where !addLink.isHittable { app.swipeUp() }
            addLink.tap()
            XCTAssertTrue(app.navigationBars["Añadir enlace"].waitForExistence(timeout: 5))
            let input = app.textFields["transferLink"]
            XCTAssertTrue(input.exists); input.tap(); input.typeText("https://example.test/album.zip")
            let start = app.buttons["startLinkImport"]
            if !start.isHittable { app.swipeUp() }
            start.tap()
            XCTAssertTrue(app.staticTexts["linkImportError"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["cancelLinkImport"].exists)
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "link-import-invalid-" + theme; image.lifetime = .keepAlways; add(image)
            app.navigationBars["Añadir enlace"].buttons["Listo"].tap()
            app.navigationBars["Añadir música"].buttons["Listo"].tap()
            XCTAssertTrue(app.navigationBars["Fuentes"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "source:")).count, sourceCount)
            app.terminate()
        }
    }
}
