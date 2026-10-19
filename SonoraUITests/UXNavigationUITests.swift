import XCTest

/// Uses only the existing, marked Sonora Lyrics QA simulator fixtures. No providers.
final class UXNavigationUITests: XCTestCase {
    @MainActor private func launch(_ theme: String = "noche", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES", "-showArtworkLyrics", "YES"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); app.assertLibraryHome()
        return app
    }
    @MainActor private func capture(_ title: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func show(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    @MainActor private func openLyrics(_ app: XCUIApplication, filename: String) {
        app.openMusicSource("Sonora Lyrics QA")
        let options = app.buttons["options-song:" + filename]; show(options, in: app); options.tap()
        XCTAssertTrue(app.buttons["Letra"].waitForExistence(timeout: 5)); app.buttons["Letra"].tap()
        XCTAssertTrue(app.buttons["editLyricsText"].waitForExistence(timeout: 10))
    }

    @MainActor func testMiniPlayerLeavesLastLibraryActionVisible() {
        for (theme, large) in [("noche", false), ("papel", true)] {
            let app = launch(theme, large: large)
            let player = app.buttons["openNowPlaying"]
            XCTAssertTrue(player.waitForExistence(timeout: 10))
            let offline = app.buttons["Copias en Sonora"]
            // Drag the outer list, away from the horizontal album shelf and player.
            for _ in 0..<6 {
                if offline.exists && offline.frame.maxY <= player.frame.minY { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.25)))
            }
            XCTAssertTrue(offline.exists)
            XCTAssertLessThanOrEqual(offline.frame.maxY, player.frame.minY,
                                     "The entire last row must remain above the mini player")
            XCTAssertTrue(offline.isHittable)
            capture("mini-player-last-row-\(theme)", app)
            offline.tap()
            XCTAssertTrue(app.navigationBars["Copias en Sonora"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["importLocalFolder"].isHittable)
            XCTAssertTrue(player.isHittable)
            app.tabBars.buttons["Listas"].tap()
            XCTAssertTrue(app.navigationBars["Listas"].waitForExistence(timeout: 5))
            XCTAssertTrue(player.isHittable)
            app.tabBars.buttons["Buscar"].tap()
            XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(player.isHittable)
            app.terminate()
        }
    }

    @MainActor func testLibrarySearchAndAlbumArtistEditingAreDirect() {
        let app = launch()
        XCTAssertTrue(app.buttons["addMusic"].isHittable)
        XCTAssertTrue(app.buttons["Fuentes"].isHittable)
        capture("ux-library-noche", app)
        app.tabBars.buttons["Listas"].tap()
        XCTAssertTrue(app.navigationBars["Listas"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Buscar"].tap()
        let search = app.searchFields.firstMatch; search.tap(); search.typeText("Sonora Tests")
        let artist = app.buttons["search-artist:sonora tests"]
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        capture("ux-grouped-search", app)
        artist.tap(); app.buttons["editArtist"].tap()
        XCTAssertTrue(app.switches["bulk-apply-artist"].waitForExistence(timeout: 10))
        app.buttons["Cancelar"].tap()
        app.tabBars.buttons["Biblioteca"].tap(); app.buttons["Álbumes"].tap()
        app.buttons["library-album:sonora tests\0letras en portada"].tap()
        XCTAssertTrue(app.buttons["editAlbum"].isHittable)
        capture("ux-album-noche", app)
        app.buttons["editAlbum"].tap()
        XCTAssertTrue(app.staticTexts["3 canciones"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Letras en portada"].exists)
        app.buttons["Cancelar"].tap()
        app.buttons["Seleccionar"].tap(); app.buttons["Seleccionar todo"].tap()
        XCTAssertTrue(app.staticTexts["3 seleccionadas"].exists)
        let edit = app.buttons["editSelectedSongs"]
        XCTAssertTrue(edit.isHittable)
        XCTAssertFalse(edit.frame.intersects(app.buttons["openNowPlaying"].frame))
        edit.tap(); XCTAssertTrue(app.switches["bulk-apply-album"].waitForExistence(timeout: 5))
        app.buttons["Cancelar"].tap()
    }

    @MainActor func testCreatePlaylistFromSongAndOpenRecentAlbum() {
        let app = launch()
        let recent = app.buttons["Letras en portada, Sonora Tests"]
        show(recent, in: app); recent.tap()
        XCTAssertTrue(app.buttons["editAlbum"].waitForExistence(timeout: 5))
        let song = "options-song:03 - Sin letra QA.flac"
        show(app.buttons[song], in: app); app.buttons[song].tap()
        app.buttons["Añadir a lista"].tap(); app.buttons["Nueva lista"].tap()
        let name = "UX playlist " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["playlistName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["Crear"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[song].waitForExistence(timeout: 5), "Creating a list must return to the song")
        app.tabBars.buttons["Listas"].tap()
        let list = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5)); list.tap()
        XCTAssertTrue(app.buttons["library-song:03 - Sin letra QA.flac"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["BackButton"].tap()
        list.press(forDuration: 1)
        app.buttons["Eliminar playlist"].tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5), "Remove only this test's newly created list")
    }

    @MainActor func testLyricsOpenWithoutChangingPlaybackAndProtectUnsavedText() {
        let app = launch()
        let before = app.buttons["openNowPlaying"].label
        openLyrics(app, filename: "01 - Letra completa QA.flac")
        capture("ux-lyrics-tools", app)
        app.buttons["editLyricsText"].tap()
        let editor = app.textViews["metadata-lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["metadata-title"].exists)
        editor.tap(); editor.typeText(" UX draft")
        XCTAssertTrue(app.buttons["metadataSave"].isEnabled)
        app.buttons["Cancelar"].tap()
        XCTAssertTrue(app.buttons["Descartar cambios"].waitForExistence(timeout: 5))
        app.buttons["Seguir editando"].tap()
        XCTAssertTrue((editor.value as? String ?? "").contains("UX draft"))
        app.buttons["Cancelar"].tap(); app.buttons["Descartar cambios"].tap()
        app.buttons["repairLyrics"].tap()
        XCTAssertTrue(app.buttons["analyzeLyricsRepair"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["analyzeLyricsRepair"].label, "Buscar análisis guardado")
        app.buttons["Volver"].tap()
        app.navigationBars["Letra"].buttons["Listo"].tap()
        app.closeMusicSource("Sonora Lyrics QA")
        XCTAssertEqual(app.buttons["openNowPlaying"].label, before, "Opening another song's lyrics must not replace playback")
    }

    @MainActor func testDirectLyricsSavePersistsAndPreservesMetadata() {
        let app = launch()
        openLyrics(app, filename: "03 - Sin letra QA.flac")
        app.buttons["editLyricsText"].tap()
        let editor = app.textViews["metadata-lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = editor.value as? String ?? ""
        XCTAssertTrue(original.isEmpty, "This test owns only the empty synthetic lyric fixture")
        let savedLyrics = "[00:01.20]Letra de prueba UX\n\n[00:02.38]Segunda línea"
        editor.tap(); editor.typeText("[00:01.20]  Letra de prueba UX  \n\n[00:02.38]  Segunda línea  ")
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["editLyricsText"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Letra de prueba UX"].waitForExistence(timeout: 10))
        app.buttons["editLyricsText"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, savedLyrics)
        capture("ux-lyrics-monospaced-trimmed", app)
        // Restore the marked synthetic fixture through the same real save flow.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: savedLyrics.count))
        XCTAssertEqual(editor.value as? String, "")
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["findMissingLyrics"].waitForExistence(timeout: 15))
        app.navigationBars["Letra"].buttons["Listo"].tap()
        app.buttons["options-song:03 - Sin letra QA.flac"].tap(); app.buttons["Editar información"].tap()
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["metadata-title"].value as? String, "Sin letra QA")
        XCTAssertEqual(app.textFields["metadata-artist"].value as? String, "Sonora Tests")
        app.buttons["Cancelar"].tap()
    }

    @MainActor func testAddMusicSoundQueueAndLargeText() {
        let app = launch("papel", large: true)
        XCTAssertTrue(app.buttons["addMusic"].isHittable)
        app.buttons["addMusic"].tap()
        for id in ["linkMusicFolder", "copyMusicFolder", "addLinkSource"] {
            let button = app.buttons[id]; show(button, in: app)
        }
        capture("ux-add-music-papel-large", app)
        app.navigationBars["Añadir música"].buttons["Listo"].tap()
        openLyrics(app, filename: "02 - Letra sincronizada QA.flac")
        XCTAssertTrue(app.buttons["editLyricsText"].isHittable)
        let repair = app.buttons["repairLyrics"]
        for _ in 0..<5 where !repair.isHittable { app.scrollViews["lyricsTools"].swipeUp() }
        XCTAssertTrue(repair.isHittable)
        capture("ux-lyrics-papel-large", app)
        app.navigationBars["Letra"].buttons["Listo"].tap(); app.closeMusicSource("Sonora Lyrics QA")
        app.buttons["openNowPlaying"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Sonido"].tap()
        XCTAssertTrue(app.buttons["Ecualizador"].waitForExistence(timeout: 5))
        capture("ux-sound-papel-large", app)
        app.navigationBars["Sonido"].buttons["Listo"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Temporizador"].tap()
        XCTAssertTrue(app.navigationBars["Temporizador"].waitForExistence(timeout: 5))
        app.buttons["Listo"].tap()
        app.buttons["playerQueue"].tap()
        XCTAssertTrue(app.staticTexts["Ahora"].waitForExistence(timeout: 5))
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue-options:")).firstMatch
        show(options, in: app); options.tap()
        for title in ["Letra", "Editar información", "Añadir a lista"] { XCTAssertTrue(app.buttons[title].exists) }
    }
}
