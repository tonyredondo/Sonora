import AVKit
import CryptoKit
import SonoraCore
import UIKit
import SwiftUI
import XCTest
@testable import Sonora

private actor HeaderHTTP: MetadataLookupTransport {
    private(set) var submissions = 0
    private(set) var acknowledgements = 0
    private(set) var generations: Set<Data> = []
    var running = false
    var loseAcknowledgement = false
    var busyAdmission = false
    var missingAck = false
    let image: Data
    let id = String(repeating: "a", count: 64)
    init(image: Data) { self.image = image }
    func run(_ value: Bool) { running = value }
    func loseNextAcknowledgement() { loseAcknowledgement = true }
    func busyThenMissingAck() { busyAdmission = true; missingAck = true }
    func send(_ request: URLRequest) async throws -> MetadataHTTPResponse {
        if request.url!.path.hasSuffix("/ack") {
            acknowledgements += 1
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            guard body["sha256"] == ArtworkExtensionStore.digest(image) else { throw MetadataLookupError.invalidResponse }
            if missingAck { return .init(data: Data("{\"error\":\"artwork_expansion_not_found\"}".utf8), status: 404, contentType: "application/json") }
            return .init(data: Data(), status: 204, contentType: nil)
        }
        if request.httpMethod == "POST" {
            submissions += 1
            if busyAdmission { busyAdmission = false; return .init(data: Data("{\"error\":\"codex_busy\"}".utf8), status: 503, contentType: "application/json") }
            let input = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            guard input["aspect"] == "2:3", let encoded = input["image"], let source = Data(base64Encoded: encoded) else { throw MetadataLookupError.invalidResponse }
            // The real server deduplicates decoded source bytes, regardless of JSON key order.
            generations.insert(source)
            if loseAcknowledgement { loseAcknowledgement = false; throw URLError(.networkConnectionLost) }
        }
        if request.url!.path.hasSuffix("/image") { return .init(data: image, status: 200, contentType: "image/png") }
        return .init(data: Data("{\"id\":\"\(id)\",\"state\":\"\(running ? "running" : "completed")\"}".utf8), status: 200, contentType: "application/json")
    }
}

@MainActor final class ArtworkExtensionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: MetadataAssistantSettings!
    private var bindings: MusicToolsCache!
    private var images: MetadataLookupCache!
    private var inputs: MetadataLookupCache!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "HeaderTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        defaults.set("http://127.0.0.1:9", forKey: "metadata.endpoint")
        settings = MetadataAssistantSettings(defaults: defaults, tokens: MetadataTokenStore(service: suite), cache: .init(directory: root.appendingPathComponent("metadata")))
        bindings = MusicToolsCache(root: root.appendingPathComponent("bindings"))
        images = MetadataLookupCache(directory: root.appendingPathComponent("images"))
        inputs = MetadataLookupCache(directory: root.appendingPathComponent("inputs"))
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func png(size: CGSize, color: UIColor = .cyan) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }.pngData()!
    }
    private func source() throws -> (Data, FileFingerprint) {
        let data = png(size: CGSize(width: 32, height: 32))
        let file = root.appendingPathComponent("original.png"); try data.write(to: file)
        return (data, try FileFingerprint(file))
    }
    private func store(_ http: HeaderHTTP) -> ArtworkExtensionStore {
        ArtworkExtensionStore(settings: settings, bindings: bindings, images: images, inputs: inputs,
            requests: CodexRequestPool(), clientFactory: { try GeneratedArtworkClient(connection: .init(endpoint: "http://127.0.0.1:9", token: "fixture"), transport: http, kind: .headerExtension) }, pollInterval: .milliseconds(10))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
    func testExistingCoverIsSharedAcrossSongsAndHeaderRestoresOfflineWithoutChangingSource() async throws {
        let (data, fingerprint) = try source()
        let http = HeaderHTTP(image: png(size: CGSize(width: 32, height: 48), color: .green))
        let first = store(http); defer { first.stop() }
        first.select(owner: "song-one", fingerprint: fingerprint)
        await first.enqueue(owner: "song-one", fingerprint: fingerprint, source: data, enabled: true)
        await first.enqueue(owner: "song-two", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { first.pendingCount == 0 && first.statuses["song-two"] == .ready }
        XCTAssertEqual(first.currentImage?.cgImage?.width, 32)
        XCTAssertEqual(first.currentImage?.cgImage?.height, 48)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("original.png")), data)
        settings.offline = true
        let second = store(http); defer { second.stop() }
        second.select(owner: "song-two", fingerprint: fingerprint)
        try await wait { second.currentImage != nil }
        XCTAssertNil(second.image(owner: "song-one", fingerprint: fingerprint))
        let submissions = await http.submissions, acknowledgements = await http.acknowledgements
        XCTAssertEqual(submissions, 1); XCTAssertEqual(acknowledgements, 1)
    }
    func testNewExtensionVersionRebuildsOnlyTheDerivativeAndKeepsOldCacheEntries() async throws {
        let (data, fingerprint) = try source()
        let oldKey = "phone-header-v2:" + ArtworkExtensionStore.digest(try ArtworkExtensionStore.normalized(data))
        let oldImage = png(size: CGSize(width: 32, height: 48), color: .red)
        try await images.storeUnlessCancelled(oldImage, key: oldKey, status: 200)
        struct OldBinding: Codable { let fingerprint: FileFingerprint; let key: String }
        try await bindings.write(OldBinding(fingerprint: fingerprint, key: oldKey), key: "phone-header-binding-v2:song")
        let http = HeaderHTTP(image: png(size: CGSize(width: 32, height: 48), color: .green))
        let value = store(http); defer { value.stop() }
        value.select(owner: "song", fingerprint: fingerprint)
        await value.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { value.currentStatus == .ready && value.pendingCount == 0 }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1)
        let retained = try await images.read(key: oldKey)
        XCTAssertEqual(retained?.data, oldImage)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("original.png")), data)
    }
    func testLostSubmissionAcknowledgementReusesOneRemoteGeneration() async throws {
        let (data, fingerprint) = try source()
        let http = HeaderHTTP(image: png(size: CGSize(width: 32, height: 48)))
        await http.loseNextAcknowledgement()
        let value = store(http); defer { value.stop() }
        await value.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { value.statuses["song"] == .ready && value.pendingCount == 0 }
        let submissions = await http.submissions, generations = await http.generations.count
        XCTAssertEqual(submissions, 2); XCTAssertEqual(generations, 1)
    }
    func testOddSquareDimensionsAcceptTheRoundedPortraitWithoutChangingTheSource() async throws {
        let data = png(size: CGSize(width: 33, height: 33))
        let file = root.appendingPathComponent("odd-original.png"); try data.write(to: file)
        let fingerprint = try FileFingerprint(file)
        let http = HeaderHTTP(image: png(size: CGSize(width: 33, height: 50)))
        let value = store(http); defer { value.stop() }
        value.select(owner: "odd", fingerprint: fingerprint)
        await value.enqueue(owner: "odd", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { value.pendingCount == 0 }
        XCTAssertEqual(value.currentStatus, .ready)
        XCTAssertEqual(value.currentImage?.cgImage?.width, 33)
        XCTAssertEqual(value.currentImage?.cgImage?.height, 50)
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertFalse(GeneratedArtworkClient.isHeaderPNG(png(size: CGSize(width: 33, height: 49))))
    }
    func testBusyAdmissionRetriesAutomaticallyAndExpiredAckKeepsTheVerifiedLocalImage() async throws {
        let (data, fingerprint) = try source()
        let http = HeaderHTTP(image: png(size: CGSize(width: 32, height: 48)))
        await http.busyThenMissingAck()
        let value = store(http); defer { value.stop() }
        value.select(owner: "song", fingerprint: fingerprint)
        await value.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { value.currentImage != nil && value.pendingCount == 0 }
        XCTAssertEqual(value.currentStatus, .ready)
        let posts = await http.submissions, count = await http.generations.count
        XCTAssertEqual(posts, 2); XCTAssertEqual(count, 1)
    }
    func testPersistedJobSurvivesLocalStopAndBackgroundWithoutResubmitting() async throws {
        let (data, fingerprint) = try source()
        let http = HeaderHTTP(image: png(size: CGSize(width: 32, height: 48)))
        await http.run(true)
        let first = store(http)
        await first.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { first.statuses["song"] == .generating }
        first.stop()
        let second = store(http); defer { second.stop() }
        second.setActive(false)
        await second.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { second.statuses["song"] == .paused }
        await http.run(false); second.setActive(true)
        try await wait { second.statuses["song"] == .ready && second.pendingCount == 0 }
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1)
    }
    func testMalformedHeaderNeverReplacesTheCoverOrAcknowledgesAnInvalidResult() async throws {
        let (data, fingerprint) = try source()
        let http = HeaderHTTP(image: data) // A valid square is not a valid upper-extension result.
        let value = store(http); defer { value.stop() }
        value.select(owner: "song", fingerprint: fingerprint)
        await value.enqueue(owner: "song", fingerprint: fingerprint, source: data, enabled: true)
        try await wait { if case .failed = value.currentStatus { return true }; return false }
        XCTAssertNil(value.currentImage)
        let acknowledgements = await http.acknowledgements; XCTAssertEqual(acknowledgements, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("original.png")), data)
    }
    func testGeneratedHeaderJoinsTheVisibleCropWhenControlsReduceArtworkHeight() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        func gradient(width: Int, height: Int, start: Int) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
                for y in 0..<height {
                    UIColor(red: CGFloat(start+y)/255, green: 0, blue: 0, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: y, width: width, height: 1))
                }
            }
        }
        for side in [100, 101] {
            let fullHeight = (side * 3 + 1) / 2
            let original = gradient(width: side, height: side, start: fullHeight - side)
            let expanded = gradient(width: side, height: fullHeight, start: 0)
            for coverHeight in [Double(side - 40), Double(side)] {
                let content = ArtworkBackdrop(image: original, extensionImage: expanded,
                    artworkSize: CGSize(width: CGFloat(side), height: coverHeight), height: 40)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: content); renderer.scale = 1
                let cg = try XCTUnwrap(renderer.uiImage?.cgImage)
                XCTAssertEqual(cg.bitsPerPixel, 32)
                let bytes = try XCTUnwrap(cg.dataProvider?.data) as Data
                let a = 39*cg.bytesPerRow+50*4, b = 40*cg.bytesPerRow+50*4
                let difference = (0..<4).map { abs(Int(bytes[a+$0])-Int(bytes[b+$0])) }.max()!
                XCTAssertLessThanOrEqual(difference, 8, "The upper image must join the actual visible source crop at height \(coverHeight)")
            }
        }
    }
    func testCompleteCoverKeepsItsBottomEdgeWhenControlsReduceAvailableHeight() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 145, width: 100, height: 5))
        }
        let content = ArtworkBackdrop(image: nil, extensionImage: portrait,
            artworkSize: CGSize(width: 100, height: 75), height: 40)
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let pixel = ((image.height - 2) * image.width + image.width / 2) * 4
        XCTAssertGreaterThan(bytes[pixel + 1], 240, "The bottom of the original cover must remain inside the viewport")
        XCTAssertLessThan(bytes[pixel], 10)
    }
    func testPreparingCoverKeepsBothSideEdgesBelowTheHeader() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 100))
            UIColor.blue.setFill(); context.fill(CGRect(x: 90, y: 0, width: 10, height: 100))
        }
        for headerHeight in [40.0, 120.0] {
            let content = ArtworkBackdrop(image: source, extensionImage: nil,
                artworkSize: CGSize(width: 100, height: 100), height: headerHeight)
            let renderer = ImageRenderer(content: content); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            let row = Int(headerHeight) + 50
            let left = (row * image.width + 5) * 4, right = (row * image.width + 95) * 4
            XCTAssertGreaterThan(bytes[left], 240, "The left edge must remain visible while the extension is pending or unavailable")
            XCTAssertLessThan(bytes[left + 2], 10)
            XCTAssertGreaterThan(bytes[right + 2], 240, "The right edge must remain visible while the extension is pending or unavailable")
            XCTAssertLessThan(bytes[right], 10)
        }
    }
    func testPreparingArtworkShowsOneContinuousPhotoWithoutAReflectedSection() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            for y in 0..<100 {
                UIColor(white: CGFloat(y) / 99, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: y, width: 100, height: 1))
            }
        }
        let content = ArtworkBackdrop(image: original, extensionImage: nil,
            artworkSize: CGSize(width: 100, height: 100), height: 40)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        let cg = try XCTUnwrap(renderer.uiImage?.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var previous = Int(bytes[50 * 4])
        for y in 1..<cg.height {
            let current = Int(bytes[(y * cg.width + 50) * 4])
            XCTAssertGreaterThanOrEqual(current, previous - 1,
                "The source photo must progress in one direction, without repeating or mirroring its upper section")
            previous = current
        }
        XCTAssertGreaterThan(previous, 240)
    }
    func testNativePlayerKeepsBottomCreditsVisibleWithRegularAndCompactControls() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 450), format: format).image { context in
            UIColor(red: 0.7, green: 0.75, blue: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
            ("FULL COVER" as NSString).draw(at: CGPoint(x: 12, y: 175), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.black])
            UIColor.magenta.setFill(); context.fill(CGRect(x: 12, y: 425, width: 110, height: 8))
            ("BOTTOM CREDIT" as NSString).draw(at: CGPoint(x: 12, y: 410), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: UIColor.black])
        }
        try await captureCreditLayouts(result: try XCTUnwrap(portrait.pngData()), prefix: "credit-regression", checkMarker: true)
    }
    func testNativeSavedPaperCoverLayouts() async throws {
        let fixtures = URL.documentsDirectory.appendingPathComponent("Header Artwork QA")
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(".owned-header-qa").path),
              let portrait = try? Data(contentsOf: fixtures.appendingPathComponent("credit-portrait.png")) else {
            throw XCTSkip("Requires an owned local copy of the reported artwork for visual comparison")
        }
        try await captureCreditLayouts(result: portrait, prefix: "paper-cover", checkMarker: false)
    }
    private func captureCreditLayouts(result: Data, prefix: String, checkMarker: Bool) async throws {
        let portrait = try XCTUnwrap(UIImage(data: result)?.cgImage)
        let sourceImage = try XCTUnwrap(portrait.cropping(to: CGRect(x: 0, y: portrait.height - portrait.width, width: portrait.width, height: portrait.width)))
        let source = try XCTUnwrap(UIImage(cgImage: sourceImage).pngData())
        let folder = root.appendingPathComponent("credit-music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wave = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "wav")))
        try wave.write(to: folder.appendingPathComponent("credit.wav")); try source.write(to: folder.appendingPathComponent("cover.png"))
        for key in ["prepareQueueAudio", "prepareQueueCharacter", "prepareQueueMeaning", "prepareQueueTranslation"] { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: "prepareQueueArtwork"); defaults.set(0, forKey: "nowPlayingPage")
        let extensions = store(HeaderHTTP(image: result))
        let squares = GeneratedArtworkStore(settings: settings, bindings: bindings, images: .init(directory: root.appendingPathComponent("credit-squares")), requests: CodexRequestPool()) { _ in
            XCTFail("An existing cover must not be generated again"); return source
        }
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("credit-imports"), generatedArtwork: squares, artworkExtensions: extensions, activateSession: {})
        defer { extensions.stop(); player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(folder, autoPlay: false)
        try await wait { player.currentArtworkExtension != nil && extensions.pendingCount == 0 }
        _ = try XCTUnwrap(player.currentArtworkExtension)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        for (name, size, scheme) in [("regular", CGSize(width: 402, height: 874), ColorScheme.dark),
                                    ("compact", CGSize(width: 375, height: 667), ColorScheme.dark),
                                    ("light", CGSize(width: 402, height: 874), ColorScheme.light)] {
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: NowPlayingView(player: player).defaultAppStorage(defaults).preferredColorScheme(scheme))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300)); window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = prefix + "-" + name; attachment.lifetime = .keepAlways; add(attachment)
            let fixtures = URL.documentsDirectory.appendingPathComponent("Header Artwork QA")
            if FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(".owned-header-qa").path) {
                try image.pngData()!.write(to: fixtures.appendingPathComponent(prefix + "-" + name + ".png"))
            }
            if checkMarker {
                let cg = try XCTUnwrap(image.cgImage)
                let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                    bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let visibleFooter = (0..<(cg.width * cg.height)).filter {
                    bytes[$0 * 4] > 220 && bytes[$0 * 4 + 1] < 20 && bytes[$0 * 4 + 2] > 220
                }.count
                XCTAssertGreaterThan(visibleFooter, 1000, "The real player must keep the bottom credit visible in \(name), including its fade")
            }
            if name == "compact" {
                let scroll = try XCTUnwrap(descendants(UIScrollView.self, in: window).first {
                    $0.bounds.height > 500 && $0.contentSize.height > $0.bounds.height + 50
                }, "Short screens must let the complete cover and playback controls scroll")
                let pages = try XCTUnwrap(descendants(UIPageControl.self, in: window).first)
                pages.currentPage = 1
                pages.sendActions(for: .valueChanged)
                try await wait { defaults.integer(forKey: "nowPlayingPage") == 1 }
                pages.currentPage = 0
                pages.sendActions(for: .valueChanged)
                try await wait { defaults.integer(forKey: "nowPlayingPage") == 0 }
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
                try await Task.sleep(for: .milliseconds(100)); window.layoutIfNeeded()
                let route = try XCTUnwrap(descendants(AVRoutePickerView.self, in: window).first)
                let routeFrame = route.convert(route.bounds, to: window)
                XCTAssertTrue(window.bounds.inset(by: window.safeAreaInsets).contains(routeFrame), "Bottom controls must remain reachable below the complete artwork")
                let hit = window.hitTest(CGPoint(x: routeFrame.midX, y: routeFrame.midY), with: nil)
                XCTAssertTrue(hit === route || hit?.isDescendant(of: route) == true, "The scrolled output control must receive touches")
                let scrolled = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: scrolled); attachment.name = prefix + "-compact-scrolled"; attachment.lifetime = .keepAlways; add(attachment)
                if FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(".owned-header-qa").path) {
                    try scrolled.pngData()!.write(to: fixtures.appendingPathComponent(prefix + "-compact-scrolled.png"))
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("cover.png")), source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("credit.wav")), wave)
    }
    private func descendants<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        let matching = (view as? T).map { [$0] } ?? []
        return matching + view.subviews.flatMap { descendants(type, in: $0) }
    }
    /// Opt-in visual proof uses only the marked source/result copied into the owned QA simulator.
    func testNativePlayerPreparesWholeQueueThenShowsTheUpperBandAndLyricsOffline() async throws {
        let fixtures = URL.documentsDirectory.appendingPathComponent("Header Artwork QA")
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent(".owned-header-qa").path) else {
            throw XCTSkip("Requires marked synthetic header artwork fixtures on the owned simulator")
        }
        let source = try Data(contentsOf: fixtures.appendingPathComponent("original.png"))
        let result = try Data(contentsOf: fixtures.appendingPathComponent("extended.png"))
        let folder = root.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wave = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "wav")))
        for name in ["one", "two"] {
            try wave.write(to: folder.appendingPathComponent(name + ".wav"))
            try (0..<30).map { String(format: "[00:%02d]Línea %02d sobre la portada ampliada", $0, $0) }.joined(separator: "\n")
                .write(to: folder.appendingPathComponent(name + ".lrc"), atomically: true, encoding: .utf8)
        }
        try source.write(to: folder.appendingPathComponent("cover.png"))
        for key in ["prepareQueueAudio", "prepareQueueCharacter", "prepareQueueMeaning", "prepareQueueTranslation"] { defaults.set(false, forKey: key) }
        defaults.set(true, forKey: "prepareQueueArtwork")
        defaults.set(0, forKey: "nowPlayingPage")
        let http = HeaderHTTP(image: result); await http.run(true)
        let extensions = store(http)
        let squares = GeneratedArtworkStore(settings: settings, bindings: bindings, images: .init(directory: root.appendingPathComponent("squares")), requests: CodexRequestPool()) { _ in
            XCTFail("An existing cover must not be generated again"); return source
        }
        let player = PlaybackController(defaults: defaults, localStorage: root.appendingPathComponent("imports"),
            generatedArtwork: squares, artworkExtensions: extensions, activateSession: {})
        defer { extensions.stop(); player.stop(); player.library.cancelIndexing() }
        await player.loadFolder(folder, autoPlay: false)
        try await wait { extensions.currentStatus == .generating && player.currentDetails?.artwork != nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NowPlayingView(player: player).defaultAppStorage(defaults).preferredColorScheme(.dark))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()!.write(to: fixtures.appendingPathComponent(name + ".png"))
            if name == "header-ready-artwork" {
                // This fixed synthetic sky is smooth here. A separate header/square
                // composition must not introduce a horizontal color discontinuity.
                let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
                let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let columns = (width * 29 / 100)..<(width / 2)
                var largestRowStep = 0.0
                for y in (width / 15)..<(width / 2) {
                    var sum = 0
                    for x in columns { for channel in 0..<3 {
                        sum += abs(Int(bytes[y * width * 4 + x * 4 + channel]) - Int(bytes[(y-1) * width * 4 + x * 4 + channel]))
                    } }
                    largestRowStep = max(largestRowStep, Double(sum) / Double(columns.count * 3))
                }
                XCTAssertLessThan(largestRowStep, 8, "The actual native player must keep the source sky continuous behind its toolbar")
            }
        }
        try await capture("header-preparing")
        await http.run(false)
        try await wait { player.currentArtworkExtension != nil && extensions.pendingCount == 0 }
        try await capture("header-ready-artwork")
        defaults.set(1, forKey: "nowPlayingPage")
        try await capture("header-ready-lyrics")
        XCTAssertEqual(extensions.statuses.count, 2, "Both queued songs must prepare their display derivative")
        let submissions = await http.submissions; XCTAssertEqual(submissions, 1, "One cover is shared across the queue")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("cover.png")), source)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("one.wav")), wave)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("two.wav")), wave)
    }
}
