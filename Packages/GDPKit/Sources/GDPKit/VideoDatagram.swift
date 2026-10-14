import GDPCore

/// The 16-byte video datagram header (gdp-spec.md §9.1).
public struct VideoDatagramHeader: Equatable, Sendable {
    public var streamID: UInt8 = 0
    public var frameID: UInt32 = 0
    public var sliceIndex: UInt16 = 0
    public var sliceCount: UInt16 = 1
    public var keyframe = false
    /// Capture time on the host's session clock, µs (§11).
    public var pts: UInt32 = 0
    /// Capture to send on the host, µs, in 10 µs units on the wire; 0 = not reported.
    public var hostLatencyMicroseconds: UInt32 = 0

    public init(streamID: UInt8 = 0, frameID: UInt32 = 0, keyframe: Bool = false, pts: UInt32 = 0,
                hostLatencyMicroseconds: UInt32 = 0) {
        self.streamID = streamID
        self.frameID = frameID
        self.keyframe = keyframe
        self.pts = pts
        self.hostLatencyMicroseconds = hostLatencyMicroseconds
    }

    init(_ h: gdpc_video_header) {
        streamID = h.stream_id
        frameID = h.frame_id
        sliceIndex = h.slice_idx
        sliceCount = h.slice_count
        keyframe = h.keyframe
        pts = h.pts
        hostLatencyMicroseconds = h.host_latency_us
    }

    var c: gdpc_video_header {
        gdpc_video_header(stream_id: streamID, frame_id: frameID, slice_idx: sliceIndex, slice_count: sliceCount,
                          keyframe: keyframe, pts: pts, host_latency_us: hostLatencyMicroseconds)
    }
}

public enum VideoDatagram {
    public static let headerSize = Int(GDPC_VIDEO_HEADER_SIZE)
    public static let fallbackPayload = Int(GDPC_FALLBACK_DATAGRAM_PAYLOAD)

    /// Slice payload for a connection whose largest datagram is `maxDatagramSize` (0 = unknown).
    public static func slicePayload(forMaxDatagramSize maxDatagramSize: Int) -> Int {
        gdpc_slice_payload_for(maxDatagramSize)
    }

    /// Parses one whole datagram (channel byte, header, payload); nil if it isn't a video datagram.
    public static func decode(_ datagram: [UInt8]) -> (header: VideoDatagramHeader, payload: Range<Int>)? {
        var header = gdpc_video_header()
        var offset = 0
        var length = 0
        let ok = datagram.withUnsafeBufferPointer {
            gdpc_video_datagram_decode($0.baseAddress, $0.count, &header, &offset, &length)
        }
        return ok ? (VideoDatagramHeader(header), offset..<(offset + length)) : nil
    }

    /// Splits a coded frame into datagrams, as the host does (§9.2).
    public static func slice(_ frame: [UInt8], header: VideoDatagramHeader, maxPayload: Int) -> [[UInt8]] {
        let sink = Sink<[UInt8]>()
        var h = header.c
        frame.withUnsafeBufferPointer { buf in
            _ = gdpc_slice_video_frame(&h, buf.baseAddress, buf.count, maxPayload, { ctx, data, len in
                Sink<[UInt8]>.from(ctx).items.append(Array(UnsafeBufferPointer(start: data, count: len)))
                return true
            }, sink.context)
        }
        return sink.items
    }
}

/// A coded frame put back together from its slices.
public struct VideoFrame: Equatable, Sendable {
    public let streamID: UInt8
    public let frameID: UInt32
    public let keyframe: Bool
    public let pts: UInt32
    public let data: [UInt8]
}

/// libgdp's `VideoFrameReassembler` (§9.3): one frame in progress per
/// stream; a newer frame_id drops an incomplete older one.
public final class VideoFrameReassembler {
    private let handle: OpaquePointer

    public init() { handle = gdpc_video_reassembler_create() }
    deinit { gdpc_video_reassembler_destroy(handle) }

    /// Feeds one whole video datagram; returns the frame it completed, if any.
    public func push(_ datagram: [UInt8]) -> VideoFrame? {
        let sink = Sink<VideoFrame>()
        datagram.withUnsafeBufferPointer { buf in
            _ = gdpc_video_reassembler_push(handle, buf.baseAddress, buf.count, { ctx, f in
                let f = f!.pointee
                Sink<VideoFrame>.from(ctx).items.append(VideoFrame(
                    streamID: f.stream_id, frameID: f.frame_id, keyframe: f.keyframe, pts: f.pts,
                    data: Array(UnsafeBufferPointer(start: f.data, count: f.len))))
            }, sink.context)
        }
        return sink.items.first
    }
}
