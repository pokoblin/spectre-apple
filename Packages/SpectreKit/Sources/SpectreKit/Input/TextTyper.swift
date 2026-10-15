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
    @ObservationIgnored private var held: (usage: UInt32, modifiers: [UInt32])?

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

    /// A key that isn't a character (Backspace, Esc, F5), with whatever
    /// modifiers are latched: pressed and released.
    public func press(_ usage: UInt32) { press(usage, shift: false) }

    /// The same, held until ``endHold()`` (a finger on an on-screen key),
    /// so the host repeats it as it would a physical key.
    public func beginHold(_ usage: UInt32) {
        endHold()
        let modifiers = latchedUsages()
        for m in modifiers { sender.key(m, pressed: true) }
        sender.key(usage, pressed: true)
        held = (usage, modifiers)
    }

    public func endHold() {
        guard let (usage, modifiers) = held else { return }
        held = nil
        sender.key(usage, pressed: false)
        for m in modifiers.reversed() { sender.key(m, pressed: false) }
        clearOnceLatches()
    }

    /// Drops every latch, locked ones included, and lets go of a held key
    /// (the keyboard went away).
    public func clearLatches() {
        endHold()
        latches = [:]
    }

    private func press(_ usage: UInt32, shift: Bool) {
        endHold()
        var modifiers = latchedUsages()
        if shift, !modifiers.contains(HIDUsage.leftShift) { modifiers.append(HIDUsage.leftShift) }
        for m in modifiers { sender.key(m, pressed: true) }
        sender.key(usage, pressed: true)
        sender.key(usage, pressed: false)
        for m in modifiers.reversed() { sender.key(m, pressed: false) }
        clearOnceLatches()
    }

    private func latchedUsages() -> [UInt32] { Modifier.allCases.filter { latch($0) != .off }.map(\.usage) }

    private func clearOnceLatches() {
        for (modifier, latch) in latches where latch == .once { latches[modifier] = .off }
    }
}
