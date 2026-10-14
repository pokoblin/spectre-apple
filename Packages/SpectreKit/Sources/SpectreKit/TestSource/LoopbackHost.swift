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
        // Keep a pointer as wraith does, so a captured mouse moves the cursor (§7.4).
        config.simulatePointer = true
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
        if host.takeKeyframeWanted() {
            // Asked for right after each SessionAccept (and after a loss):
            // also replace the test host's 2×2 cursor with one easier to see.
            index = 0
            let c = Self.crosshair
            host.sendCursorShape(width: c.side, height: c.side, hotspotX: c.side / 2, hotspotY: c.side / 2, argb: c.bgra)
        }
        let au = stream.accessUnits[index]
        host.sendVideoFrame(au.bytes, keyframe: au.keyframe)
        index = (index + 1) % stream.accessUnits.count
    }

    /// A 25×25 crosshair, white with a dark outline: premultiplied BGRA (§7.4).
    static let crosshair: (side: UInt32, bgra: [UInt8]) = {
        let n = 25, mid = 12
        var bgra = [UInt8](repeating: 0, count: n * n * 4)
        func put(_ x: Int, _ y: Int, _ v: UInt8) {
            guard (0..<n).contains(x), (0..<n).contains(y) else { return }
            let i = (y * n + x) * 4
            if bgra[i + 3] == 255, v == 0 { return } // white wins over outline
            bgra[i] = v; bgra[i + 1] = v; bgra[i + 2] = v; bgra[i + 3] = 255
        }
        for pass in [UInt8(0), 255] {
            let w = pass == 0 ? 1 : 0 // outline is one pixel wider
            for t in 0..<n where abs(t - mid) > 2 {
                for d in -w...w {
                    put(t, mid + d, pass)
                    put(mid + d, t, pass)
                }
            }
            for dy in -1 - w...1 + w { for dx in -1 - w...1 + w { put(mid + dx, mid + dy, pass) } }
        }
        return (UInt32(n), bgra)
    }()
}
