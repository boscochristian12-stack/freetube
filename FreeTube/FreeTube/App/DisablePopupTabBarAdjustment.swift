import SwiftUI
import UIKit
import LNPopupController_ObjC

/// Disables LNPopupController's iOS 27 UITabBar layout adjustment.
///
/// LNPopupController 4.5+ adds an iOS 27-specific integration that modifies
/// the underlying UITabBarController when a popup bar is presented.
/// On iOS 27.2 beta this can hit Apple's internal UITabBar assertion:
///
///     UITabBar _frameForHostedAccessoryView
///     LNPopupMinimizationSupport
///
/// FreeTube uses SwiftUI TabView, so we reach the underlying
/// UITabBarController through this UIKit bridge.
struct DisablePopupTabBarAdjustment: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(
        _ uiViewController: Controller,
        context: Context
    ) {
        uiViewController.disableAdjustment()
    }

    final class Controller: UIViewController {

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            disableAdjustment()
        }

        func disableAdjustment() {
            // SwiftUI may finish constructing the TabView's UIKit hierarchy
            // one run-loop later, so retry asynchronously.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let tabBarController = self.findTabBarController() {
                    tabBarController.adjustsTabBarLayoutForPopupBar = false
                }
            }
        }

        private func findTabBarController() -> UITabBarController? {
            // First walk upward through our normal parent hierarchy.
            var current: UIViewController? = self

            while let controller = current {
                if let tabBarController = controller as? UITabBarController {
                    return tabBarController
                }

                current = controller.parent
            }

            // SwiftUI's internal hierarchy can sometimes place the
            // representable below the expected parent chain. In that case,
            // search from the application's key window.
            guard
                let windowScene = view.window?.windowScene,
                let root = windowScene.windows
                    .first(where: { $0.isKeyWindow })?
                    .rootViewController
            else {
                return nil
            }

            return findTabBarController(in: root)
        }

        private func findTabBarController(
            in controller: UIViewController
        ) -> UITabBarController? {

            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }

            if let presented = controller.presentedViewController,
               let result = findTabBarController(in: presented) {
                return result
            }

            for child in controller.children {
                if let result = findTabBarController(in: child) {
                    return result
                }
            }

            return nil
        }
    }
}
