import SpectreKit
import SwiftUI
import UIKit

/// The iOS and iPadOS entry point. UIKit rather than a SwiftUI `App`: the
/// system asks only the window's root view controller whether to lock the
/// pointer (`prefersPointerLocked`), and a SwiftUI `WindowGroup`'s root is
/// a hosting controller the app can't subclass. The UI itself is the same
/// ContentView as on the Mac.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = RootViewController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Hosts the SwiftUI interface and locks the pointer while a session has
/// captured the mouse (``PointerLockHost``).
final class RootViewController: UIHostingController<ContentView>, PointerLockHost {
    var wantsPointerLock = false {
        didSet { if wantsPointerLock != oldValue { setNeedsUpdateOfPrefersPointerLocked() } }
    }

    override var prefersPointerLocked: Bool { wantsPointerLock }
    override var childViewControllerForPointerLock: UIViewController? { nil }
}
