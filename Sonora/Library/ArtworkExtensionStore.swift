import CryptoKit
import Foundation
import ImageIO
import Observation
import SonoraCore
import UIKit
import UniformTypeIdentifiers

/// Display-only upper extensions. Original covers, tag metadata and audio are never replaced.
@MainActor @Observable
final class ArtworkExtensionStore {
    typealias Status = GeneratedArtworkStore.Status
    typealias ClientFactory = @MainActor () throws -> GeneratedArtworkClient
    private struct Binding: Codable, Sendable { let fingerprint: FileFingerprint; let key: String }
    private struct Receipt: Codable, Sendable { let id: String? }
    private struct Selection: Equatable { let owner: String; let fingerprint: FileFingerprint }
    private(set) var statuses: [String: Status] = [:]
    private(set) var currentImage: UIImage?
    private var selection: Selection?
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let bindings: MusicToolsCache
    @ObservationIgnored private let images: MetadataLookupCache
    @ObservationIgnored private let inputs: MetadataLookupCache
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private let clientFactory: ClientFactory
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var active = true
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var targets: [String: [String: FileFingerprint]] = [:]
    @ObservationIgnored private var desired: [String: String] = [:]
    @ObservationIgnored private var retryFailures: Set<String> = []
    @ObservationIgnored private var revision = 0

    init(settings: MetadataAssistantSettings = .shared, bindings: MusicToolsCache = .shared,
         images: MetadataLookupCache = .init(directory: URL.applicationSupportDirectory.appendingPathComponent("Sonora/ArtworkExtensions"), maxBytes: 256_000_000, maxEntries: 512),
         inputs: MetadataLookupCache = .init(directory: URL.applicationSupportDirectory.appendingPathComponent("Sonora/ArtworkExtensionInputs"), maxBytes: 64_000_000, maxEntries: 128),
         requests: CodexRequestPool = .shared, clientFactory: ClientFactory? = nil, pollInterval: Duration = .seconds(2)) {
        self.settings = settings; self.bindings = bindings; self.images = images; self.inputs = inputs
        self.requests = requests; self.pollInterval = pollInterval
        self.clientFactory = clientFactory ?? { try GeneratedArtworkClient(connection: .init(endpoint: settings.endpoint, token: settings.savedToken()), kind: .headerExtension) }
    }
    func image(owner: String, fingerprint: FileFingerprint) -> UIImage? {
        selection == Selection(owner: owner, fingerprint: fingerprint) ? currentImage : nil
    }
    var pendingCount: Int { tasks.count }
    var currentStatus: Status? { selection.flatMap { statuses[$0.owner] } }
    var currentIssue: String? {
        switch currentStatus {
        case .failed(let issue), .waitingForConnection(let issue): issue
        default: nil
        }
    }
    func setActive(_ value: Bool) { active = value }
    func stop() { revision += 1; tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    func cacheSize() async throws -> Int { try await images.size() + inputs.size() }
    func clearCache() async throws {
        stop(); currentImage = nil; statuses.removeAll(); desired.removeAll(); targets.removeAll()
        try await images.clear(); try await inputs.clear()
    }
    func retry(failed: Bool) {
        for (owner, status) in statuses {
            if case .failed = status, failed, let key = desired[owner] { retryFailures.insert(key) }
        }
        statuses = statuses.filter { _, value in
            if case .failed = value { return !failed }
            return value == .ready
        }
    }
    func select(owner: String, fingerprint: FileFingerprint) {
        let next = Selection(owner: owner, fingerprint: fingerprint)
        guard selection != next else { return }
        selection = next; currentImage = nil
        let generation = revision
        Task { [weak self] in
            guard let self, let binding = try? await bindings.read(Binding.self, key: bindingKey(owner)),
                  binding.fingerprint == fingerprint, binding.key.hasPrefix("phone-header-v3:"),
                  let entry = try? await images.read(key: binding.key), entry.status == 200 else { return }
            let image = await Task.detached(priority: .utility) { Self.expandedImage(entry.data) }.value
            guard revision == generation, selection == next, desired[owner] == nil || desired[owner] == binding.key else { return }
            currentImage = image
            if image != nil { statuses[owner] = .ready }
        }
    }
    /// Admission finishes normalization and disk staging before retaining queued work. Tasks hold keys, not image bodies.
    func enqueue(owner: String, fingerprint: FileFingerprint, source: Data, enabled: Bool) async {
        let generation = revision
        do {
            let input = try await Task.detached(priority: .utility) { try Self.normalized(source) }.value
            try Task.checkCancellation()
            guard revision == generation else { return }
            let key = Self.key(input)
            if desired[owner] != key, selection?.owner == owner { currentImage = nil }
            desired[owner] = key; targets[key, default: [:]][owner] = fingerprint
            if let entry = try await images.read(key: key), entry.status == 200, await Task.detached(priority: .utility, operation: { Self.expandedImage(entry.data) != nil }).value {
                try await publish(key: key, data: entry.data, generation: generation)
                // Retained receipts also recover an acknowledgement lost after the local save.
                if try await bindings.read(Receipt.self, key: receiptKey(key, settings.endpoint)) == nil { return }
            } else {
                try await inputs.storeUnlessCancelled(input, key: key, status: 200)
            }
            guard enabled else { if statuses[owner] != .ready { statuses[owner] = .waiting }; return }
            guard tasks[key] == nil else { return }
            tasks[key] = Task { [self] in
                await requests.perform { [self] in await process(key, generation: generation) }
                if revision == generation { tasks[key] = nil }
            }
        } catch {
            if revision == generation, !(error is CancellationError) { statuses[owner] = .failed(error.localizedDescription) }
        }
    }
    private func process(_ key: String, generation: Int) async {
        var failures = 0
        while !Task.isCancelled, revision == generation {
            do {
                try await available(key)
                let endpoint = settings.endpoint, configuration = settings.configurationRevision
                let receiptKey = receiptKey(key, endpoint)
                let client = try clientFactory()
                var receipt = try await bindings.read(Receipt.self, key: receiptKey)
                let retry = retryFailures.remove(key) != nil
                if retry { receipt = nil }
                func network<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
                    try await available(key)
                    guard endpoint == settings.endpoint, configuration == settings.configurationRevision else { throw URLError(.networkConnectionLost) }
                    let request = Task { try await operation() }
                    let watcher = Task { [self] in
                        while !Task.isCancelled {
                            if !active || settings.effectiveOffline || endpoint != settings.endpoint || configuration != settings.configurationRevision { request.cancel(); return }
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                    defer { watcher.cancel() }
                    let result = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
                    try Task.checkCancellation()
                    guard endpoint == settings.endpoint, configuration == settings.configurationRevision else { throw URLError(.networkConnectionLost) }
                    return result
                }
                if let saved = try await images.read(key: key), saved.status == 200, let id = receipt?.id {
                    do { try await network { try await client.acknowledge(id, sha256: Self.digest(saved.data), offline: false) } }
                    catch MetadataLookupError.notFound { /* Already stored locally; remote retention has ended. */ }
                    try await bindings.remove(key: receiptKey)
                    return
                }
                var snapshot: GeneratedArtworkJob?
                if let id = receipt?.id {
                    do { snapshot = try await network { try await client.job(id, offline: false) } }
                    catch MetadataLookupError.notFound { receipt = nil }
                }
                if snapshot == nil {
                    guard let input = try await inputs.read(key: key) else { throw MetadataLookupError.cacheUnavailable }
                    try await bindings.write(Receipt(id: nil), key: receiptKey)
                    let submitted = try await network { try await client.submitExtension(input.data, retryFailed: retry, offline: false) }
                    snapshot = submitted
                    try await bindings.write(Receipt(id: submitted.id), key: receiptKey)
                }
                while let job = snapshot {
                    switch job.state {
                    case .failed:
                        status(key, .failed(GeneratedArtworkIssue.service(job.error ?? "unavailable").localizedDescription)); return
                    case .queued, .running:
                        status(key, job.state == .queued ? .queued : .generating)
                        try await Task.sleep(for: pollInterval)
                        snapshot = try await network { try await client.job(job.id, offline: false) }
                    case .completed:
                        status(key, .downloading)
                        let data = try await network { try await client.image(job.id, offline: false) }
                        guard await Task.detached(priority: .utility, operation: { Self.expandedImage(data) != nil }).value else { throw GeneratedArtworkIssue.invalidImage }
                        try await images.storeUnlessCancelled(data, key: key, status: 200)
                        try await publish(key: key, data: data, generation: generation)
                        do { try await network { try await client.acknowledge(job.id, sha256: Self.digest(data), offline: false) } }
                        catch MetadataLookupError.notFound { /* The local copy is already verified. */ }
                        try await bindings.remove(key: receiptKey)
                        return
                    }
                }
            } catch {
                if Task.isCancelled || revision != generation { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { continue }
                guard GeneratedArtworkStore.retryableConnection(error) else { status(key, .failed(error.localizedDescription)); return }
                status(key, .waitingForConnection(error.localizedDescription))
                try? await Task.sleep(for: min(.seconds(60), pollInterval * (1 << min(failures, 5))))
                failures += 1
            }
        }
    }
    private func available(_ key: String) async throws {
        while !active || settings.effectiveOffline || settings.endpoint.isEmpty {
            status(key, active ? .waiting : .paused)
            try await Task.sleep(for: pollInterval)
        }
        try Task.checkCancellation()
    }
    private func publish(key: String, data: Data, generation: Int) async throws {
        let image = await Task.detached(priority: .utility) { Self.expandedImage(data) }.value
        guard let image else { throw GeneratedArtworkIssue.invalidImage }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        for (owner, fingerprint) in targets[key, default: [:]] where desired[owner] == key {
            try await bindings.write(Binding(fingerprint: fingerprint, key: key), key: bindingKey(owner))
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            guard desired[owner] == key else { continue }
            statuses[owner] = .ready
            if selection == Selection(owner: owner, fingerprint: fingerprint) { currentImage = image }
        }
    }
    private func status(_ key: String, _ value: Status) {
        for owner in targets[key, default: [:]].keys where desired[owner] == key { statuses[owner] = value }
    }
    private func bindingKey(_ owner: String) -> String { "phone-header-binding-v3:" + owner }
    private func receiptKey(_ key: String, _ endpoint: String) -> String { "phone-header-job-v3:" + endpoint + ":" + key }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func key(_ data: Data) -> String { "phone-header-v3:" + digest(data) }
    /// Match the square crop shown by the player, normalize EXIF orientation, and bound upload size.
    nonisolated static func normalized(_ data: Data) throws -> Data {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { throw GeneratedArtworkIssue.invalidImage }
        let side = min(cg.width, cg.height)
        guard side > 0, let square = cg.cropping(to: CGRect(x: (cg.width-side)/2, y: (cg.height-side)/2, width: side, height: side)) else { throw GeneratedArtworkIssue.invalidImage }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw GeneratedArtworkIssue.invalidImage }
        CGImageDestinationAddImage(destination, square, nil)
        guard CGImageDestinationFinalize(destination), GeneratedArtworkClient.isPNG(result as Data) else { throw GeneratedArtworkIssue.invalidImage }
        return result as Data
    }
    nonisolated static func expandedImage(_ data: Data) -> UIImage? {
        guard GeneratedArtworkClient.isHeaderPNG(data), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), (cg.width * 3 + 1) / 2 == cg.height else { return nil }
        return UIImage(cgImage: cg)
    }
}
