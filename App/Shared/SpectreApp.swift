import SwiftUI

#if os(macOS)
@main
struct SpectreApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One window is the whole app: closing it quits, which also closes the
    /// session properly (PlaybackModel, on willTerminate) instead of leaving
    /// a windowless app holding it open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#endif
// iOS and iPadOS start in App/iOS/AppDelegate.swift: a UIKit entry point,
// so that the root view controller can lock the pointer.
