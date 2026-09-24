import CarPlay
import UIKit

/// The CarPlay scene (declared under `CPTemplateApplicationSceneSessionRoleApplication`
/// in Info.plist). iOS creates it when the iPhone connects to a car, whether or
/// not the app's own window is open; everything it shows comes from
/// `CarPlayController`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        let controller = CarPlayController(interfaceController: interfaceController, services: .shared)
        self.controller = controller
        controller.start()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller?.stop()
        controller = nil
    }
}
