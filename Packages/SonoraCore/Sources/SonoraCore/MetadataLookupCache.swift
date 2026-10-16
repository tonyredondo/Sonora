import CryptoKit
import Foundation

/// An app-owned disk cache. Tokens are never keys or entry contents.
public actor MetadataLookupCache {
    public struct Entry: Codable, Sendable {
        public let data: Data
        public let status: Int
        public let savedAt: Date
        let key: String
    }
    private let directory: URL
    private let maxBytes: Int
    private let maxEntries: Int
    public init(directory: URL, maxBytes: Int = 100_000_000, maxEntries: Int = 1000) {
        self.directory = directory; self.maxBytes = max(1, maxBytes); self.maxEntries = max(1, maxEntries)
    }
    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".plist")
    }
    public func read(key: String) throws -> Entry? {
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10_100_000 else { throw MetadataLookupError.tooLarge }
            let entry = try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: url))
            guard entry.key == key else { throw MetadataLookupError.cacheUnavailable }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return entry
        } catch { throw MetadataLookupError.cacheUnavailable }
    }
    public func store(_ data: Data, key: String, status: Int) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = Entry(data: data, status: status, savedAt: Date(), key: key)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let encoded = try encoder.encode(entry)
            guard encoded.count <= maxBytes && data.count <= 10_000_000 else { throw MetadataLookupError.tooLarge }
            try encoded.write(to: file(key), options: .atomic)
            var files = try ownedFiles().sorted { $0.date == $1.date ? $0.url.lastPathComponent < $1.url.lastPathComponent : $0.date < $1.date }
            var bytes = files.reduce(0) { $0 + $1.size }
            while bytes > maxBytes || files.count > maxEntries {
                let oldest = files.removeFirst(); try FileManager.default.removeItem(at: oldest.url); bytes -= oldest.size
            }
        } catch let error as MetadataLookupError { throw error }
        catch { throw MetadataLookupError.cacheUnavailable }
    }
    public func clear() throws { for file in try ownedFiles() { try FileManager.default.removeItem(at: file.url) } }
    public func size() throws -> Int { try ownedFiles().reduce(0) { $0 + $1.size } }
    private func ownedFiles() throws -> [(url: URL, size: Int, date: Date)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]).compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "plist", name.count == 64, name.allSatisfy({ $0.isHexDigit }) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }
}
