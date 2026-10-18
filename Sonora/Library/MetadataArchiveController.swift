import Foundation
import Observation
import SonoraCore

/// Foreground synchronization of explicit file saves. Audio stays on the device.
@MainActor @Observable final class MetadataArchiveController {
    static let shared = MetadataArchiveController(settings:.shared,
        store:MetadataArchiveStore(directory:MetadataAssistantSettings.supportDirectory.appendingPathComponent("ConfirmedMetadata",isDirectory:true)))
    let settings: MetadataAssistantSettings
    let store: MetadataArchiveStore
    private(set) var pending = 0
    private(set) var otherServersPending = 0
    private(set) var synchronizing = false
    private(set) var issue: String?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var sync: Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retryRequested = false
    @ObservationIgnored private let transport: any MetadataLookupTransport

    init(settings: MetadataAssistantSettings, store: MetadataArchiveStore, transport: any MetadataLookupTransport = MetadataURLSessionTransport(requestTimeout:15,resourceTimeout:20)) {
        self.settings = settings; self.store = store; self.transport = transport
    }
    var destination: URL? { try? MetadataProxyConnection(endpoint:settings.endpoint,token:"").endpoint }
    func client() throws -> MetadataArchiveClient {
        MetadataArchiveClient(connection:try MetadataProxyConnection(endpoint:settings.endpoint,token:settings.savedToken()),transport:transport)
    }
    func start() {
        active = true
        settings.onArchiveConnectionChange = { [weak self] in self?.connectionChanged() }
        retry()
    }
    func pause() {
        active = false; generation = UUID(); sync?.cancel(); sync = nil; synchronizing = false; retryRequested = false
    }
    func reportFailure(_ error: Error) { issue = error.localizedDescription }

    func capture(track: AudioTrack, folder: ScopedFolder, snapshot: MetadataSnapshot, server: URL?) async throws {
        let audioID = try await AudioContentIdentity.read(track:track,folder:folder,expected:snapshot.fingerprint)
        let record = try ConfirmedMetadataRecord(audioID:audioID,values:snapshot.values,artwork:snapshot.artwork)
        try await store.confirm(record,server:server)
        issue = nil
        if let destination {
            let count = try await store.pendingCount(server:destination)
            if destination == self.destination { pending = count }
        }
        retry()
    }
    /// Network failures stop this attempt. Reconnection, foreground activation, a new
    /// confirmed save or the explicit retry button starts another bounded chunk.
    func retry() {
        guard active else { return }
        guard sync == nil else { retryRequested = true; return }
        let token = generation, endpoint = destination
        sync = Task {
            defer {
                if generation == token {
                    sync = nil; synchronizing = false
                    if retryRequested { retryRequested = false; retry() }
                }
            }
            do {
                let total = try await store.pendingCount()
                try Task.checkCancellation()
                guard generation == token else { return }
                guard let endpoint else { pending = 0; otherServersPending = total; return }
                let count = try await store.pendingCount(server:endpoint)
                try Task.checkCancellation()
                guard generation == token else { return }
                pending = count
                otherServersPending = max(0,total - pending)
                guard !settings.effectiveOffline, pending > 0 else { return }
                let client = try client()
                synchronizing = true; issue = nil
                // Chunks bound memory; cancellation stops the next request. The outbox
                // keeps any unacknowledged body, including a response lost in transit.
                repeat {
                    let sent = try await store.synchronize(client:client)
                    try Task.checkCancellation()
                    pending = try await store.pendingCount(server:endpoint)
                    if sent == 0 { break }
                    await Task.yield()
                } while pending > 0 && !settings.effectiveOffline
            } catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { if generation == token { issue = error.localizedDescription } }
        }
    }
    private func connectionChanged() {
        generation = UUID(); sync?.cancel(); sync = nil; synchronizing = false; retryRequested = false
        retry()
    }
}
