import Dispatch
import QuartzCore

/// Feeds a ``TestStream`` to a ``VideoDecoder`` at the stream's frame rate,
/// looping, the way frames would arrive from the network. Decoded frames go
/// to the mailbox and `onFrame` (to wake the presenter).
///
/// In a session this role belongs to the GDP receive path: reassembled
/// frames from GDPKit go to the same decoder on the same kind of queue.
public final class StreamPlayer: @unchecked Sendable {
    public let stream: TestStream
    private let queue = DispatchQueue(label: "spectre.decode", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    // Touched only on `queue`.
    private var decoder: VideoDecoder?
    private var index = 0
    private let mailbox: FrameMailbox
    private let stats: PlaybackStats
    private let onFrame: @Sendable () -> Void

    public init(stream: TestStream, mailbox: FrameMailbox, stats: PlaybackStats,
                onFrame: @escaping @Sendable () -> Void = {}) {
        self.stream = stream
        self.mailbox = mailbox
        self.stats = stats
        self.onFrame = onFrame
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let mailbox = mailbox, stats = stats, onFrame = onFrame
            decoder = VideoDecoder(codec: stream.codec, onFrame: { frame in
                stats.recordDecoded(frame)
                mailbox.put(frame)
                onFrame()
            }, onError: { _ in stats.recordDecodeError() })
            index = 0
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / stream.framesPerSecond)
            t.schedule(deadline: .now(), repeating: interval, leeway: .nanoseconds(0))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            decoder = nil
        }
    }

    private func tick() {
        guard let decoder else { return }
        let au = stream.accessUnits[index]
        let pts = UInt32(truncatingIfNeeded: UInt64(index) * 1_000_000 / UInt64(stream.framesPerSecond))
        do {
            try au.bytes.withUnsafeBytes { try decoder.decode($0, pts: pts) }
            stats.setHardwareDecoder(decoder.isHardwareAccelerated)
        } catch {
            stats.recordDecodeError()
        }
        // Loop: the first access unit is the stream's only keyframe.
        index = (index + 1) % stream.accessUnits.count
    }
}
