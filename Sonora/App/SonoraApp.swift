import SwiftUI

@main
struct SonoraApp: App {
    @UIApplicationDelegateAdaptor(SonoraAppDelegate.self) private var appDelegate
    @State private var player = AppServices.shared.player
    @AppStorage("appearance") private var appearance: AppAppearance = .noche
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LibraryView(player: player)
                .preferredColorScheme(appearance.colorScheme)
                .task { await AppServices.shared.restore() }
                .onChange(of: phase) {
                    if phase == .active { Task { await player.linkImports.restore() } }
                    else { player.save() }
                }
        }
    }
}
