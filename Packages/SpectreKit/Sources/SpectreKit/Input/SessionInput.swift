import CoreGraphics
import Observation

/// One session's input: what the platform's session view forwards (through
/// an ``InputSender``) and the state around it that outlives a single event.
/// The views translate platform events; everything here is shared.
@MainActor
@Observable
public final class SessionInput {
    @ObservationIgnored public let sender: InputSender

    public init(sink: InputSink) {
        sender = InputSender(sink: sink)
    }

    // MARK: Keyboard

    public func key(_ usage: UInt32, pressed: Bool) { sender.key(usage, pressed: pressed) }

    /// A lock key reported once per toggle: pressed and released.
    public func tapKey(_ usage: UInt32) { sender.tap(usage) }

    // MARK: Focus

    /// The session view lost the keyboard (another window or app, or a
    /// control in this window took it): nothing may stay held (§8.2).
    public func focusLost() {
        sender.releaseAll()
    }

    /// The session is ending or the view is going away.
    public func end() {
        focusLost()
    }
}
