import CarPlay
import UIKit

@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?
    private var connection: Task<Void, Never>?
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        connection?.cancel()
        let services = AppServices.shared
        connection = Task { await services.restore() }
        // Display the cached library immediately. A provider-backed restoration
        // may wait for iCloud and must not hold up CarPlay's initial template.
        let coordinator = CarPlayCoordinator(player: services.player, present: { [weak interfaceController] template in
            guard let interfaceController, interfaceController.topTemplate !== template else { return }
            if template is CPAlertTemplate {
                guard interfaceController.presentedTemplate == nil else { return }
                interfaceController.presentTemplate(template, animated: true) { success, error in
                    if !success { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo mostrar el aviso.")" }
                }
            } else {
                interfaceController.pushTemplate(template, animated: true) { success, error in
                    if !success { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo abrir la pantalla.")" }
                }
            }
        }, dismissAlert: { [weak interfaceController] in interfaceController?.dismissTemplate(animated: true, completion: { _, _ in }) })
        self.coordinator = coordinator
        interfaceController.setRootTemplate(coordinator.rootTemplate, animated: false) { [weak self] success, error in
            guard self?.coordinator === coordinator else { return }
            if success { coordinator.start() }
            else { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo conectar la pantalla.")" }
        }
    }
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        connection?.cancel(); connection = nil; coordinator?.stop(); coordinator = nil
        AppServices.shared.player.save()
    }
}
