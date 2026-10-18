import CoreGraphics
import Dispatch
import GDPKit
import QuartzCore
import Synchronization

/// A session's video path: GDPSession (network, on its queue) → VideoDecoder
/// (on the decode queue) → FrameMailbox → the presenter. Feeds the decode
/// and present times back into StatsReport, and reports frames the decoder
/// rejected as lost so the host repairs them (gdp-spec.md §7.5). Plays the
/// session's audio when SessionAccept describes a format it can decode
/// (§6.8, §10), and sends the microphone while the user has it on (§10.1).
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
    /// Called on the session queue (gdp-spec.md §7.4).
    public var onCursorShape: (@Sendable (GDPSession.CursorShape) -> Void)?
    /// Called on the session queue: where the host put the pointer, 0...1 (§7.4).
    public var onCursorPosition: (@Sendable (CGPoint) -> Void)?
    /// Called on the session queue: the host's clipboard text (§7.9).
    public var onClipboardText: (@Sendable (String) -> Void)?
    /// Called on the session queue: file transfer events (§7.12), for
    /// ``FileTransfers/fileAccepted(_:)`` and its siblings.
    public var onFileAccepted: (@Sendable (UInt64) -> Void)?
    public var onFileProgress: (@Sendable (UInt64, UInt64) -> Void)?
    public var onFileFinished: (@Sendable (UInt64, GDPSession.FileOutcome) -> Void)?
    /// Called on the session queue: the host's copied files, and each fetch's
    /// header and bytes (``FileTransfers/Link/fileList(_:_:)`` and its siblings).
    public var onFileList: (@Sendable (UInt64, [GDPSession.FileListEntry]) -> Void)?
    public var onFileSending: (@Sendable (UInt64, String, UInt64, Date?) -> Void)?
    public var onFileData: (@Sendable (UInt64, UnsafeRawBufferPointer) -> Void)?
    /// With `file-clipboard`: a copied folder's contents (``FileTransfers/Link/fileListing(_:_:_:)``).
    public var onFileListing: (@Sendable (UInt64, UInt32, [GDPSession.FileListEntry]) -> Void)?
    /// With `file-clipboard`: the host reads one of this side's copied files
    /// (``FileTransfers/Link/fileServe(_:_:_:_:)``); the descriptor is the callee's.
    public var onFileServe: (@Sendable (UInt64, Int32, UInt64, UInt64) -> Void)?

    public private(set) var session: GDPSession?
    private let onFrame: @Sendable () -> Void
    private let audioOutput: SessionAudioPlayer.Output
    private struct AudioState {
        var player: SessionAudioPlayer?
        var unavailable: String?
        var muted = false
        /// SessionAccept.microphone, if `microphone` is in effect and we can encode it.
        var microphoneFormat: OpusFormat?
        var microphoneUnavailable: String?
        var microphone: MicrophoneCapture?
        var ended = false
    }
    private let audioState = Mutex(AudioState())

    /// Whether video is decoded: not while suspended (iOS in the background:
    /// no GPU work allowed, decoders may be invalidated), and after that not
    /// before the next keyframe.
    private struct VideoGate {
        var suspended = false
        var awaitingKeyframe = false
    }
    private let videoGate = Mutex(VideoGate())
    /// Starts and stops the player in order, off the session queue.
    private let audioQueue = DispatchQueue(label: "spectre.audio.session", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(label: "spectre.decode", qos: .userInteractive)
    // Decode queue only.
    private var decoder: VideoDecoder?
    // Session queue only.
    private var codec = ""

    public init(mailbox: FrameMailbox, stats: PlaybackStats, audioOutput: SessionAudioPlayer.Output = .device,
                onFrame: @escaping @Sendable () -> Void) {
        self.mailbox = mailbox
        self.stats = stats
        self.audioOutput = audioOutput
        self.onFrame = onFrame
        // What kind each interface is comes from a path monitor's first
        // report: start it now, so connecting doesn't wait for it.
        if VideoCodec.pyrowave.isHardwareDecodable { _ = NetworkInterfaces.shared }
    }

    deinit {
        stats.setTimingSink(nil)
        let (player, microphone) = audioState.withLock { ($0.player, $0.microphone) }
        audioQueue.async {
            player?.stop()
            microphone?.stop()
        }
    }

    /// The session's audio, from SessionAccept on, if it has a format we play.
    public var audio: SessionAudioPlayer? { audioState.withLock { $0.player } }

    /// Why the session has no audio, once established without it.
    public var audioUnavailable: String? { audioState.withLock { $0.unavailable } }

    /// Silence the session's audio on this client (the host isn't told).
    /// Holds for audio that starts later.
    public var isAudioMuted: Bool {
        get { audioState.withLock { $0.muted } }
        set {
            let player = audioState.withLock {
                $0.muted = newValue
                return $0.player
            }
            player?.isMuted = newValue
        }
    }

    /// The format the host takes the microphone in, once established with
    /// `microphone` in effect (gdp-spec.md §6.8, §10.1); nil before or without.
    public var microphoneFormat: OpusFormat? { audioState.withLock { $0.microphoneFormat } }

    /// Why the microphone can't be used, once established without it.
    public var microphoneUnavailable: String? { audioState.withLock { $0.microphoneUnavailable } }

    /// The open microphone, while it is on.
    public var microphone: MicrophoneCapture? { audioState.withLock { $0.microphone } }

    /// Turns the microphone on (asking for permission the first time) or
    /// off. Off releases the device and stops the packets; there is nothing
    /// to tell the host (§10.1). Never on unless the user asked for it.
    public func setMicrophone(_ on: Bool) async throws(MicrophoneCapture.Failure) {
        if on {
            guard let format = microphoneFormat else { throw .unsupportedFormat }
            guard await MicrophoneCapture.requestPermission() else { throw .permissionDenied }
            let session = session
            let capture = MicrophoneCapture(format: format) { [weak session] packet in
                session?.sendMicrophone(opus: packet)
            }
            let result: Result<Void, MicrophoneCapture.Failure> = await withCheckedContinuation { done in
                audioQueue.async { [self] in
                    guard audioState.withLock({ !$0.ended && $0.microphone == nil }) else {
                        return done.resume(returning: .success(()))
                    }
                    do throws(MicrophoneCapture.Failure) {
                        try capture.start()
                        audioState.withLock { $0.microphone = capture }
                        done.resume(returning: .success(()))
                    } catch {
                        done.resume(returning: .failure(error))
                    }
                }
            }
            try result.get()
        } else {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                audioQueue.async { [self] in
                    let capture = audioState.withLock {
                        let c = $0.microphone
                        $0.microphone = nil
                        return c
                    }
                    capture?.stop()
                    done.resume()
                }
            }
        }
    }

    /// One packet in the microphone format, straight to the host: what the
    /// capture does with each packet (and what tests use without a device).
    public func sendMicrophonePacket(_ opus: [UInt8]) { session?.sendMicrophone(opus: opus) }

    /// Whether SessionHello offers the `microphone` capability (§10.1). A
    /// host that takes it may give the desktop a microphone of ours, so an
    /// app that never sends one turns this off.
    public var offersMicrophone = true

    /// Whether SessionHello offers the `file` capability (§7.12): files the
    /// user sends to the host. Nothing goes unless they do.
    public var offersFiles = true

    /// Whether SessionHello offers `refine` (§7.8): a lossless layer over
    /// the video for still regions, drawn from ``refinement``.
    public var offersRefine = true

    /// Whether SessionHello may offer `pyrowave`, first (§6.6): it is, when
    /// this device decodes it and ``pyroWaveRoute`` carries it, a wired link
    /// of 1 Gbit/s or more, or the host is this machine.
    public var offersPyroWave = true

    /// The route to the host as it was when the last connection began, if
    /// PyroWave was considered: why it was offered or not.
    public private(set) var pyroWaveRoute: NetworkRoute?

    /// Lossless refinement's overlay plane, the output's size: every
    /// frame's layer goes into it as the frame arrives.
    public let refinement = RefinementPlane()
    /// Called on the session queue when a layer-only frame changed
    /// ``refinement``: the last picture wants drawing again.
    public var onRefinementChanged: (@Sendable () -> Void)?

    public func connect(_ config: GDPSession.Configuration) throws(GDPSession.ConnectError) {
        // Offered for the whole connection (it is fixed then); the microphone
        // itself stays closed until the user turns it on (§10.1).
        var config = config
        if offersMicrophone, !config.capabilities.contains("microphone") { config.capabilities.append("microphone") }
        if offersFiles, !config.capabilities.contains(GDPSession.Capability.file) {
            config.capabilities.append(GDPSession.Capability.file)
        }
        // Copied folders' contents (§7.12), with the clipboard.
        if offersFiles, config.capabilities.contains(GDPSession.Capability.clipboard),
           !config.capabilities.contains(GDPSession.Capability.fileClipboard) {
            config.capabilities.append(GDPSession.Capability.fileClipboard)
        }
        if offersRefine, !config.capabilities.contains(GDPSession.Capability.refine) {
            config.capabilities.append(GDPSession.Capability.refine)
        }
        offerPyroWave(in: &config)
        if config.clientName.isEmpty { config.clientName = ClientName.current() }
        var h = GDPSession.Handlers()
        h.accepted = { [weak self] accept in self?.accepted(accept) }
        h.closed = { [weak self] ending in
            self?.stopAudio()
            self?.onStateChange?(.ended(ending))
        }
        h.displaysChanged = { [weak self] outputs in self?.outputsChanged(outputs) }
        h.videoFrame = { [weak self] frame in self?.received(frame) ?? false }
        h.cursorShape = { [weak self] shape in self?.onCursorShape?(shape) }
        h.cursorPosition = { [weak self] x, y in self?.onCursorPosition?(CGPoint(x: x, y: y)) }
        h.audioPacket = { [weak self] sequence, pts, opus in
            self?.audioState.withLock { $0.player }?.receive(sequence: sequence, pts: pts, opus: opus)
        }
        h.clipboardText = { [weak self] text in self?.onClipboardText?(text) }
        h.fileAccepted = { [weak self] id in self?.onFileAccepted?(id) }
        h.fileProgress = { [weak self] id, acknowledged in self?.onFileProgress?(id, acknowledged) }
        h.fileFinished = { [weak self] id, outcome in self?.onFileFinished?(id, outcome) }
        h.fileList = { [weak self] listID, files in self?.onFileList?(listID, files) }
        h.fileSending = { [weak self] id, name, size, modified in self?.onFileSending?(id, name, size, modified) }
        h.fileData = { [weak self] id, bytes in self?.onFileData?(id, bytes) }
        h.fileListing = { [weak self] id, first, files in self?.onFileListing?(id, first, files) }
        h.fileServe = { [weak self] id, fd, offset, size in
            if let serve = self?.onFileServe { serve(id, fd, offset, size) } else { Darwin.close(fd) }
        }
        let session = GDPSession(handlers: h)
        if refinePaused.withLock({ $0 }) { session.setRefinePaused(true) }
        self.session = session
        stats.setTimingSink { [weak session] decode, present in
            session?.recordFrameTiming(decodeMicroseconds: decode, presentMicroseconds: present)
        }
        onStateChange?(.connecting)
        try session.connect(config)
    }

    public func close() { session?.close() }

    /// Lossless refinement on or off for the host (§7.8, RefinePause): off
    /// spares it reading back and hashing every frame. Kept across this
    /// session's reconnections.
    public func setRefinePaused(_ paused: Bool) {
        refinePaused.withLock { $0 = paused }
        session?.setRefinePaused(paused)
    }
    private let refinePaused = Mutex(false)

    /// Stops decoding video; frames keep being acknowledged and are dropped,
    /// so the host sees no loss and the connection stays healthy.
    public func suspendVideo() { videoGate.withLock { $0.suspended = true } }

    /// Decodes again, with a fresh decoder, from the next keyframe, which it asks for.
    public func resumeVideo() {
        videoGate.withLock { $0 = VideoGate(suspended: false, awaitingKeyframe: true) }
        decodeQueue.async { [self] in decoder?.reset() }
        session?.requestKeyframe()
    }

    public func linkStats() -> GDPSession.LinkStats? { session?.linkStats() }

    /// Puts `pyrowave` first where it may go (``offersPyroWave``), judged
    /// on the route as it is now: each connection decides afresh, so a
    /// reconnection after moving from Wi-Fi to a cable offers it. A
    /// configuration that names it already (the user chose it) keeps it
    /// wherever the route goes, as §6.6 allows.
    private func offerPyroWave(in config: inout GDPSession.Configuration) {
        let token = VideoCodec.pyrowave.rawValue
        pyroWaveRoute = nil
        if !config.codecs.contains(token) {
            guard offersPyroWave, VideoCodec.pyrowave.isHardwareDecodable else { return }
            let route = NetworkRoute.to(host: config.host, port: config.port)
            pyroWaveRoute = route
            guard route?.carriesPyroWave == true else { return }
            config.codecs.insert(token, at: 0)
        }
        if !config.decoders.contains("metal") { config.decoders.append("metal") }
        // The pipelines compile while the connection is set up.
        PyroWaveDevice.prepare()
    }

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
        startAudio(accept.audio)
        microphoneAccepted(accept)
        onStateChange?(.established(accept))
    }

    private func startAudio(_ config: GDPSession.AudioConfig?) {
        guard let config else {
            audioState.withLock { $0.unavailable = "the host sends no audio" }
            return
        }
        // A format we can't play: the session goes on without audio (§6.8).
        guard let format = OpusFormat(config), let player = SessionAudioPlayer(format: format, output: audioOutput) else {
            audioState.withLock {
                $0.unavailable = "unsupported audio: \(config.codec) \(config.sampleRate) Hz, \(config.channels) ch, \(config.frameMilliseconds) ms"
            }
            return
        }
        audioState.withLock {
            player.isMuted = $0.muted
            $0.player = player
        }
        audioQueue.async { player.start() }
    }

    private func microphoneAccepted(_ accept: GDPSession.Accept) {
        audioState.withLock {
            if let config = accept.microphone {
                // §6.8: a format we can't encode leaves the session without a microphone.
                if let format = OpusFormat(config), MicrophoneEncoder(format: format) != nil {
                    $0.microphoneFormat = format
                } else {
                    $0.microphoneUnavailable = "unsupported microphone format: \(config.codec) \(config.sampleRate) Hz, \(config.channels) ch, \(config.frameMilliseconds) ms"
                }
            } else {
                $0.microphoneUnavailable = "the host takes no microphone"
            }
        }
    }

    private func stopAudio() {
        let (player, microphone) = audioState.withLock {
            $0.ended = true
            let m = $0.microphone
            $0.microphone = nil
            return ($0.player, m)
        }
        audioQueue.async {
            player?.stop()
            microphone?.stop()
        }
    }

    private func outputsChanged(_ outputs: [GDPSession.Output]) {
        guard let output = outputs.first else { return }
        refinement.resize(width: Int(output.width), height: Int(output.height))
        onPictureChange?(Picture(size: CGSize(width: Int(output.width), height: Int(output.height)),
                                 color: ColorDescription(output: output, codec: codec)))
    }

    private func received(_ frame: GDPSession.VideoFrame) -> Bool {
        // The layer first, whatever becomes of the picture: the host counts
        // every frame not reported lost as applied (§9.6).
        if let layer = frame.refine {
            if !layer.isEmpty { refinement.apply(layer) }
            if frame.data.isEmpty {
                // Layer-only: nothing to decode; drawn again unless the
                // video is suspended (no GPU work in the background).
                if !layer.isEmpty, !videoGate.withLock({ $0.suspended }) { onRefinementChanged?() }
                return true
            }
        }
        let drop = videoGate.withLock { gate in
            if gate.suspended { return true }
            if gate.awaitingKeyframe {
                guard frame.keyframe else { return true }
                gate.awaitingKeyframe = false
            }
            return false
        }
        if drop { return true }
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
