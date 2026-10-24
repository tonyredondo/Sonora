import SwiftUI

@main
struct SonoraApp: App {
    @UIApplicationDelegateAdaptor(SonoraAppDelegate.self) private var appDelegate
    @State private var player = AppServices.shared.player
    @AppStorage("appearance") private var appearance: AppAppearance = .noche
    @AppStorage("lyricTranslationSource") private var translationSource = "auto"
    @AppStorage("lyricTranslationTarget") private var translationTarget = "es"
    @AppStorage("lyricMeaningLanguage") private var meaningLanguage = "es"
    @AppStorage("prepareQueueAudio") private var automaticAudio = true
    @AppStorage("prepareQueueCharacter") private var automaticCharacter = true
    @AppStorage("prepareQueueTranslation") private var automaticTranslation = true
    @AppStorage("prepareQueueMeaning") private var automaticMeaning = true
    @AppStorage("prepareQueueArtwork") private var automaticArtwork = true
    private var metadata: MetadataAssistantSettings { .shared }
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LibraryView(player: player)
                .preferredColorScheme(appearance.colorScheme)
                .task { await AppServices.shared.restore() }
                .onOpenURL { AppServices.shared.openAudioFile($0) }
                .onChange(of: translationSource) { player.translationPreferencesDidChange() }
                .onChange(of: translationTarget) { player.translationPreferencesDidChange() }
                .onChange(of: meaningLanguage) { player.preparationPreferencesDidChange() }
                .onChange(of: automaticAudio) { player.preparationPreferencesDidChange() }
                .onChange(of: automaticCharacter) { player.preparationPreferencesDidChange() }
                .onChange(of: automaticTranslation) { player.preparationPreferencesDidChange() }
                .onChange(of: automaticMeaning) { player.preparationPreferencesDidChange() }
                .onChange(of: automaticArtwork) { player.preparationPreferencesDidChange() }
                .onChange(of: metadata.configurationRevision) { player.retryQueuePreparation() }
                .onChange(of: metadata.effectiveOffline) { if !metadata.effectiveOffline { player.retryQueuePreparation() } }
                .onChange(of: phase) {
                    if phase == .active {
                        player.metadataArchive?.start()
                        player.retryQueuePreparation()
                        Task { await player.linkImports.restore() }
                    }
                    else { player.save(); player.metadataArchive?.pause() }
                }
        }
    }
}
