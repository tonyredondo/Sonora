import Foundation

/// The phone and CarPlay scenes share one transport, including on a car-only launch.
@MainActor final class AppServices {
    static let shared = AppServices(player: PlaybackController(metadataArchive:.shared))
    let player: PlaybackController
    private var restoration: Task<Void, Never>?
    init(player: PlaybackController) { self.player = player }
    func restore() async {
        MetadataAssistantSettings.shared.start()
        player.metadataArchive?.start()
        if let restoration { await restoration.value; return }
        let task = Task {
            await player.restoreFolder()
            await player.linkImports.restore()
        }
        restoration = task
        await task.value
    }
}
