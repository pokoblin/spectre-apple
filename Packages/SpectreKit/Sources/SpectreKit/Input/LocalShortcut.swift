/// The few key combinations the client keeps for itself; every other key,
/// Cmd combinations included, goes to the remote desktop (Cmd as Super).
///
/// Matched by character, not position, like the system's own shortcuts:
/// on an AZERTY keyboard Cmd+Q is where QWERTY has A.
public enum LocalShortcut: Sendable, Equatable, CaseIterable {
    /// Ctrl+Cmd+G: capture or release the mouse (the upstream macOS
    /// client's binding; Mac keyboards have no Scroll Lock).
    case toggleCapture
    /// Ctrl+Cmd+F: full screen, as the system binds it.
    case toggleFullScreen
    /// Cmd+Q: quit, left to the app menu.
    case quit

    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// `character`: the key's character without modifiers.
    public static func match(character: String, modifiers: Modifiers) -> LocalShortcut? {
        switch (character.lowercased(), modifiers) {
        case ("g", [.control, .command]): .toggleCapture
        case ("f", [.control, .command]): .toggleFullScreen
        case ("q", [.command]): .quit
        default: nil
        }
    }

    /// The keys as the Mac's menus write them, for listing.
    public var keys: String {
        switch self {
        case .toggleCapture: "⌃⌘G"
        case .toggleFullScreen: "⌃⌘F"
        case .quit: "⌘Q"
        }
    }
}
