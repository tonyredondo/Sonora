import XCTest

final class MusicToolsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func openPlayer(theme: String = "noche", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES", "-metadata.endpoint", "http://127.0.0.1:9", "-playbackAdjustment", "", "-showArtworkLyrics", "YES",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch(); app.openMusicSource("Sonora Lyrics QA")
        let song = app.buttons["library-song:02 - Letra sincronizada QA.flac"]
        XCTAssertTrue(song.waitForExistence(timeout: 5)); song.tap()
        app.closeMusicSource("Sonora Lyrics QA")
        let transport = app.buttons["miniTransport"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        transport.tap(); app.buttons["openNowPlaying"].tap()
        return app
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
    @MainActor func testLyricsUnderstandingAndTranslationAvailability() {
        let app = openPlayer()
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["understandLyrics"].waitForExistence(timeout: 10)); capture("lyrics-understanding-entry", app)
        app.buttons["understandLyrics"].tap()
        XCTAssertTrue(app.buttons["interpretLyrics"].waitForExistence(timeout: 5))
        app.buttons["interpretLyrics"].tap()
        capture("lyrics-meaning-availability", app)
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
