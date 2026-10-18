import Foundation
import SonoraCore

/// Holds folder access and verifies the file before and after a cancellable coordinated read.
enum CoordinatedAudioRead {
    static func read<Value: Sendable>(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint,
                                              operation: @escaping @Sendable (URL, NSFileCoordinator) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let job = CoordinatedReadJob()
        let worker = Task.detached(priority: .userInitiated) { try job.read(track: track, folder: folder, expected: expected, operation: operation) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value; try Task.checkCancellation(); return result
        } onCancel: { job.coordinator.cancel(); job.lyricsCoordinator.cancel(); worker.cancel() }
    }
}

private final class CoordinatedReadJob: @unchecked Sendable {
    let coordinator = NSFileCoordinator()
    let lyricsCoordinator = NSFileCoordinator()
    func read<Value>(track: AudioTrack, folder: ScopedFolder, expected: FileFingerprint, operation: (URL, NSFileCoordinator) throws -> Value) throws -> Value {
        try Task.checkCancellation()
        let url = track.url(in: folder.url)
        let base = folder.url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        var coordinationError: NSError?, result: Result<Value, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { local in
            result = Result {
                try Task.checkCancellation()
                guard try FileFingerprint(local) == expected else { throw MetadataIOError.changed }
                let value = try operation(local, lyricsCoordinator)
                try Task.checkCancellation()
                guard try FileFingerprint(local) == expected else { throw MetadataIOError.changed }
                return value
            }
        }
        try Task.checkCancellation()
        if let coordinationError { throw coordinationError }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}
