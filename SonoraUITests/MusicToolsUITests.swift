import XCTest

final class MusicToolsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func openPlayer(theme: String = "noche", large: Bool = false,
                                       track: String = "02 - Letra sincronizada QA.flac", refresh: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES", "-metadata.endpoint", "http://127.0.0.1:9", "-playbackAdjustment", "", "-showArtworkLyrics", "YES", "-lyricTranslationSource", "auto",
                               "-UIPreferredContentSizeCategoryName", large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch(); app.openMusicSource("Sonora Lyrics QA", refresh: refresh)
        let song = app.buttons["library-song:\(track)"]
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
