import XCTest

final class MusicToolsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func openPlayer(theme: String = "noche", large: Bool = false,
                                       track: String = "02 - Letra sincronizada QA.flac", refresh: Bool = false,
                                       meaningLanguage: String? = "es",
                                       additionalArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES", "-metadata.endpoint", "http://127.0.0.1:9", "-playbackAdjustment", "", "-lyricTranslationSource", "auto", "-lyricTranslationTarget", "es",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"] + additionalArguments
        if let meaningLanguage { app.launchArguments += ["-lyricMeaningLanguage", meaningLanguage] }
        app.launch(); app.openMusicSource("Sonora Lyrics QA", refresh: refresh)
        let song = app.buttons["library-song:\(track)"]
        let search = app.searchFields.firstMatch
        // List creates offscreen rows when scrolling. A partially visible final
        // row can also report hittable underneath iOS's search bar.
        for _ in 0..<8 where !song.exists || !song.isHittable || (search.exists && song.frame.intersects(search.frame)) { app.swipeUp() }
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        XCTAssertTrue(song.isHittable); song.tap()
        app.closeMusicSource("Sonora Lyrics QA")
        let transport = app.buttons["miniTransport"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        transport.tap(); app.buttons["openNowPlaying"].tap()
        app.selectPlayerPage(1)
        return app
    }
    @MainActor private func checkManualRefresh(large: Bool) {
        let app = openPlayer(large: large)
        let audioTools = app.buttons["openAudioTools"]
        for _ in 0..<5 where !audioTools.isHittable { app.swipeUp() }
        XCTAssertTrue(audioTools.isHittable); audioTools.tap()
        let refresh = app.buttons["refreshSongMetadata"]
        XCTAssertTrue(app.navigationBars["Sonido"].waitForExistence(timeout: 5))
        for _ in 0..<10 where !refresh.exists || !refresh.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(refresh.isHittable)
        capture(large ? "refresh-control-accessibility" : "refresh-control", app)
        refresh.tap()
        let audio = app.descendants(matching: .any).matching(identifier: "refreshSongMetadata.audio").firstMatch
        for _ in 0..<10 where !audio.exists || !audio.isHittable { app.swipeUp(velocity: .slow) }
        let success = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Actualizado"), object: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [success], timeout: 60), .completed)
        let meaning = app.descendants(matching: .any).matching(identifier: "refreshSongMetadata.meaning").firstMatch
        for _ in 0..<10 where !meaning.exists || !meaning.isHittable { app.swipeUp(velocity: .slow) }
        let offline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Conecta con el servidor"), object: meaning)
        XCTAssertEqual(XCTWaiter.wait(for: [offline], timeout: 15), .completed)
        XCTAssertTrue(meaning.isHittable)
        if meaning.frame.maxY > app.frame.maxY - 40 { app.swipeUp(velocity: .slow) }
        XCTAssertLessThanOrEqual(meaning.frame.maxY, app.frame.maxY - 20, "The full error message must remain reachable")
        capture(large ? "refresh-outcome-accessibility" : "refresh-outcome-offline", app)
        // Returning to playback must preserve its paused transport and waveform.
        app.navigationBars["Sonido"].buttons["Listo"].tap()
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        XCTAssertTrue(app.staticTexts["playerBPM"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor func testManualRefreshControlAndOfflineOutcome() { checkManualRefresh(large: false) }
    @MainActor func testManualRefreshAtAccessibilitySize() { checkManualRefresh(large: true) }

    @MainActor func testMeaningHeadingInCarouselAndExpandedView() {
        let app = openPlayer(track: "07 - Traducción por frases QA.flac")
        app.selectPlayerPage(3)
        let title = app.staticTexts["playerMeaningTitle"], paragraph = app.staticTexts["playerMeaningText"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Sobre la canción")
        XCTAssertTrue(title.isHittable)
        // Selectable text exposes a padded accessibility frame. Compare the
        // start of the heading with the paragraph, then inspect glyph spacing
        // in the retained screenshot rather than treating that frame as ink.
        XCTAssertLessThan(title.frame.minY, paragraph.frame.minY)
        capture("meaning-heading", app)
        app.buttons["expandMeaning"].tap()
        XCTAssertTrue(app.navigationBars["Comprender letra"].waitForExistence(timeout: 5))
        let expanded = app.staticTexts["lyricInterpretation"]
        for _ in 0..<6 where !expanded.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(expanded.isHittable)
        XCTAssertTrue(app.staticTexts["Sobre la canción"].exists)
        capture("meaning-expanded-heading", app)
        app.terminate()
    }

    @MainActor func testPlayerCarouselReadsCachedContentKeepsSelectionAndOpensExpandedContent() {
        let app = openPlayer(track: "07 - Traducción por frases QA.flac", refresh: true)
        let pages = app.pageIndicators["playerPages"]
        XCTAssertEqual(pages.value as? String, "Letra, 2 de 4")
        XCTAssertTrue(app.scrollViews["playerLyrics"].isHittable)
        let artwork = app.collectionViews["playerCarousel"]
        let expand = app.buttons["expandLyrics"], close = app.buttons["Cerrar reproductor"]
        XCTAssertEqual(expand.frame.midY, close.frame.midY, accuracy: 1, "Expansion belongs in the top toolbar")
        XCTAssertLessThan(expand.frame.maxY, artwork.frame.minY)
        XCTAssertEqual(artwork.frame.minX, app.frame.minX, accuracy: 1, "The artwork reaches the leading edge")
        XCTAssertEqual(artwork.frame.maxX, app.frame.maxX, accuracy: 1, "The artwork reaches the trailing edge")
        XCTAssertFalse(artwork.buttons["expandLyrics"].exists)
        XCTAssertFalse(app.buttons["editPlayerLyrics"].exists)
        capture("carousel-lyrics", app)
        let transport = app.buttons["playerTransport"].frame
        app.selectPlayerPage(0)
        XCTAssertFalse(app.scrollViews["playerLyrics"].exists)
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        XCTAssertEqual(artwork.buttons.count, 0, "The artwork-only page has no overlaid buttons")
        capture("carousel-artwork", app)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Letra"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["metadata-lyrics"].exists, "Expansion must not jump straight into editing")
        capture("toolbar-expanded-lyrics", app)
        app.buttons["Listo"].tap()
        XCTAssertEqual(pages.value as? String, "Portada, 1 de 4")
        app.selectPlayerPage(2)
        let translated = app.scrollViews["playerTranslatedLyrics"]
        XCTAssertTrue(translated.staticTexts["Un pájaro canta en el jardín."].waitForExistence(timeout: 10))
        translated.buttons["translatedLyricLine1"].tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:03")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        XCTAssertEqual(translated.buttons["translatedLyricLine1"].value as? String, "Línea actual")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "playerTranslationPreparation").firstMatch.exists)
        capture("carousel-translation", app)
        app.selectPlayerPage(3)
        let meaning = app.staticTexts["playerMeaningText"]
        XCTAssertTrue(meaning.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["playerMeaningTitle"].label, "Sobre la canción")
        XCTAssertLessThan(app.staticTexts["playerMeaningTitle"].frame.minY, meaning.frame.minY)
        XCTAssertTrue(meaning.label.contains("pequeños cambios del día"))
        XCTAssertEqual(app.buttons["expandMeaning"].frame.midY, close.frame.midY, accuracy: 1)
        XCTAssertFalse(artwork.buttons["expandMeaning"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "playerMeaningPreparation").firstMatch.exists)
        capture("carousel-meaning", app)
        XCTAssertEqual(app.buttons["playerTransport"].frame, transport)
        app.scrollViews["playerMeaning"].swipeUp(velocity: .slow)
        capture("carousel-meaning-end", app)
        XCTAssertTrue(app.buttons["Cerrar reproductor"].exists)
        app.buttons["expandMeaning"].tap()
        XCTAssertTrue(app.navigationBars["Comprender letra"].waitForExistence(timeout: 5))
        let expanded = app.staticTexts["lyricInterpretation"]
        for _ in 0..<6 where !expanded.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(expanded.isHittable)
        XCTAssertTrue(app.staticTexts["Sobre la canción"].exists)
        capture("meaning-expanded-heading", app)
        app.buttons["Listo"].tap()
        XCTAssertEqual(pages.value as? String, "Significado, 4 de 4")
        app.buttons["Siguiente"].tap()
        XCTAssertTrue(app.staticTexts["Última traducción QA"].waitForExistence(timeout: 10))
        XCTAssertEqual(pages.value as? String, "Significado, 4 de 4")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "ausencia"), object: meaning)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        app.selectPlayerPage(2)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Letra"].waitForExistence(timeout: 5))
        app.buttons["editLyricsText"].tap()
        XCTAssertTrue(app.textViews["metadata-lyrics"].waitForExistence(timeout: 10), "Editing stays available inside the expanded lyrics")
        XCTAssertTrue(app.navigationBars["Editar texto"].exists)
        app.buttons["Cancelar"].tap()
        app.buttons["Listo"].tap()
        XCTAssertEqual(pages.value as? String, "Traducción, 3 de 4")
        app.selectPlayerPage(3)
        XCTAssertEqual(pages.value as? String, "Significado, 4 de 4")
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(pages.value as? String, "Significado, 4 de 4")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 10)); app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(pages.value as? String, "Significado, 4 de 4")
        XCTAssertTrue(meaning.waitForExistence(timeout: 10))
        let expansion = app.buttons["expandMeaning"]
        let header = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: (close.frame.maxX + expansion.frame.minX) / 2, dy: close.frame.midY))
        header.press(forDuration: 0.05, thenDragTo: header.withOffset(CGVector(dx: 0, dy: 220)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Only the header drag minimizes the player")
        XCTAssertEqual(app.buttons["miniTransport"].label, "Reproducir")
        app.terminate()
    }

    @MainActor func testPlayerCarouselLargeTextLastLineAndMissingContent() {
        let app = openPlayer(theme: "papel", large: true, track: "08 - Última traducción QA.flac")
        app.selectPlayerPage(2)
        let artwork = app.collectionViews["playerCarousel"]
        XCTAssertEqual(artwork.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(artwork.frame.maxX, app.frame.maxX, accuracy: 1, "Large text must not add lateral artwork margins")
        let reader = app.scrollViews["playerTranslatedLyrics"]
        let last = reader.buttons["translatedLyricLine5"]
        for _ in 0..<12 where !last.isHittable { reader.swipeUp(velocity: .slow) }
        XCTAssertTrue(last.isHittable)
        reader.swipeUp(velocity: .slow)
        XCTAssertLessThanOrEqual(last.frame.maxY, reader.frame.maxY - 50, "The final pair must clear the bottom fade")
        XCTAssertTrue(last.staticTexts["y a ti"].exists)
        capture("carousel-translation-large-last-line", app)
        XCTAssertEqual(app.buttons["expandLyrics"].frame.midY, app.buttons["Cerrar reproductor"].frame.midY, accuracy: 1)
        XCTAssertTrue(app.buttons["playerTransport"].isHittable)
        XCTAssertTrue(app.buttons["openAudioTools"].isHittable)
        last.tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:15")
        reader.swipeDown(velocity: .slow)
        XCTAssertTrue(app.buttons["Cerrar reproductor"].exists, "Vertical reading must not minimize")
        app.selectPlayerPage(3)
        XCTAssertTrue(app.staticTexts["playerMeaningText"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["playerMeaningTitle"].label, "Sobre la canción")
        capture("carousel-meaning-large", app)
        // Pick a known untimed, lyric-free track without assuming library order.
        app.buttons["playerQueue"].tap()
        let instrumental = app.queueRow("09 - Pulso 180 BPM QA.flac")
        for _ in 0..<10 where !instrumental.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(instrumental.isHittable)
        instrumental.tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Pulso 180 BPM QA"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.pageIndicators["playerPages"].value as? String, "Significado, 4 de 4")
        XCTAssertTrue(app.staticTexts["Esta canción todavía no tiene letra."].exists)
        app.selectPlayerPage(2)
        XCTAssertEqual(app.pageIndicators["playerPages"].value as? String, "Traducción, 3 de 4")
        XCTAssertTrue(app.staticTexts["Esta canción todavía no tiene letra."].exists)
        app.selectPlayerPage(0)
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.staticTexts["Sin letra"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Añadir letra"].exists)
        app.terminate()
    }

    /// Requires scripts/lyrics-interpretation-fixture.py on localhost:18096.
    @MainActor func testPlayerCarouselReplacesPreparationWithMeaningWithoutAnotherRequest() async throws {
        let app = openPlayer(additionalArguments: ["-prepareQueueAudio", "NO", "-prepareQueueTranslation", "NO", "-prepareQueueMeaning", "YES"])
        connectToLyricsFixture(app)
        app.selectPlayerPage(3)
        XCTAssertTrue(app.staticTexts["Preparando significado…"].waitForExistence(timeout: 10))
        capture("carousel-meaning-preparing", app)
        let release = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18096/release")!)
        XCTAssertEqual((release.1 as? HTTPURLResponse)?.statusCode, 200)
        let text = app.staticTexts["playerMeaningText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(text.label.contains("Interpretación preparada para la prueba"))
        XCTAssertFalse(app.staticTexts["Preparando significado…"].exists)
        XCTAssertEqual(app.pageIndicators["playerPages"].value as? String, "Significado, 4 de 4")
        capture("carousel-meaning-ready", app)
        app.selectPlayerPage(0); app.selectPlayerPage(2); app.selectPlayerPage(3)
        XCTAssertTrue(text.exists)
        let stats = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18096/stats")!)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: stats.0) as? [String: Int])
        XCTAssertEqual(counts["synced"], 1, "Swiping must reuse the prepared interpretation")
        app.terminate()
    }

    @MainActor private func connectToLyricsFixture(_ app: XCUIApplication) {
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["Ajustes"].tap()
        let connection = app.buttons["metadataAssistantSettings"]
        for _ in 0..<6 where !connection.isHittable { app.swipeUp() }
        connection.tap()
        let endpoint = app.textFields["metadataEndpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        endpoint.tap()
        endpoint.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (endpoint.value as? String ?? "").count) + "http://127.0.0.1:18096")
        let token = app.secureTextFields["metadataToken"]
        token.tap()
        token.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (token.value as? String ?? "").count) + "sonora-carousel-fixture-token")
        app.buttons["saveMetadataConnection"].tap()
        let offline = app.switches["metadataOffline"]
        if offline.value as? String == "1" { offline.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        app.navigationBars["Asistente de información"].buttons["BackButton"].tap()
        app.navigationBars["Ajustes"].buttons["Listo"].tap()
        if app.buttons["Not Now"].waitForExistence(timeout: 1) { app.buttons["Not Now"].tap() }
        app.buttons["openNowPlaying"].tap()
    }

    /// Requires scripts/lyrics-interpretation-fixture.py on localhost:18096.
    @MainActor func testCodexTranslationAppearsAutomaticallyAndRemainsWithItsTimedLine() async throws {
        let app = openPlayer(track: "06 - Traducción contextual QA.flac", additionalArguments: [
            "-prepareQueueAudio", "NO", "-prepareQueueMeaning", "NO", "-prepareQueueTranslation", "YES",
            "-lyricTranslationSource", "en"
        ])
        app.selectPlayerPage(2)
        XCTAssertTrue(app.staticTexts["Pendiente de conexión con el servidor."].waitForExistence(timeout: 10))
        capture("codex-translation-offline", app)
        connectToLyricsFixture(app)
        app.selectPlayerPage(2)
        XCTAssertTrue(app.staticTexts["Traduciendo la letra completa con Codex…"].waitForExistence(timeout: 10))
        capture("codex-translation-preparing", app)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["lyricsTranslationStatus"].waitForExistence(timeout: 10))
        app.buttons["lyricsTranslationStatus"].tap()
        XCTAssertTrue(app.buttons["translateLyrics"].waitForExistence(timeout: 5))
        app.buttons["translateLyrics"].tap()
        app.navigationBars["Comprender letra"].buttons["Listo"].tap()
        app.navigationBars["Letra"].buttons["Listo"].tap()
        XCTAssertEqual(app.pageIndicators["playerPages"].value as? String, "Traducción, 3 de 4")
        let release = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18096/release-translation")!)
        XCTAssertEqual((release.1 as? HTTPURLResponse)?.statusCode, 200)
        let reader = app.scrollViews["playerTranslatedLyrics"]
        let first = reader.buttons["translatedLyricLine0"]
        let second = reader.buttons["translatedLyricLine1"]
        XCTAssertTrue(first.staticTexts["Cuando por fin pare la lluvia,"].waitForExistence(timeout: 10))
        XCTAssertTrue(second.staticTexts["saldremos a la calle."].exists)
        XCTAssertFalse(first.staticTexts["saldremos a la calle."].exists)
        XCTAssertFalse(app.staticTexts["Traduciendo la letra completa con Codex…"].exists)
        second.tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:03")
        capture("codex-translation-ready", app)
        app.selectPlayerPage(0); app.selectPlayerPage(2)
        XCTAssertTrue(second.staticTexts["saldremos a la calle."].exists)
        let stats = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18096/stats")!)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: stats.0) as? [String: Int])
        XCTAssertEqual(counts["translated"], 1)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.staticTexts["lyricsTranslationSource"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["lyricsTranslationSource"].label, "Traducción automática · Codex")
        app.buttons["lyricLine1"].tap()
        app.navigationBars["Letra"].buttons["Listo"].tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:03")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 10)); app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(app.pageIndicators["playerPages"].value as? String, "Traducción, 3 de 4")
        XCTAssertTrue(app.staticTexts["saldremos a la calle."].firstMatch.waitForExistence(timeout: 10))
        capture("codex-translation-restored-offline", app)
        app.terminate()
    }

    @MainActor func testAudioToolsWaveformMarkerAndRestore() {
        let app = openPlayer()
        let audio = app.buttons["openAudioTools"]
        XCTAssertTrue(audio.isHittable); audio.tap()
        let speed = app.sliders["playbackRate"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5)); speed.adjust(toNormalizedSliderPosition: 0.7)
        let pitch = app.steppers["playbackPitch"]
        XCTAssertTrue(pitch.isHittable); pitch.buttons.element(boundBy: 1).tap()
        capture("audio-speed-pitch-dark", app)
        app.buttons["openSongAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["songBPM"].waitForExistence(timeout: 45))
        let wave = app.descendants(matching: .any).matching(identifier: "songWaveform").allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(wave, "The analysis waveform must be accessible above the underlying player")
        guard let wave else { return }
        XCTAssertTrue(wave.isHittable)
        wave.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        app.buttons["addSongMarker"].tap()
        let name = app.textFields["markerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(" QA")
        app.navigationBars["Marcador"].buttons["Guardar"].tap()
        XCTAssertTrue(app.buttons["Editar Marcador QA"].waitForExistence(timeout: 5))
        capture("waveform-markers-dark", app)
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["Restablecer velocidad y tono"].tap()
        app.navigationBars["Sonido"].buttons["Listo"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "songWaveform").firstMatch.waitForExistence(timeout: 5))
        capture("player-waveform-dark", app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "songWaveform").firstMatch.waitForExistence(timeout: 10), "Saved analysis should restore without another full analysis")
    }
    @MainActor func testPlayerAutomaticallyShowsBPMAndDynamicWaveform() {
        let app = openPlayer(track: "05 - Dinámica 120 BPM QA.flac", refresh: true)
        let bpm = app.staticTexts["playerBPM"]
        XCTAssertTrue(bpm.waitForExistence(timeout: 45), "Opening the song must analyze it without visiting audio tools")
        XCTAssertEqual(bpm.label, "120 BPM")
        let waveform = app.descendants(matching: .any).matching(identifier: "songWaveform").firstMatch
        XCTAssertTrue(waveform.waitForExistence(timeout: 5))
        capture("automatic-waveform-dynamics", app)
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        let elapsed = app.staticTexts["playerElapsedTime"]
        XCTAssertEqual(elapsed.label, "1:00")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        capture("automatic-waveform-seek", app)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(waveform.waitForExistence(timeout: 15))
        XCTAssertEqual(bpm.label, "120 BPM")
        XCTAssertEqual(elapsed.label, "1:00")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        capture("automatic-waveform-restored", app)
    }
    @MainActor func testContextualTranslationRendersFromCacheAndKeepsOriginalSeekTimes() {
        let app = openPlayer(track: "06 - Traducción contextual QA.flac", refresh: true)
        app.buttons["expandLyrics"].tap()
        let translation = app.staticTexts["Cuando finalmente deje de llover,"].firstMatch
        XCTAssertTrue(translation.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["lyricLine0"].exists)
        XCTAssertTrue(app.buttons["lyricLine1"].exists)
        XCTAssertTrue(app.buttons["lyricLine1"].staticTexts["saldremos."].exists)
        XCTAssertTrue(app.staticTexts["lyricsTranslationSource"].exists)
        capture("contextual-translation-cached", app)
        app.buttons["lyricLine1"].tap()
        app.navigationBars["Letra"].buttons["Listo"].tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:03")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap(); app.buttons["expandLyrics"].tap()
        XCTAssertTrue(translation.waitForExistence(timeout: 10))
        capture("contextual-translation-restored", app)
    }
    @MainActor func testFinalTranslatedLineRemainsVisibleAndSeeksAtItsOwnTime() {
        for large in [false, true] {
            let app = openPlayer(large: large, track: "08 - Última traducción QA.flac", refresh: true)
            app.buttons["expandLyrics"].tap()
            XCTAssertTrue(app.staticTexts["lyricsTranslationSource"].waitForExistence(timeout: 15))
            let reader = app.scrollViews["lyricsReader"], last = app.buttons["lyricLine5"]
            for _ in 0..<8 where !last.isHittable || last.frame.maxY > reader.frame.maxY { reader.swipeUp() }
            XCTAssertTrue(last.staticTexts["and you"].exists)
            XCTAssertTrue(last.staticTexts["y a ti"].exists)
            XCTAssertEqual(last.staticTexts.count, 2)
            XCTAssertGreaterThanOrEqual(last.frame.minY, reader.frame.minY)
            XCTAssertLessThanOrEqual(last.frame.maxY, reader.frame.maxY)
            XCTAssertLessThanOrEqual(last.frame.maxY, app.staticTexts["lyricsTranslationSource"].frame.minY)
            capture(large ? "final-translation-accessibility" : "final-translation", app)
            last.tap()
            app.navigationBars["Letra"].buttons["Listo"].tap()
            XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:15")
            XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
            app.terminate()
        }
    }
    @MainActor func testFastPulseShowsRoundedHalfTimeAndRestoresIt() {
        let app = openPlayer(track: "09 - Pulso 180 BPM QA.flac", refresh: true)
        let bpm = app.staticTexts["playerBPM"]
        XCTAssertTrue(bpm.waitForExistence(timeout: 45))
        XCTAssertEqual(bpm.label, "90 BPM")
        capture("half-time-bpm", app)
        app.buttons["openAudioTools"].tap()
        app.buttons["openSongAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["songBPM"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["songBPM"].label.contains("90"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(bpm.waitForExistence(timeout: 15))
        XCTAssertEqual(bpm.label, "90 BPM")
    }
    @MainActor func testTranslatedSentencesStayBesideTheirOriginalLines() {
        let pairs = [
            ("The sun rises over the mountains", "El sol sale sobre las montañas."),
            ("A bird sings in the garden", "Un pájaro canta en el jardín."),
            ("The train arrives at noon", "El tren llega al mediodía."),
            ("We will meet by the river", "Nos encontraremos junto al río."),
            ("The evening brings a gentle breeze", "La noche trae una suave brisa."),
            ("Tomorrow we begin again", "Mañana comenzamos de nuevo.")
        ]
        let app = openPlayer(track: "07 - Traducción por frases QA.flac", refresh: true)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.staticTexts[pairs[0].1].waitForExistence(timeout: 15))
        capture("translation-aligned-sentences", app)
        let reader = app.scrollViews["lyricsReader"]
        for (index, pair) in pairs.enumerated() {
            let row = app.buttons["lyricLine\(index)"]
            for _ in 0..<6 where !row.isHittable || row.frame.maxY > reader.frame.maxY { reader.swipeUp() }
            XCTAssertTrue(row.isHittable)
            XCTAssertTrue(row.staticTexts[pair.0].exists)
            XCTAssertTrue(row.staticTexts[pair.1].exists)
            XCTAssertEqual(row.staticTexts.count, 2, "Each original line should contain only its own translated fragment")
        }
        capture("translation-aligned-last-sentence", app)
        app.buttons["lyricLine5"].tap()
        app.navigationBars["Letra"].buttons["Listo"].tap()
        XCTAssertEqual(app.staticTexts["playerElapsedTime"].label, "0:15")
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
    }
    @MainActor func testLyricsUnderstandingAndTranslationAvailability() {
        let app = openPlayer(meaningLanguage: nil)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["understandLyrics"].waitForExistence(timeout: 10)); capture("lyrics-understanding-entry", app)
        let translationStatus = app.buttons["lyricsTranslationStatus"]
        XCTAssertTrue(translationStatus.waitForExistence(timeout: 10))
        translationStatus.tap()
        let translationTab = app.segmentedControls.buttons["Traducción"]
        XCTAssertTrue(translationTab.waitForExistence(timeout: 5))
        capture("translation-status-destination", app)
        XCTAssertTrue(translationTab.isSelected, "The translation status should open its own controls")
        let translate = app.buttons["translateLyrics"]
        XCTAssertTrue(translate.waitForExistence(timeout: 10))
        XCTAssertFalse(translate.isEnabled, "This Spanish fixture does not need translating to Spanish again")
        capture("automatic-translation-language-status", app)
        app.navigationBars["Comprender letra"].buttons["Listo"].tap()
        app.buttons["understandLyrics"].tap()
        XCTAssertTrue(app.buttons["interpretLyrics"].waitForExistence(timeout: 5))
        // A launch-argument default would override subsequent Picker changes.
        app.buttons["interpretationLanguage"].tap(); app.buttons["Español"].tap()
        app.buttons["interpretLyrics"].tap()
        let issue = app.staticTexts["interpretationIssue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        capture("lyrics-meaning-availability", app)
        app.buttons["interpretationLanguage"].tap()
        app.buttons["English"].tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: issue)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 5), .completed, "A language change only loads cached results; it must not retry the failed generation")
        XCTAssertTrue(app.buttons["interpretLyrics"].isEnabled)
        capture("lyrics-language-change-awaits-request", app)
        app.segmentedControls.buttons["Traducción"].tap()
        XCTAssertTrue(app.buttons["translateLyrics"].waitForExistence(timeout: 10))
        capture("lyrics-translation-controls", app)
        app.navigationBars["Comprender letra"].buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["editLyricsText"].isHittable)
        app.buttons["editLyricsText"].tap()
        XCTAssertTrue(app.buttons["draftSongAnalysis"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["openDraftPreview"].isHittable)
        capture("editor-audio-tools-compact", app)
    }
    @MainActor func testQueuePreparationSettingsAndPendingMeaning() {
        let app = openPlayer()
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["Ajustes"].tap()
        let settings = app.buttons["queuePreparationSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        for identifier in ["prepareQueueAudio", "prepareQueueTranslation", "prepareQueueMeaning"] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "1")
        }
        capture("queue-preparation-defaults", app)
        let meaning = app.switches["prepareQueueMeaning"]
        meaning.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(meaning.value as? String, "0")
        meaning.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(meaning.value as? String, "1")
        app.buttons["Reintentar pendientes"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars["Ajustes"].buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap(); app.buttons["expandLyrics"].tap()
        app.buttons["understandLyrics"].tap()
        XCTAssertTrue(app.staticTexts["interpretationState"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["interpretLyrics"].isEnabled)
        capture("meaning-offline-queue", app)
    }
    @MainActor func testMarkerAuditionStartsPausedPlayback() {
        let app = openPlayer()
        app.buttons["openAudioTools"].tap()
        app.buttons["openSongAnalysis"].tap()
        XCTAssertTrue(app.staticTexts["songBPM"].waitForExistence(timeout: 45))
        let transport = app.buttons["draftPlayback"]
        let waveform = app.descendants(matching: .any).matching(identifier: "songWaveform").allElementsBoundByIndex.first(where: \.isHittable)
        guard let waveform else { return XCTFail("Analysis waveform is missing") }
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertEqual(transport.label, "Reproducir previsualización", "Scrubbing should preserve paused playback")
        app.buttons["addSongMarker"].tap()
        let suffix = " Audition QA " + String(UUID().uuidString.prefix(8))
        let name = app.textFields["markerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(suffix)
        let title = "Marcador" + suffix
        app.navigationBars["Marcador"].buttons["Guardar"].tap()
        let audition = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Escuchar \(title),")).firstMatch
        for _ in 0..<6 where !audition.isHittable { app.swipeUp() }
        XCTAssertTrue(audition.isHittable)
        audition.tap()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar previsualización"), object: transport)
        let outcome = XCTWaiter.wait(for: [playing], timeout: 5)
        capture("marker-audition-playback", app)
        if transport.label == "Pausar previsualización" { transport.tap() }
        // Remove only this test's marker, including when the audition assertion fails.
        audition.swipeLeft()
        app.buttons["Eliminar"].firstMatch.tap()
        XCTAssertEqual(outcome, .completed, "The marker's Escuchar action must start playback from its saved position")
    }
    @MainActor func testEstimatedBPMShowsANumberAndConfidence() {
        let app = openPlayer(track: "04 - Pulso 120 BPM QA.flac", refresh: true)
        capture("player-speaker-icon", app)
        app.buttons["openAudioTools"].tap()
        app.buttons["openSongAnalysis"].tap()
        let bpm = app.staticTexts["songBPM"]
        XCTAssertTrue(bpm.waitForExistence(timeout: 45))
        XCTAssertTrue(bpm.label.hasSuffix(" BPM"))
        XCTAssertNotNil(Double(bpm.label.replacingOccurrences(of: " BPM", with: "")))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Confianza")).firstMatch.exists)
        capture("estimated-bpm-number", app)
    }
    @MainActor func testAudioToolsInLightAndLargeText() {
        let app = openPlayer(theme: "papel", large: true)
        app.buttons["openAudioTools"].tap()
        XCTAssertTrue(app.sliders["playbackRate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["playbackRate"].isHittable)
        capture("audio-tools-light-large-text", app)
        let analysis = app.buttons["openSongAnalysis"]
        for _ in 0..<6 where !analysis.isHittable { app.swipeUp() }
        XCTAssertTrue(analysis.isHittable); analysis.tap()
        XCTAssertTrue(app.staticTexts["songBPM"].waitForExistence(timeout: 45))
        capture("analysis-light-large-text", app)
        let marker = app.buttons["addSongMarker"]
        app.swipeUp() // A partly visible button can be hittable behind the floating transport.
        for _ in 0..<6 where !marker.isHittable { app.swipeUp() }
        XCTAssertTrue(marker.isHittable)
        capture("analysis-marker-large-text", app)
    }
}
