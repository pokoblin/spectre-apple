import Observation

/// Turns characters into key strokes on the host (gdp-spec.md §8.2) for a
/// keyboard that only gives characters, the touch keyboard on iOS, and
/// holds the modifiers that keyboard lacks (Ctrl, Shift, Alt, Super) as
/// sticky keys: tapped, a modifier applies to the next stroke; locked, to
/// every stroke until it is tapped again.
///
/// Every stroke presses its modifiers, the key, then releases them in
/// reverse, through the session's ``InputSender``, so a key is never left
/// down and `releaseAll` still covers everything.
@MainActor
@Observable
public final class TextTyper {
    public enum Modifier: CaseIterable, Sendable {
        case control, shift, alt, superKey

        var usage: UInt32 {
            switch self {
            case .control: HIDUsage.leftControl
            case .shift: HIDUsage.leftShift
            case .alt: HIDUsage.leftAlt
            case .superKey: HIDUsage.leftGUI
            }
        }
    }

    public enum Latch: Sendable {
        case off
        /// For the next stroke only.
        case once
        /// Until tapped again.
        case locked
    }

    public private(set) var latches: [Modifier: Latch] = [:]
    @ObservationIgnored public var layout: KeyboardLayout
    @ObservationIgnored private let sender: InputSender

    public init(sender: InputSender, layout: KeyboardLayout = .usQWERTY) {
        self.sender = sender
        self.layout = layout
    }

    public func latch(_ modifier: Modifier) -> Latch { latches[modifier] ?? .off }

    /// A tap on a modifier: off → once → off; locked → off.
    public func tap(_ modifier: Modifier) {
        latches[modifier] = latch(modifier) == .off ? .once : .off
    }

    /// A double tap on a modifier: locked (or off again if it was).
    public func lock(_ modifier: Modifier) {
        latches[modifier] = latch(modifier) == .locked ? .off : .locked
    }

    /// Types `text`; returns how many characters the layout has no key for
    /// (they are skipped).
    @discardableResult
    public func type(_ text: String) -> Int {
        var skipped = 0
        for character in text {
            if let stroke = layout.stroke(for: character) {
                press(stroke.usage, shift: stroke.shift)
            } else {
                skipped += 1
            }
        }
        return skipped
    }

    /// A key that isn't a character (Backspace, Esc, an arrow, F5),
    /// with whatever modifiers are latched.
    public func press(_ usage: UInt32) { press(usage, shift: false) }

    /// Drops every latch, locked ones included (the keyboard went away).
    public func clearLatches() { latches = [:] }

    private func press(_ usage: UInt32, shift: Bool) {
        var modifiers = Modifier.allCases.filter { latch($0) != .off }.map(\.usage)
        if shift, !modifiers.contains(HIDUsage.leftShift) { modifiers.append(HIDUsage.leftShift) }
        for m in modifiers { sender.key(m, pressed: true) }
        sender.key(usage, pressed: true)
        sender.key(usage, pressed: false)
        for m in modifiers.reversed() { sender.key(m, pressed: false) }
        for (modifier, latch) in latches where latch == .once { latches[modifier] = .off }
    }
}
