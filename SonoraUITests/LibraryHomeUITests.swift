import XCTest

final class LibraryHomeUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }

    @MainActor private func chooseSourceAction(_ action: String, source: String, app: XCUIApplication) {
        app.buttons["source-options:" + source].tap()
        let item = app.buttons[action]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        // iOS 27 exposes the menu with mixed Button/PopUpButton attributes.
        // Tap the rendered item after it becomes hittable.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Run on a fresh Simulator before tests that import music.
    @MainActor func testEmptyLibraryOffersSourceManagementAndPickerCanBeCancelled() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome()
        XCTAssertTrue(app.buttons["addMusic"].exists)
        capture("library-empty-noche", app)
        app.buttons["Fuentes"].tap()
        XCTAssertTrue(app.staticTexts["Sin fuentes"].waitForExistence(timeout: 5))
        app.beginLinkingFolder()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 20))
        app.buttons["Cancel"].tap()
        app.navigationBars["Añadir música"].buttons["Listo"].tap()
        XCTAssertTrue(app.navigationBars["Fuentes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sin fuentes"].exists)
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
        app.assertLibraryHome()
    }

    @MainActor func testHomeIsLibraryAndSourcesAreManagedSeparately() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "noche"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Biblioteca"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["Biblioteca"].buttons["Listo"].exists)
        for category in ["Artistas", "Álbumes", "Canciones"] {
            XCTAssertTrue(app.buttons[category].exists, category)
        }
        XCTAssertTrue(app.tabBars.buttons["Listas"].exists)
        XCTAssertTrue(app.tabBars.buttons["Buscar"].exists)
        XCTAssertFalse(app.buttons["Reproducir carpeta"].exists)
        app.buttons["Fuentes"].tap()
        XCTAssertTrue(app.navigationBars["Fuentes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Añadir música"].exists)
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
        XCTAssertTrue(app.navigationBars["Biblioteca"].exists)
        app.buttons["Artistas"].tap()
        XCTAssertTrue(app.navigationBars["Artistas"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Álbumes"].tap()
        XCTAssertTrue(app.navigationBars["Álbumes"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Canciones"].tap()
        XCTAssertTrue(app.navigationBars["Canciones"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-appearance", "papel", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.assertLibraryHome()
        XCTAssertTrue(app.buttons["Fuentes"].isHittable)
        capture("library-home-papel-largest", app)
        app.buttons["Fuentes"].tap()
        XCTAssertTrue(app.navigationBars["Fuentes"].waitForExistence(timeout: 5))
        capture("library-sources-papel-largest", app)
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
    }

    /// Run scripts/seed-library-home-simulator.py first. Only these two sources are removed.
    @MainActor func testSourcesUpdateLibraryAcrossFoldersAndRemovalPersistsWithoutChangingCurrentSong() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome()
        let previous = app.buttons["openNowPlaying"].exists ? app.buttons["openNowPlaying"].label : nil
        app.buttons["Fuentes"].tap()
        for letter in ["A", "B"] {
            app.beginLinkingFolder()
            app.selectSyntheticFolder(["Sonora Home QA", "Fuente \(letter) QA"])
            XCTAssertTrue(app.buttons["source:Fuente \(letter) QA"].waitForExistence(timeout: 15))
        }
        capture("library-two-sources-noche", app)
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
        XCTAssertEqual(app.buttons["openNowPlaying"].exists ? app.buttons["openNowPlaying"].label : nil, previous,
                       "Adding sources must preserve playback")
        app.buttons["Artistas"].tap()
        XCTAssertTrue(app.staticTexts["Artista fuentes QA"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Álbumes"].tap()
        for letter in ["A", "B"] { XCTAssertTrue(app.staticTexts["Álbum fuente \(letter) QA"].waitForExistence(timeout: 10)) }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Buscar"].tap()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Artista fuentes QA")
        for path in ["tema-a.flac", "En directo/tema-b.flac"] {
            XCTAssertTrue(app.buttons["library-song:" + path].waitForExistence(timeout: 10))
        }
        app.buttons["library-song:tema-a.flac"].tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: app.buttons["miniTransport"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        app.buttons["miniTransport"].tap()
        app.terminate(); app.launchArguments = ["-appearance", "papel"]; app.launch(); app.assertLibraryHome()
        XCTAssertTrue(app.buttons["openNowPlaying"].label.contains("Tema fuente A QA"))
        app.buttons["Fuentes"].tap()
        chooseSourceAction("Quitar de la biblioteca", source: "Fuente B QA", app: app)
        capture("source-removal-confirmation", app)
        XCTAssertTrue(app.buttons["Cancelar"].waitForExistence(timeout: 5))
        app.buttons["Cancelar"].tap()
        XCTAssertTrue(app.buttons["source:Fuente B QA"].exists, "Cancelling removal must keep the source")
        chooseSourceAction("Quitar de la biblioteca", source: "Fuente B QA", app: app)
        app.buttons["Quitar de la biblioteca"].tap()
        XCTAssertTrue(app.buttons["source:Fuente B QA"].waitForNonExistence(timeout: 5))
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["openNowPlaying"].label.contains("Tema fuente A QA"))
        XCTAssertEqual(app.buttons["miniTransport"].label, "Reproducir")
        app.buttons["miniQueue"].tap()
        XCTAssertTrue(app.navigationBars["Cola · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.queueRow("tema-a.flac").exists)
        XCTAssertFalse(app.queueRow("En directo/tema-b.flac").exists)
        app.buttons["Listo"].tap()
        app.tabBars.buttons["Buscar"].tap()
        search.tap(); search.typeText("Artista fuentes QA")
        XCTAssertTrue(app.buttons["library-song:tema-a.flac"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["library-song:En directo/tema-b.flac"].exists)
        capture("library-after-removing-source-papel", app)
        app.terminate(); app.launchArguments = ["-appearance", "noche"]; app.launch(); app.assertLibraryHome()
        app.buttons["Fuentes"].tap()
        XCTAssertFalse(app.buttons["source:Fuente B QA"].exists)
        XCTAssertTrue(app.buttons["source:Fuente A QA"].exists)
        chooseSourceAction("Quitar de la biblioteca", source: "Fuente A QA", app: app)
        app.buttons["Quitar de la biblioteca"].tap()
        XCTAssertTrue(app.buttons["source:Fuente A QA"].waitForNonExistence(timeout: 5))
        app.navigationBars["Fuentes"].buttons["Listo"].tap()
        XCTAssertFalse(app.buttons["openNowPlaying"].exists, "Removing the last queued source must clear the queue")
        capture("library-after-removing-all-test-sources", app)
    }
}
