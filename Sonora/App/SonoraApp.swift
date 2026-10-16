import SwiftUI

@main
struct SonoraApp: App {
    @State private var player = AppServices.shared.player
    @AppStorage("appearance") private var appearance: AppAppearance = .noche
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LibraryView(player: player)
                .preferredColorScheme(appearance.colorScheme)
                .task { await AppServices.shared.restore() }
                .onChange(of: phase) { if phase != .active { player.save() } }
        }
    }
}
