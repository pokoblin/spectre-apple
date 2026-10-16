import Observation

/// Turns characters into key strokes on the host (gdp-spec.md §8.2) for a
/// keyboard that only gives characters, the touch keyboard on iOS, and
/// holds the modifiers that keyboard lacks (Ctrl, Shift, Alt, Super) as
/// locked keys: tapped, a modifier goes down on the host at once and stays
/// down (for a click or a drag too) until it is tapped again or a key is
/// typed, which lets go of every locked modifier.
///
/// A stroke presses the key and releases it, with Shift around it when the
/// character needs it and Shift isn't locked, all through the session's
/// ``InputSender``, so `releaseAll` still covers everything.
@MainActor
@Observable
public final class TextTyper {
    public enum Modifier: CaseIterable, Sendable {
        case control, shift, alt, superKey

        public var usage: UInt32 {
            switch self {
            case .control: HIDUsage.leftControl
            case .shift: HIDUsage.leftShift
            case .alt: HIDUsage.leftAlt
            case .superKey: HIDUsage.leftGUI
            }
        }
    }

    /// The modifiers down on the host until tapped again or a key is typed,
    /// in the order they went down.
    public private(set) var locked: [Modifier] = []
    @ObservationIgnored public var layout: KeyboardLayout
    @ObservationIgnored private let sender: InputSender
    @ObservationIgnored private var held: UInt32?

    public init(sender: InputSender, layout: KeyboardLayout = .usQWERTY) {
        self.sender = sender
        self.layout = layout
    }

    public func isLocked(_ modifier: Modifier) -> Bool { locked.contains(modifier) }

    /// A tap on a modifier: pressed on the host and locked, or, if it was
    /// locked, released.
    public func toggle(_ modifier: Modifier) {
        if let index = locked.firstIndex(of: modifier) {
            locked.remove(at: index)
            sender.key(modifier.usage, pressed: false)
        } else {
            locked.append(modifier)
            sender.key(modifier.usage, pressed: true)
        }
    }

    /// Lets go of a held key and every locked modifier: before something
    /// else takes the keyboard (a text panel, dictation), and before the
    /// app leaves the session.
    public func releaseModifiers() {
        if let usage = held {
            held = nil
            sender.key(usage, pressed: false)
        }
        releaseLocked()
    }

    /// A key let go on a hardware keyboard: a modifier it releases on the
    /// host is no longer locked here either.
    public func hostReleased(_ usage: UInt32) {
        locked.removeAll { $0.usage == usage }
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
    /// modifiers are locked: pressed and released.
    public func press(_ usage: UInt32) { press(usage, shift: false) }

    /// A combination from a menu (Ctrl+Alt+T, Super): its modifiers, with
    /// any locked ones, around its key, or tapped alone when it has none.
    public func press(_ combo: KeyCombo) {
        endHold()
        let extra = combo.modifiers.filter { !locked.contains($0) }.map(\.usage)
        for m in extra { sender.key(m, pressed: true) }
        if let usage = combo.key {
            sender.key(usage, pressed: true)
            sender.key(usage, pressed: false)
        }
        for m in extra.reversed() { sender.key(m, pressed: false) }
        releaseLocked()
    }

    /// The same, held until ``endHold()`` (a finger on an on-screen key),
    /// so the host repeats it as it would a physical key.
    public func beginHold(_ usage: UInt32) {
        endHold()
        sender.key(usage, pressed: true)
        held = usage
    }

    public func endHold() {
        guard let usage = held else { return }
        held = nil
        sender.key(usage, pressed: false)
        releaseLocked()
    }

    private func press(_ usage: UInt32, shift: Bool) {
        endHold()
        let addsShift = shift && !locked.contains(.shift)
        if addsShift { sender.key(HIDUsage.leftShift, pressed: true) }
        sender.key(usage, pressed: true)
        sender.key(usage, pressed: false)
        if addsShift { sender.key(HIDUsage.leftShift, pressed: false) }
        releaseLocked()
    }

    /// In the reverse of the order they went down, as a hand would.
    private func releaseLocked() {
        guard !locked.isEmpty else { return }
        for m in locked.reversed() { sender.key(m.usage, pressed: false) }
        locked = []
    }
}
