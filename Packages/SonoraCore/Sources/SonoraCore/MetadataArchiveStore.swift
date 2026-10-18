import CryptoKit
import Foundation

/// Durable copies and an outbox, outside the evictable lookup cache. No tokens or file paths are persisted.
/// A pending file is renamed only after its immutable ID is acknowledged; retries are idempotent.
public actor MetadataArchiveStore {
    private let directory: URL
    private var synchronizing: Set<String> = []
    private var waiters: [String:[CheckedContinuation<Void,Never>]] = [:]
    public init(directory: URL) { self.directory = directory }

    public func confirm(_ record: ConfirmedMetadataRecord, server: URL?) throws {
        try write(record, server:server, pending:server != nil)
    }
    public func cache(_ record: ConfirmedMetadataRecord, server: URL) throws {
        try write(record, server:server, pending:false)
    }
    /// List without retaining every embedded artwork in memory.
    public func summaries(audioID: String, server: URL?) throws -> [MetadataRecordSummary] {
        guard ConfirmedMetadataRecord.validAudioID(audioID) else { throw MetadataArchiveError.invalidRecord }
        var records: [UUID:MetadataRecordSummary] = [:]
        let scopes = server == nil ? [nil] : [server, nil]
        for scope in scopes {
            for file in try files(in:audioDirectory(audioID, server:scope)) where file.pathExtension == "plist" {
                let record = try autoreleasepool {
                    let record = try read(file)
                    guard record.audioID == audioID else { throw MetadataArchiveError.invalidRecord }
                    return record.summary
                }
                if let old = records[record.id], old != record { throw MetadataArchiveError.conflict }
                records[record.id] = record
            }
        }
        return records.values.sorted { $0.confirmedAt > $1.confirmedAt || ($0.confirmedAt == $1.confirmedAt && $0.id.uuidString < $1.id.uuidString) }
    }
    public func record(_ id: UUID, audioID: String, server: URL?) throws -> ConfirmedMetadataRecord? {
        guard ConfirmedMetadataRecord.validAudioID(audioID) else { throw MetadataArchiveError.invalidRecord }
        var found: ConfirmedMetadataRecord?
        let scopes = server == nil ? [nil] : [server,nil]
        for scope in scopes {
            for suffix in ["pending","saved"] {
                let file = audioDirectory(audioID,server:scope).appendingPathComponent(id.uuidString.lowercased() + "." + suffix + ".plist")
                guard FileManager.default.fileExists(atPath:file.path) else { continue }
                let record = try read(file)
                guard record.id == id, record.audioID == audioID else { throw MetadataArchiveError.invalidRecord }
                if let found, found != record { throw MetadataArchiveError.conflict }
                found = record
            }
        }
        return found
    }
    public func pendingCount(server: URL) throws -> Int { try pendingFiles(server:server).count }
    public func pendingCount() throws -> Int {
        try files(in:directory).reduce(0) { try $0 + pendingFiles(in:$1).count }
    }

    /// One bounded chunk per call. A new caller waits for the prior chunk, then
    /// reads the current outbox so a confirmation added during upload is not lost.
    @discardableResult public func synchronize(client: MetadataArchiveClient, limit: Int = 20) async throws -> Int {
        let server = client.connection.endpoint, key = scope(server)
        while synchronizing.contains(key) {
            try Task.checkCancellation()
            await withCheckedContinuation { waiters[key,default:[]].append($0) }
        }
        try Task.checkCancellation()
        synchronizing.insert(key)
        defer {
            synchronizing.remove(key)
            waiters.removeValue(forKey:key)?.forEach { $0.resume() }
        }
        var sent = 0
        for file in try pendingFiles(server:server).prefix(max(1,min(20,limit))) {
            try Task.checkCancellation()
            let record = try read(file)
            try await client.save(record)
            try Task.checkCancellation()
            let saved = file.deletingLastPathComponent().appendingPathComponent(record.id.uuidString.lowercased() + ".saved.plist")
            if FileManager.default.fileExists(atPath:saved.path) {
                guard try read(saved) == record else { throw MetadataArchiveError.conflict }
                try FileManager.default.removeItem(at:file)
            } else { try FileManager.default.moveItem(at:file, to:saved) }
            sent += 1
        }
        return sent
    }
    private func write(_ record: ConfirmedMetadataRecord, server: URL?, pending: Bool) throws {
        try record.validate()
        let folder = audioDirectory(record.audioID,server:server)
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let name = record.id.uuidString.lowercased()
        for suffix in ["pending", "saved"] {
            let existing = folder.appendingPathComponent(name + "." + suffix + ".plist")
            if FileManager.default.fileExists(atPath:existing.path) {
                guard try read(existing) == record else { throw MetadataArchiveError.conflict }
                return
            }
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        guard data.count <= 15_000_000 else { throw MetadataLookupError.tooLarge }
        try data.write(to:folder.appendingPathComponent(name + (pending ? ".pending.plist" : ".saved.plist")), options:.atomic)
    }
    private func read(_ file: URL) throws -> ConfirmedMetadataRecord {
        guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 15_000_000 else { throw MetadataLookupError.tooLarge }
        let record = try PropertyListDecoder().decode(ConfirmedMetadataRecord.self,from:Data(contentsOf:file))
        try record.validate()
        return record
    }
    private func pendingFiles(server: URL) throws -> [URL] {
        try pendingFiles(in:directory.appendingPathComponent(scope(server),isDirectory:true))
    }
    private func pendingFiles(in scope: URL) throws -> [URL] {
        var pending: [URL] = []
        for folder in try files(in:scope) {
            for file in try files(in:folder) where file.lastPathComponent.hasSuffix(".pending.plist") { pending.append(file) }
        }
        let dated = try pending.map { ($0,try $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
        return dated.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.path < $1.0.path) }.map(\.0)
    }
    private func files(in folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath:folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.fileSizeKey],options:.skipsHiddenFiles)
    }
    private func audioDirectory(_ audioID: String, server: URL?) -> URL {
        directory.appendingPathComponent(scope(server),isDirectory:true).appendingPathComponent(digest(audioID),isDirectory:true)
    }
    private func scope(_ server: URL?) -> String { server.map { digest($0.appendingPathComponent("").absoluteString) } ?? "local" }
    private func digest(_ value: String) -> String { SHA256.hash(data:Data(value.utf8)).map { String(format:"%02x",$0) }.joined() }
}
