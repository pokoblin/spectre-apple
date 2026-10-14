import Synchronization

/// The hand-off from decoder to presenter: one slot, newest frame wins.
/// A frame replaced before the presenter took it was decoded but never shown
/// (counted, as a remote desktop shows the newest picture, never a queue).
public final class FrameMailbox: Sendable {
    private struct State {
        var frame: DecodedFrame?
        var replaced: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func put(_ frame: DecodedFrame) {
        state.withLock {
            if $0.frame != nil { $0.replaced += 1 }
            $0.frame = frame
        }
    }

    /// The newest frame not yet taken, if any.
    public func take() -> DecodedFrame? {
        state.withLock {
            let f = $0.frame
            $0.frame = nil
            return f
        }
    }

    /// Frames replaced in the slot before anyone took them.
    public var replacedCount: UInt64 { state.withLock { $0.replaced } }
}
