import Foundation
import SonoraCore

enum FolderScanService {
    private final class Job: @unchecked Sendable { let coordinator = NSFileCoordinator() }
    static func scan(_ folder: ScopedFolder) async throws -> [AudioTrack] {
        try Task.checkCancellation()
        let job = Job(), worker = Task.detached(priority: .userInitiated) {
            try FolderScanner.scan(folder.url, isCancelled: { Task.isCancelled }, readText: { try MusicText.read($0, coordinator: job.coordinator) })
        }
        return try await withTaskCancellationHandler {
            do { let tracks = try await worker.value; try Task.checkCancellation(); return tracks }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: { job.coordinator.cancel(); worker.cancel() }
    }
}
