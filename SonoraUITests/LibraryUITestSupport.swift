import XCTest

extension XCUIApplication {
    @MainActor func selectPlayerPage(_ page: Int, file: StaticString = #filePath, line: UInt = #line) {
        let dots = pageIndicators["playerPages"]
        XCTAssertTrue(dots.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<6 {
            let numbers = (dots.value as? String ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let current = numbers.first else {
                XCTFail("Missing page selection: \(String(describing: dots.value))", file: file, line: line); return
            }
            if current == page + 1 { return }
            let region = collectionViews["playerCarousel"]
            let start = region.coordinate(withNormalizedOffset: CGVector(dx: current < page + 1 ? 0.85 : 0.15, dy: 0.45))
            let end = region.coordinate(withNormalizedOffset: CGVector(dx: current < page + 1 ? 0.15 : 0.85, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Could not select page \(page): \(String(describing: dots.value))", file: file, line: line)
    }

    @MainActor func assertLibraryHome(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(navigationBars["Biblioteca"].waitForExistence(timeout: 15), file: file, line: line)
    }

    @MainActor func openMusicSource(_ name: String = "Sonora QA", refresh: Bool = false) {
        assertLibraryHome()
        buttons["Fuentes"].tap()
        let source = buttons["source:" + name]
        for _ in 0..<8 where !source.isHittable { swipeUp() }
        XCTAssertTrue(source.waitForExistence(timeout: 10), debugDescription)
        if refresh {
            buttons["source-options:" + name].tap(); buttons["Actualizar fuente"].tap()
        }
        source.tap()
    }

    @MainActor func closeMusicSource(_ name: String = "Sonora QA") {
        navigationBars[name].buttons.element(boundBy: 0).tap()
        navigationBars["Fuentes"].buttons["Listo"].tap()
        assertLibraryHome()
    }

    @MainActor func startDemoPlayback() {
        openMusicSource()
        // The paused mini-player has the same play label. Select the known FLAC fixture explicitly.
        buttons["library-song:01 - Luz de madrugada.flac"].tap()
        closeMusicSource()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pausar"), object: buttons["miniTransport"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
    }

    @MainActor func queueRow(_ relativePath: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "queue-track:", relativePath)).firstMatch
    }

    /// Uses Files' actual folder picker; callers provide marked synthetic folders only.
    @MainActor func selectSyntheticFolder(_ path: [String]) {
        let picker = otherElements["Browse View (Picker)"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), debugDescription)
        XCTAssertTrue(buttons["DOCPicker.actionButton"].waitForExistence(timeout: 10))
        // Files' tab bar sits beside its browsing view, including on a fresh launch at Recents.
        if buttons["Browse"].exists { buttons["Browse"].tap() }
        let local = picker.staticTexts["On My iPhone"]
        XCTAssertTrue(local.waitForExistence(timeout: 10), debugDescription)
        local.tap()
        let container = picker.cells.containing(.staticText, identifier: "Sonora").firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 10), debugDescription)
        container.images.firstMatch.tap()
        for name in path {
            let folder = picker.cells.containing(.staticText, identifier: name).firstMatch
            for _ in 0..<8 where !folder.isHittable { picker.swipeUp() }
            XCTAssertTrue(folder.waitForExistence(timeout: 10), debugDescription)
            folder.images.firstMatch.tap()
        }
        buttons["DOCPicker.actionButton"].tap()
        if navigationBars["Añadir música"].waitForExistence(timeout: 3) {
            navigationBars["Añadir música"].buttons["Listo"].tap()
        }
    }

    @MainActor func addDemoSourceFromFiles() {
        assertLibraryHome(); buttons["Fuentes"].tap(); beginLinkingFolder()
        selectSyntheticFolder(["Sonora QA"])
        XCTAssertTrue(buttons["source:Sonora QA"].waitForExistence(timeout: 15))
        navigationBars["Fuentes"].buttons["Listo"].tap()
    }
    @MainActor func beginLinkingFolder() {
        buttons["Añadir música"].tap()
        XCTAssertTrue(buttons["linkMusicFolder"].waitForExistence(timeout: 5))
        buttons["linkMusicFolder"].tap()
    }
    @MainActor func openSoundTool(_ title: String) {
        if buttons["Sonido"].exists { buttons["Sonido"].tap() }
        XCTAssertTrue(buttons[title].waitForExistence(timeout: 5))
        buttons[title].tap()
    }
    @MainActor func returnToSettings() {
        for _ in 0..<3 where !navigationBars["Ajustes"].exists { navigationBars.buttons["BackButton"].tap() }
        XCTAssertTrue(navigationBars["Ajustes"].exists)
    }

}
