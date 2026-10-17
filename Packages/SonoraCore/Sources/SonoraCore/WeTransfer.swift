import Foundation

public enum WeTransferError: LocalizedError {
    case invalidLink, invalidResponse, unavailable, restricted, empty, response(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Introduce un enlace válido de WeTransfer o we.tl."
        case .invalidResponse: "WeTransfer no ha devuelto una descarga válida. Puede que necesite una verificación o que haya cambiado su página."
        case .unavailable: "La transferencia ha caducado o ya no está disponible."
        case .restricted: "Esta transferencia requiere contraseña, identificación o permiso de descarga en WeTransfer."
        case .empty: "La transferencia no contiene archivos para descargar."
        case .response(let code): "WeTransfer ha respondido con un error (\(code)). Inténtalo de nuevo más tarde."
        }
    }
}

public struct WeTransferLink: Sendable {
    public let url: URL
    public let transferID: String?
    public let recipientID: String?
    public let securityHash: String?

    public init(_ input: String) throws {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let url = parts.url else { throw WeTransferError.invalidLink }
        let path = parts.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? "" }
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        if host == "we.tl" {
            guard path.count == 1, path[0].hasPrefix("t-"), token(path[0]) else { throw WeTransferError.invalidLink }
            transferID = nil; recipientID = nil; securityHash = nil
        } else {
            guard host == "wetransfer.com" || host.hasSuffix(".wetransfer.com"),
                  path.count == 3 || path.count == 4, path[0] == "downloads",
                  path.dropFirst().allSatisfy(token) else { throw WeTransferError.invalidLink }
            transferID = path[1]; recipientID = path.count == 4 ? path[2] : nil; securityHash = path.last
        }
        self.url = url
    }
}

public struct WeTransferTransfer: Sendable {
    public let transferID: String
    public let name: String
    public let filename: String
    public let bytes: Int64
    public let files: Int
    let link: WeTransferLink
    public var importIdentifier: String { "wetransfer:" + transferID }
}

/// Provider-specific page and download protocol, isolated from storage/playback.
/// Only the short-lived request objects contain the transfer's access tokens.
public struct WeTransferClient: Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
    }
    public func inspect(_ input: String) async throws -> WeTransferTransfer {
        let requested = try WeTransferLink(input)
        var request = URLRequest(url: requested.url)
        request.setValue("Sonora/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validate(response)
        guard data.count <= 4 * 1024 * 1024, let finalURL = response.url,
              let link = try? WeTransferLink(finalURL.absoluteString), let id = link.transferID,
              let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html), let json = html[range].data(using: .utf8) else { throw WeTransferError.invalidResponse }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: json) }
        catch { throw WeTransferError.invalidResponse }
        let page = envelope.props.pageProps
        guard page.isTransferUnavailable != true, let transfer = page.initialTransfer, transfer.state == "downloadable" else { throw WeTransferError.unavailable }
        guard transfer.id == id else { throw WeTransferError.invalidResponse }
        guard transfer.passwordProtected != true, transfer.paid != true, transfer.encrypted != true,
              transfer.downloaderEmailVerification == nil || transfer.downloaderEmailVerification == "anonymous",
              transfer.viewOption != "preview_only" else { throw WeTransferError.restricted }
        let files = transfer.filesCount ?? transfer.items?.count ?? 0
        guard files > 0 else { throw WeTransferError.empty }
        guard files <= 100_000, let bytes = transfer.size, bytes >= 0 else { throw WeTransferError.invalidResponse }
        let filename = transfer.recommendedFilename ?? "WeTransfer.zip"
        guard filename.utf8.count <= 4096, AudioTrack(relativePath: filename) != nil, !filename.contains("\\"), !filename.contains("/") else { throw WeTransferError.invalidResponse }
        let name = transfer.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WeTransferTransfer(transferID: id, name: name?.isEmpty == false ? name! : (filename as NSString).deletingPathExtension,
                                  filename: filename, bytes: bytes, files: files, link: link)
    }
    public func downloadURL(for transfer: WeTransferTransfer) async throws -> URL {
        var body = ["security_hash": transfer.link.securityHash ?? "", "intent": "entire_transfer"]
        if let recipient = transfer.link.recipientID { body["recipient_id"] = recipient }
        var request = URLRequest(url: URL(string: "https://wetransfer.com/api/v4/transfers/\(transfer.transferID)/download")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Sonora/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("https://wetransfer.com", forHTTPHeaderField: "Origin")
        request.setValue("https://wetransfer.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation(); try validate(response)
        guard data.count <= 1024 * 1024, let reply = try? JSONDecoder().decode(Download.self, from: data),
              let url = URL(string: reply.directLink), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw WeTransferError.invalidResponse }
        return url
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw WeTransferError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw WeTransferError.restricted
        case 404, 410: throw WeTransferError.unavailable
        default: throw WeTransferError.response(http.statusCode)
        }
    }
    private struct Download: Decodable {
        let directLink: String
        enum CodingKeys: String, CodingKey { case directLink = "direct_link" }
    }
    private struct Envelope: Decodable {
        let props: Props
        struct Props: Decodable { let pageProps: Page }
        struct Page: Decodable { let initialTransfer: Transfer?; let isTransferUnavailable: Bool? }
    }
    private struct Transfer: Decodable {
        let id: String; let state: String; let recommendedFilename: String?; let title: String?
        let size: Int64?; let filesCount: Int?; let items: [Item]?
        let passwordProtected: Bool?; let paid: Bool?; let encrypted: Bool?
        let downloaderEmailVerification: String?; let viewOption: String?
        struct Item: Decodable { let id: String }
        enum CodingKeys: String, CodingKey {
            case id, state, title, size, items, paid, encrypted
            case recommendedFilename = "recommended_filename", filesCount = "files_count", passwordProtected = "password_protected"
            case downloaderEmailVerification = "downloader_email_verification", viewOption = "view_option"
        }
    }
}
