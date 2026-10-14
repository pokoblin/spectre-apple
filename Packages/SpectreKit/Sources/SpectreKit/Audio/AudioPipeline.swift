import AVFoundation
import Synchronization

/// Session audio from packets to the render callback, without the audio
/// device: the jitter buffer (locked; packets come in on the network queue),
/// the Opus decoder and the ring. Three sides:
///
/// - ``receive(sequence:pts:opus:now:)``, any thread;
/// - ``pump(now:)``, the decode thread: keeps `lookahead` of PCM in the ring;
/// - ``render(frames:into:hostTime:)``, Core Audio's real-time thread: only
///   copies from the ring, outputs silence for what's missing, and records
///   that it ran dry so the next pump re-buffers (an underrun).
public final class AudioPipeline: @unchecked Sendable {
    public struct Statistics: Sendable, Equatable {
        public var counters = AudioJitterBuffer.Counters()
        public var isPlaying = false
        /// Packets queued in the jitter buffer.
        public var queuedPackets = 0
        /// Decoded audio waiting in the ring, seconds.
        public var ringSeconds = 0.0
        /// The packets the decoder failed on.
        public var decodeErrors = 0
        /// `(client clock when it reaches the speaker) − pts` of the latest
        /// rendered sample, µs, wrapped to 32 bits like `pts` (gdp-spec.md
        /// §11). It carries the unknown offset between the two ends' clocks,
        /// which cancels against video's same measurement. nil until known.
        public var playoutMinusPTS: Int32?
    }

    public let format: OpusFormat
    public let ring: AudioRing
    /// Decoded audio the pump keeps ahead of the render callback, frames,
    /// at least: it also covers the largest render request seen plus a
    /// packet (iOS renders 4096 frames at a time with the screen locked).
    public let lookahead: Int
    private let jitter: Mutex<AudioJitterBuffer>

    private struct Decoding {
        let decoder: OpusDecoder
        var errors = 0
        /// pts of the sample at a ring frame index, one per decoded slot still
        /// (possibly) in the ring.
        var marks: [(index: Int, pts: UInt32)] = []
        var lastPTS: UInt32?
        var playoutMinusPTS: Int32?
    }
    private let decoding: Mutex<Decoding>

    /// Set by the render callback when it couldn't fill a request.
    private let starved = Atomic<Bool>(false)
    /// Set by ``flush()``: the render callback empties the ring (it is the
    /// ring's only reader).
    private let drainRequested = Atomic<Bool>(false)
    /// Host time of the last render and the ring's read index at its first frame.
    private let lastRender = Atomic<WordPair>(WordPair(first: 0, second: 0))
    private let outputLatencyMicros = Atomic<Int>(0)
    private let largestRender = Atomic<Int>(0)

    public init?(format: OpusFormat, configuration: AudioJitterBuffer.Configuration? = nil, lookaheadPackets: Int = 2) {
        guard let decoder = OpusDecoder(format) else { return nil }
        var config = configuration ?? AudioJitterBuffer.Configuration()
        config.packetDuration = format.packetDuration
        self.format = format
        lookahead = lookaheadPackets * format.framesPerPacket
        // A 4096-frame render request with a packet on top, and slack.
        ring = AudioRing(channels: format.channels,
                         minimumCapacity: max(8192, (lookaheadPackets + 4) * format.framesPerPacket))
        jitter = Mutex(AudioJitterBuffer(config))
        decoding = Mutex(Decoding(decoder: decoder))
    }

    // MARK: - Network side

    /// `now`: seconds on a monotonic clock, the same one ``pump(now:)`` gets.
    public func receive(sequence: UInt16, pts: UInt32, opus: UnsafeRawBufferPointer, now: Double) {
        let bytes = [UInt8](opus)
        jitter.withLock { $0.insert(sequence: sequence, pts: pts, data: bytes, now: now) }
    }

    // MARK: - Decode thread

    /// Re-buffers after an underrun and tops the ring up to `lookahead`.
    public func pump(now: Double) {
        if starved.exchange(false, ordering: .acquiringAndReleasing) {
            // The output ran dry. With packets still queued, it was this
            // pump falling behind, not the network: just top up.
            jitter.withLock { if $0.depth == 0 { $0.underrun() } }
        }
        let target = min(max(lookahead, largestRender.load(ordering: .relaxed) + format.framesPerPacket),
                         ring.capacity - 2 * format.framesPerPacket)
        decoding.withLock { d in
            measurePlayout(&d)
            while ring.available < target {
                guard let slot = jitter.withLock({ $0.next(now: now) }) else { break }
                let pts: UInt32
                let packet: [UInt8]?
                switch slot {
                case .packet(let p):
                    pts = p.pts
                    packet = p.data
                case .conceal:
                    pts = (d.lastPTS ?? 0) &+ UInt32(format.frameMilliseconds * 1000)
                    packet = nil
                }
                d.lastPTS = pts
                let start = ring.writeIndex
                var frames = 0
                if !d.decoder.decode(packet, { frames += ring.write($0) }) { d.errors += 1 }
                guard frames > 0 else { continue }
                // A priming trim shortens the slot from the front.
                let trimmed = max(0, format.framesPerPacket - frames)
                d.marks.append((start, pts &+ UInt32(trimmed * 1_000_000 / format.sampleRate)))
            }
        }
    }

    private func measurePlayout(_ d: inout Decoding) {
        let last = lastRender.load(ordering: .acquiring)
        let hostTime = UInt64(last.first), index = Int(last.second)
        guard hostTime != 0, let i = d.marks.lastIndex(where: { $0.index <= index }), index < ring.writeIndex else { return }
        d.marks.removeFirst(i)
        let mark = d.marks[0]
        let pts = mark.pts &+ UInt32((index - mark.index) * 1_000_000 / format.sampleRate)
        let playout = UInt64(AVAudioTime.seconds(forHostTime: hostTime) * 1_000_000) + UInt64(outputLatencyMicros.load(ordering: .relaxed))
        d.playoutMinusPTS = Int32(bitPattern: UInt32(truncatingIfNeeded: playout) &- pts)
    }

    // MARK: - Real-time thread

    /// Fills `frames` frames of every buffer in `buffers` (non-interleaved
    /// Float32): from the ring, and silence for the rest. Returns true if
    /// all of it was silence. `hostTime` is the render's time stamp (0 if
    /// it has none).
    public func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer, hostTime: UInt64) -> Bool {
        if drainRequested.exchange(false, ordering: .acquiringAndReleasing) { ring.drain() }
        if frames > largestRender.load(ordering: .relaxed) { largestRender.store(frames, ordering: .relaxed) }
        let index = ring.readIndex
        let n = ring.read(into: buffers, frames: frames)
        if n < frames {
            for b in buffers {
                guard let out = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                (out + n).update(repeating: 0, count: frames - n)
            }
            starved.store(true, ordering: .releasing)
        }
        if n > 0 && hostTime != 0 {
            lastRender.store(WordPair(first: UInt(hostTime), second: UInt(index)), ordering: .releasing)
        }
        return n == 0
    }

    // MARK: - Control

    /// From the device: how long a rendered sample takes to be heard.
    public func setOutputLatency(_ seconds: Double) {
        outputLatencyMicros.store(Int(max(0, seconds) * 1_000_000), ordering: .relaxed)
    }

    /// Drop everything queued and decoded, and buffer afresh (an
    /// interruption, a new output device).
    public func flush() {
        decoding.withLock { d in
            jitter.withLock { $0.flush() }
            drainRequested.store(true, ordering: .releasing)
            d.decoder.reset()
            d.marks.removeAll()
            d.lastPTS = nil
            d.playoutMinusPTS = nil
        }
        starved.store(false, ordering: .releasing)
        lastRender.store(WordPair(first: 0, second: 0), ordering: .releasing)
    }

    public var statistics: Statistics {
        var s = Statistics()
        jitter.withLock {
            s.counters = $0.counters
            s.isPlaying = $0.isPlaying
            s.queuedPackets = $0.depth
        }
        s.ringSeconds = Double(ring.available) / Double(format.sampleRate)
        decoding.withLock {
            s.decodeErrors = $0.errors
            s.playoutMinusPTS = $0.playoutMinusPTS
        }
        return s
    }
}
