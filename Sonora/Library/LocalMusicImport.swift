import Foundation
import SonoraCore

struct ImportedMusicRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let files: Int
    let importedAt: Date
}
struct LocalMusicImportProgress: Sendable {
    let filename: String
    let completed: Int
    let total: Int
    let bytes: Int64
}

enum LocalMusicImport {
    static var defaultStorage: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SonoraMusic", isDirectory: true) }
    static func musicURL(_ record: ImportedMusicRecord, storage: URL = defaultStorage) -> URL {
        storage.appendingPathComponent(record.id, isDirectory: true).appendingPathComponent("Music", isDirectory: true)
    }
    static func records(in storage: URL = defaultStorage) throws -> [ImportedMusicRecord] {
        guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles).compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil else { return nil }
            let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: folder.appendingPathComponent(".sonora-import.json"))
            guard data.count < 16_384 else { throw CocoaError(.fileReadCorruptFile) }
            let record = try JSONDecoder().decode(ImportedMusicRecord.self, from: data)
            guard record.id == folder.lastPathComponent, record.files > 0, record.bytes >= 0, record.name.utf8.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            return record
        }.sorted { $0.importedAt > $1.importedAt }
    }
    static func remove(_ record: ImportedMusicRecord, storage: URL = defaultStorage) throws {
        guard UUID(uuidString: record.id) != nil, try records(in: storage).contains(record) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: storage.appendingPathComponent(record.id))
    }
    static func copy(_ url: URL, storage: URL = defaultStorage,
                     progress: @escaping @Sendable (LocalMusicImportProgress) -> Void = { _ in }) async throws -> ImportedMusicRecord {
        try Task.checkCancellation()
        let job = CopyJob(), worker = Task.detached(priority: .utility) { try job.copy(url, storage: storage, progress: progress) }
        // After the atomic directory move, a successful copy is committed even
        // if cancellation races with its completion. Never leave half a library.
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}

private final class CopyJob: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    func copy(_ url: URL, storage: URL, progress: @escaping @Sendable (LocalMusicImportProgress) -> Void) throws -> ImportedMusicRecord {
        try Task.checkCancellation()
        let source = try ScopedFolder(url), root = source.url.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        let prefix = root.path + "/", allowed = FolderScanner.defaultExtensions.union(["cue", "lrc", "txt", "jpg", "jpeg", "png", "m3u", "m3u8"])
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        var files: [(URL, String)] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { continue }
            guard info.isRegularFile == true, allowed.contains(file.pathExtension.lowercased()) else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix), let track = AudioTrack(relativePath: String(path.dropFirst(prefix.count))) else { throw CocoaError(.fileReadNoPermission) }
            guard files.count < 100_000 else { throw MusicTextError.invalid("La carpeta supera los 100.000 archivos. Importa una subcarpeta.") }
            files.append((file, track.relativePath))
        }
        if let enumerationError { throw enumerationError }
        try Task.checkCancellation()
        guard files.contains(where: { FolderScanner.defaultExtensions.contains($0.0.pathExtension.lowercased()) }) else { throw MusicTextError.invalid("La carpeta no contiene audio compatible.") }
        let id = UUID().uuidString
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("SonoraImport-" + id, isDirectory: true)
        let music = staging.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var totalBytes: Int64 = 0, lastReport = -Double.infinity
        func report(_ value: LocalMusicImportProgress) {
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastReport >= 0.1 || value.completed == value.total { progress(value); lastReport = now }
        }
        for (index, pair) in files.enumerated() {
            try Task.checkCancellation()
            report(.init(filename: pair.1, completed: index, total: files.count, bytes: totalBytes))
            if (try? pair.0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
                try FileManager.default.startDownloadingUbiquitousItem(at: pair.0)
            }
            let destination = music.appendingPathComponent(pair.1)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            var error: NSError?, result: Result<Int64, Error>?
            coordinator.coordinate(readingItemAt: pair.0, options: .withoutChanges, error: &error) { local in
                result = Result {
                    let fingerprint = try FileFingerprint(local)
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let input = try FileHandle(forReadingFrom: local), output = try FileHandle(forWritingTo: destination)
                    defer { try? input.close(); try? output.close() }
                    var count: Int64 = 0, lastUpdate = Date.timeIntervalSinceReferenceDate
                    while true {
                        try Task.checkCancellation()
                        guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
                        try output.write(contentsOf: data); count += Int64(data.count)
                        let now = Date.timeIntervalSinceReferenceDate
                        if now - lastUpdate >= 0.1 {
                            report(.init(filename: pair.1, completed: index, total: files.count, bytes: totalBytes + count)); lastUpdate = now
                        }
                    }
                    try output.synchronize()
                    guard try FileFingerprint(local) == fingerprint, UInt64(count) == fingerprint.size else { throw MetadataIOError.changed }
                    return count
                }
            }
            if let error { throw error }
            guard let result else { throw CancellationError() }
            totalBytes += try result.get()
            report(.init(filename: pair.1, completed: index + 1, total: files.count, bytes: totalBytes))
        }
        try Task.checkCancellation()
        guard !(try FolderScanner.scan(music, isCancelled: { Task.isCancelled })).isEmpty else { throw MusicTextError.invalid("No se ha encontrado audio en la copia.") }
        let record = ImportedMusicRecord(id: id, name: root.lastPathComponent, bytes: totalBytes, files: files.count, importedAt: Date())
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent(".sonora-import.json"), options: .atomic)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: storage.appendingPathComponent(id, isDirectory: true))
        return record
    }
}
