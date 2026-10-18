import XCTest

/// Real app and proxy, with synthetic audio and a loopback-only speech fixture.
final class LyricsRepairUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func open(_ app:XCUIApplication, filename:String = "01 - Reparación QA.flac") {
        app.launchArguments = ["-appearance","noche","-metadata.offline","NO","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        let source = app.buttons["source:Sonora Repair QA"]
        if !source.exists {
            let add = app.buttons["Añadir carpeta"]; reveal(add,in:app)
            add.tap(); app.selectSyntheticFolder(["Sonora Repair QA"])
        }
        reveal(source,in:app)
        app.buttons["source-options:Sonora Repair QA"].tap(); app.buttons["Actualizar fuente"].tap(); source.tap()
        let song = app.buttons["library-song:" + filename]
        XCTAssertTrue(song.waitForExistence(timeout:10)); song.tap(); app.closeMusicSource("Sonora Repair QA")
        let playing = XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","Pausar"),object:app.buttons["miniTransport"])
        XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:10),.completed)
        app.buttons["miniTransport"].tap(); openReader(app)
    }
    @MainActor private func openReader(_ app:XCUIApplication) {
        app.buttons["openNowPlaying"].tap()
        if app.buttons["toggleArtworkLyrics"].value as? String == "Ocultas" { app.buttons["toggleArtworkLyrics"].tap() }
        XCTAssertTrue(app.buttons["expandLyrics"].waitForExistence(timeout:10)); app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.buttons["repairLyrics"].waitForExistence(timeout:10))
    }
    @MainActor private func counts() async throws -> [String:Int] {
        let (data,_) = try await URLSession.shared.data(from:XCTUnwrap(URL(string:"http://127.0.0.1:28192/__stats")))
        return try JSONDecoder().decode([String:Int].self,from:data)
    }
    @MainActor private func setProviderFailure(_ mode: String) async throws {
        var request = URLRequest(url:URL(string:"http://127.0.0.1:28192/__failure")!)
        request.httpMethod = "POST"; request.httpBody = Data(mode.utf8)
        let (_,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    }
    @MainActor func testFullSongRepairReviewCancelOfflineManualEditAndSave() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app)
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristel")
        app.buttons["repairLyrics"].tap()
        let analyze = app.buttons["analyzeLyricsRepair"]
        XCTAssertTrue(analyze.waitForExistence(timeout:10)); capture("repair-entry-noche",app)
        let before = try await counts(); analyze.tap()
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].waitForExistence(timeout:25))
        let online = try await counts()
        XCTAssertEqual(online["transcription"],(before["transcription"] ?? 0) + 1)
        XCTAssertEqual(online["catalog"],before["catalog"]); XCTAssertEqual(online["alignment"],before["alignment"])
        let completion = app.buttons["repairAccept-0"], correction = app.buttons["repairAccept-1"]
        reveal(completion,in:app); capture("repair-completion-noche",app)
        app.buttons["repairListen-0"].tap(); completion.tap()
        reveal(correction,in:app); correction.tap()
        app.buttons["repairUndo-1"].tap(); app.buttons["repairKeep-1"].tap()
        capture("repair-correction-kept-noche",app)
        let preview = app.buttons["previewLyricsRepair"]; preview.tap()
        XCTAssertTrue(app.buttons["saveLyricsRepair"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["repairPreviewAttribution"].exists)
        XCTAssertTrue(app.staticTexts["Camino de cristel"].exists); XCTAssertTrue(app.staticTexts["Vuelve la luz."].exists)
        capture("repair-preview-cancel-noche",app)
        app.buttons["cancelRepairPreview"].tap()
        app.navigationBars["Reparar letra"].buttons["BackButton"].tap()
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristel","Cancelling must leave the file unchanged")
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap(); app.terminate()

        app.launchArguments = ["-appearance","papel","-metadata.offline","YES","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout:15)); openReader(app)
        app.buttons["repairLyrics"].tap(); XCTAssertTrue(analyze.waitForExistence(timeout:10)); analyze.tap()
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].waitForExistence(timeout:25))
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].label.contains("guardado"))
        capture("repair-offline-papel-maximum-text",app)
        reveal(completion,in:app); completion.tap()
        reveal(app.buttons["repairEdit-1"],in:app); app.buttons["repairEdit-1"].tap()
        let text = app.textViews["repairEditText"]; XCTAssertTrue(text.waitForExistence(timeout:10))
        // Tap the trailing whitespace of its first line to place the caret at
        // the end, rather than relying on TextEditor's initial selection.
        text.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.1)).tap()
        text.typeText(" transparente")
        XCTAssertEqual(text.value as? String,"cristal transparente")
        app.buttons["repairUseEdit"].tap()
        for _ in 0..<12 where !app.switches["repairOnlyCompletions"].isHittable { app.swipeDown() }
        app.switches["repairOnlyCompletions"].tap(); preview.tap()
        XCTAssertTrue(app.buttons["saveLyricsRepair"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["repairPreviewAttribution"].exists)
        XCTAssertTrue(app.staticTexts["Camino de cristel"].exists,"The additions-only filter must exclude a selected correction")
        capture("repair-only-completions-preview-papel",app)
        app.buttons["cancelRepairPreview"].tap(); app.switches["repairOnlyCompletions"].tap(); preview.tap()
        XCTAssertTrue(app.staticTexts["Camino de cristal transparente"].waitForExistence(timeout:10))
        capture("repair-manual-preview-papel",app)
        app.buttons["saveLyricsRepair"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["repairLyrics"].waitForExistence(timeout:15))
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristal transparente")
        XCTAssertEqual(app.buttons["lyricLine2"].label,"♪","Repairing the text must retain the instrumental pause cue")
        XCTAssertEqual(app.staticTexts["lyricsSource"].label,"Letra incrustada")
        capture("repair-saved-reader-papel",app)
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap(); app.terminate()
        app.launchArguments = ["-appearance","noche","-metadata.offline","YES","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout:15)); openReader(app)
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristal transparente")
        XCTAssertEqual(app.buttons["lyricLine2"].label,"♪")
        XCTAssertEqual(app.staticTexts["lyricsSource"].label,"Letra incrustada")
        let after = try await counts(); XCTAssertEqual(after,online,"Offline review, editing and saving must not repeat an analysis")
        capture("repair-saved-reader-after-relaunch-noche",app)
    }
    @MainActor func testUnrecognizedLyricsArePreservedWithoutSuggestions() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app,filename:"04 - Letra conservada QA.flac")
        app.buttons["repairLyrics"].tap()
        let analyze = app.buttons["analyzeLyricsRepair"]
        XCTAssertTrue(analyze.waitForExistence(timeout:10)); analyze.tap()
        let empty = app.staticTexts["No hay correcciones ni fragmentos para completar."]
        XCTAssertTrue(empty.waitForExistence(timeout:25))
        XCTAssertFalse(app.staticTexts["Texto no reconocido por la IA"].exists)
        XCTAssertFalse(app.buttons["previewLyricsRepair"].isEnabled)
        app.switches["repairOnlyCompletions"].tap()
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.staticTexts["No hay propuestas para completar. Desactiva el filtro para revisar las correcciones."].exists)
        capture("repair-no-actionable-proposals-noche",app)
        app.navigationBars["Reparar letra"].buttons["BackButton"].tap()
        XCTAssertEqual(app.buttons["lyricLine2"].label,"Conserva esta frase")
    }

    @MainActor func testAnalysisFailureShowsCauseAndCopyableRequestReference() async throws {
        continueAfterFailure = false
        try await setProviderFailure("quota")
        addTeardownBlock { @MainActor in try await self.setProviderFailure("none") }
        let before = try await counts()
        let app = XCUIApplication(); open(app,filename:"03 - Error de análisis QA.flac")
        app.buttons["repairLyrics"].tap()
        let analyze = app.buttons["analyzeLyricsRepair"]
        XCTAssertTrue(analyze.waitForExistence(timeout:10)); analyze.tap()
        let issue = app.descendants(matching:.any).matching(identifier:"repairIssue").firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout:25))
        XCTAssertTrue(issue.label.contains("ElevenLabs") && issue.label.contains("quota_exceeded"), issue.label)
        XCTAssertTrue(issue.label.contains("502") && issue.label.contains("429"), issue.label)
        XCTAssertTrue(issue.label.contains("Referencia:"), issue.label)
        XCTAssertFalse(issue.label.contains("private-lyrics") || issue.label.contains("synthetic-eleven-key"))
        capture("repair-detailed-provider-error-noche",app)
        let totals = try await counts()
        XCTAssertEqual(totals["transcription"], (before["transcription"] ?? 0) + 1)
    }

    @MainActor func testMixedLyricsAreRejectedBeforeAnalysisCanSendAudio() async throws {
        continueAfterFailure = false
        let before = try await counts()
        let app = XCUIApplication(); open(app,filename:"02 - Letra mixta QA.flac")
        app.buttons["repairLyrics"].tap()
        let issue = app.staticTexts["repairIssue"]
        XCTAssertTrue(issue.waitForExistence(timeout:10)); XCTAssertTrue(issue.label.contains("mezcla líneas"))
        XCTAssertFalse(app.buttons["analyzeLyricsRepair"].isEnabled)
        capture("repair-invalid-format-before-upload-noche",app)
        let after = try await counts(); XCTAssertEqual(after,before)
    }
}
