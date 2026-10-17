import SpectreKit
import UIKit

/// The iPad menu bar's Session menu (docs/ipad-layout.md): the session
/// on screen registers here, the menu's commands act on it through the
/// root view controller, and are dimmed while there is none.
///
/// No item has a keyboard shortcut, on purpose (against the HIG's advice
/// to give menu items one): a menu's shortcut is taken before the remote
/// desktop sees the keys, so Cmd+W would disconnect instead of reaching
/// the host. Every key combination goes to the remote desktop.
@MainActor
final class SessionCommands {
    static let shared = SessionCommands()

    private(set) weak var model: PlaybackModel?
    private(set) weak var keyBar: KeyBarModel?
    private(set) weak var regions: RegionAlertModel?
    /// Opens the session's file picker (Send Files…).
    private var chooseFiles: (() -> Void)?

    func register(_ model: PlaybackModel, keyBar: KeyBarModel, regions: RegionAlertModel,
                  chooseFiles: @escaping () -> Void) {
        self.model = model
        self.keyBar = keyBar
        self.regions = regions
        self.chooseFiles = chooseFiles
        UIMenuSystem.main.setNeedsRevalidate()
    }

    func unregister(_ model: PlaybackModel) {
        guard self.model === model else { return }
        self.model = nil
        keyBar = nil
        regions = nil
        chooseFiles = nil
        UIMenuSystem.main.setNeedsRevalidate()
    }

    static let menuIdentifier = UIMenu.Identifier("org.ghost.spectre.session")

    /// The Session menu, after View.
    static func build(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        func command(_ title: String, _ symbol: String, _ action: Selector) -> UICommand {
            UICommand(title: title, image: UIImage(systemName: symbol), action: action)
        }
        let menu = UIMenu(title: String(localized: "Session"), identifier: menuIdentifier, children: [
            UIMenu(options: .displayInline, children: [
                command(String(localized: "Write and Send to Host"), "square.and.pencil",
                        #selector(RootViewController.sessionWritePrompt(_:))),
                command(String(localized: "Select Region to Watch"), "rectangle.dashed",
                        #selector(RootViewController.sessionSelectRegion(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                command(String(localized: "Fill Screen"), "arrow.up.left.and.arrow.down.right",
                        #selector(RootViewController.sessionToggleFill(_:))),
                command(String(localized: "Hide Key Bar"), "keyboard",
                        #selector(RootViewController.sessionToggleKeyBar(_:))),
                command(String(localized: "Show Keyboard"), "keyboard.chevron.compact.down",
                        #selector(RootViewController.sessionToggleKeyboard(_:))),
                command(String(localized: "Send Clipboard to Host"), "doc.on.clipboard",
                        #selector(RootViewController.sessionSendClipboard(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                command(String(localized: "Send Files…"), "arrow.up.doc",
                        #selector(RootViewController.sessionSendFiles(_:))),
                command(String(localized: "Download Copied Files"), "arrow.down.doc",
                        #selector(RootViewController.sessionDownloadCopiedFiles(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                command(String(localized: "Disconnect"), "xmark.circle",
                        #selector(RootViewController.sessionDisconnect(_:))),
            ]),
        ])
        builder.insertSibling(menu, afterMenu: .view)
        // Standard items whose shortcuts would take keys meant for the host
        // whenever something in the app answers them: Close Window (Cmd+W),
        // New Window (Cmd+N), Settings (Cmd+,: opens the Settings app),
        // Show Sidebar (Ctrl+Cmd+S: the home screen's, under the session),
        // Format (Cmd+B, Cmd+I, Cmd+U, Cmd+{), Find (Cmd+E), Help (Cmd+?).
        // Edit stays: the prompt panel's text field copies and pastes with it,
        // and nothing answers it while the remote desktop has the keyboard
        // (Cmd+C and Cmd+V reach the host as Super+C and Super+V).
        for menu: UIMenu.Identifier in [.close, .newScene, .preferences, .sidebar, .format, .find, .help] {
            builder.remove(menu: menu)
        }
    }
}

// MARK: - Performing

/// What the root view controller's command methods do (it can't have
/// them in an extension: it inherits from a generic class).
extension SessionCommands {
    func writePrompt() { keyBar?.isPromptOpen = true }
    func selectRegion() { regions?.startSelecting() }
    func toggleFill() { model?.input?.toggleFill() }
    func toggleKeyBar() { keyBar?.isShown.toggle() }
    func toggleKeyboard() { model?.input?.showsTouchKeyboard.toggle() }
    func disconnect() { model?.disconnect() }
    func sendFiles() { chooseFiles?() }
    func downloadCopiedFiles() { model?.downloadCopiedFiles() }

    /// The iPad's clipboard to the host's, as the paste button does: on
    /// with clipboard sharing, or put there for pasting when it is off.
    func sendClipboard() {
        guard let clipboard = model?.clipboard, let text = UIPasteboard.general.string else { return }
        if clipboard.isEnabled {
            clipboard.send(text)
        } else {
            _ = clipboard.sendForPaste(text)
        }
    }

    /// Whether `action` can run now; nil for an action that isn't the Session menu's.
    func canPerform(_ action: Selector) -> Bool? {
        let input = model?.input
        switch action {
        case #selector(RootViewController.sessionWritePrompt(_:)):
            return input != nil && keyBar?.isPromptOpen == false
        case #selector(RootViewController.sessionSelectRegion(_:)):
            return input != nil && keyBar?.isPromptOpen == false && regions?.isSelecting == false
        case #selector(RootViewController.sessionToggleFill(_:)), #selector(RootViewController.sessionToggleKeyboard(_:)):
            return input != nil
        case #selector(RootViewController.sessionToggleKeyBar(_:)):
            return keyBar != nil
        case #selector(RootViewController.sessionSendClipboard(_:)):
            return model?.clipboard != nil
        case #selector(RootViewController.sessionSendFiles(_:)):
            return model?.files.isAvailable == true && keyBar?.isPromptOpen == false
        case #selector(RootViewController.sessionDownloadCopiedFiles(_:)):
            return model?.copiedFiles?.downloadable.isEmpty == false
        case #selector(RootViewController.sessionDisconnect(_:)):
            return model != nil
        default:
            return nil
        }
    }

    /// Titles that say what the command will do now.
    func validate(_ command: UICommand) {
        let input = model?.input
        switch command.action {
        case #selector(RootViewController.sessionToggleFill(_:)):
            command.title = input?.zoom.isZoomed == true ? String(localized: "Fit Screen") : String(localized: "Fill Screen")
        case #selector(RootViewController.sessionToggleKeyBar(_:)):
            command.title = keyBar?.isShown == false ? String(localized: "Show Key Bar") : String(localized: "Hide Key Bar")
        case #selector(RootViewController.sessionToggleKeyboard(_:)):
            command.title = input?.showsTouchKeyboard == true ? String(localized: "Hide Keyboard")
                                                               : String(localized: "Show Keyboard")
        default:
            break
        }
    }
}
