import SwiftUI

#if os(macOS)
@main
struct SpectreApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(AppDelegate.hidesToolbarKey) private var hidesToolbarInFullScreen = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .windowToolbarFullScreenVisibility(hidesToolbarInFullScreen ? .onHover : .visible)
                .onChange(of: hidesToolbarInFullScreen) { AppDelegate.reenterFullScreen() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Hide Toolbar in Full Screen", isOn: $hidesToolbarInFullScreen)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// In full screen the toolbar (and the menu bar) slide away and the
    /// remote desktop fills the screen; pushing the pointer against the top
    /// edge brings them back over the picture. On unless turned off in the
    /// View menu.
    static let hidesToolbarKey = "hidesToolbarInFullScreen"

    /// One window is the whole app: closing it quits, which also closes the
    /// session properly (PlaybackModel, on willTerminate) instead of leaving
    /// a windowless app holding it open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A window restored in full screen (after a crash, or by "reopen
        // windows" at login) got there before SwiftUI applied the setting,
        // so its toolbar stays.
        if UserDefaults.standard.object(forKey: Self.hidesToolbarKey) as? Bool ?? true {
            Self.reenterFullScreen()
        }
    }

    /// SwiftUI reads windowToolbarFullScreenVisibility only as the window
    /// enters full screen, and AppKit ignores autoHideToolbar in the app's
    /// presentation options there (the window's delegate, SwiftUI's, decides
    /// them). So a window already in full screen leaves it and comes back.
    @MainActor static func reenterFullScreen() {
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) }) else { return }
        Task {
            let exited = NotificationCenter.default.notifications(named: NSWindow.didExitFullScreenNotification,
                                                                  object: window)
            window.toggleFullScreen(nil)
            for await _ in exited { break }
            window.toggleFullScreen(nil)
        }
    }
}
#endif
// iOS and iPadOS start in App/iOS/AppDelegate.swift: a UIKit entry point,
// so that the root view controller can lock the pointer.
