import Dispatch
import Synchronization

/// How many file bytes may be on their way to the host at once, across
/// every transfer of a session (gdp-spec.md §7.12).
///
/// File data shares the uplink with what keeps the session responsive: key
/// presses, and the StatsReports the host's rate control steers the video
/// by. QUIC's congestion control fills a slow uplink's buffer, and
/// everything else then waits behind the file. So the budget follows the
/// connection's round-trip time, the way LEDBAT-style background transfers
/// do: it grows while the RTT stays within ``targetDelay`` of the lowest
/// seen, and halves (at most once per RTT) when the queue builds up. On a
/// LAN the RTT never rises that far, and the budget grows to its maximum.
public struct UploadWindow: Sendable, Equatable {
    public static let minimum = 256 * 1024
    public static let maximum = 16 << 20
    public static let initial = 2 << 20
    /// Queueing delay tolerated before backing off.
    public static let targetDelayMicroseconds: UInt32 = 25_000
    /// Growth per RTT sample under the target.
    static let step = 256 * 1024

    public private(set) var bytes = initial
    public private(set) var baseRTT: UInt32?
    private var lastDecreaseMicroseconds: UInt64?

    public init() {}

    /// One RTT sample (µs, the connection's smoothed RTT) at `now` (µs).
    public mutating func update(rttMicroseconds rtt: UInt32, now: UInt64) {
        guard rtt > 0 else { return }
        baseRTT = min(baseRTT ?? rtt, rtt)
        if rtt > baseRTT! + Self.targetDelayMicroseconds {
            if let last = lastDecreaseMicroseconds, now - last < UInt64(rtt) { return }
            bytes = max(Self.minimum, bytes / 2)
            lastDecreaseMicroseconds = now
        } else {
            bytes = min(Self.maximum, bytes + Self.step)
        }
    }
}

/// The session's ``UploadWindow``, shared by its transfers: each reserves
/// room before sending and gives it back as the host acknowledges. A
/// transfer that finds no room is woken when some frees up.
final class UploadBudget: Sendable {
    private struct State {
        var window = UploadWindow()
        var inFlight = 0
        var waiting: [@Sendable () -> Void] = []
        var lastSampleMicroseconds: UInt64 = 0
    }
    private let state = Mutex(State())
    /// The connection's RTT now, µs (nil when there is none to read).
    private let rtt: @Sendable () -> UInt32?
    /// RTT samples at most this often.
    static let sampleInterval: UInt64 = 50_000

    init(rtt: @escaping @Sendable () -> UInt32?) {
        self.rtt = rtt
    }

    var window: UploadWindow { state.withLock { $0.window } }
    var inFlight: Int { state.withLock { $0.inFlight } }

    /// Up to `wanted` bytes of room, or 0, in which case `wake` runs once
    /// some is given back.
    func reserve(_ wanted: Int, wake: @escaping @Sendable () -> Void) -> Int {
        state.withLock {
            let room = max(0, $0.window.bytes - $0.inFlight)
            guard room > 0 else {
                $0.waiting.append(wake)
                return 0
            }
            let granted = min(wanted, room)
            $0.inFlight += granted
            return granted
        }
    }

    /// `bytes` acknowledged (or abandoned): room for others.
    func release(_ bytes: Int) {
        guard bytes > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds / 1000
        let sample = state.withLock { s -> Bool in
            guard now - s.lastSampleMicroseconds >= Self.sampleInterval else { return false }
            s.lastSampleMicroseconds = now
            return true
        }
        // Read outside the lock: it asks the session's queue.
        let measured = sample ? rtt() : nil
        let woken = state.withLock { s -> [@Sendable () -> Void] in
            s.inFlight = max(0, s.inFlight - bytes)
            if let measured { s.window.update(rttMicroseconds: measured, now: now) }
            defer { s.waiting = [] }
            return s.waiting
        }
        woken.forEach { $0() }
    }
}
