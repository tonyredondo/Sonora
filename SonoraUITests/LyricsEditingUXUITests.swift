import XCTest

final class LyricsEditingUXUITests: XCTestCase {
    @MainActor private func launch(theme: String = "noche", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES", "-showArtworkLyrics", "YES", "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch(); app.assertLibraryHome(); return app
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor private func show(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
    @MainActor private func openTimedLyrics(_ app: XCUIApplication) {
        app.openMusicSource("Sonora Lyrics QA")
        let options = app.buttons["options-song:02 - Letra sincronizada QA.flac"]; show(options, app); options.tap()
        app.buttons["Letra"].tap(); XCTAssertTrue(app.buttons["editLyricsText"].waitForExistence(timeout: 15))
    }
    @MainActor func testTimedLyricsCanSynchronizeAgainAndDraftCanBeAuditionedThenDiscarded() {
        let app = launch(); openTimedLyrics(app)
        let resync = app.buttons["synchronizeUntimedLyrics"]; show(resync, app)
        XCTAssertEqual(resync.label, "Sincronizar de nuevo"); resync.tap()
        let action = app.buttons["synchronizeLyrics"]
        XCTAssertTrue(action.waitForExistence(timeout: 10)); XCTAssertTrue(action.isEnabled)
        capture("resynchronize-existing-timing", app)
        app.navigationBars["Sincronizar letra"].buttons["Cancelar"].tap()
        let raw = app.textViews["metadata-lyrics"]; XCTAssertTrue(raw.waitForExistence(timeout: 5))
        let original = raw.value as? String ?? ""
        app.segmentedControls["lyricsDraftMode"].buttons["Frases"].tap()
        let phrase = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "draft-phrase-")).firstMatch
        XCTAssertTrue(phrase.waitForExistence(timeout: 5)); phrase.tap()
        XCTAssertTrue(app.textFields["draftPhraseTime"].waitForExistence(timeout: 5))
        let text = app.descendants(matching: .any).matching(identifier: "draftPhraseText").firstMatch
        text.tap(); text.typeText(" QA draft")
        app.buttons["+0,1 s"].tap(); app.buttons["applyDraftPhrase"].tap()
        app.buttons["openDraftPreview"].tap()
        XCTAssertTrue(app.scrollViews["draftLyricsPreview"].waitForExistence(timeout: 5))
        // A sheet may leave its presenting editor in the accessibility tree.
        // Exercise the visible transport, and require exactly one usable control.
        let transports = app.buttons.matching(identifier: "draftPlayback").allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(transports.count, 1)
        guard let playback = transports.first else { return }
        if playback.label == "Pausar previsualización" { playback.tap() }
        playback.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar previsualización"), object: playback)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let skips = app.buttons.matching(identifier: "draftSkipForward").allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(skips.count, 1)
        guard let skip = skips.first else { return }
        skip.tap()
        XCTAssertEqual(app.sliders.matching(identifier: "draftPlaybackTimeline").allElementsBoundByIndex.filter(\.isHittable).count, 1)
        let active = app.buttons.matching(NSPredicate(format: "value == %@", "Línea actual del borrador")).firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        XCTAssertTrue(active.isHittable, "The preview must scroll to the currently sung draft phrase")
        capture("lyrics-draft-preview-with-transport", app)
        playback.tap(); XCTAssertEqual(playback.label, "Reproducir previsualización")
        app.buttons["closeDraftPreview"].tap()
        XCTAssertTrue(app.navigationBars["Previsualizar borrador"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["metadataSave"].isEnabled, "The phrase edit must remain a pending draft")
        app.navigationBars["Editar texto"].buttons["Cancelar"].tap()
        XCTAssertTrue(app.buttons["Descartar cambios"].waitForExistence(timeout: 5)); app.buttons["Descartar cambios"].tap()
        XCTAssertTrue(app.navigationBars["Editar texto"].waitForNonExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["editLyricsText"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        app.buttons["editLyricsText"].tap(); XCTAssertTrue(raw.waitForExistence(timeout: 10))
        XCTAssertEqual(raw.value as? String, original, "Audition and discard must never save the draft")
        app.navigationBars["Editar texto"].buttons["Cancelar"].tap()
    }
    @MainActor func testCreatePlaylistSelectSongsSearchAndManageInsideIt() {
        let app = launch(); app.tabBars.buttons["Listas"].tap(); app.buttons["Nueva lista"].tap()
        let name = "Editing UX " + String(UUID().uuidString.prefix(6))
        let field = app.textFields["playlistName"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.buttons["Crear"].tap()
        XCTAssertTrue(app.navigationBars["Añadir canciones"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch; search.tap(); search.typeText("Letra sincronizada QA")
        let song = app.buttons["playlist-pick-02 - Letra sincronizada QA.flac"]
        XCTAssertTrue(song.waitForExistence(timeout: 5)); song.tap()
        capture("playlist-select-from-library", app)
        app.buttons["confirmPlaylistSongs"].tap()
        let list = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5)); list.tap()
        XCTAssertTrue(app.buttons["addPlaylistSongs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["managePlaylist"].isHittable)
        capture("playlist-visible-actions", app)
        app.buttons["addPlaylistSongs"].tap(); XCTAssertTrue(app.navigationBars["Añadir canciones"].waitForExistence(timeout: 5))
        let searchAgain = app.searchFields.firstMatch; searchAgain.tap(); searchAgain.typeText("Letra sincronizada QA")
        XCTAssertTrue(song.waitForExistence(timeout: 5)); XCTAssertFalse(song.isEnabled, "Existing songs cannot be added twice")
        app.buttons["cancelPlaylistSongs"].tap()
        XCTAssertTrue(app.buttons["cancelPlaylistSongs"].waitForNonExistence(timeout: 5))
        app.buttons["managePlaylist"].tap()
        XCTAssertTrue(app.buttons["Eliminar playlist"].waitForExistence(timeout: 5)); app.buttons["Eliminar playlist"].tap()
        XCTAssertTrue(app.buttons["Eliminar playlist"].waitForExistence(timeout: 5)); app.buttons["Eliminar playlist"].tap()
        XCTAssertTrue(app.navigationBars["Listas"].waitForExistence(timeout: 5)); XCTAssertFalse(list.exists)
    }
    @MainActor func testSearchScopeAlbumDensityAndBulkReview() {
        let app = launch(); app.tabBars.buttons["Buscar"].tap()
        let search = app.searchFields.firstMatch; search.tap(); search.typeText("Sonora Tests\n")
        app.buttons["searchScope-Canciones"].tap()
        XCTAssertFalse(app.buttons["search-artist:sonora tests"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-song:")).firstMatch.exists)
        capture("search-song-filter", app)
        app.tabBars.buttons["Biblioteca"].tap(); app.buttons["Álbumes"].tap(); app.buttons["library-album:sonora tests\0letras en portada"].tap()
        XCTAssertTrue(app.buttons["editAlbum"].isHittable)
        XCTAssertTrue(app.buttons["library-song:01 - Letra completa QA.flac"].isHittable)
        capture("compact-album-actions", app)
        app.buttons["editAlbum"].tap(); XCTAssertTrue(app.navigationBars["Editar álbum"].waitForExistence(timeout: 10))
        let toggle = app.switches["bulk-apply-album"]; XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); XCTAssertEqual(toggle.value as? String, "1")
        let value = app.textFields["bulk-field-album"]; XCTAssertTrue(value.waitForExistence(timeout: 5)); value.tap(); value.typeText(" draft")
        app.buttons["Guardar"].tap(); XCTAssertTrue(app.navigationBars["Revisar cambios"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Actual: Letras en portada"].exists)
        XCTAssertTrue(app.staticTexts["Nuevo: Letras en portada draft"].exists)
        capture("bulk-metadata-before-after", app)
        app.buttons["Volver"].tap(); app.buttons["Cancelar"].tap(); app.buttons["Descartar cambios"].tap()
    }
    @MainActor func testMetadataEditorLoadsSidecarLyricsWithoutCreatingChanges() {
        let app = launch(); app.openMusicSource("Sonora Lyrics QA")
        let options = app.buttons["options-song:02 - Letra sincronizada QA.flac"]; show(options, app); options.tap()
        app.buttons["Editar información"].tap()
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["metadataSave"].isEnabled, "Reading a sidecar must not mark metadata as edited")
        let edit = app.buttons["editLyrics"]; show(edit, app); edit.tap()
        let text = app.textViews["metadata-lyrics"]; XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue((text.value as? String ?? "").contains("Línea sincronizada"), "General metadata editing must load the same effective lyrics as the lyrics screen")
        XCTAssertTrue(app.buttons["draftPlayback"].isHittable)
        app.navigationBars["Editar letra"].buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["metadataSave"].isEnabled)
        app.navigationBars["Información"].buttons["Cancelar"].tap()
    }

    @MainActor func testPartiallyTimedDraftShowsTheMissingPhraseAndDoesNotSave() {
        let app = launch(); app.openMusicSource("Sonora Lyrics QA")
        let options = app.buttons["options-song:03 - Sin letra QA.flac"]; show(options, app); options.tap(); app.buttons["Letra"].tap()
        XCTAssertTrue(app.buttons["findMissingLyrics"].waitForExistence(timeout: 10)); app.buttons["editLyricsText"].tap()
        let text = app.textViews["metadata-lyrics"]; XCTAssertTrue(text.waitForExistence(timeout: 10)); XCTAssertEqual(text.value as? String, "")
        text.tap(); text.typeText("[00:01]First\nMissing cue")
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.alerts["No se pudo guardar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Missing cue")).firstMatch.exists)
        app.buttons["Volver al borrador"].tap(); app.navigationBars["Editar texto"].buttons["Cancelar"].tap(); app.buttons["Descartar cambios"].tap()
        XCTAssertTrue(app.navigationBars["Editar texto"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["findMissingLyrics"].waitForExistence(timeout: 10))
    }

    @MainActor func testDraftTransportAndControlsInPapelLargeText() {
        let app = launch(theme: "papel", large: true); openTimedLyrics(app)
        app.buttons["editLyricsText"].tap(); XCTAssertTrue(app.buttons["draftPlayback"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["draftPlayback"].isHittable)
        XCTAssertTrue(app.buttons["draftSkipForward"].isHittable)
        XCTAssertTrue(app.buttons["openDraftPreview"].isHittable)
        capture("lyrics-editor-papel-large-text", app)
        app.buttons["openDraftPreview"].tap()
        XCTAssertTrue(app.scrollViews["draftLyricsPreview"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "draftPlayback").allElementsBoundByIndex.filter(\.isHittable).count, 1)
        capture("lyrics-preview-papel-large-text", app)
        app.buttons["closeDraftPreview"].tap()
        app.navigationBars["Editar texto"].buttons["Cancelar"].tap()
    }
}
