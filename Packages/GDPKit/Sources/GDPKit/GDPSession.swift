import Dispatch
import Foundation
import GDPCore

/// A GDP session connection (gdp-spec.md §6-§11) over libgdp, driven from
/// one serial queue: ``queue`` pumps the transport whenever it has work,
/// sends a StatsReport every 250 ms, and runs every handler. Commands may be
/// called from any thread; they hop onto the queue.
public final class GDPSession: @unchecked Sendable {
    public enum NetworkProfile: Int32, Sendable {
        case auto = 0, lan, internet, mobile
    }

    public struct DisplayRequest: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public var refreshMillihertz: UInt32
        public var scale: Double

        public init(width: UInt32, height: UInt32, refreshMillihertz: UInt32 = 0, scale: Double = 0) {
            self.width = width
            self.height = height
            self.refreshMillihertz = refreshMillihertz
            self.scale = scale
        }
    }

    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var token: String
        /// The only certificate the host may present (`Redirect.cert_sha256`, §2.3).
        public var certificate: CertificateFingerprint
        /// Video codec tokens this client decodes, most preferred first (§6.6).
        public var codecs: [String]
        /// Capabilities this client implements (§6.7).
        public var capabilities: [String] = []
        /// Informational decoder backends, e.g. `videotoolbox`.
        public var decoders: [String] = []
        public var display: DisplayRequest?
        public var takeOver = false
        public var networkProfile = NetworkProfile.auto
        public var dropUntilKeyframeAfterLoss = true

        public init(host: String, port: UInt16, token: String, certificate: CertificateFingerprint, codecs: [String]) {
            self.host = host
            self.port = port
            self.token = token
            self.certificate = certificate
            self.codecs = codecs
        }
    }

    /// An output (§7.2). Colour fields are session.proto enum values; 0 = the codec's default (§7.3).
    public struct Output: Sendable, Equatable {
        public var streamID: UInt32
        public var width: UInt32
        public var height: UInt32
        public var refreshMillihertz: UInt32
        public var scale: Double
        public var matrix: Int32
        public var range: Int32
        public var primaries: Int32
        public var transfer: Int32
        public var bitDepth: UInt32
        public var chroma: Int32

        init(_ o: gdpc_output) {
            streamID = o.stream_id
            width = o.width
            height = o.height
            refreshMillihertz = o.refresh_mhz
            scale = o.scale
            matrix = o.matrix
            range = o.range
            primaries = o.primaries
            transfer = o.transfer
            bitDepth = o.bit_depth
            chroma = o.chroma
        }
    }

    public struct AudioConfig: Sendable, Equatable {
        public var codec: String
        public var sampleRate: UInt32
        public var channels: UInt32
        public var frameMilliseconds: UInt32
    }

    public struct Accept: Sendable {
        public var codec: String
        public var outputs: [Output]
        public var bitrateCeiling: UInt32
        public var audio: AudioConfig?
        public var capabilities: [String]
        public var networkProfile: NetworkProfile
        public var viaGateway: Bool
        public var encoder: String
        public var hostUser: String
        public var hostName: String
    }

    /// How the connection ended.
    public struct Ending: Error, Sendable, CustomStringConvertible {
        /// The §12 code (the host's, or the one this client closed with); 0 for a plain close.
        public let code: UInt64
        public let reason: String
        public let certificateRejected: Bool

        /// §12 groups: 1x protocol, 2x access, 3x availability, 4x an ordinary end.
        public var isOrdinaryEnd: Bool { code == 0 || code / 10 == 4 }
        public var description: String {
            code == 0 ? (reason.isEmpty ? "closed" : reason) : "\(reason) (code \(code))"
        }
    }

    /// A reassembled video frame; `data` is valid only during the handler.
    public struct VideoFrame {
        public let streamID: UInt8
        public let frameID: UInt32
        public let keyframe: Bool
        public let pts: UInt32
        public let data: UnsafeRawBufferPointer
    }

    public struct CursorShape: Sendable, Equatable {
        public let width: UInt32
        public let height: UInt32
        public let hotspotX: UInt32
        public let hotspotY: UInt32
        /// BGRA in memory, premultiplied; empty with 0×0 for "no cursor".
        public let bgra: [UInt8]

        public init(width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32, bgra: [UInt8]) {
            self.width = width
            self.height = height
            self.hotspotX = hotspotX
            self.hotspotY = hotspotY
            self.bgra = bgra
        }
    }

    public struct LinkStats: Sendable {
        public var rttMicroseconds: UInt32
        public var upstreamRTTMicroseconds: UInt32
        public var pathMTU: UInt16
        public var maxDatagramSize: UInt16
        public var statsReportsSent: UInt32
        public var framesDelivered: UInt64
        public var framesDropped: UInt64
        public var highestFrameID: UInt32?
        public var lossBitmap: UInt64
        public var windowSpan: UInt32
        public var delayMinMicroseconds: Int32
        public var delayAvgMicroseconds: Int32
        public var delaySamples: UInt32
        public var bytesLastWindow: UInt64
        public var lastWindowMicroseconds: UInt32

        /// Frames lost of the trailing window (up to 64).
        public var recentLosses: Int { lossBitmap.nonzeroBitCount }
        public var megabitsPerSecond: Double {
            lastWindowMicroseconds > 0 ? Double(bytesLastWindow * 8) / Double(lastWindowMicroseconds) : 0
        }
    }

    /// Everything the session reports, all called on ``queue``.
    /// Called on the queue, never the main thread: hop to the main actor yourself.
    public struct Handlers: Sendable {
        public var accepted: (@Sendable (Accept) -> Void)?
        public var closed: (@Sendable (Ending) -> Void)?
        public var displaysChanged: (@Sendable ([Output]) -> Void)?
        /// Return false if the frame can't be used now: it counts as lost (§7.5).
        public var videoFrame: (@Sendable (VideoFrame) -> Bool)?
        public var audioPacket: (@Sendable (_ sequence: UInt16, _ pts: UInt32, _ opus: UnsafeRawBufferPointer) -> Void)?
        public var cursorShape: (@Sendable (CursorShape) -> Void)?
        public var cursorPosition: (@Sendable (_ x: Double, _ y: Double) -> Void)?
        public var networkProfileChanged: (@Sendable (NetworkProfile) -> Void)?
        /// Answer with ``GDPSession/sendDiagnosticsReport(_:)``.
        public var diagnosticsRequested: (@Sendable () -> Void)?

        public init() {}
    }

    public struct ConnectError: Error, CustomStringConvertible {
        public let description: String
    }

    public static let statsInterval: DispatchTimeInterval = .milliseconds(250) // §7.5

    public let queue: DispatchQueue
    private let handlers: Handlers
    private let queueKey = DispatchSpecificKey<Void>()
    // Touched only on `queue`.
    private var handle: OpaquePointer?
    private var readSource: DispatchSourceRead?
    private var statsTimer: DispatchSourceTimer?
    private var ended = false
    /// Signalled once the connection has closed (the close callback ran).
    private let closedSignal = DispatchSemaphore(value: 0)

    public init(queue: DispatchQueue = DispatchQueue(label: "spectre.session", qos: .userInteractive),
                handlers: Handlers) {
        self.queue = queue
        self.handlers = handlers
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    /// Starts connecting; the outcome arrives through ``Handlers/accepted`` or ``Handlers/closed``.
    public func connect(_ config: Configuration) throws(ConnectError) {
        let error: String? = onQueue {
            guard handle == nil else { return "already connected" }
            var callbacks = gdpc_session_callbacks()
            callbacks.ctx = Unmanaged.passUnretained(self).toOpaque()
            callbacks.accepted = { ctx, a in GDPSession.from(ctx).onAccepted(a!.pointee) }
            callbacks.closed = { ctx, code, reason, cert in
                GDPSession.from(ctx).onClosed(Ending(code: code, reason: String(cString: reason!), certificateRejected: cert))
            }
            callbacks.displays_changed = { ctx, outputs, count in
                let list = UnsafeBufferPointer(start: outputs, count: count).map(Output.init)
                GDPSession.from(ctx).handlers.displaysChanged?(list)
            }
            callbacks.video_frame = { ctx, f in
                let f = f!.pointee
                let frame = VideoFrame(streamID: f.stream_id, frameID: f.frame_id, keyframe: f.keyframe, pts: f.pts,
                                       data: UnsafeRawBufferPointer(start: f.data, count: f.len))
                return GDPSession.from(ctx).handlers.videoFrame?(frame) ?? false
            }
            callbacks.audio_packet = { ctx, seq, pts, data, len in
                GDPSession.from(ctx).handlers.audioPacket?(seq, pts, UnsafeRawBufferPointer(start: data, count: len))
            }
            callbacks.cursor_shape = { ctx, w, h, hx, hy, bgra in
                let bytes = bgra.map { Array(UnsafeBufferPointer(start: $0, count: Int(w) * Int(h) * 4)) } ?? []
                GDPSession.from(ctx).handlers.cursorShape?(CursorShape(width: w, height: h, hotspotX: hx, hotspotY: hy,
                                                                        bgra: bytes))
            }
            callbacks.cursor_position = { ctx, x, y in GDPSession.from(ctx).handlers.cursorPosition?(x, y) }
            callbacks.network_profile_changed = { ctx, p in
                GDPSession.from(ctx).handlers.networkProfileChanged?(NetworkProfile(rawValue: p) ?? .auto)
            }
            callbacks.diagnostics_requested = { ctx in GDPSession.from(ctx).handlers.diagnosticsRequested?() }

            let h = gdpc_session_create(&callbacks)!
            var errorBuffer = [CChar](repeating: 0, count: 256)
            let ok = withCStrings(config.codecs) { codecs in
                withCStrings(config.capabilities) { caps in
                    withCStrings(config.decoders) { decoders in
                        config.host.withCString { host in
                            config.token.withCString { token in
                                config.certificate.hex.withCString { cert in
                                    var c = gdpc_session_config()
                                    c.host = host
                                    c.port = config.port
                                    c.token = token
                                    c.cert_sha256 = cert
                                    c.codecs = codecs.baseAddress
                                    c.codec_count = codecs.count
                                    c.capabilities = caps.baseAddress
                                    c.capability_count = caps.count
                                    c.decoders = decoders.baseAddress
                                    c.decoder_count = decoders.count
                                    c.display_width = config.display?.width ?? 0
                                    c.display_height = config.display?.height ?? 0
                                    c.display_refresh_mhz = config.display?.refreshMillihertz ?? 0
                                    c.display_scale = config.display?.scale ?? 0
                                    c.take_over = config.takeOver
                                    c.network_profile = config.networkProfile.rawValue
                                    c.drop_until_keyframe_after_loss = config.dropUntilKeyframeAfterLoss
                                    return gdpc_session_connect(h, &c, &errorBuffer, errorBuffer.count)
                                }
                            }
                        }
                    }
                }
            }
            guard ok else {
                gdpc_session_destroy(h)
                return string(fromNulTerminated: errorBuffer)
            }
            handle = h
            startPumping(h)
            return nil
        }
        if let error { throw ConnectError(description: error) }
    }

    /// Detach: close with code 0; the desktop session keeps running (§7.10).
    /// Closes the connection (code 0). What was sent just before (the key
    /// releases §8.2 asks for before detaching) goes out first: libgdp only
    /// buffers stream data until its network thread flushes, and a close
    /// posted right behind it would be written first and discard it. So
    /// the close waits ``flushDelay()``.
    public func close() {
        queue.async { [self] in
            guard handle != nil, !ended else { return }
            queue.asyncAfter(deadline: .now() + flushDelay()) { [self] in
                if let handle, !ended { gdpc_session_close(handle) }
            }
        }
    }

    /// How long a close waits for stream data queued before it: two round
    /// trips (enough for it to be sent, and on most links acknowledged),
    /// within 20-250 ms. Session queue only.
    private func flushDelay() -> TimeInterval {
        var rtt: UInt32 = 0
        if let handle {
            var s = gdpc_session_link_stats()
            gdpc_session_get_link_stats(handle, &s)
            rtt = s.rtt_us
        }
        return min(max(2 * Double(rtt) / 1e6, 0.02), 0.25)
    }

    /// Closes (as ``close()``, after the flush delay) and waits, at most
    /// `timeout`, for the close to go out: for an
    /// app about to exit, which would otherwise take its CONNECTION_CLOSE
    /// with it and leave the host to notice through its idle timeout.
    /// Everything queued before (key releases) is sent first. Returns
    /// whether the connection closed in time. Not from the session queue.
    @discardableResult
    public func closeAndWait(timeout: TimeInterval = 0.5) -> Bool {
        precondition(DispatchQueue.getSpecific(key: queueKey) == nil, "closeAndWait from the session queue")
        let alreadyEnded: Bool = queue.sync { handle == nil || ended }
        close()
        if alreadyEnded { return true }
        guard closedSignal.wait(timeout: .now() + timeout) == .success else { return false }
        closedSignal.signal() // for anyone else waiting
        return true
    }

    public func recordFrameTiming(decodeMicroseconds: UInt32, presentMicroseconds: UInt32) {
        async { gdpc_session_record_frame_timing($0, decodeMicroseconds, presentMicroseconds) }
    }

    /// A frame the video handler accepted turned out unusable (the decoder rejected it).
    public func markFrameDiscarded(streamID: UInt8, frameID: UInt32) {
        async { gdpc_session_mark_frame_discarded($0, streamID, frameID) }
    }

    public func requestKeyframe(streamID: UInt32 = 0) { async { gdpc_session_request_keyframe($0, streamID) } }

    public func requestResolution(streamID: UInt32 = 0, width: UInt32, height: UInt32) {
        async { gdpc_session_request_resolution($0, streamID, width, height) }
    }

    /// Ends the desktop session itself; completion is a close with `SESSION_ENDED` (§7.10).
    public func sendLogout() { async { gdpc_session_send_logout($0) } }

    public func sendDiagnosticsReport(_ text: Data) {
        async { h in text.withUnsafeBytes { gdpc_session_send_diagnostics_report(h, $0.baseAddress, $0.count) } }
    }

    // Input (§8.2, §8.3).
    public func sendKey(hidUsage: UInt32, pressed: Bool) { async { gdpc_session_send_key($0, hidUsage, pressed) } }
    public func sendPointerMotion(dx: Double, dy: Double, absolute: Bool) {
        async { gdpc_session_send_pointer_motion($0, dx, dy, absolute) }
    }
    public func sendPointerButton(_ button: UInt32, pressed: Bool) {
        async { gdpc_session_send_pointer_button($0, button, pressed) }
    }
    public func sendPointerAxis(horizontal: Double, vertical: Double) {
        async { gdpc_session_send_pointer_axis($0, horizontal, vertical) }
    }
    public enum TouchPhase: Int32, Sendable { case down = 1, move, up, cancel }
    public func sendTouch(id: UInt32, phase: TouchPhase, x: Double, y: Double) {
        async { gdpc_session_send_touch($0, id, phase.rawValue, x, y) }
    }

    /// A snapshot for the statistics overlay.
    public func linkStats() -> LinkStats? {
        onQueue {
            guard let handle else { return nil }
            var s = gdpc_session_link_stats()
            gdpc_session_get_link_stats(handle, &s)
            return LinkStats(rttMicroseconds: s.rtt_us, upstreamRTTMicroseconds: s.upstream_rtt_us, pathMTU: s.path_mtu,
                             maxDatagramSize: s.max_datagram_size, statsReportsSent: s.stats_reports_sent,
                             framesDelivered: s.frames_delivered, framesDropped: s.frames_dropped,
                             highestFrameID: s.has_frames ? s.highest_frame_id : nil, lossBitmap: s.loss_bitmap,
                             windowSpan: s.window_span, delayMinMicroseconds: s.delay_min_us,
                             delayAvgMicroseconds: s.delay_avg_us, delaySamples: s.delay_samples,
                             bytesLastWindow: s.bytes_last_window, lastWindowMicroseconds: s.last_window_us)
        }
    }

    // MARK: - Internals

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> GDPSession {
        Unmanaged<GDPSession>.fromOpaque(ctx!).takeUnretainedValue()
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? body() : queue.sync(execute: body)
    }

    private func async(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        queue.async { [self] in
            if let handle, !ended { body(handle) }
        }
    }

    private func startPumping(_ h: OpaquePointer) {
        let read = DispatchSource.makeReadSource(fileDescriptor: gdpc_session_notify_fd(h), queue: queue)
        read.setEventHandler { [weak self] in self?.pump() }
        read.resume()
        readSource = read
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, let handle = self.handle, !self.ended else { return }
            gdpc_session_dispatch(handle)
            if !self.ended { gdpc_session_send_stats_report(handle) }
        }
        timer.resume()
        statsTimer = timer
    }

    private func pump() {
        guard let handle, !ended else { return }
        gdpc_session_dispatch(handle)
    }

    private func onAccepted(_ a: gdpc_session_accept) {
        let accept = Accept(
            codec: String(cString: a.codec),
            outputs: UnsafeBufferPointer(start: a.outputs, count: a.output_count).map(Output.init),
            bitrateCeiling: a.bitrate_ceiling_bps,
            audio: a.has_audio ? AudioConfig(codec: String(cString: a.audio_codec), sampleRate: a.audio_sample_rate_hz,
                                             channels: a.audio_channels, frameMilliseconds: a.audio_frame_ms) : nil,
            capabilities: UnsafeBufferPointer(start: a.capabilities, count: a.capability_count).map { String(cString: $0!) },
            networkProfile: NetworkProfile(rawValue: a.network_profile) ?? .auto,
            viaGateway: a.via_gateway,
            encoder: String(cString: a.encoder),
            hostUser: String(cString: a.host_user),
            hostName: String(cString: a.host_name))
        handlers.accepted?(accept)
    }

    private func onClosed(_ ending: Ending) {
        ended = true
        // Stop pumping; the handle stays until teardown (we are inside its dispatch()).
        readSource?.cancel()
        statsTimer?.cancel()
        handlers.closed?(ending)
        closedSignal.signal()
    }

    private func teardown() {
        ended = true
        readSource?.cancel()
        statsTimer?.cancel()
        readSource = nil
        statsTimer = nil
        if let handle {
            gdpc_session_destroy(handle)
            self.handle = nil
        }
    }
}

/// Calls `body` with a C array of C strings for `strings`, valid for the call.
func withCStrings<R>(_ strings: [String], _ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> R) -> R {
    let copies = strings.map { UnsafePointer(strdup($0)) }
    defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
    return copies.withUnsafeBufferPointer(body)
}
