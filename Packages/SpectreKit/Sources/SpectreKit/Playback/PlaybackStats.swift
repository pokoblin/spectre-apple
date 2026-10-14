import Darwin
import Foundation
import QuartzCore
import Synchronization

/// Per-frame timings of the decode-and-present pipeline, the numbers a
/// session reports in `StatsReport` (gdp-spec.md §7.5: decode and present
/// time) and the statistics overlay shows.
public final class PlaybackStats: Sendable {
    /// Distribution of one measurement, milliseconds.
    public struct Distribution: Sendable, CustomStringConvertible {
        public let count: Int
        public let mean: Double
        public let p50: Double
        public let p95: Double
        public let p99: Double
        public let max: Double

        init(_ samples: [Double]) {
            count = samples.count
            guard !samples.isEmpty else {
                mean = 0; p50 = 0; p95 = 0; p99 = 0; max = 0
                return
            }
            let s = samples.sorted()
            func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
            mean = s.reduce(0, +) / Double(s.count)
            p50 = pct(0.5)
            p95 = pct(0.95)
            p99 = pct(0.99)
            max = s.last!
        }

        public var description: String {
            String(format: "mean %.2f  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f ms", mean, p50, p95, p99, max)
        }
    }

    public struct Summary: Sendable, CustomStringConvertible {
        public let seconds: Double
        public let decodedFrames: Int
        public let presentedFrames: Int
        /// Decoded but replaced by a newer frame before being drawn.
        public let replacedFrames: UInt64
        /// Drawn but never reached the screen (`presentedTime == 0`).
        public let unpresentedFrames: Int
        public let decodeErrors: Int
        /// Frames whose textures were checked to be views of the decoder's IOSurface.
        public let zeroCopyFrames: Int
        public let decode: Distribution
        /// Decoder output to on screen (`MTLDrawable.presentedTime`).
        public let present: Distribution
        /// GPU execution of the video pass.
        public let gpu: Distribution
        /// Interval between consecutive on-screen frames.
        public let presentInterval: Distribution
        /// Process CPU time over wall time (100 % = one core).
        public let cpuPercent: Double
        public let hardwareDecoder: Bool
        /// On-screen intervals rounded to milliseconds -> count.
        public let intervalHistogram: [Int: Int]

        public var decodedFPS: Double { seconds > 0 ? Double(decodedFrames) / seconds : 0 }
        public var presentedFPS: Double { seconds > 0 ? Double(presentedFrames) / seconds : 0 }

        public var description: String {
            """
            \(String(format: "%.1f s: decoded %d (%.1f fps), presented %d (%.1f fps)", seconds, decodedFrames, decodedFPS, presentedFrames, presentedFPS))
              replaced \(replacedFrames), not presented \(unpresentedFrames), decode errors \(decodeErrors), zero-copy \(zeroCopyFrames)/\(presentedFrames + unpresentedFrames), hardware decoder \(hardwareDecoder)
              decode           \(decode)
              decode→present   \(present)
              gpu              \(gpu)
              present interval \(presentInterval)
              interval histogram (ms: frames) \(intervalHistogram.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
              cpu \(String(format: "%.1f %%", cpuPercent))
            """
        }
    }

    private struct State {
        var start = CACurrentMediaTime()
        var cpuStart = processCPUTime()
        var decode: [Double] = []
        var present: [Double] = []
        var gpu: [Double] = []
        var intervals: [Double] = []
        var lastPresented: CFTimeInterval = 0
        var unpresented = 0
        var decodeErrors = 0
        var zeroCopy = 0
        var replacedAtStart: UInt64 = 0
        var hardwareDecoder = false
    }

    private let state = Mutex(State())
    private let mailbox: FrameMailbox?
    private let timingSink = Mutex<(@Sendable (_ decodeMicroseconds: UInt32, _ presentMicroseconds: UInt32) -> Void)?>(nil)

    /// Called with each on-screen frame's decode and decode→present times:
    /// what a session's StatsReport carries (gdp-spec.md §7.5).
    public func setTimingSink(_ sink: (@Sendable (_ decodeMicroseconds: UInt32, _ presentMicroseconds: UInt32) -> Void)?) {
        timingSink.withLock { $0 = sink }
    }

    public init(mailbox: FrameMailbox? = nil) {
        self.mailbox = mailbox
        reset()
    }

    /// Starts a new measurement window.
    public func reset() {
        let replaced = mailbox?.replacedCount ?? 0
        state.withLock {
            let hw = $0.hardwareDecoder
            $0 = State()
            $0.replacedAtStart = replaced
            $0.hardwareDecoder = hw
        }
    }

    public func recordDecoded(_ frame: DecodedFrame) {
        state.withLock { $0.decode.append(frame.decodeDuration * 1000) }
    }

    public func recordDecodeError() { state.withLock { $0.decodeErrors += 1 } }
    public func setHardwareDecoder(_ hw: Bool) { state.withLock { $0.hardwareDecoder = hw } }

    /// One drawn frame: `presentedTime` from the drawable (0 if it never
    /// made it to the screen), GPU start/end from the command buffer.
    public func recordPresented(frame: DecodedFrame, presentedTime: CFTimeInterval, gpuStart: CFTimeInterval,
                                gpuEnd: CFTimeInterval, zeroCopy: Bool) {
        state.withLock {
            if zeroCopy { $0.zeroCopy += 1 }
            if gpuEnd > gpuStart { $0.gpu.append((gpuEnd - gpuStart) * 1000) }
            guard presentedTime > 0 else {
                $0.unpresented += 1
                return
            }
            $0.present.append((presentedTime - frame.decodedTime) * 1000)
            if $0.lastPresented > 0 { $0.intervals.append((presentedTime - $0.lastPresented) * 1000) }
            $0.lastPresented = presentedTime
        }
        guard presentedTime > 0, let sink = timingSink.withLock({ $0 }) else { return }
        func us(_ seconds: CFTimeInterval) -> UInt32 { UInt32(clamping: Int64((max(seconds, 0) * 1_000_000).rounded())) }
        sink(us(frame.decodeDuration), us(presentedTime - frame.decodedTime))
    }

    public func summary() -> Summary {
        let replaced = mailbox?.replacedCount ?? 0
        let now = CACurrentMediaTime()
        let cpu = processCPUTime()
        return state.withLock { s in
            let seconds = now - s.start
            return Summary(seconds: seconds, decodedFrames: s.decode.count, presentedFrames: s.present.count,
                           replacedFrames: replaced - s.replacedAtStart, unpresentedFrames: s.unpresented,
                           decodeErrors: s.decodeErrors, zeroCopyFrames: s.zeroCopy,
                           decode: Distribution(s.decode), present: Distribution(s.present), gpu: Distribution(s.gpu),
                           presentInterval: Distribution(s.intervals),
                           cpuPercent: seconds > 0 ? (cpu - s.cpuStart) / seconds * 100 : 0,
                           hardwareDecoder: s.hardwareDecoder,
                           intervalHistogram: Dictionary(s.intervals.map { (Int($0.rounded()), 1) }, uniquingKeysWith: +))
        }
    }
}

/// User + system CPU time of this process, seconds.
func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return secs(usage.ru_utime) + secs(usage.ru_stime)
}
