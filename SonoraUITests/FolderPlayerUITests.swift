import XCTest

/// Run scripts/seed-simulator.py <UDID> after the app is installed, before this test.
final class FolderPlayerUITests: XCTestCase {
    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func assertPlayerFitsWithoutScrolling(_ app: XCUIApplication) {
        let viewport = app.windows.firstMatch.frame
        print("Player viewport: \(viewport)")
        for control in [app.buttons["Cerrar reproductor"], app.buttons["playerQueue"],
                        app.buttons["playerTransport"], app.buttons["Anterior"],
                        app.buttons["Siguiente"], app.buttons["Aleatorio"], app.buttons["Repetición"],
                        app.sliders["Posición de reproducción"]] {
            XCTAssertTrue(control.isHittable, control.debugDescription)
            XCTAssertTrue(viewport.contains(control.frame), "Control outside viewport: \(control.debugDescription)")
        }
        XCTAssertFalse(app.staticTexts["Volumen y salida en el Centro de control"].exists)
        for identifier in ["playerTitle", "playerVolume", "playerOutput"] {
            let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            XCTAssertTrue(element.exists, identifier)
            XCTAssertTrue(viewport.contains(element.frame), "Outside viewport: \(identifier) \(element.frame)")
        }
        let close = app.buttons["Cerrar reproductor"]
        let originalY = close.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(close.frame.minY, originalY, accuracy: 1, "Player must stay fixed after a vertical drag")
    }
    @MainActor
    func testMiniPlayerStaysAvailableWhileBrowsingLibraryAndPlayerFitsBothThemes() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-appearance", "noche"]; app.launch()
        app.assertLibraryHome()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 10), "Use the synthetic queue prepared by the library tests")
        capture("library-home-noche", app: app)
        app.buttons["Canciones"].tap()
        XCTAssertTrue(app.navigationBars["Canciones"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["openNowPlaying"].isHittable, "Browsing the library must keep the mini-player available")
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["Cerrar reproductor"].waitForExistence(timeout: 5))
        assertPlayerFitsWithoutScrolling(app)
        capture("library-player-noche", app: app)
        app.terminate()
        app.launchArguments = ["-appearance", "papel", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); app.assertLibraryHome()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["Cerrar reproductor"].waitForExistence(timeout: 5))
        assertPlayerFitsWithoutScrolling(app)
        capture("library-player-papel-largest", app: app)
        app.terminate()
    }

    @MainActor
    func testFolderPlaybackBothThemesBackgroundAndRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-folderSnapshot", ""]
        app.launch()
        app.assertLibraryHome()
        app.buttons["Ajustes"].tap()
        app.buttons["Noche"].tap()
        app.buttons["Listo"].tap()
        capture("01-library-before-import", app: app)
        let previousSong = app.buttons["openNowPlaying"].exists ? app.buttons["openNowPlaying"].label : nil
        let previousTransport = app.buttons["miniTransport"].exists ? app.buttons["miniTransport"].label : nil
        app.addDemoSourceFromFiles()
        XCTAssertEqual(app.buttons["openNowPlaying"].exists ? app.buttons["openNowPlaying"].label : nil, previousSong,
                       "Adding a source must preserve the current song")
        XCTAssertEqual(app.buttons["miniTransport"].exists ? app.buttons["miniTransport"].label : nil, previousTransport,
                       "Adding a source must not start or pause playback")
        app.startDemoPlayback()
        app.buttons["miniQueue"].tap()
        XCTAssertTrue(app.navigationBars["Cola · 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.queueRow("01 - Luz de madrugada.flac").exists)
        capture("02-files-folder-imported", app: app)
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["Pausar"].exists)
        capture("03-library-noche", app: app)
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["Cerrar reproductor"].waitForExistence(timeout: 5))
        app.buttons["playerTransport"].tap()
        let scrubber = app.sliders["Posición de reproducción"]
        scrubber.adjust(toNormalizedSliderPosition: 0.55)
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let elapsed = app.staticTexts["playerElapsedTime"].label.split(separator: ":").compactMap { Double($0) }
            guard elapsed.count == 2 else { return false }
            return elapsed[0] == 0 && elapsed[1] >= 12 && elapsed[1] <= 22
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 5), .completed, "Dragging the thumbless bar must seek the paused 30-second track")
        capture("04-player-noche", app: app)
        assertPlayerFitsWithoutScrolling(app)
        app.buttons["playerQueue"].tap()
        XCTAssertTrue(app.staticTexts["En directo/03 - Horizonte.wav"].waitForExistence(timeout: 5))
        capture("05-queue", app: app)
        app.buttons["Listo"].tap()
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["Ajustes"].tap()
        app.buttons["Papel"].tap()
        app.buttons["Listo"].tap()
        capture("06-library-papel", app: app)
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["Reproducir"].waitForExistence(timeout: 5))
        capture("07-player-papel", app: app)
        assertPlayerFitsWithoutScrolling(app)
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["miniQueue"].tap()
        app.queueRow("01 - Luz de madrugada.flac").tap()
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["Pausar"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        // A bounded actual background interval, not an app-state mock.
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.buttons["Pausar"].waitForExistence(timeout: 10))
        app.buttons["miniTransport"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.assertLibraryHome()
        app.buttons["miniQueue"].tap()
        XCTAssertTrue(app.navigationBars["Cola · 3"].waitForExistence(timeout: 10))
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.buttons["Reproducir"].exists)
        capture("08-restored-paused", app: app)
        app.buttons["Ajustes"].tap()
        app.buttons["Noche"].tap()
        app.buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["playerTransport"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["playerTransport"].label, "Reproducir")
        capture("09-player-noche-restored", app: app)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15))
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["playerTransport"].waitForExistence(timeout: 5))
        assertPlayerFitsWithoutScrolling(app)
        capture("10-player-noche-accessibility", app: app)
        app.buttons["Cerrar reproductor"].tap()
        app.buttons["Ajustes"].tap()
        app.buttons["Papel"].tap()
        app.buttons["Listo"].tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["playerTransport"].waitForExistence(timeout: 5))
        assertPlayerFitsWithoutScrolling(app)
        capture("11-player-papel-accessibility", app: app)
    }
}

#if !targetEnvironment(simulator)
final class DeviceVolumeUITests: XCTestCase {
    @MainActor private func volumeValue(_ slider: XCUIElement) -> Double? {
        guard let value = slider.value as? String else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.isLenient = true
        return formatter.number(from: value)?.doubleValue
    }

    @MainActor private func restoreVolume(_ slider: XCUIElement, to target: Double) -> Bool {
        // Drag from the actual thumb position; XCTest's normalized adjustment can overshoot.
        for _ in 0..<3 {
            guard let current = volumeValue(slider) else { return false }
            if abs(current - target) < 0.025 { return true }
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: current, dy: 0.5))
            let end = slider.coordinate(withNormalizedOffset: CGVector(dx: target, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if let observed = volumeValue(slider), abs(observed - target) < 0.025 { return true }
        // Always restore an initially muted device, even if the slider assertion fails.
        if target == 0 {
            for _ in 0..<16 {
                if (volumeValue(slider) ?? 1) == 0 { return true }
                XCUIDevice.shared.press(.volumeDown)
            }
            return volumeValue(slider) == 0
        }
        return false
    }

    @MainActor
    func testVolumeSliderUpdatesSystemVolume() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15), "Restore the existing listening queue")
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["playerTransport"].waitForExistence(timeout: 5))
        let volume = app.descendants(matching: .any).matching(identifier: "playerVolume").firstMatch
        XCTAssertTrue(volume.exists, app.debugDescription)
        let slider = volume.elementType == .slider ? volume : volume.sliders.firstMatch
        XCTAssertTrue(slider.isHittable, app.debugDescription)
        let original = try XCTUnwrap(volumeValue(slider), "Read volume from Sonora's native system control")
        // A rerun can recover the baseline from an interrupted device test.
        let restorationTarget = try ProcessInfo.processInfo.environment["SONORA_TEST_RESTORE_VOLUME"].map {
            try XCTUnwrap(Double($0), "Volume restoration target must be numeric")
        } ?? original
        guard (0...1).contains(restorationTarget) else { XCTFail("Invalid volume restoration target"); return }
        let target = original > 0.15 ? 0.01 : 0.2
        addTeardownBlock { @MainActor in
            if slider.exists && slider.isHittable { _ = self.restoreVolume(slider, to: restorationTarget) }
        }
        slider.adjust(toNormalizedSliderPosition: CGFloat(target))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = self.volumeValue(slider) else { return false }
            return target > original ? value > original + 0.02 : value < original - 0.02
        }, object: nil)
        let changedResult = XCTWaiter.wait(for: [changed], timeout: 5)
        let afterDrag = volumeValue(slider)
        let bars = XCTAttachment(screenshot: app.screenshot())
        bars.name = "device-two-thumbless-bars"; bars.lifetime = .keepAlways; add(bars)
        XCUIDevice.shared.press(.volumeUp)
        let hardware = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = self.volumeValue(slider), let afterDrag else { return false }
            return value > afterDrag + 0.02
        }, object: nil)
        let hardwareResult = XCTWaiter.wait(for: [hardware], timeout: 5)
        let afterHardware = volumeValue(slider)
        let restored = restoreVolume(slider, to: restorationTarget)
        print("Native system volume: original=\(original), target=\(target), afterDrag=\(String(describing: afterDrag)), afterHardware=\(String(describing: afterHardware)), restorationTarget=\(restorationTarget), restored=\(String(describing: volumeValue(slider)))")
        XCTAssertEqual(changedResult, .completed, "The native slider must change system volume")
        XCTAssertEqual(hardwareResult, .completed, "The same slider must reflect the physical volume key")
        XCTAssertTrue(restored, "Restore the original system volume")
        XCTAssertEqual(slider.frame.midY, app.descendants(matching: .any).matching(identifier: "playerOutput").firstMatch.frame.midY, accuracy: 5, "Align volume with its output picker")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "device-player-volume"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
