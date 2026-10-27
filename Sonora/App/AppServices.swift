import Foundation

/// The phone and CarPlay scenes share one transport, including on a car-only launch.
@MainActor final class AppServices {
    static let shared = AppServices(player: PlaybackController(metadataArchive:.shared, generatedArtwork: GeneratedArtworkStore(), artworkExtensions: ArtworkExtensionStore()))
    let player: PlaybackController
    private var restoration: Task<Void, Never>?
    private var receivedAudioFile = false
    init(player: PlaybackController) { self.player = player }
    func lookupCacheSize(settings: MetadataAssistantSettings = .shared) async throws -> Int {
        let queries = try await settings.cache.size()
        let covers = try await player.generatedArtwork?.cacheSize() ?? 0
        let extensions = try await player.artworkExtensions?.cacheSize() ?? 0
        return queries + covers + extensions
    }
    func clearLookupCaches(settings: MetadataAssistantSettings = .shared) async throws {
        try await player.generatedArtwork?.clearCache()
        try await player.artworkExtensions?.clearCache()
        try await settings.cache.clear()
        player.preparationPreferencesDidChange()
    }
    func openAudioFile(_ url: URL) {
        if player.openAudioFile(url) { receivedAudioFile = true }
    }
    func restore() async {
        MetadataAssistantSettings.shared.start()
        player.metadataArchive?.start()
        if let restoration { await restoration.value; return }
        let task = Task {
            if !receivedAudioFile { await player.restoreFolder() }
            await player.linkImports.restore()
        }
        restoration = task
        await task.value
    }
}
