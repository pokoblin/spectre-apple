import Foundation
import GDPCore

/// A minimal GDP session host on 127.0.0.1 (static token, gdp-spec.md
/// §6.11), for tests and the app's loopback demo. It accepts one viewer,
/// streams the frames it is given as video datagrams and records what the
/// client sends. Thread-safe.
public final class GDPTestHost: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var token = "test-token"
        public var codecs = ["h264", "h265"]
        public var capabilities: [String] = []
        public var width: UInt32 = 1920
        public var height: UInt32 = 1080
        public var audio = false
        /// Accept with this codec whatever was offered (a misbehaving host).
        public var forceCodec: String?
        /// Close with this §12 code after a good hello.
        public var refuseCode: UInt64 = 0
        public var rejectReason: String?
        public var pingBeforeAccept = false
        public var firstFrameID: UInt32 = 0
        /// Keep a pointer like a host does and, after input that moved it
        /// relatively, report it with CursorPosition (gdp-spec.md §7.4).
        public var simulatePointer = false
        public var scratchDirectory = FileManager.default.temporaryDirectory

        public init() {}
    }

    public struct Observed: Sendable {
        public var connected, helloReceived: Bool
        public var token: String
        public var codecs, capabilities, decoders: [String]
        public var takeOver, viaGateway: Bool
        public var networkProfile: Int32
        public var requestedWidth, requestedHeight: UInt32
        public var accepted: Bool
        public var acceptedCodec: String
        public var closed: Bool
        public var closeCode: UInt64

        public var statsReports: UInt32
        public var lastRTT: UInt32
        public var lastHasStream: Bool
        public var lastHighestFrameID: UInt32
        public var lastLossBitmap: UInt64
        public var lastDecodeMicroseconds, lastPresentMicroseconds, lastIntervalMicroseconds: UInt32
        public var lastBytesReceived: UInt64
        public var lastDelayMin, lastDelayAvg: Int32
        public var lastDelaySamples, lastTrains, lastTrainDatagrams, lastTrainBytes: UInt32
        public var bytesReported: UInt64
        /// Every frame any StatsReport marked lost (the first 64).
        public var lostFrameIDs: [UInt32]

        public var keyframeRequests, resolutionRequests: UInt32
        public var lastResolution: (width: UInt32, height: UInt32)
        public var logoutRequested: Bool
        public var pongs: UInt32
        public var lastPongNonce: UInt64
        public var diagnosticsReportLength: Int

        public var keyEvents, lastKeyUsage: UInt32
        public var lastKeyPressed: Bool
        public var pointerMotions: UInt32
        public var lastMotion: (x: Double, y: Double, absolute: Bool)
        public var buttonEvents, lastButton: UInt32
        public var lastButtonPressed: Bool
        public var axisVerticalSum, axisHorizontalSum: Double
        public var touches: UInt32
        public var inputBeforeAccept: Bool
        /// How many events ``GDPTestHost/inputEvents(from:)`` has (at most 8192).
        public var inputEventCount: Int
        /// The simulated pointer (``Configuration/simulatePointer``), 0...1.
        public var pointer: (x: Double, y: Double)
        public var cursorPositionsSent: UInt32
        /// The accepted viewer's connection ended: its close code and the transport's reason.
        public var viewerClosed: Bool
        public var viewerCloseCode: UInt64
        public var viewerCloseReason: String

        public var framesSent, nextFrameID: UInt32
        public var maxDatagramSize: UInt16
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private let handle: OpaquePointer
    public let port: UInt16
    public let certificate: CertificateFingerprint

    public init(_ config: Configuration = Configuration()) throws(Failure) {
        var error = [CChar](repeating: 0, count: 256)
        let h: OpaquePointer? = withCStrings(config.codecs) { codecs in
            withCStrings(config.capabilities) { caps in
                config.scratchDirectory.path(percentEncoded: false).withCString { dir in
                    config.token.withCString { token in
                        withOptionalCString(config.forceCodec) { force in
                            withOptionalCString(config.rejectReason) { reject in
                                var c = gdpc_test_host_config()
                                c.scratch_dir = dir
                                c.token = token
                                c.codecs = codecs.baseAddress
                                c.codec_count = codecs.count
                                c.capabilities = caps.baseAddress
                                c.capability_count = caps.count
                                c.width = config.width
                                c.height = config.height
                                c.audio = config.audio
                                c.force_codec = force
                                c.refuse_code = config.refuseCode
                                c.reject_reason = reject
                                c.ping_before_accept = config.pingBeforeAccept
                                c.first_frame_id = config.firstFrameID
                                c.simulate_pointer = config.simulatePointer
                                return gdpc_test_host_create(&c, &error, error.count)
                            }
                        }
                    }
                }
            }
        }
        guard let h else { throw Failure(description: string(fromNulTerminated: error)) }
        handle = h
        port = gdpc_test_host_port(h)
        var hex = [CChar](repeating: 0, count: Int(GDPC_SHA256_HEX_LEN) + 1)
        gdpc_test_host_cert_sha256(h, &hex)
        certificate = CertificateFingerprint(hex: string(fromNulTerminated: hex))!
    }

    deinit { gdpc_test_host_destroy(handle) }

    /// A session configuration that connects to this host.
    public func sessionConfiguration(codecs: [String] = ["h264"], token: String? = nil) -> GDPSession.Configuration {
        GDPSession.Configuration(host: "127.0.0.1", port: port, token: token ?? "test-token", certificate: certificate,
                                 codecs: codecs)
    }

    /// Sends one coded frame as video datagrams with the next frame_id.
    public func sendVideoFrame(_ data: some Collection<UInt8>, keyframe: Bool, dropSlices: [UInt16] = [],
                               maxPayload: Int = 0) {
        data.withContiguousBytes { buf in
            dropSlices.withUnsafeBufferPointer { drop in
                gdpc_test_host_send_video_frame(handle, buf.baseAddress, buf.count, keyframe, drop.baseAddress, drop.count,
                                                maxPayload)
            }
        }
    }

    public func sendAudioPacket(sequence: UInt16, pts: UInt32, opus: [UInt8]) {
        opus.withUnsafeBufferPointer { gdpc_test_host_send_audio_packet(handle, sequence, pts, $0.baseAddress, $0.count) }
    }

    public func sendPing(nonce: UInt64) { gdpc_test_host_send_ping(handle, nonce) }

    public func sendCursorShape(width: UInt32, height: UInt32, hotspotX: UInt32, hotspotY: UInt32, argb: [UInt8]) {
        argb.withUnsafeBufferPointer {
            gdpc_test_host_send_cursor_shape(handle, width, height, hotspotX, hotspotY, $0.baseAddress, $0.count)
        }
    }

    public func sendCursorPosition(x: Double, y: Double) { gdpc_test_host_send_cursor_position(handle, x, y) }
    public func sendDisplaysChanged(width: UInt32, height: UInt32) {
        gdpc_test_host_send_displays_changed(handle, width, height)
    }
    public func sendNetworkProfile(_ profile: GDPSession.NetworkProfile) {
        gdpc_test_host_send_network_profile(handle, profile.rawValue)
    }
    public func sendGatewayPath(upstreamRTTMicroseconds: UInt32) {
        gdpc_test_host_send_gateway_path(handle, upstreamRTTMicroseconds)
    }
    public func sendDiagnosticsRequest() { gdpc_test_host_send_diagnostics_request(handle) }
    public func close(code: UInt64) { gdpc_test_host_close(handle, code) }

    /// Whether a keyframe was asked for (KeyframeRequest, or a newly
    /// reported loss) since the last call: the cue to send one.
    public func takeKeyframeWanted() -> Bool { gdpc_test_host_take_keyframe_wanted(handle) }

    /// One input event as the host received it (gdp-spec.md §8.2, §8.3).
    public enum InputEvent: Sendable, Equatable {
        case key(usage: UInt32, pressed: Bool)
        case motion(x: Double, y: Double, absolute: Bool)
        case button(UInt32, pressed: Bool)
        case axis(horizontal: Double, vertical: Double)
        case touch(id: UInt32, phase: Int32, x: Double, y: Double)
    }

    /// The input events received so far (the first 8192), oldest first, from index `first`.
    public func inputEvents(from first: Int = 0) -> [InputEvent] {
        var out: [InputEvent] = []
        var buffer = [gdpc_test_input_event](repeating: gdpc_test_input_event(), count: 256)
        var next = first
        while true {
            let n = buffer.withUnsafeMutableBufferPointer {
                gdpc_test_host_input_events(handle, next, $0.baseAddress, $0.count)
            }
            for e in buffer.prefix(n) {
                switch e.kind {
                case Int32(GDPC_TEST_INPUT_KEY.rawValue): out.append(.key(usage: e.code, pressed: e.pressed))
                case Int32(GDPC_TEST_INPUT_MOTION.rawValue): out.append(.motion(x: e.x, y: e.y, absolute: e.absolute))
                case Int32(GDPC_TEST_INPUT_BUTTON.rawValue): out.append(.button(e.code, pressed: e.pressed))
                case Int32(GDPC_TEST_INPUT_AXIS.rawValue): out.append(.axis(horizontal: e.x, vertical: e.y))
                default: out.append(.touch(id: e.code, phase: e.phase, x: e.x, y: e.y))
                }
            }
            next += n
            if n < buffer.count { return out }
        }
    }

    public var observed: Observed {
        var o = gdpc_test_host_observed()
        gdpc_test_host_get_observed(handle, &o)
        func s<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        func list<T>(_ tuple: T) -> [String] {
            let v = s(tuple)
            return v.isEmpty ? [] : v.split(separator: ",").map(String.init)
        }
        let lost = withUnsafeBytes(of: o.lost_frame_ids) { Array($0.bindMemory(to: UInt32.self)) }
        return Observed(
            connected: o.connected, helloReceived: o.hello_received, token: s(o.token), codecs: list(o.codecs),
            capabilities: list(o.capabilities), decoders: list(o.decoders), takeOver: o.take_over,
            viaGateway: o.via_gateway, networkProfile: o.network_profile, requestedWidth: o.requested_width,
            requestedHeight: o.requested_height, accepted: o.accepted, acceptedCodec: s(o.accepted_codec),
            closed: o.closed, closeCode: o.close_code, statsReports: o.stats_reports, lastRTT: o.last_rtt_us,
            lastHasStream: o.last_has_stream, lastHighestFrameID: o.last_highest_frame_id,
            lastLossBitmap: o.last_loss_bitmap, lastDecodeMicroseconds: o.last_decode_us,
            lastPresentMicroseconds: o.last_present_us, lastIntervalMicroseconds: o.last_interval_us,
            lastBytesReceived: o.last_bytes_received, lastDelayMin: o.last_delay_min_us,
            lastDelayAvg: o.last_delay_avg_us, lastDelaySamples: o.last_delay_samples, lastTrains: o.last_trains,
            lastTrainDatagrams: o.last_train_datagrams, lastTrainBytes: o.last_train_bytes,
            bytesReported: o.bytes_reported, lostFrameIDs: Array(lost.prefix(Int(min(o.lost_frame_count, 64)))),
            keyframeRequests: o.keyframe_requests, resolutionRequests: o.resolution_requests,
            lastResolution: (o.last_resolution_width, o.last_resolution_height), logoutRequested: o.logout_requested,
            pongs: o.pongs, lastPongNonce: o.last_pong_nonce, diagnosticsReportLength: o.diagnostics_report_len,
            keyEvents: o.key_events, lastKeyUsage: o.last_key_usage, lastKeyPressed: o.last_key_pressed,
            pointerMotions: o.pointer_motions, lastMotion: (o.last_motion_x, o.last_motion_y, o.last_motion_absolute),
            buttonEvents: o.button_events, lastButton: o.last_button, lastButtonPressed: o.last_button_pressed,
            axisVerticalSum: o.axis_vertical_sum, axisHorizontalSum: o.axis_horizontal_sum, touches: o.touches,
            inputBeforeAccept: o.input_before_accept, inputEventCount: Int(o.input_event_count),
            pointer: (o.pointer_x, o.pointer_y), cursorPositionsSent: o.cursor_positions_sent,
            viewerClosed: o.viewer_closed, viewerCloseCode: o.viewer_close_code,
            viewerCloseReason: s(o.viewer_close_reason),
            framesSent: o.frames_sent, nextFrameID: o.next_frame_id, maxDatagramSize: o.max_datagram_size)
    }
}

func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
