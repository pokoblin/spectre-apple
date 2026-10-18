#if os(macOS)
import AppKit
import SpectreKit
import SwiftUI

/// What the menu bar's Session menu acts on: the session in the key
/// window (docs/macos-layout.md).
struct SessionActions {
    let model: PlaybackModel
    /// Asks before ending the desktop session, as the toolbar's Log Out… does.
    let logOut: () -> Void
    /// Opens the file picker, as the toolbar's Send Files… does.
    let sendFiles: () -> Void
    /// Opens the folder picker, for a folder to share (§7.12).
    let shareFolder: () -> Void
}

extension FocusedValues {
    @Entry var session: SessionActions?
}

/// The Session menu, after View: dimmed unless a session's window is in
/// front.
///
/// No item has a keyboard shortcut, on purpose (as on the iPad): a menu's
/// shortcut is taken before the remote desktop sees the keys. Capturing
/// the mouse keeps its Ctrl+Cmd+G, which the session's input handles itself.
struct SessionMenu: Commands {
    @FocusedValue(\.session) private var session

    var body: some Commands {
        CommandMenu("Session") {
            let model = session?.model
            Toggle("Capture Mouse", isOn: Binding(get: { model?.input?.isCaptured ?? false },
                                                  set: { model?.input?.setCaptured($0) }))
                .disabled(model?.input == nil)
            Button("Send Clipboard to Host", action: sendClipboard)
                .disabled(model?.clipboard == nil)
            Toggle("Lossless Refinement", isOn: Binding(get: { model?.isRefinementOn ?? false },
                                                        set: { model?.isRefinementOn = $0 }))
                .disabled(model?.hasRefinement != true)
            if PlaybackModel.canDecodePyroWave {
                Toggle("PyroWave on Wired Networks", isOn: Binding(get: { model?.isPyroWaveOn ?? false },
                                                                   set: { model?.isPyroWaveOn = $0 }))
                    .disabled(model?.isRemoteSession != true)
            }
            Button("Send Files…") { session?.sendFiles() }
                .disabled(model?.files.isAvailable != true)
            Button("Download Copied Files") { model?.downloadCopiedFiles() }
                .disabled(model?.copiedFiles?.downloadable.isEmpty ?? true)
            Button("Share Folder…") { session?.shareFolder() }
                .disabled(model?.sharedFolders.isAvailable != true)
            Menu("Stop Sharing") {
                if let shared = model?.sharedFolders {
                    ForEach(shared.folders) { folder in
                        Button { shared.stop(folder.id) } label: { Text(verbatim: folder.name) }
                    }
                }
            }
            .disabled(model?.sharedFolders.folders.isEmpty ?? true)
            Menu("Send Keys") {
                if let typer = model?.input?.typer {
                    ForEach(KeyCombo.menu) { group in
                        if let submenu = group.submenu {
                            Menu(submenu) { keys(group.combos, typer) }
                        } else {
                            Section { keys(group.combos, typer) }
                        }
                    }
                }
            }
            .disabled(model?.input == nil)
            Divider()
            Button("Disconnect") { model?.disconnect() }
                .disabled(model?.isRemoteSession != true)
            Button("Log Out…") { session?.logOut() }
                .disabled(model?.isRemoteSession != true)
        }
    }

    private func keys(_ combos: [KeyCombo], _ typer: TextTyper) -> some View {
        ForEach(combos) { combo in
            Button { typer.press(combo) } label: {
                // The key caps, then what they do: menu items have one line.
                if let purpose = combo.purpose {
                    Text(verbatim: "\(combo.title) — \(purpose)")
                } else {
                    Text(verbatim: combo.title)
                }
            }
        }
    }

    /// The Mac's clipboard to the host's: shared, or put there for pasting
    /// when sharing is off.
    private func sendClipboard() {
        guard let clipboard = session?.model.clipboard,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        if clipboard.isEnabled {
            clipboard.send(text)
        } else {
            _ = clipboard.sendForPaste(text)
        }
    }
}
#endif
