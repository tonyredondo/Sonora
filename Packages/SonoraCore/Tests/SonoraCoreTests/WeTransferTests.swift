import Foundation
import XCTest
@testable import SonoraCore

final class WeTransferTests: XCTestCase {
    private let transfer = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa20261017120000"
    private let recipient = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb20261017120001"
    private var share: String { "https://wetransfer.com/downloads/\(transfer)/\(recipient)/abc123" }

    func testRecognizesEmailAndShortLinksWithoutTreatingTrackingAsIdentity() throws {
        let email = try WeTransferLink(share + "?utm_source=test&t_exp=1999999999")
        XCTAssertEqual(email.transferID, transfer)
        XCTAssertEqual(email.recipientID, recipient)
        XCTAssertEqual(email.securityHash, "abc123")
        let direct = try WeTransferLink("https://wetransfer.com/downloads/\(transfer)/abc123")
        XCTAssertEqual(direct.transferID, transfer)
        XCTAssertNil(direct.recipientID)
        XCTAssertNil(try WeTransferLink("https://we.tl/t-example").transferID)
        for invalid in ["http://wetransfer.com/downloads/x/y", "https://wetransfer.com.evil.test/downloads/x/y",
                        "https://user:pass@wetransfer.com/downloads/x/y", "https://wetransfer.com/downloads/a/%2Fetc",
                        "https://example.test/music.zip", "hello"] {
            XCTAssertThrowsError(try WeTransferLink(invalid), invalid)
        }
    }

    func testProviderPageAndDownloadRequestProduceUsableDescriptorAndURL() async throws {
        let html = page()
        let expectedRecipient = recipient
        let session = session { request in
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String: String]
                XCTAssertEqual(body["security_hash"], "abc123")
                XCTAssertEqual(body["recipient_id"], expectedRecipient)
                XCTAssertEqual(body["intent"], "entire_transfer")
                return (request.url!, 200, Data(#"{"direct_link":"https://download.wetransfer.com/test/archive.zip?signature=synthetic"}"#.utf8))
            }
            return (request.url!, 200, html)
        }
        defer { session.invalidateAndCancel() }
        let client = WeTransferClient(session: session)
        let value = try await client.inspect(share)
        XCTAssertEqual(value.transferID, transfer)
        XCTAssertEqual(value.name, "Concierto de prueba")
        XCTAssertEqual(value.filename, "concierto.zip")
        XCTAssertEqual(value.bytes, 123456)
        XCTAssertEqual(value.files, 2)
        let download = try await client.downloadURL(for: value)
        XCTAssertEqual(download.host, "download.wetransfer.com")
        XCTAssertEqual(download.path, "/test/archive.zip")
    }

    func testUnavailableProtectedAndUnexpectedPagesCannotStartAnImport() async throws {
        for html in [page(state: "expired"), page(password: true), Data("<html>Consent required</html>".utf8),
                     Data(#"<script id="__NEXT_DATA__">{"props":{"pageProps":{"isTransferUnavailable":true}}}</script>"#.utf8)] {
            let session = session { request in (request.url!, 200, html) }
            defer { session.invalidateAndCancel() }
            do { _ = try await WeTransferClient(session: session).inspect(share); XCTFail("Unavailable content cannot be imported") }
            catch { XCTAssertTrue(error is WeTransferError) }
        }
    }

    func testShortLinkUsesFinalProviderURLAndRejectsAnotherHost() async throws {
        let html = page()
        for host in ["wetransfer.com", "example.test"] {
            let final = URL(string: share.replacingOccurrences(of: "wetransfer.com", with: host))!
            let session = session { _ in (final, 200, html) }
            defer { session.invalidateAndCancel() }
            do {
                let value = try await WeTransferClient(session: session).inspect("https://we.tl/t-example")
                XCTAssertEqual(host, "wetransfer.com")
                XCTAssertEqual(value.transferID, transfer)
            } catch { XCTAssertEqual(host, "example.test") }
        }
    }

    private func page(state: String = "downloadable", password: Bool = false) -> Data {
        let data: [String: Any] = ["props": ["pageProps": ["isTransferUnavailable": false, "securityHash": "abc123",
            "metadata": ["id": transfer, "title": "Concierto de prueba", "files_count": 2, "should_open_preview": false],
            "initialTransfer": ["id": transfer, "state": state, "transfer_type": "email", "shortened_url": NSNull(),
                "recommended_filename": "concierto.zip", "expires_at": "2026-10-24T12:00:00Z", "password_protected": password,
                "uploaded_at": "2026-10-17T12:00:00Z", "expiry_in_seconds": 604800, "size": 123456, "deleted_at": NSNull(),
                "extended_expiry_date": NSNull(), "user_state": "anonymous", "downloader_email_verification": "anonymous",
                "download_limit": NSNull(), "view_option": "preview_and_download", "allow_comments": false, "allow_favorites": false,
                "force_watermark": false, "is_editable": false, "edit_mode": NSNull(), "can_edit_files": false, "creator": NSNull(),
                "recipient_id": recipient, "display_name": "Sonora QA", "workspace_id": NSNull(), "security_hash": "abc123",
                "description": "Synthetic audio", "paid": false, "workspace": NSNull(), "number_of_downloads": 0,
                "experiment_ids": [], "encrypted": false, "title": "Concierto de prueba", "files_count": 2,
                "transfer_channel_name": NSNull(), "should_open_preview": false,
                "items": [["id": "one", "name": "CD 1/song.mp3", "size": 123000, "retries": 0, "item_type": "file", "uploader_user_id": NSNull(), "previewable": true, "content_identifier": NSNull()],
                          ["id": "two", "name": "CD 1/song.lrc", "size": 456, "retries": 0, "item_type": "file", "uploader_user_id": NSNull(), "previewable": false, "content_identifier": NSNull()]]]]]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: data), encoding: .utf8)!
        return Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
    }
    private func session(_ handler: @escaping (URLRequest) throws -> (URL, Int, Data)) -> URLSession {
        TransferURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class TransferURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (URL, Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (url, code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
