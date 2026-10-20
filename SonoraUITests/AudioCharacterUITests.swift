import XCTest

final class AudioCharacterUITests: XCTestCase {
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func open(_ theme: String = "noche", large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appearance",theme,"-metadata.offline","YES","-prepareQueueTranslation","NO","-prepareQueueMeaning","NO","-nowPlayingPage","0",
                               "-UIPreferredContentSizeCategoryName",large ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch(); app.assertLibraryHome(); app.buttons["Fuentes"].tap()
        XCTAssertTrue(app.navigationBars["Fuentes"].waitForExistence(timeout: 10))
        let source = app.buttons["source:Sonora Tags QA"]
        for _ in 0..<8 where !source.exists || !source.isHittable { app.swipeUp() }
        if !source.exists {
            app.collectionViews.buttons["Añadir música"].firstMatch.tap()
            XCTAssertTrue(app.buttons["linkMusicFolder"].waitForExistence(timeout: 5))
            app.buttons["linkMusicFolder"].tap(); app.selectSyntheticFolder(["Sonora Tags QA"])
            for _ in 0..<8 where !source.exists || !source.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let track = app.buttons["library-song:01 - Style layout QA.wav"]
        XCTAssertTrue(track.waitForExistence(timeout: 15)); track.tap()
        app.closeMusicSource("Sonora Tags QA")
        let transport = app.buttons["miniTransport"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format:"label == %@","Pausar"),object:transport)
        XCTAssertEqual(XCTWaiter.wait(for:[playing],timeout:15),.completed); transport.tap()
        app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["songStyle:Rock---Alternative Rock"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func testTagsLayoutDetailAndOfflineRestoration() {
        let app = open()
        let play = app.buttons["playerTransport"], tags = app.scrollViews["songCharacterTags"]
        let metrics: [String: [String: Double]] = ["play":play,"tags":tags,"album":app.staticTexts["playerAlbum"],
            "artwork":app.descendants(matching:.any).matching(identifier:"playerArtwork").firstMatch,
            "volume":app.descendants(matching:.any).matching(identifier:"playerVolume").firstMatch].mapValues {
                ["x":$0.frame.minX,"y":$0.frame.minY,"width":$0.frame.width,"height":$0.frame.height]
            }
        let layout = XCTAttachment(data: try! JSONSerialization.data(withJSONObject:metrics,options:.sortedKeys), uniformTypeIdentifier:"public.json")
        layout.name="player-layout-metrics"; layout.lifetime = .keepAlways; add(layout)
        XCTAssertEqual(play.frame.width, 68, accuracy: 1)
        XCTAssertGreaterThanOrEqual(tags.frame.height, 44)
        XCTAssertGreaterThanOrEqual(tags.frame.minY, app.staticTexts["playerAlbum"].frame.maxY)
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(identifier: "playerVolume").firstMatch.frame.minY, play.frame.maxY)
        for name in ["Anterior","Siguiente","Aleatorio","Repetición"] {
            XCTAssertGreaterThanOrEqual(app.buttons[name].frame.width,44)
            XCTAssertGreaterThanOrEqual(app.buttons[name].frame.height,44)
        }
        capture("tags-player-noche",app)
        app.buttons["songStyle:Rock---Alternative Rock"].tap()
        XCTAssertTrue(app.navigationBars["Estilo y ambiente"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Rock alternativo"].exists)
        capture("tags-detail",app)
        app.buttons["refreshAudioCharacter"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Conecta con tu servidor")).firstMatch.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Rock alternativo"].exists, "Failed refresh must keep the previous tags")
        capture("tags-refresh-offline",app)
        app.buttons["Listo"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["openNowPlaying"].waitForExistence(timeout: 15)); app.buttons["openNowPlaying"].tap()
        XCTAssertTrue(app.buttons["songMood:sad"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["songMood:relaxed"].exists)
        capture("tags-restored-offline",app); app.terminate()
    }
    @MainActor func testLightAndLargeTextKeepControlsReachable() {
        for (theme,large) in [("papel",false),("noche",true)] {
            let app = open(theme,large:large)
            XCTAssertTrue(app.buttons["playerTransport"].isHittable)
            XCTAssertTrue(app.buttons["openAudioTools"].isHittable)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "playerOutput").firstMatch.isHittable)
            let row = app.scrollViews["songCharacterTags"], first = app.buttons["songStyle:Rock---Alternative Rock"]
            XCTAssertGreaterThanOrEqual(row.frame.height + 1, first.frame.height, "Large labels must fit vertically inside their scroll view")
            capture(large ? "tags-player-accessibility" : "tags-player-papel",app)
            app.terminate()
        }
    }
}
