import SpectreKit
import SwiftUI

/// The Mac's Settings window (Spectre › Settings…): the defaults sessions
/// start with, which their toolbars also change, and the trusted servers
/// (docs/macos-layout.md).
///
/// A change here applies to the open sessions too. One made in a session's
/// toolbar stays with that session and becomes the default shown here: two
/// sessions side by side can each be muted on their own.
struct SettingsView: View {
    let app: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(app: app) }
            Tab("Video", systemImage: "display") { VideoSettings(app: app) }
            Tab("Input", systemImage: "keyboard") { InputSettings(app: app) }
            Tab("Servers", systemImage: "lock.shield") {
                TrustedServersList(app: app).frame(minHeight: 360)
            }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    let app: AppModel
    @AppStorage(AppDelegate.hidesToolbarKey) private var hidesToolbar = true
    @AppStorage(ClipboardSync.enabledKey) private var sharesClipboard = false
    @AppStorage(PlaybackModel.audioMutedKey) private var isAudioMuted = false

    var body: some View {
        Form {
            Section {
                // SpectreApp applies it to a window already in full screen.
                Toggle("Hide Toolbar in Full Screen", isOn: $hidesToolbar)
            }
            Section {
                Toggle("Share the Clipboard", isOn: app.live($sharesClipboard) { $0.setClipboardShared($1) })
            } footer: {
                Text("Share the clipboard with the remote desktop: text copied on either side can be pasted on the other")
            }
            Section {
                Toggle("Mute the Remote Desktop", isOn: app.live($isAudioMuted) { $0.isAudioMuted = $1 })
            } footer: {
                Text("Mute the remote desktop's sound on this device")
            }
            Section {
            } footer: {
                Text("These are the defaults for new sessions. A change here applies to open sessions too.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct VideoSettings: View {
    let app: AppModel
    @AppStorage(PlaybackModel.matchesWindowSizeKey) private var matchesWindowSize = true
    @AppStorage(PlaybackModel.resolutionUnitsKey) private var resolutionUnits = ResolutionFollower.Units.points
    @AppStorage(PlaybackModel.refinementKey) private var isRefinementOn = true
    @AppStorage(PlaybackModel.pyroWaveKey) private var isPyroWaveOn = true

    var body: some View {
        Form {
            Section {
                Toggle("Match Window Size", isOn: app.live($matchesWindowSize) { $0.matchesWindowSize = $1 })
                Toggle("Retina Resolution", isOn: retina)
                    .disabled(!matchesWindowSize)
            } footer: {
                Text("Sharper on Retina screens, at up to four times the work for the host")
            }
            Section {
                Toggle("Lossless Refinement", isOn: app.live($isRefinementOn) { $0.isRefinementOn = $1 })
            } footer: {
                Text("Exact text and lines on a still screen, at more work for the host")
            }
            if PlaybackModel.canDecodePyroWave {
                Section {
                    Toggle("PyroWave on Wired Networks", isOn: app.live($isPyroWaveOn) { $0.isPyroWaveOn = $1 })
                } footer: {
                    Text("Sharper video over a wired network of 1 Gbit/s or more, at hundreds of Mbit/s")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var retina: Binding<Bool> {
        let units = app.live($resolutionUnits) { $0.resolutionUnits = $1 }
        return Binding(get: { units.wrappedValue == .pixels }, set: { units.wrappedValue = $0 ? .pixels : .points })
    }
}

private struct InputSettings: View {
    let app: AppModel
    @AppStorage(GamepadForwarder.enabledKey) private var forwardsGamepads = false

    var body: some View {
        Form {
            Section {
                Toggle("Gamepads", isOn: app.live($forwardsGamepads) { $0.gamepads?.isEnabled = $1 })
            } footer: {
                Text("Forward game controllers to the remote desktop, up to four")
            }
            Section {
                ForEach(LocalShortcut.allCases, id: \.self) { shortcut in
                    LabeledContent {
                        Text(verbatim: shortcut.keys).monospaced().foregroundStyle(.secondary)
                    } label: {
                        Text(shortcut.purpose)
                    }
                }
            } header: {
                Text("Keys Spectre Keeps")
            } footer: {
                Text("Every other key goes to the remote desktop, Cmd as Super.")
            }
        }
        .formStyle(.grouped)
    }
}

private extension LocalShortcut {
    var purpose: LocalizedStringResource {
        switch self {
        case .toggleCapture: "Capture or Release the Mouse"
        case .toggleFullScreen: "Enter or Exit Full Screen"
        case .quit: "Quit Spectre"
        }
    }
}

private extension AppModel {
    /// A setting's switch: shows the saved default; a change saves it and
    /// makes it in every open session.
    func live<Value>(_ stored: Binding<Value>, _ apply: @escaping (PlaybackModel, Value) -> Void) -> Binding<Value> {
        Binding(get: { stored.wrappedValue }, set: { value in
            stored.wrappedValue = value
            self.applyToSessions { apply($0, value) }
        })
    }
}
