import CarPlay
import UIKit

@MainActor final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?
    private var connection: Task<Void, Never>?
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        connection?.cancel()
        coordinator?.stop()
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
                let push = { [weak interfaceController] in
                    interfaceController?.pushTemplate(template, animated: true) { success, error in
                        if !success { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo abrir la pantalla.")" }
                    }
                }
                let stack = interfaceController.templates
                if stack.contains(where: { $0 === template }) {
                    interfaceController.pop(to: template, animated: true) { success, error in
                        if !success { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo volver al reproductor.")" }
                    }
                } else if template === CPNowPlayingTemplate.shared, stack.count > 1 {
                    // Now Playing is a global destination. Leave room for Audio
                    // and its settings without exceeding the five-template limit.
                    interfaceController.popToRootTemplate(animated: false) { success, error in
                        if success { push() }
                        else { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo abrir el reproductor.")" }
                    }
                } else if stack.count >= 5 {
                    interfaceController.popTemplate(animated: false) { success, error in
                        if success { push() }
                        else { services.player.issue = "CarPlay: \(error?.localizedDescription ?? "No se pudo abrir la pantalla.")" }
                    }
                } else {
                    push()
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
