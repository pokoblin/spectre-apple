/// The session audio's jitter buffer (gdp-spec.md §10): orders packets by
/// `seq`, holds `targetPackets` of them before playback starts, and hands
/// out one slot per packet time: a packet to decode, or a gap to conceal
/// with Opus packet loss concealment.
///
/// It never runs ahead on its own. `next` returns nil when the expected
/// packet hasn't arrived and nothing after it has; only the output running
/// dry (``underrun()``) ends playback, and the next arrivals re-buffer and
/// re-anchor the expected `seq`. That is what makes a silence at the source
/// safe: wraith stops sending, and its `seq` stands still, while it has no
/// audio, so concealing ahead would make every later packet look late.
///
/// Clock drift: the host's audio clock and the local output's differ by tens
/// of ppm, so in continuous playback the depth creeps. The mean depth over
/// each window of pulls is compared with the first window's after playback
/// starts; when it is off by `driftThreshold` packets, one packet is dropped
/// or one concealed slot is inserted. At 100 ppm that is one 10 ms step every
/// few minutes.
///
/// All `seq` comparisons are by their difference as a signed 16-bit value,
/// so wrapping at 2¹⁶ needs no special case. Not thread-safe: the owner
/// locks it.
public struct AudioJitterBuffer: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Packets held before playback starts: the latency the buffer adds.
        public var targetPackets = 6
        /// Duration of one packet, seconds (`AudioConfig.frame_ms`, §6.8).
        public var packetDuration = 0.010
        /// More than this many queued: drop the oldest, back to `targetPackets`.
        public var maxPackets = 12
        /// A packet this many or more ahead of where playback is (or of the
        /// buffered ones) starts the buffer over, as does one that far behind
        /// while buffering.
        public var resyncDistance = 50
        /// Pulls per drift measurement (200 = 2 s of 10 ms packets).
        public var driftWindow = 200
        /// Mean depth off the reference by this many packets: correct by one.
        public var driftThreshold = 1.5

        public init() {}
    }

    public struct Packet: Sendable, Equatable {
        public var sequence: UInt16
        public var pts: UInt32
        public var data: [UInt8]
        /// When it arrived, seconds on the caller's monotonic clock.
        public var arrival: Double
    }

    public enum Slot: Sendable, Equatable {
        case packet(Packet)
        /// One packet's time with no packet: Opus packet loss concealment.
        case conceal
    }

    public struct Counters: Sendable, Equatable {
        public var received = 0
        public var played = 0
        /// Missing packets concealed (each one packet's time).
        public var concealed = 0
        /// Arrived after their slot was played or concealed.
        public var late = 0
        public var duplicates = 0
        /// Dropped by overrun trimming or drift correction.
        public var dropped = 0
        /// Concealed slots inserted by drift correction.
        public var inserted = 0
        /// The output ran dry while playing.
        public var underruns = 0
        /// Started over on a packet far from the others.
        public var resyncs = 0
    }

    public let configuration: Configuration
    public private(set) var counters = Counters()
    public private(set) var isPlaying = false
    /// Sorted by `seq` (by signed distance).
    private var queue: [Packet] = []
    private var expected: UInt16 = 0

    private enum Correction { case drop, insert }
    private var driftSum = 0
    private var driftSamples = 0
    private var driftReference: Double?
    private var pendingCorrection: Correction?

    public init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Packets queued, not yet handed out.
    public var depth: Int { queue.count }

    /// `seq` and `pts` of the next packet that will be handed out, if queued.
    public var head: (sequence: UInt16, pts: UInt32)? { queue.first.map { ($0.sequence, $0.pts) } }

    public mutating func insert(sequence: UInt16, pts: UInt32, data: [UInt8], now: Double) {
        counters.received += 1
        if isPlaying {
            let d = Self.distance(sequence, expected)
            if d < 0 {
                counters.late += 1
                return
            }
            if d >= configuration.resyncDistance { restart() }
        } else if let first = queue.first, abs(Self.distance(sequence, first.sequence)) >= configuration.resyncDistance {
            restart()
        }

        // Most packets arrive in order: search from the back.
        var i = queue.count
        while i > 0 {
            let d = Self.distance(sequence, queue[i - 1].sequence)
            if d == 0 {
                counters.duplicates += 1
                return
            }
            if d > 0 { break }
            i -= 1
        }
        queue.insert(Packet(sequence: sequence, pts: pts, data: data, arrival: now), at: i)

        if isPlaying && queue.count > configuration.maxPackets {
            let n = queue.count - configuration.targetPackets
            queue.removeFirst(n)
            counters.dropped += n
            expected = queue[0].sequence
            resetDrift()
        }
    }

    /// The next slot to play, or nil when there is nothing to play yet:
    /// still buffering, or the expected packet and everything after it
    /// haven't arrived.
    public mutating func next(now: Double) -> Slot? {
        if !isPlaying {
            guard let first = queue.first else { return nil }
            // A short sound followed by nothing (the host stops sending in
            // silence) still plays once the oldest packet has waited the
            // target latency.
            let oldest = queue.map(\.arrival).min() ?? first.arrival
            guard queue.count >= configuration.targetPackets
                    || now - oldest >= Double(configuration.targetPackets) * configuration.packetDuration - 1e-9
            else { return nil }
            isPlaying = true
            expected = first.sequence
            resetDrift()
        }

        switch pendingCorrection {
        case .drop?:
            pendingCorrection = nil
            if queue.first?.sequence == expected { queue.removeFirst() }
            expected &+= 1
            counters.dropped += 1
        case .insert?:
            pendingCorrection = nil
            counters.inserted += 1
            return .conceal
        case nil:
            break
        }

        guard let first = queue.first else { return nil }
        measureDrift()
        expected &+= 1
        if first.sequence == expected &- 1 {
            queue.removeFirst()
            counters.played += 1
            return .packet(first)
        }
        // The expected packet is missing and later ones are here: it's lost.
        counters.concealed += 1
        return .conceal
    }

    /// The output ran out of audio: stop, and re-buffer on what arrives next.
    public mutating func underrun() {
        guard isPlaying else { return }
        isPlaying = false
        counters.underruns += 1
        resetDrift()
    }

    /// Drop everything and start buffering again (an interruption, a new
    /// output device).
    public mutating func flush() {
        queue.removeAll()
        isPlaying = false
        resetDrift()
    }

    private mutating func restart() {
        counters.resyncs += 1
        flush()
    }

    private mutating func resetDrift() {
        driftSum = 0
        driftSamples = 0
        driftReference = nil
        pendingCorrection = nil
    }

    private mutating func measureDrift() {
        driftSum += queue.count
        driftSamples += 1
        guard driftSamples >= configuration.driftWindow else { return }
        let mean = Double(driftSum) / Double(driftSamples)
        driftSum = 0
        driftSamples = 0
        guard let reference = driftReference else {
            driftReference = mean
            return
        }
        if mean >= reference + configuration.driftThreshold {
            pendingCorrection = .drop
        } else if mean <= reference - configuration.driftThreshold {
            pendingCorrection = .insert
        }
    }

    /// `a - b` for 16-bit sequence numbers (gdp-spec.md §10, §11).
    static func distance(_ a: UInt16, _ b: UInt16) -> Int { Int(Int16(bitPattern: a &- b)) }
}
