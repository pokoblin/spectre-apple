import Dispatch
import GDPKit

/// A stand-in for wraith in this process: GDPKit's test host on 127.0.0.1,
/// fed a ``TestStream`` at its frame rate. The client connects to it over
/// real QUIC, so the whole receive path runs as it would against a host.
/// When the host is asked for a keyframe (a KeyframeRequest or a reported
/// loss), the stream restarts at its first access unit, its only keyframe.
public final class LoopbackHost: @unchecked Sendable {
    public let host: GDPTestHost
    public let stream: TestStream
    private let queue = DispatchQueue(label: "spectre.loopback-host", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var index = 0 // queue only

    public init(stream: TestStream) throws(GDPTestHost.Failure) {
        var config = GDPTestHost.Configuration()
        config.codecs = [stream.codec.rawValue]
        config.width = UInt32(stream.width)
        config.height = UInt32(stream.height)
        host = try GDPTestHost(config)
        self.stream = stream
    }

    deinit { timer?.cancel() }

    /// A configuration that connects a session to this host.
    public func sessionConfiguration() -> GDPSession.Configuration {
        var config = host.sessionConfiguration(codecs: [stream.codec.rawValue])
        config.decoders = ["videotoolbox"]
        config.networkProfile = .lan
        return config
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
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
        }
    }

    private func tick() {
        if host.takeKeyframeWanted() { index = 0 }
        let au = stream.accessUnits[index]
        host.sendVideoFrame(au.bytes, keyframe: au.keyframe)
        index = (index + 1) % stream.accessUnits.count
    }
}
