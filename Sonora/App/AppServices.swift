import Foundation

/// The phone and CarPlay scenes share one transport, including on a car-only launch.
@MainActor final class AppServices {
    static let shared = AppServices(player: PlaybackController(metadataArchive:.shared))
    let player: PlaybackController
    private var restoration: Task<Void, Never>?
    private var receivedAudioFile = false
    init(player: PlaybackController) { self.player = player }
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
