import XCTest

/// Real app and proxy, with synthetic audio and a loopback-only speech fixture.
final class LyricsRepairUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private enum ScrollDirection { case up, down }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, toward direction: ScrollDirection = .up) {
        for _ in 0..<16 {
            let navigation = app.navigationBars.firstMatch
            let top = navigation.exists ? navigation.frame.maxY + 8 : app.frame.minY + 8
            let footer = app.buttons["previewLyricsRepair"]
            let bottom = footer.exists ? footer.frame.minY - 8 : app.frame.maxY - 40
            let frame = element.exists ? element.frame : nil
            if let frame, element.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
            // Full-screen swipes can jump past a control at maximum Dynamic Type.
            // Drag toward the viewport center without crossing its fixed chrome.
            let center = (top + bottom) / 2
            let limit = max(40, (bottom - top) / 2 - 16)
            let distance = frame.map { max(-limit, min(limit, center - $0.midY)) }
                ?? (direction == .down ? limit : -limit)
            let start = app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:app.frame.midX,dy:center))
            start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:distance)),withVelocity:.slow,thenHoldForDuration:0.1)
        }
        XCTFail("The control must be fully visible above the fixed review button: \(element)")
    }
    @MainActor private func open(_ app:XCUIApplication, filename:String = "01 - Reparación QA.flac") {
        app.launchArguments = ["-appearance","noche","-metadata.offline","NO","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryL"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        let source = app.buttons["source:Sonora Repair QA"]
        if !source.exists {
            app.beginLinkingFolder(); app.selectSyntheticFolder(["Sonora Repair QA"])
        }
        reveal(source,in:app)
        app.buttons["source-options:Sonora Repair QA"].tap(); app.buttons["Actualizar fuente"].tap(); source.tap()
        let song = app.buttons["library-song:" + filename]
        XCTAssertTrue(song.waitForExistence(timeout:10))
        let search = app.searchFields.firstMatch
        if search.exists && song.frame.maxY > search.frame.minY { app.swipeUp() }
        song.tap(); app.closeMusicSource("Sonora Repair QA")
        let title = URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent.components(separatedBy:" - ").dropFirst().joined(separator:" - ")
        XCTAssertTrue(app.buttons["openNowPlaying"].label.contains(title), "The requested song must actually be selected")
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
        let previewContent = app.scrollViews["repairPreviewContent"]
        XCTAssertTrue(previewContent.staticTexts["Camino de cristel"].exists); XCTAssertTrue(previewContent.staticTexts["Vuelve la luz."].exists)
        capture("repair-preview-cancel-noche",app)
        app.buttons["cancelRepairPreview"].tap()
        app.navigationBars["Reparar letra"].buttons["Volver"].tap()
        if app.buttons["Descartar decisiones"].exists { app.buttons["Descartar decisiones"].tap() }
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristel","Cancelling must leave the file unchanged")
        app.buttons["Listo"].tap(); app.buttons["Cerrar reproductor"].tap(); app.terminate()

        app.launchArguments = ["-appearance","papel","-metadata.offline","YES","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout:15)); openReader(app)
        app.buttons["repairLyrics"].tap(); XCTAssertTrue(analyze.waitForExistence(timeout:10)); analyze.tap()
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].waitForExistence(timeout:25))
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].label.contains("guardado"))
        capture("repair-offline-papel-maximum-text",app)
        reveal(completion,in:app); completion.tap()
        XCTAssertEqual(app.buttons["previewLyricsRepair"].label,"Revisar selección (1)")
        reveal(app.buttons["repairEdit-1"],in:app); app.buttons["repairEdit-1"].tap()
        let text = app.textViews["repairEditText"]; XCTAssertTrue(text.waitForExistence(timeout:10))
        // Tap the trailing whitespace of its first line to place the caret at
        // the end, rather than relying on TextEditor's initial selection.
        text.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.1)).tap()
        text.typeText(" transparente")
        XCTAssertEqual(text.value as? String,"cristal transparente")
        app.buttons["repairUseEdit"].tap()
        XCTAssertEqual(app.buttons["previewLyricsRepair"].label,"Revisar selección (2)")
        let filter = app.switches["repairOnlyCompletions"]
        reveal(filter,in:app,toward:.down)
        // Toggle's accessibility frame includes its multiline label. Tap the trailing control.
        let filterControl = filter.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5))
        filterControl.tap()
        XCTAssertEqual(filter.value as? String,"1")
        XCTAssertEqual(app.buttons["previewLyricsRepair"].label,"Revisar selección (1)")
        preview.tap()
        XCTAssertTrue(app.buttons["saveLyricsRepair"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["repairPreviewAttribution"].exists)
        XCTAssertTrue(previewContent.staticTexts["Camino de cristel"].exists,"The additions-only filter must exclude a selected correction")
        XCTAssertTrue(previewContent.staticTexts["Vuelve la luz."].exists)
        capture("repair-only-completions-preview-papel",app)
        app.buttons["cancelRepairPreview"].tap(); filterControl.tap()
        XCTAssertEqual(filter.value as? String,"0")
        XCTAssertEqual(preview.label,"Revisar selección (2)")
        preview.tap()
        XCTAssertTrue(previewContent.staticTexts["Camino de cristal transparente"].waitForExistence(timeout:10))
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
        let filter = app.switches["repairOnlyCompletions"]
        filter.coordinate(withNormalizedOffset:CGVector(dx:0.9,dy:0.5)).tap()
        XCTAssertEqual(filter.value as? String,"1")
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.staticTexts["No hay propuestas para completar. Desactiva el filtro para revisar las correcciones."].exists)
        capture("repair-no-actionable-proposals-noche",app)
        app.navigationBars["Reparar letra"].buttons["Volver"].tap()
        if app.buttons["Descartar decisiones"].exists { app.buttons["Descartar decisiones"].tap() }
        XCTAssertEqual(app.buttons["lyricLine2"].label,"Conserva esta frase")
    }
    @MainActor func testPhraseTimingConflictCanBeEditedAndSaved() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(); open(app,filename:"05 - Ajuste de tiempos QA.flac")
        app.buttons["repairLyrics"].tap()
        let analyze = app.buttons["analyzeLyricsRepair"]
        XCTAssertTrue(analyze.waitForExistence(timeout:10))
        let before = try await counts(); analyze.tap()
        XCTAssertTrue(app.staticTexts["repairAnalysisSource"].waitForExistence(timeout:25))
        let proposal = app.staticTexts["repairProposal-1"]
        reveal(proposal,in:app)
        XCTAssertEqual(proposal.label,"Ajuste de tiempo")
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"repairOriginalTiming-1").firstMatch.label.contains("0:01.20"))
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"repairTiming-1").firstMatch.label.contains("0:01.16"))
        XCTAssertTrue(app.staticTexts["Adelantar 0.04 s"].exists)
        capture("repair-timing-current-and-proposed",app)
        let currentAudio = app.buttons["repairListenCurrent-1"], proposedAudio = app.buttons["repairListenProposed-1"]
        reveal(currentAudio,in:app); currentAudio.tap()
        XCTAssertEqual(currentAudio.value as? String,"Reproduciendo")
        reveal(proposedAudio,in:app); proposedAudio.tap()
        XCTAssertEqual(currentAudio.value as? String,"Detenido")
        XCTAssertEqual(proposedAudio.value as? String,"Reproduciendo")
        proposedAudio.tap(); XCTAssertEqual(proposedAudio.value as? String,"Detenido")
        XCTAssertEqual(app.buttons["previewLyricsRepair"].label,"Revisar selección (0)","Listening must not select a change")
        capture("repair-comparable-audio-starts",app)
        reveal(app.buttons["repairEdit-1"],in:app)
        app.buttons["repairEdit-1"].tap()
        let time = app.textFields["repairEditTime"]
        XCTAssertTrue(time.waitForExistence(timeout:10)); time.tap()
        time.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:(time.value as? String ?? "").count) + "15")
        XCTAssertEqual(time.value as? String,"15")
        let editAudio = app.buttons["repairListenEdited-1"]
        XCTAssertTrue(editAudio.exists); editAudio.tap()
        XCTAssertEqual(editAudio.value as? String,"Reproduciendo")
        let stopped = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@","Detenido"),object:editAudio)
        XCTAssertEqual(XCTWaiter.wait(for:[stopped],timeout:7),.completed,"A sample must stop on its own")
        capture("repair-edit-audio-preview",app)
        app.buttons["repairUseEdit"].tap(); app.buttons["previewLyricsRepair"].tap()
        let alert = app.alerts["Revisa la selección"]
        XCTAssertTrue(alert.waitForExistence(timeout:10))
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator:" ")
        XCTAssertTrue(message.contains("Camino de cristal.")); XCTAssertTrue(message.contains("0:15.00")); XCTAssertTrue(message.contains("0:08.00"))
        capture("repair-timing-identifies-conflicting-fragment",app)
        alert.buttons["Editar fragmento"].tap()
        XCTAssertTrue(time.waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Inicio permitido: 0:00.00 – 0:08.00"].exists)
        time.tap(); time.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:(time.value as? String ?? "").count) + "1.1")
        XCTAssertEqual(time.value as? String,"1.1")
        app.buttons["repairUseEdit"].tap()
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"repairTiming-1").firstMatch.label.contains("0:01.10"))
        app.buttons["previewLyricsRepair"].tap()
        XCTAssertTrue(app.buttons["saveLyricsRepair"].waitForExistence(timeout:10))
        XCTAssertTrue(app.scrollViews["repairPreviewContent"].staticTexts["0:01.10"].exists)
        capture("repair-timing-valid-preview",app)
        app.buttons["saveLyricsRepair"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["repairLyrics"].waitForExistence(timeout:15))
        XCTAssertEqual(app.buttons["lyricLine0"].label,"Camino de cristal.")
        XCTAssertEqual(app.buttons["lyricLine2"].label,"Conserva esta frase")
        let after = try await counts()
        XCTAssertEqual(after["transcription"],(before["transcription"] ?? 0) + 1)
        capture("repair-timing-saved-with-original-words",app)
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
        XCTAssertTrue(issue.label.contains("El servicio de análisis") && issue.label.contains("quota_exceeded"), issue.label)
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
