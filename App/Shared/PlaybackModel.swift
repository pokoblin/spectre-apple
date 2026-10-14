import Foundation
#if os(macOS)
import AppKit
#endif
import GDPKit
import Observation
import SpectreKit

/// Drives the video path from one of three sources and reports timings once
/// a second (and, with `--bench`, a summary over a fixed run before exiting):
///
/// - loopback (default): a test stream served by GDPKit's test host in this
///   process and received through a real GDP session over QUIC loopback;
/// - direct: the test stream fed straight to the decoder, no network;
/// - remote: a real host, `--connect HOST:PORT --token TOKEN --fingerprint SHA256`
///   (a wraith started with a static token, gdp-spec.md §6.11).
@MainActor
@Observable
final class PlaybackModel {
    enum Source: String, CaseIterable, Identifiable {
        case loopback, direct, remote
        var id: String { rawValue }
    }


    enum Phase: Equatable {
        case idle
        case encoding(VideoCodec, Double)
        case connecting(String)
        case playing
        case failed(String)
    }

    struct BenchOptions {
        var seconds: Double
        var warmup: Double = 2
    }

    private(set) var phase = Phase.idle
    private(set) var statsText = ""
    private(set) var sessionText = ""
    private(set) var streamInfo = ""
    var codec: VideoCodec = .h264 {
        // Only a user's change replays; init's assignment comes before start().
        didSet { if codec != oldValue, phase != .idle { Task { await play() } } }
    }
    var source: Source = .loopback {
        didSet { if source != oldValue, phase != .idle { Task { await play() } } }
    }
    var mode: VideoPresenter.Mode = .onArrival {
        didSet { presenter?.mode = mode; stats.reset() }
    }

    let presenter: VideoPresenter?
    /// The session's input, while there is a session to send it to.
    private(set) var input: SessionInput?
    private let mailbox = FrameMailbox()
    private let stats: PlaybackStats
    private var player: StreamPlayer?
    private var loopback: LoopbackHost?
    private var remote: RemoteSession?
    private var remoteConfig: GDPSession.Configuration?
    /// Objects the session depends on (the demo's in-process servers).
    private var keepAlive: [AnyObject] = []
    /// Set for a session opened from the login screen: called once when it ends.
    private var onEnded: ((String) -> Void)?
    private var endReported = false
    private var streams: [VideoCodec: TestStream] = [:]
    private var ticker: Task<Void, Never>?
    private let bench: BenchOptions?
    private var benchScreen: Int?
    private var hostInputPrinted = 0

    init(arguments: [String] = CommandLine.arguments) {
        // The per-second report reaches a log file (or a pipe) as it is printed.
        setvbuf(stdout, nil, _IOLBF, 0)
        stats = PlaybackStats(mailbox: mailbox)
        var presenter: VideoPresenter?
        var failure: String?
        do {
            presenter = VideoPresenter(renderer: try VideoRenderer(), mailbox: mailbox, stats: stats)
        } catch {
            failure = String(describing: error)
        }
        self.presenter = presenter

        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        bench = value("--bench").flatMap(Double.init).map { BenchOptions(seconds: $0) }
        if let c = value("--codec").flatMap(VideoCodec.init(rawValue:)) { codec = c }
        if let s = value("--source").flatMap(Source.init(rawValue:)) { source = s }
        if let m = value("--mode").flatMap(VideoPresenter.Mode.init(rawValue:)) {
            mode = m
            presenter?.mode = m
        }
        if let rate = value("--rate").flatMap(Int.init) { presenter?.displayLinkRate = rate }
        if let ms = value("--min-present-ms").flatMap(Double.init) { presenter?.minimumPresentDuration = ms / 1000 }
        if let n = value("--in-flight").flatMap(Int.init) { presenter?.maxFramesInFlight = n > 0 ? n : nil }
        benchScreen = value("--screen").flatMap(Int.init)
        if let target = value("--connect") {
            let parts = target.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]), let token = value("--token"),
               let fp = value("--fingerprint").flatMap({ CertificateFingerprint(hex: $0.lowercased()) }) {
                var config = GDPSession.Configuration(host: String(parts[0]), port: port, token: token, certificate: fp,
                                                      codecs: ["h265", "h264"])
                config.decoders = ["videotoolbox"]
                remoteConfig = config
                streamInfo = target
                source = .remote
            } else {
                failure = "--connect HOST:PORT needs --token and --fingerprint (64 hex digits)"
            }
        }
        if let failure { phase = .failed(failure) }
    }

    /// A session opened from the login screen.
    convenience init(session config: GDPSession.Configuration, title: String, keepAlive: [AnyObject] = [],
         onEnded: @escaping (String) -> Void) {
        self.init(arguments: [])
        remoteConfig = config
        source = .remote
        streamInfo = title
        self.keepAlive = keepAlive
        self.onEnded = onEnded
    }

    /// Detach: the desktop session keeps running (gdp-spec.md §7.10).
    func disconnect() {
        guard let remote else { return reportEnded("Disconnected.") }
        input?.end() // §8.2: release what is held before detaching
        remote.close()
    }

    /// End the desktop session itself; the host closes with SESSION_ENDED.
    func logOut() {
        input?.end()
        remote?.session?.sendLogout()
    }

    var isRemoteSession: Bool { source == .remote }

    private func reportEnded(_ message: String) {
        guard let onEnded, !endReported else { return }
        endReported = true
        ticker?.cancel()
        stopAll()
        onEnded(message)
    }

    func start() async {
        guard presenter != nil, phase == .idle else { return }
        #if os(macOS)
        if bench != nil {
            // A run started from a terminal opens behind it; an occluded
            // window's drawables are never presented, which would void the run.
            NSApplication.shared.activate()
            if let window = NSApplication.shared.windows.first {
                window.level = .floating
                // `--screen N`: run on that display (NSScreen.screens order; 0 has the menu bar).
                // After a moment: SwiftUI places the window itself once it appears.
                if let n = benchScreen, NSScreen.screens.indices.contains(n) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let visible = NSScreen.screens[n].visibleFrame
                        window.setFrame(NSRect(x: visible.midX - window.frame.width / 2,
                                               y: visible.midY - window.frame.height / 2,
                                               width: window.frame.width, height: window.frame.height), display: true)
                    }
                }
            }
        }
        #endif
        await play()
    }

    private func stopAll() {
        input?.end()
        input = nil
        player?.stop()
        player = nil
        loopback?.stop()
        remote?.close()
        remote = nil
        loopback = nil
        hostInputPrinted = testHost?.observed.inputEventCount ?? 0 // the demo's host outlives a session
        sessionText = ""
    }

    private func play() async {
        stopAll()
        guard presenter != nil else { return }
        switch source {
        case .remote:
            guard let config = remoteConfig else {
                phase = .failed("no remote host: sign in, or start with --connect HOST:PORT --token TOKEN --fingerprint SHA256")
                return
            }
            connect(config)
        case .loopback, .direct:
            guard let stream = await testStream(codec) else { return }
            guard codec == self.codec else { return }
            streamInfo = String(format: "%@ %d×%d@%d, %d frames, %.1f Mb/s", codec.displayName, stream.width,
                                stream.height, stream.framesPerSecond, stream.accessUnits.count,
                                stream.averageBitrate / 1e6)
            print("stream: \(streamInfo), source \(source.rawValue)")
            if source == .direct {
                playDirect(stream)
            } else {
                do {
                    let host = try LoopbackHost(stream: stream)
                    loopback = host
                    connect(host.sessionConfiguration())
                    host.start()
                } catch {
                    phase = .failed("loopback host: \(error)")
                }
            }
        }
    }

    private func testStream(_ codec: VideoCodec) async -> TestStream? {
        if let cached = streams[codec] { return cached }
        phase = .encoding(codec, 0)
        let progress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                if case .encoding = self?.phase { self?.phase = .encoding(codec, p) }
            }
        }
        do {
            let stream = try await Task.detached(priority: .userInitiated) {
                try TestStreamEncoder.encode(codec: codec, progress: progress)
            }.value
            streams[codec] = stream
            return stream
        } catch {
            phase = .failed("encode \(codec.displayName): \(error)")
            return nil
        }
    }

    private func playDirect(_ stream: TestStream) {
        guard let presenter else { return }
        presenter.displaySize = CGSize(width: stream.width, height: stream.height)
        presenter.color = .blockCodecDefault
        let player = StreamPlayer(stream: stream, mailbox: mailbox, stats: stats) { [presenter] in
            presenter.frameAvailable()
        }
        self.player = player
        stats.reset()
        player.start()
        phase = .playing
        startTicker()
    }

    private func connect(_ config: GDPSession.Configuration) {
        guard let presenter else { return }
        let remote = RemoteSession(mailbox: mailbox, stats: stats) { [presenter] in presenter.frameAvailable() }
        remote.onPictureChange = { [weak presenter, weak self] picture in
            Task { @MainActor in
                presenter?.displaySize = picture.size
                presenter?.color = picture.color
                self?.input?.pictureChanged(picture.size)
            }
        }
        remote.onCursorShape = { [weak self] shape in
            Task { @MainActor in self?.input?.hostCursorShape(shape) }
        }
        remote.onCursorPosition = { [weak self] position in
            Task { @MainActor in self?.input?.hostCursorPosition(position) }
        }
        remote.onStateChange = { [weak self] state in
            Task { @MainActor in self?.sessionStateChanged(state, remote: remote) }
        }
        self.remote = remote
        do {
            try remote.connect(config)
            input = remote.session.map { SessionInput(sink: $0, presenter: presenter) }
        } catch {
            phase = .failed("connect: \(error)")
        }
    }

    private func sessionStateChanged(_ state: RemoteSession.State, remote: RemoteSession) {
        guard remote === self.remote else { return } // a session we already replaced
        switch state {
        case .connecting:
            phase = .connecting(streamInfo)
        case let .established(accept):
            let size = accept.outputs.first.map { "\($0.width)×\($0.height)" } ?? "?"
            print("session: accepted \(accept.codec) \(size), encoder \(accept.encoder), host \(accept.hostName)")
            if source == .remote { streamInfo = "\(streamInfo) — \(accept.codec) \(size), \(accept.encoder)" }
            stats.reset()
            phase = .playing
            startTicker()
        case let .ended(ending):
            print("session: ended: \(ending)")
            input?.end()
            input = nil
            if onEnded != nil {
                reportEnded(Self.explain(ending))
            } else if !(phase == .idle) {
                phase = .failed("session ended: \(ending)")
            }
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            if let bench = self?.bench {
                do {
                    try await Task.sleep(for: .seconds(bench.warmup))
                    self?.stats.reset()
                    for second in 1...Int(bench.seconds.rounded(.up)) {
                        try await Task.sleep(for: .seconds(1))
                        self?.benchProgress(second)
                    }
                } catch {
                    return // replaced by a newer run
                }
                self?.finishBench()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let summary = stats.summary()
                stats.reset()
                statsText = Self.overlay(summary, mode: mode)
                sessionText = sessionOverlay()
                print(String(format: "decode p50 %.2f / max %.2f ms, decode→present p50 %.2f / max %.2f ms, "
                    + "gpu %.2f ms, %.1f fps shown, replaced %llu, zero-copy %d/%d, cpu %.1f%%",
                    summary.decode.p50, summary.decode.max, summary.present.p50, summary.present.max,
                    summary.gpu.mean, summary.presentedFPS, summary.replacedFrames, summary.zeroCopyFrames,
                    summary.presentedFrames + summary.unpresentedFrames, summary.cpuPercent))
                if !sessionText.isEmpty { print(sessionText.replacingOccurrences(of: "\n", with: " | ")) }
                printHostInput()
            }
        }
    }

    /// The session's side: what the transport measures and what goes into StatsReport.
    private func sessionOverlay() -> String {
        guard let link = remote?.linkStats() else { return "" }
        var text = String(format: "QUIC RTT %.2f ms, MTU %u, %.1f Mb/s, lost %d of last %u frames",
                          Double(link.rttMicroseconds) / 1000, link.pathMTU, link.megabitsPerSecond,
                          link.recentLosses, link.windowSpan)
        text += String(format: "\nfirst-slice delay min %d / avg %d µs (offset unknown), %u reports sent",
                       link.delayMinMicroseconds, link.delayAvgMicroseconds, link.statsReportsSent)
        if let host = testHost?.observed {
            text += String(format: "\nhost saw: %u reports, frame %u acked, decode %u µs, present %u µs, %u lost",
                           host.statsReports, host.lastHighestFrameID, host.lastDecodeMicroseconds,
                           host.lastPresentMicroseconds,
                           host.lostFrameIDs.count)
            text += "\n" + Self.inputOverlay(host)
        }
        return text
    }

    /// The in-process test host behind this session, if any (loopback or the demo).
    private var testHost: GDPTestHost? {
        loopback?.host ?? keepAlive.lazy.compactMap { ($0 as? DemoServer)?.host.host }.first
    }

    /// Prints each input event the in-process test host received since the last call.
    private func printHostInput() {
        guard let host = testHost else { return }
        let events = host.inputEvents(from: hostInputPrinted)
        hostInputPrinted += events.count
        for e in events { print("host input: \(e)") }
    }

    /// What the test host received on the input stream (gdp-spec.md §8.2).
    private static func inputOverlay(_ o: GDPTestHost.Observed) -> String {
        func state(_ pressed: Bool) -> String { pressed ? "down" : "up" }
        var parts = [String(format: "keys %u", o.keyEvents)]
        if o.keyEvents > 0 { parts[0] += String(format: " (0x%02X %@)", o.lastKeyUsage, state(o.lastKeyPressed)) }
        var motion = String(format: "motion %u", o.pointerMotions)
        if o.pointerMotions > 0 {
            motion += o.lastMotion.absolute
                ? String(format: " (%.3f, %.3f)", o.lastMotion.x, o.lastMotion.y)
                : String(format: " (%+.1f, %+.1f px)", o.lastMotion.x, o.lastMotion.y)
        }
        parts.append(motion)
        var buttons = String(format: "buttons %u", o.buttonEvents)
        if o.buttonEvents > 0 { buttons += String(format: " (0x%X %@)", o.lastButton, state(o.lastButtonPressed)) }
        parts.append(buttons)
        parts.append(String(format: "scroll %+.2f, %+.2f", o.axisHorizontalSum, o.axisVerticalSum))
        return "host input: " + parts.joined(separator: ", ")
    }

    private func benchProgress(_ second: Int) {
        let s = stats.summary()
        var visibility = ""
        #if os(macOS)
        if let window = NSApplication.shared.windows.first {
            visibility = window.occlusionState.contains(.visible) ? ", window visible" : ", window OCCLUDED"
            if let screen = window.screen {
                visibility += " on \(screen.localizedName) (\(screen.maximumFramesPerSecond) Hz)"
            }
        }
        #endif
        print(String(format: "  [%2d s] decoded %d, presented %d, not presented %d%@", second, s.decodedFrames,
                     s.presentedFrames, s.unpresentedFrames, visibility))
    }

    private func finishBench() {
        let summary = stats.summary()
        print("=== bench: \(streamInfo), source \(source.rawValue), mode \(mode.rawValue), display link \(presenter?.displayLinkRate ?? 0) Hz, in flight \(presenter?.maxFramesInFlight.map(String.init) ?? "∞"), min present \(presenter?.minimumPresentDuration.map { "\($0 * 1000) ms" } ?? "-") ===")
        print(summary)
        let session = sessionOverlay()
        if !session.isEmpty { print("  " + session.replacingOccurrences(of: "\n", with: "\n  ")) }
        fflush(stdout)
        exit(0)
    }

    /// Words for how a session ended (gdp-spec.md §12).
    static func explain(_ e: GDPSession.Ending) -> String {
        if e.certificateRejected { return "The session host presented a different certificate than the login promised." }
        switch e.code {
        case 0: return e.reason == "closed" || e.reason.isEmpty ? "Disconnected." : "Disconnected: \(e.reason)."
        case 13: return "The host can't send any video format this device decodes."
        case 20: return "The session refused the login token. Sign in again."
        case 24: return "Someone else is viewing this session. Sign in again and choose to take it over."
        case 40: return "The session ended."
        case 41: return "You logged in at the host itself, which ended this session."
        case 42: return "Another client took this session over."
        default: return "The session ended: \(e.reason) (code \(e.code))."
        }
    }

    private static func overlay(_ s: PlaybackStats.Summary, mode: VideoPresenter.Mode) -> String {
        """
        \(String(format: "%.0f fps decoded, %.0f fps shown (%@)", s.decodedFPS, s.presentedFPS, mode.rawValue))
        \(String(format: "decode %.2f ms (max %.2f)%@", s.decode.p50, s.decode.max, s.hardwareDecoder ? ", hardware" : ""))
        \(String(format: "decode→present %.2f ms (max %.2f)", s.present.p50, s.present.max))
        \(String(format: "gpu %.2f ms, interval %.2f ms (max %.2f)", s.gpu.mean, s.presentInterval.p50, s.presentInterval.max))
        \(String(format: "zero-copy %d/%d, replaced %llu, cpu %.1f%%", s.zeroCopyFrames, s.presentedFrames + s.unpresentedFrames, s.replacedFrames, s.cpuPercent))
        """
    }
}
