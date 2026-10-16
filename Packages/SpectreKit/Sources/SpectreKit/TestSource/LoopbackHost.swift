import Dispatch
import Foundation
import GDPKit

/// A stand-in for wraith in this process: GDPKit's test host on 127.0.0.1,
/// fed a ``TestStream`` at its frame rate. The client connects to it over
/// real QUIC, so the whole receive path runs as it would against a host.
/// When the host is asked for a keyframe (a KeyframeRequest or a reported
/// loss), the stream restarts at its first access unit, its only keyframe.
///
/// With `audio`, it also advertises wraith's audio format and sends a test
/// tone every 10 ms: a 0.1 s, 880 Hz beep once a second, silence between.
///
/// Files the viewer sends (gdp-spec.md §7.12) land in ``fileDirectory``,
/// as wraith's land in the download directory.
public final class LoopbackHost: @unchecked Sendable {
    public let host: GDPTestHost
    public let stream: TestStream
    /// Where received files go: "Loopback Files" in the app's temporary directory.
    public let fileDirectory: URL
    private let queue = DispatchQueue(label: "spectre.loopback-host", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var audioTimer: DispatchSourceTimer?
    private var index = 0 // queue only
    private let beep: [[UInt8]]
    private var beepIndex = 0 // queue only

    /// `clipboard`: the host's clipboard text to start with (gdp-spec.md §7.9).
    public init(stream: TestStream, audio: Bool = true, clipboard: String? = nil) throws(GDPTestHost.Failure) {
        var config = GDPTestHost.Configuration()
        config.codecs = [stream.codec.rawValue]
        config.width = UInt32(stream.width)
        config.height = UInt32(stream.height)
        // Keep a pointer as wraith does, so a captured mouse moves the cursor (§7.4).
        config.simulatePointer = true
        // Take the microphone, so loopback shows what the host receives (§10.1),
        // gamepads (§8.5), files (§7.12), and keep a clipboard: what the
        // viewer copies comes back on the next attach.
        config.capabilities = ["microphone", GDPSession.Capability.gamepad, GDPSession.Capability.clipboard,
                               GDPSession.Capability.file]
        config.clipboard = clipboard
        fileDirectory = FileManager.default.temporaryDirectory.appending(path: "Loopback Files", directoryHint: .isDirectory)
        // Without the directory the files would only be kept in memory.
        if (try? FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)) != nil {
            config.fileDirectory = fileDirectory
        }
        beep = audio ? Self.encodeBeep() : []
        config.audio = !beep.isEmpty
        host = try GDPTestHost(config)
        self.stream = stream
    }

    deinit {
        timer?.cancel()
        audioTimer?.cancel()
    }

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

            guard !beep.isEmpty else { return }
            let a = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            a.schedule(deadline: .now(), repeating: .milliseconds(OpusFormat.session.frameMilliseconds), leeway: .nanoseconds(0))
            a.setEventHandler { [weak self] in self?.audioTick() }
            audioTimer = a
            a.resume()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            audioTimer?.cancel()
            audioTimer = nil
        }
    }

    private func audioTick() {
        host.sendAudio(opus: beep[beepIndex])
        beepIndex = (beepIndex + 1) % beep.count
    }

    /// One second of 10 ms packets: 880 Hz for 0.1 s with 5 ms fades, then
    /// silence. Empty if the system encoder isn't there.
    static func encodeBeep() -> [[UInt8]] {
        let format = OpusFormat.session
        guard let encoder = OpusEncoder(format) else { return [] }
        let n = format.framesPerPacket, rate = Double(format.sampleRate)
        let beepFrames = Int(0.1 * rate), fade = Int(0.005 * rate)
        var packets: [[UInt8]] = []
        for p in 0..<(1000 / format.frameMilliseconds) {
            var samples = [Float](repeating: 0, count: n * format.channels)
            for i in 0..<n {
                let t = p * n + i
                guard t < beepFrames else { break }
                let gain = Float(min(1, Double(min(t, beepFrames - t)) / Double(fade)))
                let v = 0.2 * gain * Float(sin(2 * .pi * 880 * Double(t) / rate))
                for c in 0..<format.channels { samples[i * format.channels + c] = v }
            }
            packets += encoder.encode(samples)
        }
        return packets.count == 1000 / format.frameMilliseconds ? packets : []
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
