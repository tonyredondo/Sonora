import Foundation
import XCTest
@testable import SonoraCore

private actor TranslationHTTP: MetadataLookupTransport {
    var calls: [URLRequest] = []
    var response = MetadataHTTPResponse(data: Data(#"{"lines":[{"id":0,"text":" Decidí dejar "},{"id":2,"text":"de fumar."}],"model":"gpt-6.1-sol","effort":"medium"}"#.utf8),
                                        status: 200, contentType: "application/json")
    func send(_ request: URLRequest) -> MetadataHTTPResponse { calls.append(request); return response }
    func set(_ data: String, status: Int = 200) { response = MetadataHTTPResponse(data: Data(data.utf8), status: status, contentType: "application/json") }
}

final class LyricsTranslationTests: XCTestCase {
    private let document = LyricsDocument(text: "[00:02]I decided to give\n[00:03]\n[00:04]up smoking.")
    private func client(_ http: TranslationHTTP) throws -> LyricsTranslationClient {
        LyricsTranslationClient(connection: try MetadataProxyConnection(endpoint: "http://127.0.0.1:8089", token: "fixture-token"), transport: http)
    }
    func testWholeDocumentHasStableIDsButNoTimestampsOrCredentialsInBody() async throws {
        let http = TranslationHTTP()
        let translated = try await client(http).translate(document, source: "auto", target: "es", refresh: true)
        XCTAssertNil(translated.phrases)
        XCTAssertEqual(translated.lines, [0: "Decidí dejar", 2: "de fumar."])
        XCTAssertEqual(document.lines.map(\.time), [2, 3, 4])
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1)
        let request = try XCTUnwrap(calls.first)
        XCTAssertEqual(request.url?.path, "/v1/lyrics/translate")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["source_language"] as? String, "auto")
        XCTAssertEqual(body["target_language"] as? String, "es")
        XCTAssertEqual(body["refresh"] as? Bool, true)
        let lines = try XCTUnwrap(body["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.compactMap { $0["id"] as? Int }, [0, 2])
        XCTAssertEqual(lines.compactMap { $0["text"] as? String }, ["I decided to give", "up smoking."])
        XCTAssertTrue(lines.allSatisfy { Set($0.keys) == ["id", "text"] })
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("fixture-token"))
    }
    func testMissingDuplicateForeignReorderedAndEmptyLinesAreRejected() async throws {
        let http = TranslationHTTP(), service = try client(http)
        for lines in [
            #"[]"#,
            #"[{"id":0,"text":"Collapsed all words"}]"#,
            #"[{"id":0,"text":"First"},{"id":0,"text":"Duplicate"}]"#,
            #"[{"id":0,"text":"First"},{"id":8,"text":"Foreign"}]"#,
            #"[{"id":2,"text":"Second"},{"id":0,"text":"First"}]"#,
            #"[{"id":0,"text":"First"},{"id":2,"text":" "}]"#,
            #"[{"id":0,"text":"First\nSecond"},{"id":2,"text":"Second"}]"#,
        ] {
            await http.set(#"{"lines":\#(lines),"model":"gpt-6.1-sol","effort":"medium"}"#)
            do { _ = try await service.translate(document, source: "en", target: "es"); XCTFail(lines) }
            catch MetadataLookupError.invalidResponse { }
        }
    }
    func testUnexpectedModelOrEffortIsRejected() async throws {
        let http = TranslationHTTP(), service = try client(http)
        for (model, effort) in [("gpt-6-astra", "xhigh"), ("gpt-6.1-sol", "xhigh"), ("other", "medium")] {
            await http.set(#"{"lines":[{"id":0,"text":"Primera"},{"id":2,"text":"Segunda"}],"model":"\#(model)","effort":"\#(effort)"}"#)
            do { _ = try await service.translate(document, source: "en", target: "es"); XCTFail("\(model)/\(effort)") }
            catch MetadataLookupError.invalidResponse { }
        }
    }
    func testAuthenticationErrorsAndOldServerAreActionableAndDoNotLeakProviderText() async throws {
        let http = TranslationHTTP(), service = try client(http)
        await http.set(#"{"error":"unauthorized"}"#, status: 401)
        do { _ = try await service.translate(document, source: "en", target: "es"); XCTFail() }
        catch MetadataLookupError.unauthorized { }
        for (status, body, expected) in [
            (404, "", "actualizado"),
            (504, #"{"error":"codex_timeout","message":"private details"}"#, "demasiado"),
            (429, #"{"error":"codex_limit","message":"private details"}"#, "límite")
        ] {
            await http.set(body, status: status)
            do { _ = try await service.translate(document, source: "en", target: "es"); XCTFail() }
            catch {
                XCTAssertTrue(error.localizedDescription.contains(expected))
                XCTAssertFalse(error.localizedDescription.contains("private details"))
            }
        }
    }
    func testInvalidInputNeverUsesTheNetwork() async throws {
        let http = TranslationHTTP(), service = try client(http)
        for (doc, source, target) in [
            (LyricsDocument(text: ""), "en", "es"),
            (document, "bad instructions", "es"),
            (document, "en", "auto"),
            (LyricsDocument(text: String(repeating: "a", count: 10001)), "en", "es")
        ] {
            do { _ = try await service.translate(doc, source: source, target: target); XCTFail() }
            catch MusicTextError.invalid { }
        }
        let calls = await http.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testMeaningfulUnicodeFormatCharactersSurviveTranslationAndContextValidation() async throws {
        let http = TranslationHTTP(), service = try client(http)
        await http.set(#"{"lines":[{"id":0,"text":"می‌خواهم"},{"id":2,"text":"\u200eTraducción"}],"model":"gpt-6.1-sol","effort":"medium"}"#)
        let value = try await service.translate(document, source: "en", target: "fa")
        XCTAssertEqual(value.lines[0], "می‌خواهم")
        XCTAssertEqual(value.lines[2], "\u{200e}Traducción")
        let original = LyricsDocument(text: "می‌خواهم")
        await http.set(#"{"lines":[{"id":0,"text":"I want"}],"model":"gpt-6.1-sol","effort":"medium"}"#)
        let reverse = try await service.translate(original, source: "fa", target: "en")
        XCTAssertEqual(reverse.lines[0], "I want")
        XCTAssertTrue(LyricsInterpretationContext(title: "می‌خواهم").isValid)
        XCTAssertTrue(AlbumInterpretationInput(title: "Record", artist: "Artist", tracks: [.init(context: .init(title: "Song"), lyrics: "می‌خواهم", genre: "Rock")]).isValid)
    }

}
