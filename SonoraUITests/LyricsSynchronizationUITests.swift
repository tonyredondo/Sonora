import XCTest

/// Real app + Rust proxy + synthetic upstreams. Never uses an ElevenLabs account.
final class LyricsSynchronizationUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func open(_ app: XCUIApplication, filename: String, theme: String, fromLyrics: Bool = false, missingLyrics: Bool = false) {
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        let source = app.buttons["source:Sonora Sync QA"]
        if !source.exists {
            app.beginLinkingFolder(); app.selectSyntheticFolder(["Sonora Sync QA"])
        }
        for _ in 0..<8 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        app.buttons["source-options:Sonora Sync QA"].tap(); app.buttons["Actualizar fuente"].tap()
        source.tap()
        let song = app.buttons["library-song:" + filename]
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        app.closeMusicSource("Sonora Sync QA")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: app.buttons["miniTransport"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        app.buttons["miniTransport"].tap(); app.buttons["openNowPlaying"].tap()
        if fromLyrics {
            let toggle = app.buttons["toggleArtworkLyrics"]
            if toggle.value as? String == "Ocultas" { toggle.tap() }
            app.buttons["expandLyrics"].tap()
            let synchronize = app.buttons[missingLyrics ? "findMissingLyrics" : "synchronizeUntimedLyrics"]
            XCTAssertTrue(synchronize.waitForExistence(timeout: 5)); capture("synchronization-entry-noche", app); synchronize.tap()
            XCTAssertTrue(app.buttons["synchronizeLyrics"].waitForExistence(timeout: 10)); return
        }
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 10))
        let sync = app.buttons["openLyricsSynchronization"]
        for _ in 0..<10 where !sync.isHittable { app.swipeUp() }
        XCTAssertTrue(sync.isHittable); sync.tap()
        XCTAssertTrue(app.buttons["synchronizeLyrics"].waitForExistence(timeout: 5))
    }
    @MainActor func testCatalogPreviewApplyDraftAndCancelPreservesOriginal() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app, filename: "01 - Catálogo sincronizado QA.flac", theme: "noche")
        let before = try await counts()
        app.buttons["synchronizeLyrics"].tap()
        let source = app.staticTexts["lyricsSynchronizationSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 15)); XCTAssertEqual(source.label, "LRCLIB")
        let after = try await counts(); XCTAssertEqual(after["alignment"], before["alignment"], "A catalog hit must not send audio to ElevenLabs")
        capture("synchronization-catalog-preview-noche", app)
        let apply = app.buttons["applySynchronizedLyrics"]
        for _ in 0..<8 where !apply.isHittable { app.swipeUp() }
        apply.tap()
        XCTAssertTrue(app.buttons["metadataSave"].isEnabled)
        app.buttons["editLyrics"].tap()
        let editor = app.textViews["metadata-lyrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); XCTAssertTrue((editor.value as? String ?? "").contains("[00:01.00]Primera línea de Sonora"))
        capture("synchronization-draft-before-save", app)
        app.buttons["BackButton"].tap(); app.buttons["Cancelar"].tap(); app.buttons["Descartar cambios"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        let edit = app.buttons["editLyrics"]
        for _ in 0..<10 where !edit.isHittable { app.swipeUp() }
        edit.tap(); XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Primera línea de Sonora\nSegunda línea de Sonora")
    }
    @MainActor func testElevenLabsFallbackSavedLyricsAppearInPlayerAndOfflineReuse() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app, filename: "02 - Tiempos Eleven QA.flac", theme: "papel")
        app.buttons["synchronizeLyrics"].tap()
        let source = app.staticTexts["lyricsSynchronizationSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 20)); XCTAssertEqual(source.label, "Sincronización por IA")
        let onlineCounts = try await counts()
        XCTAssertEqual(onlineCounts["alignment"], 1, "The real Rust proxy must reach the synthetic alignment provider exactly once")
        capture("synchronization-aligned-preview-papel", app)
        (app.navigationBars["Buscar letra"].exists ? app.navigationBars["Buscar letra"] : app.navigationBars["Sincronizar letra"]).buttons["Cancelar"].tap(); (app.navigationBars["Editar texto"].exists ? app.navigationBars["Editar texto"] : app.navigationBars["Información"]).buttons["Cancelar"].tap()
        app.buttons["Cerrar reproductor"].tap(); app.terminate()
        // Relaunch in offline mode, preserving the original untimed lyrics and local analysis cache.
        app.launchArguments = ["-appearance", "papel", "-metadata.offline", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        let sync = app.buttons["openLyricsSynchronization"]
        for _ in 0..<15 where !sync.isHittable { app.swipeUp() }
        sync.tap()
        let search = app.buttons["synchronizeLyrics"]
        for _ in 0..<15 where !search.isHittable { app.swipeUp() }
        XCTAssertTrue(search.isHittable); search.tap()
        for _ in 0..<15 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 20)); XCTAssertEqual(source.label, "Sincronización por IA")
        let offlineCounts = try await counts(); XCTAssertEqual(offlineCounts, onlineCounts, "Offline reuse must not contact either provider")
        let apply = app.buttons["applySynchronizedLyrics"]
        for _ in 0..<15 where !apply.isHittable { app.swipeUp() }
        capture("synchronization-offline-papel-maximum-text", app)
        XCTAssertTrue(apply.isHittable); apply.tap()
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["Opciones de canción"].waitForExistence(timeout: 15))
        let toggle = app.buttons["toggleArtworkLyrics"]
        if toggle.value as? String == "Ocultas" { toggle.tap() }
        XCTAssertTrue(app.buttons["expandLyrics"].waitForExistence(timeout: 5)); app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["lyricLine0"].waitForExistence(timeout: 10))
    }
    @MainActor private func counts() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: XCTUnwrap(URL(string: "http://127.0.0.1:18092/__stats")))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
    @MainActor func testMissingLyricsTranscriptionPreviewOfflineSaveAndPersistentAttribution() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        open(app, filename: "03 - Sin letra IA QA.flac", theme: "noche", fromLyrics: true, missingLyrics: true)
        XCTAssertEqual(app.buttons["synchronizeLyrics"].label, "Buscar o transcribir", "LRC information headers are not lyric text")
        let before = try await counts()
        app.buttons["synchronizeLyrics"].tap()
        let source = app.staticTexts["lyricsSynchronizationSource"]
        XCTAssertTrue(source.waitForExistence(timeout: 20)); XCTAssertEqual(source.label, "Transcripción por IA")
        let attribution = app.staticTexts["transcriptionAttribution"]
        for _ in 0..<8 where !attribution.isHittable { app.swipeUp() }
        XCTAssertEqual(attribution.label, "Transcrita por IA")
        capture("transcription-preview-noche", app)
        let online = try await counts()
        XCTAssertEqual(online["transcription"], (before["transcription"] ?? 0) + 1)
        XCTAssertEqual(online["alignment"], before["alignment"])
        (app.navigationBars["Buscar letra"].exists ? app.navigationBars["Buscar letra"] : app.navigationBars["Sincronizar letra"]).buttons["Cancelar"].tap()
        (app.navigationBars["Editar texto"].exists ? app.navigationBars["Editar texto"] : app.navigationBars["Información"]).buttons["Cancelar"].tap()
        XCTAssertTrue(app.buttons["findMissingLyrics"].waitForExistence(timeout: 10), "Cancelling must leave the original without lyrics")
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap(); app.terminate()
        app.launchArguments = ["-appearance", "papel", "-metadata.offline", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        app.buttons["Opciones de canción"].tap(); app.buttons["Editar información"].tap()
        let sync = app.buttons["openLyricsSynchronization"]
        for _ in 0..<15 where !sync.isHittable { app.swipeUp() }
        sync.tap()
        let search = app.buttons["synchronizeLyrics"]
        for _ in 0..<15 where !search.isHittable { app.swipeUp() }
        search.tap()
        for _ in 0..<15 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 20)); XCTAssertEqual(source.label, "Transcripción por IA")
        for _ in 0..<15 where !attribution.isHittable { app.swipeUp() }
        capture("transcription-offline-preview-papel-large-text", app)
        let apply = app.buttons["applySynchronizedLyrics"]
        for _ in 0..<15 where !apply.isHittable { app.swipeUp() }
        apply.tap(); app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["Opciones de canción"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["-appearance", "noche", "-metadata.offline", "YES", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.staticTexts["playerLyricsAttribution"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["playerLyricsAttribution"].label, "Transcrita por IA")
        capture("transcription-player-noche-after-relaunch", app)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["lyricLine0"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["lyricsSource"].label, "Transcrita por IA")
        capture("transcription-expanded-noche", app)
        let after = try await counts(); XCTAssertEqual(after, online, "Offline preview/save/relaunch must not call either provider")
    }
    @MainActor func testUntimedLyricsScreenOpensSynchronizationForTheFixedTrack() {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app, filename: "01 - Catálogo sincronizado QA.flac", theme: "noche", fromLyrics: true)
        app.buttons["synchronizeLyrics"].tap()
        XCTAssertTrue(app.staticTexts["lyricsSynchronizationSource"].waitForExistence(timeout: 15))
        (app.navigationBars["Buscar letra"].exists ? app.navigationBars["Buscar letra"] : app.navigationBars["Sincronizar letra"]).buttons["Cancelar"].tap()
        (app.navigationBars["Editar texto"].exists ? app.navigationBars["Editar texto"] : app.navigationBars["Información"]).buttons["Cancelar"].tap()
        XCTAssertTrue(app.buttons["synchronizeUntimedLyrics"].waitForExistence(timeout: 5))
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap()
    }

}
