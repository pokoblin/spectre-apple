import GDPCore

/// One ControlEnvelope parsed off a control stream (gdp-spec.md §6.1).
public struct ControlFrame: Equatable, Sendable {
    /// The envelope's oneof case: the ControlEnvelope field number.
    public enum Message: Equatable, Sendable {
        case ping(nonce: UInt64)
        case pong(nonce: UInt64)
        case keyframeRequest(streamID: UInt32)
        /// Any other case, by field number (0 = unset).
        case other(Int32)
    }

    public let message: Message
    /// The envelope's protobuf size, without the length prefix.
    public let encodedSize: Int

    init(_ f: gdpc_control_frame) {
        switch f.msg_case {
        case Int32(GDPC_CONTROL_MSG_PING.rawValue): message = .ping(nonce: f.nonce)
        case Int32(GDPC_CONTROL_MSG_PONG.rawValue): message = .pong(nonce: f.nonce)
        case Int32(GDPC_CONTROL_MSG_KEYFRAME_REQUEST.rawValue): message = .keyframeRequest(streamID: f.stream_id)
        default: message = .other(f.msg_case)
        }
        encodedSize = f.encoded_size
    }
}

/// Length-prefixed ControlEnvelope encoding (gdp-spec.md §3.1), by libgdp.
public enum ControlFraming {
    public static let maxFrameSize = Int(GDPC_MAX_FRAME_SIZE)
    public static let lengthPrefixSize = Int(GDPC_FRAME_LENGTH_PREFIX_SIZE)

    public static func ping(nonce: UInt64) -> [UInt8] { encode { gdpc_encode_ping(nonce, $0, $1) } }
    public static func pong(nonce: UInt64) -> [UInt8] { encode { gdpc_encode_pong(nonce, $0, $1) } }
    public static func keyframeRequest(streamID: UInt32) -> [UInt8] {
        encode { gdpc_encode_keyframe_request(streamID, $0, $1) }
    }

    private static func encode(_ body: (UnsafeMutablePointer<UInt8>?, Int) -> Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count) }
        precondition(n > 0, "control frame larger than its buffer")
        return Array(buf.prefix(n))
    }
}

public enum ControlFramingError: Error, Equatable {
    /// A length prefix exceeded the limit; close with `errorCode` (FRAME_TOO_LARGE, §12).
    case frameTooLarge(errorCode: UInt64)
    /// A frame did not parse; close with `errorCode` (MALFORMED_FRAME, §12).
    case malformed(errorCode: UInt64)
}

/// Reassembles ControlEnvelopes from control-stream bytes in any chunking
/// (libgdp's `gdp::FrameReader`).
public final class ControlFrameReader {
    private let handle: OpaquePointer

    /// - Parameter maxFrameSize: a lower cap, e.g. gdp-spec.md §6.3's
    ///   pre-authentication one; clamped to ``ControlFraming/maxFrameSize``.
    public init(maxFrameSize: Int? = nil) {
        handle = gdpc_control_reader_create()
        if let maxFrameSize {
            gdpc_control_reader_set_max_frame_size(handle, maxFrameSize)
        }
    }

    deinit { gdpc_control_reader_destroy(handle) }

    /// Feeds bytes as the stream delivered them; returns every frame they completed.
    public func feed(_ bytes: some Collection<UInt8>) throws(ControlFramingError) -> [ControlFrame] {
        let sink = Sink<ControlFrame>()
        let result = bytes.withContiguousBytes { buf in
            gdpc_control_reader_feed(handle, buf.baseAddress, buf.count, { ctx, frame in
                Sink<ControlFrame>.from(ctx).items.append(ControlFrame(frame!.pointee))
            }, sink.context)
        }
        switch result {
        case GDPC_FEED_OK: return sink.items
        case GDPC_FEED_TOO_LARGE: throw .frameTooLarge(errorCode: gdpc_control_reader_error_code(handle))
        default: throw .malformed(errorCode: gdpc_control_reader_error_code(handle))
        }
    }
}

/// Collects what a C callback reports, through its `ctx` pointer. The
/// caller keeps the sink alive until it reads `items` back.
final class Sink<T> {
    var items: [T] = []
    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static func from(_ ctx: UnsafeMutableRawPointer?) -> Sink<T> {
        Unmanaged<Sink<T>>.fromOpaque(ctx!).takeUnretainedValue()
    }
}
