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
    enum Status: Equatable { case preparing, ready, waiting, failed(String) }
    typealias Generator = @MainActor (GeneratedArtworkInput) async throws -> Data
    private struct Binding: Codable, Sendable { let fingerprint: FileFingerprint; let imageKey: String }
    private struct Selection: Equatable { let owner: String; let fingerprint: FileFingerprint }
    private(set) var statuses: [String: Status] = [:]
    private(set) var automaticIssue: String?
    private var selected: Selection?
    private var selectedImage: UIImage?
    @ObservationIgnored var onImageChanged: (() -> Void)?
    @ObservationIgnored private let settings: MetadataAssistantSettings
    @ObservationIgnored private let bindings: MusicToolsCache
    @ObservationIgnored private let images: MetadataLookupCache
    @ObservationIgnored private let requests: CodexRequestPool
    @ObservationIgnored private let generate: Generator
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fingerprints: [String: FileFingerprint] = [:]
    @ObservationIgnored private var requested: [String: FileFingerprint] = [:]
    init(settings: MetadataAssistantSettings = .shared, bindings: MusicToolsCache = .shared,
         images: MetadataLookupCache = .init(directory: URL.applicationSupportDirectory.appendingPathComponent("Sonora/GeneratedArtwork"), maxBytes: 256_000_000, maxEntries: 512),
         requests: CodexRequestPool = .shared, generate: Generator? = nil) {
        self.settings = settings; self.bindings = bindings; self.images = images; self.requests = requests
        self.generate = generate ?? { input in
            try await GeneratedArtworkClient(connection: .init(endpoint: settings.endpoint, token: settings.savedToken()))
                .generate(input, offline: settings.effectiveOffline)
        }
    }
    var pendingCount: Int { pending.count }
    var currentIssue: String? {
        guard let selected, case .failed(let message) = statuses[selected.owner] else { return nil }
        return message
    }
    func image(owner: String, fingerprint: FileFingerprint) -> UIImage? {
        selected == Selection(owner: owner, fingerprint: fingerprint) ? selectedImage : nil
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
        guard let binding = try await bindings.read(Binding.self, key: bindingKey(owner)), binding.fingerprint == fingerprint,
              let entry = try await images.read(key: binding.imageKey), entry.status == 200,
              let image = Self.image(entry.data) else { return false }
        guard let latest = try await bindings.read(Binding.self, key: bindingKey(owner)), latest.imageKey == binding.imageKey,
              latest.fingerprint == fingerprint else { return false }
        if selected == Selection(owner: owner, fingerprint: fingerprint) { selectedImage = image; onImageChanged?() }
        statuses[owner] = .ready
        return true
    }
    func retry() { automaticIssue = nil; statuses = statuses.filter { $0.value == .preparing || $0.value == .ready } }
    /// Captured scopes and contexts belong to the job, not the visible song.
    func enqueue(owner: String, fingerprint: FileFingerprint, enabled: Bool,
                 allowed: @escaping @MainActor () -> Bool = { true },
                 prepare: @escaping @MainActor () async throws -> GeneratedArtworkInput?) {
        requested[owner] = fingerprint
        if let task = pending[owner] {
            if fingerprints[owner] != fingerprint {
                Task { [self] in
                    await task.value
                    guard requested[owner] == fingerprint else { return }
                    enqueue(owner: owner, fingerprint: fingerprint, enabled: enabled, allowed: allowed, prepare: prepare)
                }
            }
            return
        }
        guard fingerprints[owner] != fingerprint || statuses[owner] == nil || (statuses[owner] == .waiting && enabled && allowed()) else { return }
        fingerprints[owner] = fingerprint
        statuses[owner] = .preparing
        pending[owner] = Task { [self] in
            defer { pending[owner] = nil }
            let endpoint = settings.endpoint, revision = settings.configurationRevision
            do {
                if try await restore(owner: owner, fingerprint: fingerprint) { return }
                guard enabled, allowed(), !settings.effectiveOffline, !settings.endpoint.isEmpty, automaticIssue == nil else { statuses[owner] = .waiting; return }
                guard let context = try await prepare() else { statuses[owner] = .ready; return }
                guard context.isValid else { throw MetadataLookupError.invalidSearch }
                let key = context.cacheIdentity
                let data: Data
                if let cached = try await images.read(key: key), cached.status == 200, Self.image(cached.data) != nil { data = cached.data }
                else {
                    guard !settings.effectiveOffline, !settings.endpoint.isEmpty, automaticIssue == nil else { statuses[owner] = .waiting; return }
                    var result: Result<Data, Error>?
                    await requests.perform {
                        do {
                            guard endpoint == settings.endpoint else { throw MetadataLookupError.invalidConnection }
                            guard automaticIssue == nil else { throw MetadataLookupError.notCached }
                            guard allowed() else { throw MetadataLookupError.notCached }
                            let output = try await generate(context)
                            let prepared = try await Task.detached(priority: .utility) { try Self.jpeg(output) }.value
                            result = .success(prepared)
                        } catch { result = .failure(error) }
                    }
                    guard let result else { throw MetadataLookupError.invalidResponse }
                    data = try result.get()
                    try await images.store(data, key: key, status: 200)
                }
                try await bindings.write(Binding(fingerprint: fingerprint, imageKey: key), key: bindingKey(owner))
                _ = try await restore(owner: owner, fingerprint: fingerprint)
            } catch {
                if case MetadataLookupError.notCached = error { statuses[owner] = .waiting }
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
    private static func blocksAutomaticQueue(_ error: Error) -> Bool {
        if error is GeneratedArtworkIssue || error is URLError || error is MetadataTransportFailure { return true }
        if case MetadataLookupError.unauthorized = error { return true }
        if case MetadataLookupError.invalidConnection = error { return true }
        return false
    }
    private nonisolated static func image(_ data: Data) -> UIImage? {
        guard data.count <= 10_000_000, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, width == height, width <= 2048,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return nil }
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
