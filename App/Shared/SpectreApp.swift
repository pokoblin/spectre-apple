import SwiftUI

#if os(macOS)
@main
struct SpectreApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
    }
}
#endif
// iOS and iPadOS start in App/iOS/AppDelegate.swift: a UIKit entry point,
// so that the root view controller can lock the pointer.
