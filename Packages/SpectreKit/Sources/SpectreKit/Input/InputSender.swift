import CoreGraphics
import GDPKit

/// Where input goes: the session's input stream (gdp-spec.md §8.2).
/// GDPSession is one; tests record instead.
public protocol InputSink: AnyObject, Sendable {
    func sendKey(hidUsage: UInt32, pressed: Bool)
    func sendPointerMotion(dx: Double, dy: Double, absolute: Bool)
    func sendPointerButton(_ button: UInt32, pressed: Bool)
    func sendPointerAxis(horizontal: Double, vertical: Double)
}

extension GDPSession: InputSink {}

/// Forwards keyboard and pointer input to a session and remembers what it
/// reported held, so that all of it can be released at once: §8.2 asks a
/// client to release every key it reported pressed before it detaches or
/// loses focus, and a button left down would leave the host mid-drag.
///
/// It also drops what the host must not see twice: a press of a key that is
/// already down (the platform's auto-repeat; the host repeats keys itself)
/// and a release of one that isn't (a key that went down before the session
/// view had focus).
@MainActor
public final class InputSender {
    public private(set) var heldKeys: Set<UInt32> = []
    public private(set) var heldButtons: Set<UInt32> = []
    /// The last absolute position sent (0...1), where the host's pointer is
    /// while the client sends absolute motion.
    public private(set) var lastPosition: CGPoint?

    private let sink: InputSink

    public init(sink: InputSink) { self.sink = sink }

    public func key(_ usage: UInt32, pressed: Bool) {
        if pressed {
            guard heldKeys.insert(usage).inserted else { return }
        } else {
            guard heldKeys.remove(usage) != nil else { return }
        }
        sink.sendKey(hidUsage: usage, pressed: pressed)
    }

    /// A key that toggles a lock rather than being held (Caps Lock as AppKit
    /// reports it: one event per toggle): a press and a release.
    public func tap(_ usage: UInt32) {
        key(usage, pressed: true)
        key(usage, pressed: false)
    }

    public func button(_ code: UInt32, pressed: Bool) {
        if pressed {
            guard heldButtons.insert(code).inserted else { return }
        } else {
            guard heldButtons.remove(code) != nil else { return }
        }
        sink.sendPointerButton(code, pressed: pressed)
    }

    /// Moves the pointer to a position on the output, 0...1 each way.
    public func move(to position: CGPoint) {
        guard position != lastPosition else { return }
        lastPosition = position
        sink.sendPointerMotion(dx: position.x, dy: position.y, absolute: true)
    }

    /// Moves the pointer by an amount in output pixels (the mouse captured).
    public func move(by dx: Double, _ dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        sink.sendPointerMotion(dx: dx, dy: dy, absolute: false)
    }

    /// Scrolls, in wheel notches: positive right and down (§8.2).
    public func scroll(horizontal: Double, vertical: Double) {
        guard horizontal != 0 || vertical != 0 else { return }
        sink.sendPointerAxis(horizontal: horizontal, vertical: vertical)
    }

    /// Releases every key and button reported held: ordinary keys first,
    /// then modifiers, so that the host never sees a bare key with its
    /// modifier already gone (Super+L becoming L), then buttons.
    public func releaseAll() {
        let keys = heldKeys.sorted { (HIDUsage.isModifier($0) ? 1 : 0, $0) < (HIDUsage.isModifier($1) ? 1 : 0, $1) }
        for usage in keys { key(usage, pressed: false) }
        for code in heldButtons.sorted() { button(code, pressed: false) }
    }

    /// Releases the pointer buttons held (the pointer changing hands).
    public func releaseButtons() {
        for code in heldButtons.sorted() { button(code, pressed: false) }
    }

    /// Forget the last position so the next absolute motion is sent even if
    /// it is the same (after the mouse was captured, the host's pointer is
    /// wherever relative motion left it).
    public func forgetPosition() { lastPosition = nil }
}
