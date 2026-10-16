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
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        SessionCommands.build(builder)
    }

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
        let window = SessionWindow(windowScene: scene)
        window.rootViewController = RootViewController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// Sends trackpad and mouse clicks nowhere while the pointer is locked
/// (the mouse captured). A locked pointer stays where it was, often on the
/// Capture Mouse button that locked it, and its clicks would still land
/// there: toggling the capture off and on, and whether GCMouse's report of
/// the same click reached the host first was down to the order the two
/// came in. Captured, GCMouse gives the buttons and the session view
/// ignores these touches anyway.
///
/// Routed by hit-testing rather than dropped from `sendEvent`, so UIKit
/// still sees every touch from start to end: a click begun before the
/// lock (the one on Capture Mouse) keeps its view, one begun during it
/// stays with the window after the release. Fingers always hit-test as
/// usual.
final class SessionWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event, event.type == .touches, windowScene?.pointerLockState?.isLocked == true,
           Self.isPointerClick(event) {
            return self
        }
        return super.hitTest(point, with: event)
    }

    /// A finger coming down hit-tests normally, even while a click is held.
    /// The click's own touch isn't in `allTouches` yet when it is hit-tested
    /// (only its buttons are in the mask), so this looks at both.
    private static func isPointerClick(_ event: UIEvent) -> Bool {
        let beginning = event.allTouches?.filter { $0.phase == .began } ?? []
        if beginning.contains(where: { $0.type != .indirectPointer }) { return false }
        return !beginning.isEmpty || !event.buttonMask.isEmpty
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

    // The menu bar's Session menu (SessionCommands).
    @objc func sessionWritePrompt(_ sender: Any?) { SessionCommands.shared.writePrompt() }
    @objc func sessionToggleFill(_ sender: Any?) { SessionCommands.shared.toggleFill() }
    @objc func sessionToggleKeyBar(_ sender: Any?) { SessionCommands.shared.toggleKeyBar() }
    @objc func sessionToggleKeyboard(_ sender: Any?) { SessionCommands.shared.toggleKeyboard() }
    @objc func sessionSendClipboard(_ sender: Any?) { SessionCommands.shared.sendClipboard() }
    @objc func sessionDisconnect(_ sender: Any?) { SessionCommands.shared.disconnect() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        SessionCommands.shared.canPerform(action) ?? super.canPerformAction(action, withSender: sender)
    }

    override func validate(_ command: UICommand) {
        super.validate(command)
        SessionCommands.shared.validate(command)
    }
}
