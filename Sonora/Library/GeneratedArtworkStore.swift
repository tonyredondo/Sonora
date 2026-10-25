import Foundation
import ImageIO
import Observation
import SonoraCore
import UIKit
import UniformTypeIdentifiers

/// Generated images are kept separately from tag metadata and audio files.
/// Only the selected image is held in memory; queued work finishes into disk.
@MainActor @Observable
final class GeneratedArtworkStore {
    enum Status: Equatable { case preparing, connecting, queued, generating, downloading, paused, ready, waiting, waitingForConnection(String), failed(String) }
    typealias Generator = @MainActor (GeneratedArtworkInput) async throws -> Data
    typealias ClientFactory = @MainActor () throws -> GeneratedArtworkClient
    private struct Binding: Codable, Sendable { let fingerprint: FileFingerprint; let imageKey: String }
    private struct RemoteJob: Codable, Sendable {
        let fingerprint: FileFingerprint
        let endpoint: String
        let input: GeneratedArtworkInput
        let id: String?
    }
    private struct Selection: Equatable { let owner: String; let fingerprint: FileFingerprint }
    private(set) var statuses: [String: Status] = [:]
    private(set) var automaticIssue: String?
    private(set) var thumbnailRevision = 0
    private var selected: Selection?
    private var selectedImage: UIImage?
    @ObservationIgnored var onImageChanged: (() -> Void)?
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let bindings: MusicToolsCache
    @ObservationIgnored private let images: MetadataLookupCache
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private let generate: Generator?
    @ObservationIgnored private let clientFactory: ClientFactory
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let connectionRetryDelay: Duration
    @ObservationIgnored private var active = true
    @ObservationIgnored private var activityRevision = 0
    @ObservationIgnored private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var networkCancellations: [String: () -> Void] = [:]
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fingerprints: [String: FileFingerprint] = [:]
    @ObservationIgnored private var configurations: [String: Int] = [:]
    @ObservationIgnored private var requested: [String: FileFingerprint] = [:]
    @ObservationIgnored private var retryFailedOwners: Set<String> = []
    @ObservationIgnored private var cacheRevision = 0
    @ObservationIgnored private var clearingCache = false
    init(settings: MetadataAssistantSettings = .shared, bindings: MusicToolsCache = .shared,
         images: MetadataLookupCache = .init(directory: URL.applicationSupportDirectory.appendingPathComponent("Sonora/GeneratedArtwork"), maxBytes: 256_000_000, maxEntries: 512),
         requests: CodexRequestPool = .shared, generate: Generator? = nil,
         clientFactory: ClientFactory? = nil, pollInterval: Duration = .seconds(2), connectionRetryDelay: Duration = .seconds(2)) {
        self.settings = settings; self.bindings = bindings; self.images = images; self.requests = requests
        self.generate = generate; self.pollInterval = pollInterval
        self.connectionRetryDelay = max(.milliseconds(10), connectionRetryDelay)
        self.clientFactory = clientFactory ?? { try GeneratedArtworkClient(connection: .init(endpoint: settings.endpoint, token: settings.savedToken())) }
    }
    var pendingCount: Int { pending.count }
    func cacheSize() async throws -> Int { try await images.size() }
    func clearCache() async throws {
        guard !clearingCache else { return }
        clearingCache = true
        defer { clearingCache = false }
        cacheRevision += 1
        thumbnailRevision += 1
        pending.values.forEach { $0.cancel() }
        networkCancellations.values.forEach { $0() }
        pending.removeAll(); networkCancellations.removeAll()
        let waiters = resumeWaiters; resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        selectedImage = nil
        statuses.removeAll(); fingerprints.removeAll(); configurations.removeAll(); requested.removeAll()
        retryFailedOwners.removeAll(); automaticIssue = nil
        onImageChanged?()
        try await images.clear()
    }
    private func checkCacheRevision(_ revision: Int) throws {
        try Task.checkCancellation()
        guard revision == cacheRevision, !clearingCache else { throw CancellationError() }
    }
    var currentStatus: Status? {
        guard let selected else { return nil }
        if selectedImage != nil { return .ready }
        // Observe status even before the first job establishes its fingerprint.
        let status = statuses[selected.owner]
        guard fingerprints[selected.owner] == selected.fingerprint else { return nil }
        return status
    }
    var currentIssue: String? {
        switch currentStatus {
        case .failed(let message), .waitingForConnection(let message): message
        default: nil
        }
    }
    func image(owner: String, fingerprint: FileFingerprint) -> UIImage? {
        selected == Selection(owner: owner, fingerprint: fingerprint) ? selectedImage : nil
    }
    /// Cache-only list artwork never changes the player's selected image or starts a job.
    func cachedThumbnail(owner: String, fingerprint: FileFingerprint) async throws -> UIImage? {
        let revision = cacheRevision
        guard !clearingCache,
              let binding = try await bindings.read(Binding.self, key: bindingKey(owner)), binding.fingerprint == fingerprint,
              let entry = try await images.read(key: binding.imageKey), entry.status == 200 else { return nil }
        try Task.checkCancellation()
        let image = await Task.detached(priority: .utility) { Self.image(entry.data, maxPixelSize: 160) }.value
        let latest = try await bindings.read(Binding.self, key: bindingKey(owner))
        try Task.checkCancellation()
        guard revision == cacheRevision, !clearingCache,
              latest?.imageKey == binding.imageKey, latest?.fingerprint == fingerprint else { return nil }
        return image
    }
    /// An app update relocates the container while retaining its files/inodes.
    /// Keep app-owned paths relative; external file grants retain their own URL.
    static func owner(_ track: AudioTrack, folder: ScopedFolder, appHome: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        let file = track.url(in: folder.url).standardizedFileURL
        let home = appHome.standardizedFileURL.path + "/"
        if file.path.hasPrefix(home) { return "app:" + file.path.dropFirst(home.count) + ":" + track.localID }
        return QueuePreparationStore.Item.id(track, folder: folder)
    }
    private func bindingKey(_ owner: String) -> String { "generated-artwork-binding-v1:" + owner }
    private func jobKey(_ owner: String, endpoint: String) -> String { "generated-artwork-job-v1:" + endpoint + ":" + owner }
    func setActive(_ active: Bool) {
        self.active = active
        if active {
            let waiters = resumeWaiters; resumeWaiters = []
            waiters.forEach { $0.resume() }
        } else {
            activityRevision += 1
            for cancel in networkCancellations.values { cancel() }
        }
    }
    func select(owner: String, fingerprint: FileFingerprint) {
        let selection = Selection(owner: owner, fingerprint: fingerprint)
        guard selected != selection else { return }
        selected = selection; selectedImage = nil
        Task { [weak self] in
            guard let self else { return }
            let restored = (try? await restore(owner: owner, fingerprint: fingerprint)) == true
            if !restored, selected == selection, pending[owner] == nil { statuses[owner] = nil }
        }
    }
    @discardableResult func restore(owner: String, fingerprint: FileFingerprint) async throws -> Bool {
        let revision = cacheRevision
        guard !clearingCache else { return false }
        guard let binding = try await bindings.read(Binding.self, key: bindingKey(owner)), binding.fingerprint == fingerprint,
              let entry = try await images.read(key: binding.imageKey), entry.status == 200,
              let image = Self.image(entry.data) else { return false }
        guard let latest = try await bindings.read(Binding.self, key: bindingKey(owner)), latest.imageKey == binding.imageKey,
              latest.fingerprint == fingerprint else { return false }
        guard revision == cacheRevision, !clearingCache else { return false }
        if selected == Selection(owner: owner, fingerprint: fingerprint) { selectedImage = image; onImageChanged?() }
        statuses[owner] = .ready
        return true
    }
    func retry(failed: Bool = true) {
        if failed {
            automaticIssue = nil
            if generate == nil {
                retryFailedOwners.formUnion(statuses.compactMap { if case .failed = $0.value { $0.key } else { nil } })
            }
        }
        statuses = statuses.filter {
            if pending[$0.key] != nil || $0.value == .ready { return true }
            if !failed, case .failed = $0.value { return true }
            return false
        }
    }
    /// Captured scopes and contexts belong to the job, not the visible song.
    func enqueue(owner: String, fingerprint: FileFingerprint, enabled: Bool,
                 allowed: @escaping @MainActor () -> Bool = { true },
                 prepare: @escaping @MainActor () async throws -> GeneratedArtworkInput?) {
        guard !clearingCache else { return }
        let imageRevision = cacheRevision
        requested[owner] = fingerprint
        let configuration = settings.configurationRevision
        if let task = pending[owner] {
            if fingerprints[owner] != fingerprint || configurations[owner] != configuration {
                Task { [self] in
                    await task.value
                    guard cacheRevision == imageRevision, requested[owner] == fingerprint, settings.configurationRevision == configuration else { return }
                    enqueue(owner: owner, fingerprint: fingerprint, enabled: enabled, allowed: allowed, prepare: prepare)
                }
            }
            return
        }
        guard fingerprints[owner] != fingerprint || configurations[owner] != configuration || statuses[owner] == nil || (statuses[owner] == .waiting && enabled && allowed()) else { return }
        fingerprints[owner] = fingerprint
        configurations[owner] = configuration
        statuses[owner] = .preparing
        pending[owner] = Task { [self] in
            defer { if imageRevision == cacheRevision { pending[owner] = nil } }
            let endpoint = settings.endpoint, revision = settings.configurationRevision
            do {
                if try await restore(owner: owner, fingerprint: fingerprint) { return }
                try checkCacheRevision(imageRevision)
                guard enabled, allowed(), !settings.effectiveOffline, !settings.endpoint.isEmpty, automaticIssue == nil else { statuses[owner] = .waiting; return }
                let saved = generate == nil ? try await bindings.read(RemoteJob.self, key: jobKey(owner, endpoint: endpoint)) : nil
                try checkCacheRevision(imageRevision)
                let remote = saved.flatMap { $0.fingerprint == fingerprint && $0.endpoint == endpoint && $0.input.isValid && ($0.id.map(GeneratedArtworkJob.validID) ?? true) ? $0 : nil }
                let context: GeneratedArtworkInput
                if let remote { context = remote.input }
                else {
                    let prepared = try await prepare()
                    try checkCacheRevision(imageRevision)
                    guard let prepared else { statuses[owner] = .ready; return }
                    context = prepared
                }
                try checkCacheRevision(imageRevision)
                guard context.isValid else { throw MetadataLookupError.invalidSearch }
                let key = context.cacheIdentity
                let data: Data
                if let cached = try await images.read(key: key), cached.status == 200, Self.image(cached.data) != nil { data = cached.data }
                else {
                    guard !settings.effectiveOffline, !settings.endpoint.isEmpty, automaticIssue == nil else { statuses[owner] = .waiting; return }
                    var result: Result<Data, Error>?
                    statuses[owner] = .queued
                    await requests.perform {
                        do {
                            try checkCacheRevision(imageRevision)
                            guard endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
                            guard automaticIssue == nil else { throw MetadataLookupError.notCached }
                            guard allowed() else { throw MetadataLookupError.notCached }
                            let output: Data
                            if let generate {
                                statuses[owner] = .generating
                                output = try await generate(context)
                            } else {
                                output = try await remoteImage(owner: owner, fingerprint: fingerprint, endpoint: endpoint, input: context, saved: remote)
                            }
                            guard endpoint == settings.endpoint, revision == settings.configurationRevision else { throw MetadataLookupError.invalidConnection }
                            let prepared = try await Task.detached(priority: .utility) { try Self.jpeg(output) }.value
                            result = .success(prepared)
                        } catch { result = .failure(error) }
                    }
                    try checkCacheRevision(imageRevision)
                    guard let result else { throw MetadataLookupError.invalidResponse }
                    data = try result.get()
                    try await images.storeUnlessCancelled(data, key: key, status: 200)
                }
                try checkCacheRevision(imageRevision)
                try await bindings.write(Binding(fingerprint: fingerprint, imageKey: key), key: bindingKey(owner))
                guard try await restore(owner: owner, fingerprint: fingerprint) else { throw GeneratedArtworkIssue.invalidImage }
                try checkCacheRevision(imageRevision)
                thumbnailRevision += 1
                if generate == nil { try await bindings.remove(key: jobKey(owner, endpoint: endpoint)) }
            } catch {
                guard imageRevision == cacheRevision else { return }
                if case MetadataLookupError.notCached = error { statuses[owner] = .waiting }
                else if error is URLError || error is MetadataTransportFailure {
                    statuses[owner] = .waitingForConnection(error.localizedDescription)
                }
                else {
                    statuses[owner] = .failed(error.localizedDescription)
                    if endpoint == settings.endpoint, revision == settings.configurationRevision,
                       Self.blocksAutomaticQueue(error) {
                        automaticIssue = error.localizedDescription
                    }
                }
            }
        }
    }
    /// A saved reference is consulted before rebuilding mutable album/tag context.
    /// Repeating POST after a lost acknowledgement is safe: the server deduplicates it.
    private func remoteImage(owner: String, fingerprint: FileFingerprint, endpoint: String,
                             input: GeneratedArtworkInput, saved: RemoteJob?) async throws -> Data {
        let client = try clientFactory()
        statuses[owner] = .connecting
        var snapshot: GeneratedArtworkJob
        let retryFailure = retryFailedOwners.remove(owner) != nil
        if let id = saved?.id, !retryFailure {
            do { snapshot = try await network(owner: owner, endpoint: endpoint) { try await client.job(id, offline: false) } }
            catch MetadataLookupError.notFound {
                snapshot = try await network(owner: owner, endpoint: endpoint) { try await client.submit(input, offline: false) }
            }
        } else {
            // Persist the original input before sending: losing the POST acknowledgement
            // must not rebuild a different request from later album/tag results.
            try await bindings.write(RemoteJob(fingerprint: fingerprint, endpoint: endpoint, input: input, id: nil), key: jobKey(owner, endpoint: endpoint))
            snapshot = try await network(owner: owner, endpoint: endpoint) { try await client.submit(input, retryFailed: retryFailure, offline: false) }
        }
        try Task.checkCancellation()
        try await bindings.write(RemoteJob(fingerprint: fingerprint, endpoint: endpoint, input: input, id: snapshot.id), key: jobKey(owner, endpoint: endpoint))
        while true {
            try Task.checkCancellation()
            switch snapshot.state {
            case .failed:
                throw GeneratedArtworkIssue.service(snapshot.error ?? "unavailable")
            case .completed:
                statuses[owner] = .downloading
                let id = snapshot.id
                do { return try await network(owner: owner, endpoint: endpoint) { try await client.image(id, offline: false) } }
                catch MetadataLookupError.notFound {
                    try await bindings.remove(key: jobKey(owner, endpoint: endpoint))
                    throw GeneratedArtworkIssue.service("codex_result_expired")
                }
            case .queued: statuses[owner] = .queued
            case .running: statuses[owner] = .generating
            }
            try await Task.sleep(for: pollInterval)
            let id = snapshot.id
            snapshot = try await network(owner: owner, endpoint: endpoint) { try await client.job(id, offline: false) }
        }
    }
    private func network<Value: Sendable>(owner: String, endpoint: String,
                                          operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let imageRevision = cacheRevision
        var failures = 0
        while true {
            try Task.checkCancellation()
            while !active {
                statuses[owner] = .paused
                await withCheckedContinuation { resumeWaiters.append($0) }
                try Task.checkCancellation()
                statuses[owner] = .connecting
            }
            try Task.checkCancellation()
            guard endpoint == settings.endpoint, configurations[owner] == settings.configurationRevision else { throw MetadataLookupError.invalidConnection }
            guard !settings.effectiveOffline else { throw MetadataLookupError.notCached }
            let request = Task { try await operation() }
            let revision = activityRevision
            networkCancellations[owner] = { request.cancel() }
            do {
                let value = try await withTaskCancellationHandler {
                    try await request.value
                } onCancel: { request.cancel() }
                if imageRevision == cacheRevision { networkCancellations[owner] = nil }
                try Task.checkCancellation()
                return value
            } catch {
                if imageRevision == cacheRevision { networkCancellations[owner] = nil }
                if !Task.isCancelled, revision != activityRevision,
                   error is CancellationError || (error as? URLError)?.code == .cancelled { continue }
                try checkCacheRevision(imageRevision)
                guard Self.retryableConnection(error) else { throw error }
                statuses[owner] = .waitingForConnection(error.localizedDescription)
                let delay = min(.seconds(60), connectionRetryDelay * (1 << failures))
                failures = min(failures + 1, 5)
                try await Task.sleep(for: delay)
            }
        }
    }
    private static func retryableConnection(_ error: Error) -> Bool {
        let code = (error as? URLError)?.code.rawValue ?? (error as? MetadataTransportFailure)?.code
        if let code {
            return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff, .callIsActive,
                    .dataNotAllowed, .resourceUnavailable].contains { $0.rawValue == code }
        }
        if case GeneratedArtworkIssue.service(let code) = error {
            // Retrying HTTP admission/download is idempotent. Terminal generation
            // failures arrive as a job snapshot and are retried by the server.
            return ["codex_busy", "codex_timeout", "codex_unavailable", "codex_cache_unavailable", "unavailable"].contains(code)
        }
        return false
    }
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if case GeneratedArtworkIssue.serverUpdateRequired = error { return true }
        if case GeneratedArtworkIssue.service("codex_disabled") = error { return true }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }
    private nonisolated static func image(_ data: Data, maxPixelSize: Int = 1200) -> UIImage? {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, width == height, width <= 2048,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    private nonisolated static func jpeg(_ data: Data) throws -> Data {
        guard GeneratedArtworkClient.isPNG(data), let image = image(data)?.cgImage else { throw GeneratedArtworkIssue.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw GeneratedArtworkIssue.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GeneratedArtworkIssue.invalidImage }
        return output as Data
    }
}
