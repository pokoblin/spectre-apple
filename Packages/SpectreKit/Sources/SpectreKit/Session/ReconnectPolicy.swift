import Foundation
import GDPKit

/// When a session that went away is worth connecting again, how often to
/// try, and when to take it over without asking (docs/reconnect.md).
public enum ReconnectPolicy {
    /// The wait before each attempt; after the last one fails, give up.
    /// About a minute in all: long enough for a network to come back, short
    /// enough that the user isn't left watching a spinner.
    public static let delays: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8),
                                            .seconds(15), .seconds(15), .seconds(15)]

    /// A session ended by its connection failing, not by anyone (the host
    /// logging out, a take-over, our own close) is worth reconnecting.
    public static func reconnects(after ending: GDPSession.Ending) -> Bool {
        ending.connectionLost && !ending.certificateRejected
    }

    /// A login that failed during a reconnect: try again (no answer, the
    /// host offline or busy, §12's 3x) or stop (wrong password, a refusal,
    /// a protocol problem: asking again won't change the answer).
    public static func retries(loginFailure code: UInt64) -> Bool {
        code == 0 || code / 10 == 3
    }

    /// How long after losing its own connection a client may take its
    /// session over without asking: until the host notices (its idle timeout
    /// is 30 s), the "viewer" it sees attached is most likely that very
    /// connection. Past this, someone else may have attached.
    public static let ownViewerWindow: TimeInterval = 60

    /// Whether to take over a session that reports a viewer attached.
    /// `lostAt`: when this client's connection was lost without being
    /// closed (nil if it closed it itself, the host saw it go).
    public static func takesOverAutomatically(lostAt: Date?, now: Date = Date()) -> Bool {
        guard let lostAt else { return false }
        return now.timeIntervalSince(lostAt) < ownViewerWindow
    }
}
