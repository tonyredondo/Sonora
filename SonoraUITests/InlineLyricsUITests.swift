import XCTest

/// Exercises only the marked synthetic folder from seed-lyrics-simulator.py.
final class InlineLyricsUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func openPlayer(_ app: XCUIApplication, theme: String, track: String, accessibility: Bool = false) {
        app.launchArguments = ["-appearance", theme, "-metadata.offline", "YES"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        let source = app.buttons["source:Sonora Lyrics QA"]
        if !source.exists {
            let add = app.buttons["Añadir carpeta"]
            for _ in 0..<8 where !add.isHittable { app.swipeUp() }
            add.tap(); app.selectSyntheticFolder(["Sonora Lyrics QA"])
        }
        for _ in 0..<8 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 15)); source.tap()
        let song = app.buttons["library-song:" + track]
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        app.closeMusicSource("Sonora Lyrics QA")
        let transport = app.buttons["miniTransport"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: transport)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        transport.tap()
        if accessibility {
            app.terminate()
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            app.launch()
            XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        }
        app.buttons["openNowPlaying"].tap()
        let toggle = app.buttons["toggleArtworkLyrics"]
        if toggle.exists, toggle.value as? String == "Ocultas" { toggle.tap() }
    }

    @MainActor private func seekUsingLyrics(_ app: XCUIApplication, line: Int) {
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Letra"].waitForExistence(timeout: 5))
        setFollowing(true, in: app)
        app.sliders["lyricsOffset"].adjust(toNormalizedSliderPosition: 0.5)
        let target = app.buttons["lyricLine\(line)"]
        let scroll = app.scrollViews.matching(NSPredicate(format: "identifier != %@", "playerLyrics")).firstMatch
        for _ in 0..<25 {
            if target.isHittable { break }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: line > 10 ? 0.8 : 0.3))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: line > 10 ? 0.4 : 0.7))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(target.isHittable)
        target.tap()
        app.buttons["Listo"].tap()
    }

    @MainActor private func setFollowing(_ enabled: Bool, in app: XCUIApplication) {
        let control = app.switches["Seguir la letra"]
        let value = enabled ? "1" : "0"
        if control.value as? String == value { return }
        // The large Dynamic Type label can cover the center of the accessibility frame.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    @MainActor func testArtworkFollowsTheCurrentLyricWhenSeeking() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "noche", track: "02 - Letra sincronizada QA.flac")
        let controls = app.buttons["playerTransport"].frame
        seekUsingLyrics(app, line: 20)
        let lyrics = app.scrollViews["playerLyrics"]
        let current = lyrics.staticTexts["Línea sincronizada 20"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), "The artwork must scroll to the current line after seeking")
        XCTAssertTrue(current.isHittable)
        XCTAssertEqual(current.value as? String, "Línea actual")
        let previous = lyrics.staticTexts["Línea sincronizada 19"]
        XCTAssertNotEqual(previous.value as? String, "Línea actual")
        XCTAssertGreaterThan(current.frame.height, previous.frame.height, "The current phrase should use a larger font")
        XCTAssertEqual(app.buttons["playerTransport"].frame, controls)
        capture("current-lyric-noche-seek", app)

        app.buttons["toggleArtworkLyrics"].tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5))
        app.buttons["toggleArtworkLyrics"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isHittable, "Showing lyrics should immediately follow the paused position")
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isHittable, "Reopening playback should start at the current phrase")

        seekUsingLyrics(app, line: 2)
        let earlier = lyrics.staticTexts["Línea sincronizada 02"]
        XCTAssertTrue(earlier.waitForExistence(timeout: 5))
        XCTAssertTrue(earlier.isHittable)
        XCTAssertEqual(earlier.value as? String, "Línea actual")
        capture("current-lyric-noche-backward", app)
    }

    @MainActor func testPlayerCanBeDraggedDownWithoutHijackingLyricsOrPlaybackControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for (theme,largeText) in [("noche",false),("papel",true)] {
            openPlayer(app,theme:theme,track:"02 - Letra sincronizada QA.flac",accessibility:largeText)
            let close = app.buttons["Cerrar reproductor"], toggle = app.buttons["toggleArtworkLyrics"]
            let originalFrame = close.frame
            let header = app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:(close.frame.maxX + toggle.frame.minX) / 2,dy:close.frame.midY))
            header.press(forDuration:0.05,thenDragTo:header.withOffset(CGVector(dx:0,dy:30)),withVelocity:.slow,thenHoldForDuration:0.1)
            XCTAssertTrue(close.exists)
            XCTAssertEqual(close.frame.minY,originalFrame.minY,accuracy:1,"A short pull must return to its original position")
            header.press(forDuration:0.05,thenDragTo:header.withOffset(CGVector(dx:90,dy:5)),withVelocity:.slow,thenHoldForDuration:0.1)
            XCTAssertTrue(close.exists,"A horizontal gesture must not minimize playback")
            let lyrics = app.scrollViews["playerLyrics"]
            let before = lyrics.staticTexts.allElementsBoundByIndex.filter(\.isHittable).map(\.label)
            let from = lyrics.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.75))
            from.press(forDuration:0.05,thenDragTo:lyrics.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.25)))
            XCTAssertTrue(close.exists)
            let after = lyrics.staticTexts.allElementsBoundByIndex.filter(\.isHittable).map(\.label)
            XCTAssertNotEqual(before,after,"The artwork's lyric region must still scroll")
            lyrics.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.25)).press(forDuration:0.05,thenDragTo:lyrics.coordinate(withNormalizedOffset:CGVector(dx:0.45,dy:0.75)))
            XCTAssertTrue(close.exists,"A downward lyric scroll must not minimize the player")
            app.sliders["Posición de reproducción"].adjust(toNormalizedSliderPosition:0.2)
            XCTAssertTrue(close.exists)
            let seconds = Int(app.staticTexts["playerElapsedTime"].label.split(separator:":").last ?? "") ?? -1
            XCTAssertGreaterThan(seconds,20,"The timeline must still seek")
            app.buttons["playerTransport"].tap()
            header.press(forDuration:0.05,thenDragTo:header.withOffset(CGVector(dx:0,dy:220)),withVelocity:.slow,thenHoldForDuration:0.1)
            XCTAssertTrue(close.waitForNonExistence(timeout:5),"Dragging the header must minimize the player")
            app.assertLibraryHome()
            XCTAssertEqual(app.buttons["miniTransport"].label,"Pausar","Minimizing must keep the song playing")
            capture("player-drag-minimized-" + theme,app)
            app.buttons["openNowPlaying"].tap(); XCTAssertTrue(close.waitForExistence(timeout:5))
            app.buttons["playerTransport"].tap(); toggle.tap()
            XCTAssertTrue(lyrics.waitForNonExistence(timeout:5))
            let artwork = app.descendants(matching:.any).matching(identifier:"playerArtwork").firstMatch
            XCTAssertTrue(artwork.exists)
            capture("player-drag-uncovered-artwork-" + theme,app)
            let cover = artwork.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.25))
            cover.press(forDuration:0.05,thenDragTo:cover.withOffset(CGVector(dx:0,dy:220)),withVelocity:.slow,thenHoldForDuration:0.1)
            XCTAssertTrue(close.waitForNonExistence(timeout:5),"Dragging the uncovered artwork must minimize playback")
            app.assertLibraryHome(); XCTAssertEqual(app.buttons["miniTransport"].label,"Reproducir")
            app.buttons["openNowPlaying"].tap(); XCTAssertTrue(close.waitForExistence(timeout:5))
            close.tap(); app.assertLibraryHome(); app.terminate()
        }
    }

    @MainActor func testArtworkAdvancesWithActualAudioPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "noche", track: "02 - Letra sincronizada QA.flac")
        seekUsingLyrics(app, line: 20)
        let elapsed = app.staticTexts["playerElapsedTime"]
        XCTAssertEqual(elapsed.label, "0:20")
        app.buttons["playerTransport"].tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "0:20"), object: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 12), .completed)
        app.buttons["playerTransport"].tap()
        let seconds = Int(elapsed.label.split(separator: ":").last ?? "") ?? -1
        XCTAssertGreaterThan(seconds, 20)
        XCTAssertLessThan(seconds, 39)
        let lyrics = app.scrollViews["playerLyrics"]
        let current = lyrics.staticTexts.matching(NSPredicate(format: "value == %@", "Línea actual")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        let line = Int(current.label.split(separator: " ").last ?? "") ?? -1
        // The clock displays whole seconds; the highlighted phrase can already be the next one.
        XCTAssertGreaterThanOrEqual(line, seconds)
        XCTAssertLessThanOrEqual(line, seconds + 1)
        let previous = lyrics.staticTexts[String(format: "Línea sincronizada %02d", line - 1)]
        XCTAssertTrue(current.isHittable)
        XCTAssertEqual(current.value as? String, "Línea actual")
        XCTAssertNotEqual(previous.value as? String, "Línea actual", "The preceding phrase should return to its normal style")
        XCTAssertGreaterThan(current.frame.height, previous.frame.height)
        capture("current-lyric-noche-playback", app)
    }

    @MainActor func testArtworkSharesOffsetAndFollowPreferenceInPapel() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "papel", track: "02 - Letra sincronizada QA.flac", accessibility: true)
        app.sliders["Posición de reproducción"].adjust(toNormalizedSliderPosition: 0.1)
        let seconds = Int(app.staticTexts["playerElapsedTime"].label.split(separator: ":").last ?? "") ?? -1
        XCTAssertGreaterThan(seconds, 10)
        XCTAssertLessThan(seconds, 40, "Use a timestamp within the fixture's 40 timed lines")
        app.buttons["expandLyrics"].tap()
        setFollowing(true, in: app)
        let offset = app.sliders["lyricsOffset"]
        XCTAssertTrue(offset.waitForExistence(timeout: 5))
        offset.adjust(toNormalizedSliderPosition: 0.5)
        let active = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@", "lyricLine", "Línea actual")).firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        let line = Int(active.identifier.dropFirst("lyricLine".count)) ?? -1
        XCTAssertGreaterThan(line, 10)
        XCTAssertLessThan(line, 40)
        // A +5 second offset moves back five one-second phrases, including any visual anticipation.
        offset.adjust(toNormalizedSliderPosition: 1)
        let adjustedLine = app.buttons["lyricLine\(line - 5)"]
        XCTAssertTrue(adjustedLine.waitForExistence(timeout: 5))
        XCTAssertEqual(adjustedLine.value as? String, "Línea actual")
        capture("current-lyric-papel-expanded-offset", app)
        app.buttons["Listo"].tap()
        let lyrics = app.scrollViews["playerLyrics"]
        let delayed = lyrics.staticTexts[String(format: "Línea sincronizada %02d", line - 5)]
        XCTAssertTrue(delayed.waitForExistence(timeout: 5))
        XCTAssertTrue(delayed.isHittable, app.debugDescription)
        XCTAssertEqual(delayed.value as? String, "Línea actual", "Artwork must apply the expanded view's +5 second adjustment")
        capture("current-lyric-papel-offset", app)

        app.buttons["expandLyrics"].tap()
        setFollowing(false, in: app)
        XCTAssertEqual(app.switches["Seguir la letra"].value as? String, "0")
        offset.adjust(toNormalizedSliderPosition: 0.5)
        app.buttons["Listo"].tap()
        let current = lyrics.staticTexts[String(format: "Línea sincronizada %02d", line)]
        XCTAssertFalse(current.isHittable, "Disabling following should allow the listener to keep reading elsewhere")

        app.buttons["expandLyrics"].tap()
        setFollowing(true, in: app)
        // A simulated midpoint drag may leave a fractional offset; use the expanded reader's selection.
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        let restoredLine = Int(active.identifier.dropFirst("lyricLine".count)) ?? -1
        XCTAssertGreaterThanOrEqual(restoredLine, 0)
        let restored = lyrics.staticTexts[String(format: "Línea sincronizada %02d", restoredLine)]
        app.buttons["Listo"].tap()
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.isHittable, "Enabling following should bring the current phrase back immediately")
        XCTAssertEqual(restored.value as? String, "Línea actual")
        XCTAssertTrue(app.buttons["playerTransport"].isHittable)
        capture("current-lyric-papel-follow-restored", app)
    }

    @MainActor func testArtworkLyricsCanBeHiddenAndTheChoiceIsRemembered() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "noche", track: "02 - Letra sincronizada QA.flac")
        let toggle = app.buttons["toggleArtworkLyrics"]
        let lyrics = app.scrollViews["playerLyrics"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The header should let the listener show or hide inline lyrics")
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        let controls = app.buttons["playerTransport"].frame
        capture("artwork-lyrics-visible-noche", app)

        toggle.tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["expandLyrics"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Ocultas")
        XCTAssertEqual(app.buttons["playerTransport"].frame, controls)
        capture("artwork-lyrics-hidden-noche", app)
        toggle.tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Letra"].waitForExistence(timeout: 5))
        app.buttons["Editar"].tap()
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
        app.buttons["Cancelar"].tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(lyrics.exists, "Opening the full lyrics should keep inline lyrics visible")
        toggle.tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["expandLyrics"].waitForNonExistence(timeout: 5))

        app.buttons["Cerrar reproductor"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(toggle.value as? String, "Ocultas")
        XCTAssertFalse(lyrics.exists)
        XCTAssertFalse(app.buttons["expandLyrics"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap()
        XCTAssertEqual(toggle.value as? String, "Ocultas")
        XCTAssertFalse(lyrics.exists)
        XCTAssertFalse(app.buttons["expandLyrics"].exists)

        app.buttons["Siguiente"].tap()
        XCTAssertTrue(app.staticTexts["Sin letra QA"].waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "Ocultas")
        app.buttons["Anterior"].tap()
        XCTAssertTrue(app.staticTexts["Letra sincronizada QA"].waitForExistence(timeout: 10))
        XCTAssertFalse(lyrics.exists, "Changing songs should keep lyrics hidden")
        toggle.tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertTrue(lyrics.staticTexts["Línea sincronizada 00"].isHittable)
        XCTAssertEqual(toggle.value as? String, "Visibles")
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        capture("artwork-lyrics-restored-noche", app)
    }

    @MainActor func testInlineScrollingExpansionEditingAndTrackChanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "noche", track: "01 - Letra completa QA.flac")
        let lyrics = app.scrollViews["playerLyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5), "Lyrics should appear within the artwork without opening a sheet")
        XCTAssertTrue(lyrics.staticTexts["Verso 01 de la prueba de Sonora"].isHittable)
        let controls = app.buttons["playerTransport"].frame
        let lastLine = lyrics.staticTexts["Verso 40 de la prueba de Sonora"]
        for _ in 0..<25 where !lastLine.isHittable { lyrics.swipeUp() }
        XCTAssertTrue(lastLine.isHittable)
        XCTAssertEqual(app.buttons["playerTransport"].frame, controls)
        XCTAssertTrue(app.buttons["playerTransport"].isHittable)
        XCTAssertTrue(app.otherElements["playerOutput"].exists)
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        capture("inline-lyrics-noche-scrolled", app)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.navigationBars["Letra"].waitForExistence(timeout: 5))
        app.buttons["Editar"].tap()
        XCTAssertTrue(app.textFields["metadata-title"].waitForExistence(timeout: 5))
        let edit = app.buttons["editLyrics"]
        for _ in 0..<10 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        let text = app.textViews["metadata-lyrics"]
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.tap()
        text.press(forDuration: 1.2)
        let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Select All", "Seleccionar todo"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.tap()
        let replacement = "Letra actualizada desde el editor\nSegundo verso actualizado"
        text.typeText(replacement)
        XCTAssertEqual(text.value as? String, replacement)
        app.buttons["BackButton"].tap()
        app.buttons["metadataSave"].tap(); app.buttons["Guardar en archivo"].tap()
        XCTAssertTrue(app.buttons["Editar"].waitForExistence(timeout: 10)); app.buttons["Listo"].tap()
        XCTAssertTrue(lyrics.staticTexts["Letra actualizada desde el editor"].waitForExistence(timeout: 10))
        XCTAssertTrue(lyrics.staticTexts["Letra actualizada desde el editor"].isHittable)
        XCTAssertFalse(lyrics.staticTexts["Verso 01 de la prueba de Sonora"].exists)
        capture("inline-lyrics-noche-edited", app)
        app.buttons["Siguiente"].tap()
        XCTAssertTrue(lyrics.staticTexts["Línea sincronizada 00"].waitForExistence(timeout: 10))
        XCTAssertTrue(lyrics.staticTexts["Línea sincronizada 00"].isHittable, "Changing songs should reset the lyrics scroll")
        XCTAssertFalse(lyrics.staticTexts["Letra actualizada desde el editor"].exists)
        app.buttons["Siguiente"].tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        capture("inline-lyrics-noche-no-lyrics", app)
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.staticTexts["Sin letra"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Añadir letra"].exists)
    }

    @MainActor func testTimedLyricsInPapelAtMaximumTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openPlayer(app, theme: "papel", track: "02 - Letra sincronizada QA.flac", accessibility: true)
        let lyrics = app.scrollViews["playerLyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        let transport = app.buttons["playerTransport"].frame
        let end = lyrics.staticTexts["Línea sincronizada 03"]
        let seconds = Int(app.staticTexts["playerElapsedTime"].label.split(separator: ":").last ?? "") ?? 0
        let scrollsForward = seconds < 3
        for _ in 0..<24 {
            if end.isHittable { break }
            lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollsForward ? 0.75 : 0.25))
                .press(forDuration: 0.05, thenDragTo: lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(end.isHittable)
        XCTAssertEqual(app.buttons["playerTransport"].frame, transport)
        XCTAssertTrue(app.buttons["Siguiente"].isHittable)
        XCTAssertTrue(app.buttons["expandLyrics"].isHittable)
        capture("inline-lyrics-papel-accessibility", app)
        let toggle = app.buttons["toggleArtworkLyrics"]
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
        XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["expandLyrics"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["playerTransport"].frame, transport)
        capture("artwork-lyrics-hidden-papel-accessibility", app)
        toggle.tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        app.buttons["expandLyrics"].tap()
        XCTAssertTrue(app.switches["Seguir la letra"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Editar"].isHittable)
        capture("inline-lyrics-papel-expanded", app)
    }
}
