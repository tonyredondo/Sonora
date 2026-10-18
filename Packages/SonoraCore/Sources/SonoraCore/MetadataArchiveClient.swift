import Foundation

/// Uses the private proxy only. Confirmed tags never go to external providers.
public struct MetadataArchiveClient: Sendable {
    public let connection: MetadataProxyConnection
    private let transport: any MetadataLookupTransport
    public init(connection: MetadataProxyConnection, transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout:15, resourceTimeout:20)) {
        self.connection = connection; self.transport = transport
    }
    public func save(_ record: ConfirmedMetadataRecord) async throws {
        try record.validate()
        var request = try connection.request(path:"v1/metadata-records/" + record.id.uuidString.lowercased())
        request.httpMethod = "PUT"; request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        request.httpBody = try encoder.encode(record)
        guard (request.httpBody?.count ?? 0) <= 22_000_000 else { throw MetadataLookupError.tooLarge }
        let response = try await transport.send(request)
        try Task.checkCancellation(); try check(response)
        struct Acknowledgement: Decodable { let id: UUID }
        guard response.data.count <= 4096, try JSONDecoder().decode(Acknowledgement.self, from:response.data).id == record.id else { throw MetadataArchiveError.invalidRecord }
    }
    public func list(audioID: String, before: Int64? = nil) async throws -> MetadataRecordPage {
        guard ConfirmedMetadataRecord.validAudioID(audioID), before.map({ $0 > 0 }) ?? true else { throw MetadataArchiveError.invalidRecord }
        let response = try await transport.send(connection.request(path:"v1/audio/" + audioID + "/metadata", parameters:before.map { [URLQueryItem(name:"before",value:String($0))] } ?? []))
        try Task.checkCancellation(); try check(response)
        guard response.data.count <= 400_000 else { throw MetadataLookupError.tooLarge }
        let page = try JSONDecoder().decode(MetadataRecordPage.self, from:response.data)
        guard page.records.count <= 50 else { throw MetadataArchiveError.invalidRecord }
        if let next = page.nextCursor, next <= 0 || (before.map { next >= $0 } ?? false) { throw MetadataArchiveError.invalidRecord }
        return page
    }
    public func record(_ id: UUID, audioID: String) async throws -> ConfirmedMetadataRecord {
        guard ConfirmedMetadataRecord.validAudioID(audioID) else { throw MetadataArchiveError.invalidRecord }
        let response = try await transport.send(connection.request(path:"v1/metadata-records/" + id.uuidString.lowercased()))
        try Task.checkCancellation(); try check(response)
        guard response.data.count <= 22_000_000 else { throw MetadataLookupError.tooLarge }
        let record = try JSONDecoder().decode(ConfirmedMetadataRecord.self, from:response.data)
        try record.validate()
        guard record.id == id, record.audioID == audioID else { throw MetadataArchiveError.invalidRecord }
        return record
    }
    private func check(_ response: MetadataHTTPResponse) throws {
        switch response.status {
        case 200,201: return
        case 401,403: throw MetadataLookupError.unauthorized
        case 409: throw MetadataArchiveError.conflict
        case 413: throw MetadataLookupError.tooLarge
        case 507: throw MetadataArchiveError.storageFull
        case 404:
            if let error = try? JSONDecoder().decode([String:String].self, from:response.data), error["error"] == "metadata_not_found" { throw MetadataLookupError.notFound }
            throw MetadataArchiveError.unsupported
        default: throw MetadataLookupError.unavailable
        }
    }
}
