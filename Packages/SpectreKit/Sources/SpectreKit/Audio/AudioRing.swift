import AVFoundation
import Synchronization

/// Decoded audio from the decode thread to the real-time render callback:
/// a single-producer, single-consumer ring of interleaved Float32 frames.
/// No locks and no allocation after init, so the render side may run on
/// Core Audio's real-time thread.
public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    /// In frames; a power of two.
    public let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    // Frame counts since creation; they only grow (wrapping takes ~6 million
    // years at 48 kHz). `written` is stored by the producer only, `read` by
    // the consumer only.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    public init(channels: Int, minimumCapacity: Int) {
        self.channels = channels
        var c = 1
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        samples = .allocate(capacity: c * channels)
        samples.initialize(repeating: 0, count: c * channels)
    }

    deinit { samples.deallocate() }

    /// Frames ready to read.
    public var available: Int { written.load(ordering: .acquiring) - read.load(ordering: .acquiring) }

    /// Frames written since creation (the index of the next one written).
    public var writeIndex: Int { written.load(ordering: .acquiring) }

    /// Frames read since creation (the index of the next one read).
    public var readIndex: Int { read.load(ordering: .acquiring) }

    /// Producer: append interleaved samples; returns frames taken (fewer
    /// when full).
    @discardableResult
    public func write(_ source: UnsafeBufferPointer<Float>) -> Int {
        let w = written.load(ordering: .relaxed)
        let free = capacity - (w - read.load(ordering: .acquiring))
        let frames = min(source.count / channels, free)
        var done = 0
        while done < frames {
            let at = (w + done) & (capacity - 1)
            let n = min(frames - done, capacity - at)
            (samples + at * channels).update(from: source.baseAddress! + done * channels, count: n * channels)
            done += n
        }
        written.store(w + frames, ordering: .releasing)
        return frames
    }

    /// Producer: append `frames` frames from non-interleaved buffers (one
    /// per channel; missing ones read as silence); returns frames taken.
    /// No allocation: fit for the real-time thread.
    @discardableResult
    public func write(from buffers: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        let w = written.load(ordering: .relaxed)
        let free = capacity - (w - read.load(ordering: .acquiring))
        let n = min(frames, free)
        for c in 0..<channels {
            let source = c < buffers.count ? buffers[c].mData?.assumingMemoryBound(to: Float.self) : nil
            for i in 0..<n {
                samples[((w + i) & (capacity - 1)) * channels + c] = source?[i] ?? 0
            }
        }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer: up to `frames` frames, de-interleaved into `channels`
    /// buffers starting at `offset`. Returns frames read.
    public func read(into buffers: UnsafeMutableAudioBufferListPointer, frames: Int, offset: Int = 0) -> Int {
        let r = read.load(ordering: .relaxed)
        let n = min(frames, written.load(ordering: .acquiring) - r)
        for (c, buffer) in buffers.enumerated() {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channel = min(c, channels - 1) // mono to every output channel
            for i in 0..<n {
                out[offset + i] = samples[((r + i) & (capacity - 1)) * channels + channel]
            }
        }
        read.store(r + n, ordering: .releasing)
        return n
    }

    /// Consumer: throw away everything buffered.
    public func drain() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}
