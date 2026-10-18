import Foundation
import SonoraCore

struct ImportedMusicRecord: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let files: Int
    let importedAt: Date
    var linkID: String? = nil
}
struct LocalMusicImportProgress: Sendable {
    let filename: String
    let completed: Int
    let total: Int
    let bytes: Int64
}

enum LocalMusicImport {
    static func downloaded(_ payload: URL, filename: String, name: String, linkID: String,
                           importID: UUID = UUID(), storage: URL = defaultStorage,
                           progress: @escaping @Sendable (LocalMusicImportProgress) -> Void = { _ in }) async throws -> ImportedMusicRecord {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if let existing = try records(in: storage).first(where: { $0.linkID == linkID }) { return existing }
            guard !linkID.isEmpty, linkID.utf8.count <= 256, !name.isEmpty, name.utf8.count <= 4096,
                  AudioTrack(relativePath: filename) != nil, !filename.contains("/"), !filename.contains("\\") else { throw MusicArchiveError.unsafePath }
            let files = FileManager.default, id = importID.uuidString
            let staging = linkStaging(importID)
            // This exact UUID belongs to the pending link import. A killed
            // extraction restarts from its retained payload, never partial files.
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: staging) }
            let music = staging.appendingPathComponent("Music", isDirectory: true)
            let input = try FileHandle(forReadingFrom: payload)
            let signature = try input.read(upToCount: 4); try input.close()
            let isZIP = filename.lowercased().hasSuffix(".zip") || signature?.prefix(2) == Data([0x50, 0x4b])
            let count: Int, bytes: Int64
            if isZIP {
                let budget = availableBytes(at: storage).map { max(0, $0 - 64 * 1024 * 1024) } ?? 32 * 1024 * 1024 * 1024
                let extracted = try MusicArchive.extract(payload, to: music, maxBytes: budget, isCancelled: { Task.isCancelled }) { value in
                    progress(.init(filename: "Descomprimiendo…", completed: 0, total: 0, bytes: value.bytes))
                }
                count = extracted.files; bytes = extracted.bytes
            } else {
                guard FolderScanner.defaultExtensions.contains((filename as NSString).pathExtension.lowercased()) else { throw MusicTextError.invalid("La descarga no contiene audio ni un archivo ZIP compatible.") }
                try files.createDirectory(at: music, withIntermediateDirectories: true)
                try files.copyItem(at: payload, to: music.appendingPathComponent(filename))
                count = 1; bytes = Int64(try payload.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            try Task.checkCancellation()
            guard !(try FolderScanner.scan(music, isCancelled: { Task.isCancelled })).isEmpty else { throw MusicTextError.invalid("La descarga no contiene audio compatible.") }
            progress(.init(filename: name, completed: count, total: count, bytes: bytes))
            let record = ImportedMusicRecord(id: id, name: name, bytes: bytes, files: count, importedAt: Date(), linkID: linkID)
            return try publish(record, staging: staging, storage: storage)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    static func linkStaging(_ id: UUID) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("SonoraLinkImport-" + id.uuidString, isDirectory: true) }
    static func availableBytes(at storage: URL = defaultStorage) -> Int64? {
        var existing = storage
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        if let value = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return value }
        return (try? FileManager.default.attributesOfFileSystem(forPath: existing.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }
    static func checkDownloadSpace(_ bytes: Int64) throws {
        let (twice, overflow) = bytes.multipliedReportingOverflow(by: 2)
        guard bytes >= 0, !overflow, twice <= Int64.max - 64 * 1024 * 1024 else { throw MusicArchiveError.expandedLimit }
        if let available = availableBytes(), available < twice + 64 * 1024 * 1024 {
            throw MusicTextError.invalid("No hay espacio suficiente para descargar y descomprimir esta transferencia. Necesitas aproximadamente \(ByteCountFormatter.string(fromByteCount: twice + 64 * 1024 * 1024, countStyle: .file)) libres.")
        }
    }
    fileprivate static func publish(_ record: ImportedMusicRecord, staging: URL, storage: URL) throws -> ImportedMusicRecord {
        try JSONEncoder().encode(record).write(to: staging.appendingPathComponent(".sonora-import.json"), options: .atomic)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: storage.appendingPathComponent(record.id, isDirectory: true))
        return record
    }
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
            guard record.id == folder.lastPathComponent, record.files >= 0, record.bytes >= 0, record.name.utf8.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            return record
        }.sorted { $0.importedAt > $1.importedAt }
    }
    static func remove(_ record: ImportedMusicRecord, storage: URL = defaultStorage) throws {
        guard UUID(uuidString: record.id) != nil, try records(in: storage).contains(record) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: storage.appendingPathComponent(record.id))
    }
    static func refresh(_ record: ImportedMusicRecord, storage: URL = defaultStorage) throws {
        guard try records(in: storage).contains(record) else { throw CocoaError(.fileWriteNoPermission) }
        let root = musicURL(record, storage: storage)
        let info = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        var enumerationError: Error?
        guard info.isDirectory == true, info.isSymbolicLink != true,
              let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadNoPermission) }
        var count = 0, bytes: Int64 = 0, hasAudio = false
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            count += 1; bytes += Int64(values.fileSize ?? 0)
            hasAudio = hasAudio || FolderScanner.defaultExtensions.contains(url.pathExtension.lowercased())
        }
        if let enumerationError { throw enumerationError }
        // Keep an empty copy visible so it can be removed, but let its link be
        // imported again after the user deletes the last audio file.
        let updated = ImportedMusicRecord(id: record.id, name: record.name, bytes: bytes, files: count, importedAt: record.importedAt,
                                          linkID: hasAudio ? record.linkID : nil)
        try JSONEncoder().encode(updated).write(to: root.deletingLastPathComponent().appendingPathComponent(".sonora-import.json"), options: .atomic)
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
        return try LocalMusicImport.publish(record, staging: staging, storage: storage)
    }
}
