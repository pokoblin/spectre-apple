import SwiftUI

@main
struct SpectreApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 760)
        #endif
    }
}
