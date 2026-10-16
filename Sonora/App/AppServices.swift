import Foundation

/// The phone and CarPlay scenes share one transport, including on a car-only launch.
@MainActor final class AppServices {
    static let shared = AppServices(player: PlaybackController())
    let player: PlaybackController
    private var restoration: Task<Void, Never>?
    init(player: PlaybackController) { self.player = player }
    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { await player.restoreFolder() }
        restoration = task
        await task.value
    }
}
