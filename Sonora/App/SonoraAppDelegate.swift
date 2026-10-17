import UIKit

@MainActor final class SonoraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == LinkImportController.sessionIdentifier else { completionHandler(); return }
        AppServices.shared.player.linkImports.handleBackgroundEvents(completionHandler)
    }
}
