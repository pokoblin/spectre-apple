import SwiftUI

#if os(macOS)
/// The Mac: the home screen in a window of its own, and a window for each
/// session (docs/macos-layout.md).
@main
struct SpectreApp: App {
    static let homeWindow = "home"
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(AppDelegate.hidesToolbarKey) private var hidesToolbarInFullScreen = true
    @State private var app = AppModel()
    @State private var language = AppLanguage()

    var body: some Scene {
        // Each window shows the language chosen in Settings, at once.
        Window(Text(verbatim: "Spectre"), id: Self.homeWindow) {
            HomeView(app: app)
                .environment(\.locale, language.locale)
        }
        .defaultSize(width: 960, height: 640)

        WindowGroup(for: UUID.self) { $id in
            SessionWindow(app: app, id: id)
                .windowToolbarFullScreenVisibility(hidesToolbarInFullScreen ? .onHover : .visible)
                .onChange(of: hidesToolbarInFullScreen) { AppDelegate.reenterFullScreen() }
                .environment(\.locale, language.locale)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Hide Toolbar in Full Screen", isOn: $hidesToolbarInFullScreen)
            }
            AppCommands()
            SessionMenu()
        }
        .environment(\.locale, language.locale)

        Settings {
            SettingsView(app: app, language: language)
                .environment(\.locale, language.locale)
        }
        // Its Settings… item is AppCommands' own.
        .commandsRemoved()
    }
}

/// The app menu's own items.
struct AppCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.session) private var session

    var body: some Commands {
        // The system's About panel, with the thanks to ghost as its credits.
        CommandGroup(replacing: .appInfo) {
            Button("About Spectre") { Credits.showAboutPanel() }
        }
        // Settings… as the system makes it, but Cmd+, only outside a
        // session's window: in one, every key is the remote desktop's.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(session == nil ? KeyboardShortcut(",", modifiers: .command) : nil)
        }
    }
}

/// A session's window: titled with its host, closing it disconnects. It
/// closes itself when the session is over (or, restored after a crash,
/// was never there).
struct SessionWindow: View {
    let app: AppModel
    let id: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let id, let session = app.session(id) {
            SessionView(model: session.model)
                .id(id)
                .background(FullScreenOnOpen())
                .navigationTitle(Text(verbatim: session.model.title.isEmpty ? "Spectre" : session.model.title))
                .onAppear {
                    // The home window may be closed: this one can open the next.
                    app.onSessionOpened = { [openWindow] id in openWindow(value: id) }
                    app.onShowHome = { [openWindow] in openWindow(id: SpectreApp.homeWindow) }
                }
                .onDisappear { app.windowClosed(id) }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

/// Puts a new session's window in full screen when Settings says so
/// (`AppDelegate.opensSessionsInFullScreenKey`), once, as it first shows.
/// A window restored in full screen is already there.
private struct FullScreenOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            guard UserDefaults.standard.bool(forKey: AppDelegate.opensSessionsInFullScreenKey) else { return }
            // Not before the window is on screen: toggleFullScreen does nothing then.
            DispatchQueue.main.async {
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
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

    /// A session's window goes to full screen as it opens. Off unless
    /// turned on in Settings.
    static let opensSessionsInFullScreenKey = "opensSessionsInFullScreen"

    /// Closing the last window, the home window or a session's, quits:
    /// a windowless app has nothing to show.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Before the first window shows, so it doesn't change in sight.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Appearance.saved.apply()
    }

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
