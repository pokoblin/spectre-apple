import Foundation
import GDPCore

/// A minimal GDP session host on 127.0.0.1 (static token, gdp-spec.md
/// §6.11), for tests and the app's loopback source. It accepts one viewer,
/// streams the frames it is given as video datagrams and records what the
/// client sends. Thread-safe.
public final class GDPTestHost: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var token = "test-token"
        public var codecs = ["h264", "h265"]
        public var capabilities: [String] = []
        public var width: UInt32 = 1920
        public var height: UInt32 = 1080
        /// Advertise `audioFormat` in SessionAccept.audio (gdp-spec.md §6.8).
        public var audio = false
        public var audioFormat = GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 2, frameMilliseconds: 10)
        /// SessionAccept.microphone, sent when `microphone` is negotiated: put
        /// it in `capabilities` to support it (gdp-spec.md §6.8, §10.1).
        public var microphoneFormat = GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 1,
                                                             frameMilliseconds: 10)
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
        /// The host's clipboard text to start with, sent right after
        /// SessionAccept when `clipboard` is in effect (§7.9). Text the
        /// viewer sends replaces it.
        public var clipboard: String?
        /// File transfer (§7.12), with ``GDPSession/Capability/file`` among
        /// ``capabilities``: files the viewer sends are kept in memory
        /// (``GDPTestHost/receivedFiles``). For tests: refuse every offer
        /// with this error, fail once this many bytes of a file arrived (0:
        /// never), or never answer an offer at all.
        public var fileRefusal: GDPSession.FileError?
        public var fileFailAfter: UInt64 = 0
        public var fileIgnoreOffers = false
        /// Write received files here instead of keeping them in memory
        /// (never over an existing file); ``ReceivedFile/path`` says where.
        public var fileDirectory: URL?
        /// Files "copied" on the host (§7.12): listed right after SessionAccept
        /// when `file` is in effect, and sent when the viewer asks.
        public var hostFiles: [URL] = []
        /// With `file-clipboard`: how many bytes of copied folders' contents
        /// the list carries (0: the spec's 512 KiB); and whether to ignore
        /// ranges, like a host from before them.
        public var fileListBudget = 0
        public var fileIgnoreRanges = false
        /// How many of its latest lists it answers from (0: only the latest).
        public var fileKeptLists: UInt32 = 0
        public var scratchDirectory = FileManager.default.temporaryDirectory

        public init() {}
    }

    public struct Observed: Sendable {
        public var connected, helloReceived: Bool
        public var token: String
        public var codecs, capabilities, decoders: [String]
        public var clientName: String
        public var takeOver, viaGateway: Bool
        public var networkProfile: Int32
        public var requestedWidth, requestedHeight: UInt32
        public var requestedScale: Double
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
        public var lastResolutionScale: Double
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
        /// ClipboardData messages from the viewer, and the MIME type of the
        /// latest (its data: ``GDPTestHost/lastClipboard``).
        public var clipboardMessages: UInt32
        public var lastClipboardMime: String
        /// RefinePause messages (§7.8), and the latest one's state.
        public var refinePauses: UInt32
        public var refinePaused: Bool
        /// The accepted viewer's connection ended: its close code and the transport's reason.
        public var viewerClosed: Bool
        public var viewerCloseCode: UInt64
        public var viewerCloseReason: String

        public var framesSent, nextFrameID: UInt32
        public var maxDatagramSize: UInt16

        /// Microphone datagrams from the viewer under `microphone` (§10.1),
        /// their bytes, and those dropped (no capability, or not the viewer).
        public var microphonePackets: UInt32
        public var microphoneBytes: UInt64
        public var microphoneDropped: UInt32

        /// File streams from the viewer (§7.12), by how each ended, those
        /// still open, and the latest offered name.
        public var filesOffered, filesSaved, filesRefused, filesFailed, filesCancelled: UInt32
        public var fileStreamsOpen: UInt32
        public var lastFileName: String
        /// Copied files (§7.12): lists sent and the latest one's id, requests,
        /// files sent whole, requests refused.
        public var fileListsSent: UInt32
        public var fileListID: UInt64
        public var filesRequested, filesServed, fileRequestsRefused: UInt32
        /// Folder listings asked for (file-clipboard), and refused.
        public var listingsRequested, listingsRefused: UInt32
        /// FileLists from the viewer, and the answering streams it opened.
        public var clientFileLists, fetchAnswers: UInt32
        /// FileShare messages from the viewer.
        public var shareMessages: UInt32
    }

    /// A file the host saved (§7.12).
    public struct ReceivedFile: Sendable, Equatable {
        /// As offered, and as the viewer was told it was saved.
        public var name, savedName: String
        public var modifiedUnixMilliseconds: Int64
        public var size: UInt64
        /// The contents, kept in memory without ``Configuration/fileDirectory``.
        public var data: [UInt8]
        /// Where it was written, with ``Configuration/fileDirectory``.
        public var path: String?
    }

    /// Every file saved so far, in order.
    public var receivedFiles: [ReceivedFile] {
        var out: [ReceivedFile] = []
        var index = 0
        while true {
            var info = gdpc_test_host_file()
            guard gdpc_test_host_received_file(handle, index, &info, nil, 0) else { return out }
            func s<T>(_ tuple: T) -> String {
                withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
            let path = s(info.path)
            var data = [UInt8](repeating: 0, count: path.isEmpty ? Int(info.size) : 0)
            _ = data.withUnsafeMutableBufferPointer {
                gdpc_test_host_received_file(handle, index, nil, $0.baseAddress, $0.count)
            }
            out.append(ReceivedFile(name: s(info.name), savedName: s(info.saved_name),
                                    modifiedUnixMilliseconds: info.modified_unix_ms, size: info.size, data: data,
                                    path: path.isEmpty ? nil : path))
            index += 1
        }
    }

    public struct MicrophonePacket: Sendable, Equatable {
        public var sequence: UInt16
        public var pts: UInt32
        public var opus: [UInt8]
    }

    /// The most recent microphone packet, if any (also after the first minute).
    public var latestMicrophonePacket: MicrophonePacket? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var seq: UInt16 = 0, pts: UInt32 = 0, len = 0
        let found = buffer.withUnsafeMutableBufferPointer {
            gdpc_test_host_latest_microphone_packet(handle, &seq, &pts, $0.baseAddress, $0.count, &len)
        }
        return found ? MicrophonePacket(sequence: seq, pts: pts, opus: Array(buffer.prefix(min(len, buffer.count)))) : nil
    }

    /// The microphone packets received from index `first` on, in arrival
    /// order (the first minute's are kept).
    public func microphonePackets(from first: Int = 0) -> [MicrophonePacket] {
        var out: [MicrophonePacket] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var index = first
        while true {
            var seq: UInt16 = 0, pts: UInt32 = 0, len = 0
            let found = buffer.withUnsafeMutableBufferPointer {
                gdpc_test_host_microphone_packet(handle, index, &seq, &pts, $0.baseAddress, $0.count, &len)
            }
            guard found else { return out }
            out.append(MicrophonePacket(sequence: seq, pts: pts, opus: Array(buffer.prefix(min(len, buffer.count)))))
            index += 1
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private let handle: OpaquePointer
    public let port: UInt16
    public let certificate: CertificateFingerprint

    public init(_ config: Configuration = Configuration()) throws(Failure) {
        _ = GDP.ignoreBrokenPipes
        var error = [CChar](repeating: 0, count: 256)
        let hostFiles = config.hostFiles.map { $0.path(percentEncoded: false) }
        let h: OpaquePointer? = withCStrings(hostFiles) { hostFiles in withCStrings(config.codecs) { codecs in
            withCStrings(config.capabilities) { caps in
                config.scratchDirectory.path(percentEncoded: false).withCString { dir in
                    config.token.withCString { token in
                        withOptionalCString(config.microphoneFormat.codec) { microphoneCodec in
                        withOptionalCString(config.audioFormat.codec) { audioCodec in
                        withOptionalCString(config.forceCodec) { force in
                            withOptionalCString(config.rejectReason) { reject in
                            withOptionalCString(config.clipboard) { clipboard in
                            withOptionalCString(config.fileDirectory?.path(percentEncoded: false)) { fileDirectory in
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
                                c.audio_codec = audioCodec
                                c.audio_sample_rate_hz = config.audioFormat.sampleRate
                                c.audio_channels = config.audioFormat.channels
                                c.audio_frame_ms = config.audioFormat.frameMilliseconds
                                c.microphone_codec = microphoneCodec
                                c.microphone_sample_rate_hz = config.microphoneFormat.sampleRate
                                c.microphone_channels = config.microphoneFormat.channels
                                c.microphone_frame_ms = config.microphoneFormat.frameMilliseconds
                                c.force_codec = force
                                c.refuse_code = config.refuseCode
                                c.reject_reason = reject
                                c.ping_before_accept = config.pingBeforeAccept
                                c.first_frame_id = config.firstFrameID
                                c.simulate_pointer = config.simulatePointer
                                c.clipboard = clipboard
                                c.file_refuse = config.fileRefusal?.rawValue ?? 0
                                c.file_fail_after = config.fileFailAfter
                                c.file_ignore_offers = config.fileIgnoreOffers
                                c.file_directory = fileDirectory
                                c.host_files = hostFiles.baseAddress
                                c.host_file_count = hostFiles.count
                                c.file_list_budget = config.fileListBudget
                                c.file_ignore_ranges = config.fileIgnoreRanges
                                c.file_kept_lists = config.fileKeptLists
                                return gdpc_test_host_create(&c, &error, error.count)
                            }
                            }
                            }
                        }
                        }
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
    /// With ``GDPSession/Capability/refine`` in effect (§7.8): one frame and
    /// its lossless layer, `bgra` as in ``GDPSession/RefineLayer``. No
    /// `data` is a layer-only frame. ``sendVideoFrame(_:keyframe:dropSlices:maxPayload:)``
    /// wraps its frames with an empty layer then.
    public func sendRefinedFrame(_ data: [UInt8], keyframe: Bool, reset: Bool = false,
                                 clears: [GDPSession.RefineRect] = [], tiles: [GDPSession.RefineRect] = [],
                                 bgra: [UInt8] = []) {
        let rect = { (r: GDPSession.RefineRect) in gdpc_rect(x: r.x, y: r.y, width: r.width, height: r.height) }
        let clearRects = clears.map(rect), tileRects = tiles.map(rect)
        data.withUnsafeBufferPointer { d in
            clearRects.withUnsafeBufferPointer { c in
                tileRects.withUnsafeBufferPointer { t in
                    bgra.withUnsafeBufferPointer { px in
                        var layer = gdpc_refine_layer(reset: reset, clears: c.baseAddress, clear_count: c.count,
                                                      tiles: t.baseAddress, tile_count: t.count,
                                                      bgra: px.baseAddress, bgra_len: px.count)
                        gdpc_test_host_send_refined_frame(handle, d.baseAddress, d.count, keyframe, &layer)
                    }
                }
            }
        }
    }

    /// Sends `payload` as one frame's whole payload, never wrapped (malformed containers).
    public func sendRawVideo(_ payload: [UInt8], keyframe: Bool) {
        payload.withUnsafeBufferPointer { gdpc_test_host_send_raw_video(handle, $0.baseAddress, $0.count, keyframe) }
    }

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

    /// As a host does: `seq` counts from 0 at SessionAccept and `pts` is
    /// the session clock now, the same clock as video's (gdp-spec.md §10).
    public func sendAudio(opus: [UInt8]) {
        opus.withUnsafeBufferPointer { gdpc_test_host_send_audio(handle, $0.baseAddress, $0.count) }
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
    /// Sends ClipboardData as given, even if invalid; a `text/plain` one
    /// also becomes the host's clipboard.
    public func sendClipboard(_ data: some Collection<UInt8>, mimeType: String = "text/plain") {
        data.withContiguousBytes { buf in
            gdpc_test_host_send_clipboard(handle, mimeType, buf.baseAddress, buf.count)
        }
    }
    public func sendClipboard(_ text: String) { sendClipboard(Array(text.utf8)) }

    /// Lists `files` as what the host's user copied (§7.12), replacing the
    /// last list; none says nothing is copied any more.
    /// What the host reads of the viewer's files (file-clipboard, file-share).
    public struct FetchRequest: Sendable {
        public var listID: UInt64 = 0
        public var index: UInt32 = 0
        public var offset: UInt64 = 0
        public var length: UInt64 = 0
        public var listing = false
        public var shareID: UInt64 = 0
        public var path = ""

        public init(listID: UInt64 = 0, index: UInt32 = 0, offset: UInt64 = 0, length: UInt64 = 0,
                    listing: Bool = false, shareID: UInt64 = 0, path: String = "") {
            self.listID = listID
            self.index = index
            self.offset = offset
            self.length = length
            self.listing = listing
            self.shareID = shareID
            self.path = path
        }
    }

    /// How the viewer answered a ``FetchRequest``, so far.
    public struct FetchResult: Sendable, Equatable {
        public enum State: Int32, Sendable { case waiting, sending, listing, refused, reset }
        public var state: State
        /// The viewer finished its answer (FIN).
        public var finished: Bool
        public var error: GDPSession.FileError?
        public var name: String
        public var size, offset, fileSize: UInt64
        public var modifiedUnixMilliseconds: Int64
        public var data: [UInt8]
        public var firstIndex: UInt32
        /// A listing's names, "/" after a folder's.
        public var entries: [String]
    }

    /// Asks the viewer for one of its files; returns the fetch's id.
    @discardableResult
    public func fetch(_ request: FetchRequest) -> UInt64 {
        request.path.withCString { path in
            var r = gdpc_test_fetch(list_id: request.listID, index: request.index, offset: request.offset,
                                    length: request.length, listing: request.listing, share_id: request.shareID,
                                    path: path)
            return gdpc_test_host_fetch(handle, &r)
        }
    }

    public func fetchResult(_ id: UInt64) -> FetchResult? {
        var info = gdpc_test_fetch_result()
        guard gdpc_test_host_fetch_result(handle, id, &info, nil, 0, nil, 0) else { return nil }
        var data = [UInt8](repeating: 0, count: Int(info.data_length))
        var entries = [CChar](repeating: 0, count: 1 << 20)
        _ = data.withUnsafeMutableBufferPointer { d in
            entries.withUnsafeMutableBufferPointer { e in
                gdpc_test_host_fetch_result(handle, id, &info, d.baseAddress, d.count, e.baseAddress, e.count)
            }
        }
        func s<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let lines = text(entries).split(separator: "\n").map(String.init)
        return FetchResult(state: FetchResult.State(rawValue: info.state) ?? .waiting, finished: info.finished,
                           error: info.state == 3 ? GDPSession.FileError(code: info.error) : nil, name: s(info.name),
                           size: info.size, offset: info.offset, fileSize: info.file_size,
                           modifiedUnixMilliseconds: info.modified_unix_ms, data: Array(data.prefix(Int(info.data_length))),
                           firstIndex: info.first_index, entries: lines)
    }

    /// Resets the viewer's answering stream, as a host that no longer wants it.
    public func resetFetch(_ id: UInt64) { gdpc_test_host_reset_fetch(handle, id) }

    /// The viewer's latest FileList: its id, and an entry per line, "parent
    /// name", with "/" after a folder and "?" after an unlisted one.
    public var clientFileList: (listID: UInt64, entries: [String]) {
        var listID: UInt64 = 0
        let length = gdpc_test_host_client_file_list(handle, &listID, nil, 0)
        var out = [CChar](repeating: 0, count: length + 1)
        _ = out.withUnsafeMutableBufferPointer { gdpc_test_host_client_file_list(handle, &listID, $0.baseAddress, $0.count) }
        return (listID, text(out).split(separator: "\n").map(String.init))
    }

    /// The folders the viewer shares (file-share), by id.
    public var clientShares: [UInt64: String] {
        let length = gdpc_test_host_client_shares(handle, nil, 0)
        var out = [CChar](repeating: 0, count: length + 1)
        _ = out.withUnsafeMutableBufferPointer { gdpc_test_host_client_shares(handle, $0.baseAddress, $0.count) }
        var shares: [UInt64: String] = [:]
        for line in text(out).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, let id = UInt64(parts[0]) { shares[id] = String(parts[1]) }
        }
        return shares
    }

    public func sendFileList(_ files: [URL]) {
        withCStrings(files.map { $0.path(percentEncoded: false) }) {
            gdpc_test_host_send_file_list(handle, $0.baseAddress, $0.count)
        }
    }

    /// The data of the latest ClipboardData from the viewer.
    public var lastClipboard: [UInt8] {
        let length = gdpc_test_host_last_clipboard(handle, nil, 0)
        var out = [UInt8](repeating: 0, count: length)
        let n = out.withUnsafeMutableBufferPointer { gdpc_test_host_last_clipboard(handle, $0.baseAddress, $0.count) }
        return Array(out.prefix(min(n, length)))
    }
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
        case gamepadConnect(slot: UInt32, name: String)
        /// As sent: how many axes and buttons it carried, the first 6 axes,
        /// the first 26 buttons as bits (bit i = button i).
        case gamepadState(slot: UInt32, axisCount: Int, buttonCount: Int, axes: [Float], buttons: UInt32)
        case gamepadDisconnect(slot: UInt32)
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
                case Int32(GDPC_TEST_INPUT_TOUCH.rawValue): out.append(.touch(id: e.code, phase: e.phase, x: e.x, y: e.y))
                case Int32(GDPC_TEST_INPUT_GAMEPAD_CONNECT.rawValue):
                    let name = withUnsafeBytes(of: e.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                    out.append(.gamepadConnect(slot: e.code, name: name))
                case Int32(GDPC_TEST_INPUT_GAMEPAD_STATE.rawValue):
                    let axes = withUnsafeBytes(of: e.axes) { Array($0.bindMemory(to: Float.self)) }
                    out.append(.gamepadState(slot: e.code, axisCount: Int(e.axis_count), buttonCount: Int(e.button_count),
                                             axes: Array(axes.prefix(Int(min(e.axis_count, 6)))), buttons: e.buttons))
                default: out.append(.gamepadDisconnect(slot: e.code))
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
            capabilities: list(o.capabilities), decoders: list(o.decoders), clientName: s(o.client_name), takeOver: o.take_over,
            viaGateway: o.via_gateway, networkProfile: o.network_profile, requestedWidth: o.requested_width,
            requestedHeight: o.requested_height, requestedScale: o.requested_scale, accepted: o.accepted, acceptedCodec: s(o.accepted_codec),
            closed: o.closed, closeCode: o.close_code, statsReports: o.stats_reports, lastRTT: o.last_rtt_us,
            lastHasStream: o.last_has_stream, lastHighestFrameID: o.last_highest_frame_id,
            lastLossBitmap: o.last_loss_bitmap, lastDecodeMicroseconds: o.last_decode_us,
            lastPresentMicroseconds: o.last_present_us, lastIntervalMicroseconds: o.last_interval_us,
            lastBytesReceived: o.last_bytes_received, lastDelayMin: o.last_delay_min_us,
            lastDelayAvg: o.last_delay_avg_us, lastDelaySamples: o.last_delay_samples, lastTrains: o.last_trains,
            lastTrainDatagrams: o.last_train_datagrams, lastTrainBytes: o.last_train_bytes,
            bytesReported: o.bytes_reported, lostFrameIDs: Array(lost.prefix(Int(min(o.lost_frame_count, 64)))),
            keyframeRequests: o.keyframe_requests, resolutionRequests: o.resolution_requests,
            lastResolution: (o.last_resolution_width, o.last_resolution_height),
            lastResolutionScale: o.last_resolution_scale, logoutRequested: o.logout_requested,
            pongs: o.pongs, lastPongNonce: o.last_pong_nonce, diagnosticsReportLength: o.diagnostics_report_len,
            keyEvents: o.key_events, lastKeyUsage: o.last_key_usage, lastKeyPressed: o.last_key_pressed,
            pointerMotions: o.pointer_motions, lastMotion: (o.last_motion_x, o.last_motion_y, o.last_motion_absolute),
            buttonEvents: o.button_events, lastButton: o.last_button, lastButtonPressed: o.last_button_pressed,
            axisVerticalSum: o.axis_vertical_sum, axisHorizontalSum: o.axis_horizontal_sum, touches: o.touches,
            inputBeforeAccept: o.input_before_accept, inputEventCount: Int(o.input_event_count),
            pointer: (o.pointer_x, o.pointer_y), cursorPositionsSent: o.cursor_positions_sent,
            clipboardMessages: o.clipboard_messages, lastClipboardMime: s(o.last_clipboard_mime),
            refinePauses: o.refine_pauses, refinePaused: o.refine_paused,
            viewerClosed: o.viewer_closed, viewerCloseCode: o.viewer_close_code,
            viewerCloseReason: s(o.viewer_close_reason),
            framesSent: o.frames_sent, nextFrameID: o.next_frame_id, maxDatagramSize: o.max_datagram_size,
            microphonePackets: o.microphone_packets, microphoneBytes: o.microphone_bytes,
            microphoneDropped: o.microphone_dropped,
            filesOffered: o.files_offered, filesSaved: o.files_saved, filesRefused: o.files_refused,
            filesFailed: o.files_failed, filesCancelled: o.files_cancelled, fileStreamsOpen: o.file_streams_open,
            lastFileName: s(o.last_file_name), fileListsSent: o.file_lists_sent, fileListID: o.file_list_id,
            filesRequested: o.files_requested, filesServed: o.files_served,
            fileRequestsRefused: o.file_requests_refused, listingsRequested: o.listings_requested,
            listingsRefused: o.listings_refused, clientFileLists: o.client_file_lists, fetchAnswers: o.fetch_answers,
            shareMessages: o.share_messages)
    }
}

/// A NUL-terminated buffer's text.
private func text(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}
