import XCTest

/// Exercises only the synthetic Sonora QA folder created by seed-simulator.py.
final class VolumeAnalysisUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<7 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor func testAnalyzeSongSaveTagsAndRestoreLocalResult() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome()
        app.buttons["Canciones"].tap()
        let options = app.buttons["options-song:01 - Luz de madrugada.flac"]
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap()
        let analyze = app.buttons["analyze-song:01 - Luz de madrugada.flac"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5)); analyze.tap()
        XCTAssertTrue(app.buttons["volumeAnalyze"].waitForExistence(timeout: 5))
        capture("volume-ready-noche", app)
        app.buttons["volumeAnalyze"].tap()
        XCTAssertTrue(app.staticTexts["Análisis completado"].waitForExistence(timeout: 30))
        let result = app.descendants(matching: .any)["volume-result:01 - Luz de madrugada.flac"]
        reveal(result, in: app); XCTAssertTrue(result.label.contains("dB"))
        capture("volume-result-noche", app)
        reveal(app.buttons["Guardar etiquetas…"], in: app); app.buttons["Guardar etiquetas…"].tap()
        app.buttons["Guardar en los archivos"].tap()
        let saved = app.staticTexts["volumeSaveResult"]
        for _ in 0..<5 where !saved.isHittable { app.swipeDown() }
        XCTAssertTrue(saved.waitForExistence(timeout: 20)); XCTAssertEqual(saved.label, "Guardados 1 de 1")
        capture("volume-tags-saved", app)
        app.navigationBars["Analizar volumen"].buttons["Listo"].tap()
        app.terminate(); app.launchArguments = ["-appearance", "papel"]; app.launch()
        app.assertLibraryHome()
        app.buttons["Canciones"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 10)); options.tap(); app.buttons["analyze-song:01 - Luz de madrugada.flac"].tap()
        XCTAssertTrue(app.buttons["volumeAnalyze"].waitForExistence(timeout: 10))
        reveal(result, in: app); XCTAssertTrue(result.label.contains("dB"))
        capture("volume-restored-papel", app)
    }

    @MainActor func testAlbumAnalysisAtLargestTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", "papel", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.assertLibraryHome()
        app.buttons["Álbumes"].tap()
        let album = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-album:")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 10)); album.tap()
        let action = app.buttons["Analizar álbum completo"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); reveal(action, in: app); action.tap()
        XCTAssertTrue(app.staticTexts["Álbum completo"].waitForExistence(timeout: 5))
        reveal(app.buttons["volumeAnalyze"], in: app); app.buttons["volumeAnalyze"].tap()
        XCTAssertTrue(app.staticTexts["Análisis completado"].waitForExistence(timeout: 30))
        reveal(app.staticTexts["volumeAlbumGain"], in: app)
        capture("volume-album-papel-largest", app)
    }

    @MainActor func testSelectionAndRecursiveSourceFolderActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome(); app.buttons["Canciones"].tap()
        app.buttons["Seleccionar"].tap()
        let selectAll = app.buttons["Seleccionar todo"]
        XCTAssertTrue(selectAll.isHittable)
        XCTAssertFalse(selectAll.frame.intersects(app.buttons["openNowPlaying"].frame), "Selection actions must stay above the mini-player")
        capture("library-selection-no-overlap", app)
        selectAll.tap()
        app.buttons["3 seleccionadas"].tap(); app.buttons["Analizar volumen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["3 canciones seleccionadas"].waitForExistence(timeout: 5))
        reveal(app.buttons["volumeAnalyze"], in: app); app.buttons["volumeAnalyze"].tap()
        XCTAssertTrue(app.staticTexts["Análisis completado"].waitForExistence(timeout: 30))
        let nested = app.descendants(matching: .any)["volume-result:En directo/03 - Horizonte.wav"]
        reveal(nested, in: app); XCTAssertTrue(nested.label.contains("dB"))
        capture("volume-selection-noche", app)
        app.navigationBars["Analizar volumen"].buttons["Listo"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.openMusicSource()
        app.buttons["Analizar volumen"].tap()
        XCTAssertTrue(app.staticTexts["3 canciones seleccionadas"].waitForExistence(timeout: 5))
        app.buttons["volumeAnalyze"].tap()
        XCTAssertTrue(app.staticTexts["Análisis completado"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["volumeSummary"].label.contains("Reutilizados 3"))
        capture("volume-folder-reused-noche", app)
    }
}
