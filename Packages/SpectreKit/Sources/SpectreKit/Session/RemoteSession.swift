import CoreGraphics
import Dispatch
import GDPKit
import QuartzCore

/// A session's video path: GDPSession (network, on its queue) → VideoDecoder
/// (on the decode queue) → FrameMailbox → the presenter. Feeds the decode
/// and present times back into StatsReport, and reports frames the decoder
/// rejected as lost so the host repairs them (gdp-spec.md §7.5).
public final class RemoteSession: @unchecked Sendable {
    public enum State: Sendable {
        case connecting
        case established(GDPSession.Accept)
        case ended(GDPSession.Ending)
    }

    /// What the presenter needs to know about the picture.
    public struct Picture: Sendable, Equatable {
        public var size: CGSize
        public var color: ColorDescription
    }

    public let mailbox: FrameMailbox
    public let stats: PlaybackStats
    /// Called on the session queue.
    public var onStateChange: (@Sendable (State) -> Void)?
    /// Called on the session queue: at SessionAccept and every DisplaysChanged (§7.2).
    public var onPictureChange: (@Sendable (Picture) -> Void)?
    public var onCursorShape: (@Sendable (GDPSession.CursorShape) -> Void)?

    public private(set) var session: GDPSession?
    private let onFrame: @Sendable () -> Void
    private let decodeQueue = DispatchQueue(label: "spectre.decode", qos: .userInteractive)
    // Decode queue only.
    private var decoder: VideoDecoder?
    // Session queue only.
    private var codec = ""

    public init(mailbox: FrameMailbox, stats: PlaybackStats, onFrame: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox
        self.stats = stats
        self.onFrame = onFrame
    }

    deinit {
        stats.setTimingSink(nil)
    }

    public func connect(_ config: GDPSession.Configuration) throws(GDPSession.ConnectError) {
        var h = GDPSession.Handlers()
        h.accepted = { [weak self] accept in self?.accepted(accept) }
        h.closed = { [weak self] ending in self?.onStateChange?(.ended(ending)) }
        h.displaysChanged = { [weak self] outputs in self?.outputsChanged(outputs) }
        h.videoFrame = { [weak self] frame in self?.received(frame) ?? false }
        h.cursorShape = { [weak self] shape in self?.onCursorShape?(shape) }
        let session = GDPSession(handlers: h)
        self.session = session
        stats.setTimingSink { [weak session] decode, present in
            session?.recordFrameTiming(decodeMicroseconds: decode, presentMicroseconds: present)
        }
        onStateChange?(.connecting)
        try session.connect(config)
    }

    public func close() { session?.close() }

    public func linkStats() -> GDPSession.LinkStats? { session?.linkStats() }

    // MARK: - Session queue

    private func accepted(_ accept: GDPSession.Accept) {
        codec = accept.codec
        guard let videoCodec = VideoCodec(rawValue: accept.codec) else {
            // Only decodable codecs are offered, so this can't happen with a conforming host.
            session?.close()
            return
        }
        let stats = stats, mailbox = mailbox, onFrame = onFrame
        let session = session
        decodeQueue.async { [self] in
            decoder = VideoDecoder(codec: videoCodec, onFrame: { frame in
                stats.recordDecoded(frame)
                mailbox.put(frame)
                onFrame()
            }, onError: { _, frameID in
                stats.recordDecodeError()
                session?.markFrameDiscarded(streamID: 0, frameID: frameID)
            })
        }
        outputsChanged(accept.outputs)
        onStateChange?(.established(accept))
    }

    private func outputsChanged(_ outputs: [GDPSession.Output]) {
        guard let output = outputs.first else { return }
        onPictureChange?(Picture(size: CGSize(width: Int(output.width), height: Int(output.height)),
                                 color: ColorDescription(output: output, codec: codec)))
    }

    private func received(_ frame: GDPSession.VideoFrame) -> Bool {
        // The one copy of the compressed frame: GDPKit's buffer is only valid
        // during this call, and decoding runs on its own queue.
        let bytes = [UInt8](frame.data)
        let id = frame.frameID, pts = frame.pts, streamID = frame.streamID
        let stats = stats, session = session
        decodeQueue.async { [self] in
            guard let decoder else {
                session?.markFrameDiscarded(streamID: streamID, frameID: id)
                return
            }
            do {
                try bytes.withUnsafeBytes { try decoder.decode($0, pts: pts, frameID: id) }
                stats.setHardwareDecoder(decoder.isHardwareAccelerated)
            } catch {
                stats.recordDecodeError()
                session?.markFrameDiscarded(streamID: streamID, frameID: id)
            }
        }
        return true
    }
}
