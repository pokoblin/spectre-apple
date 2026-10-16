import Foundation
import Network
#if os(macOS)
import AppKit
#else
import UIKit
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
///
/// `--host-clipboard TEXT` gives the loopback host a clipboard to send on attach.
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
        /// The connection was lost; trying again (docs/reconnect.md).
        case reconnecting(attempt: Int, of: Int, reason: String)
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
    /// A remote session's title (user@server, or the --connect target),
    /// which `streamInfo` extends with the codec once accepted.
    private(set) var title = ""
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
    /// Silence the session's audio on this device (the host isn't told);
    /// remembered across sessions and launches.
    var isAudioMuted = UserDefaults.standard.bool(forKey: PlaybackModel.audioMutedKey) {
        didSet {
            remote?.isAudioMuted = isAudioMuted
            UserDefaults.standard.set(isAudioMuted, forKey: Self.audioMutedKey)
        }
    }
    private static let audioMutedKey = "audioMuted"
    /// Keep the remote desktop the size of the session view (docs/resolution.md);
    /// on unless turned off, remembered.
    var matchesWindowSize = UserDefaults.standard.object(forKey: PlaybackModel.matchesWindowSizeKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(matchesWindowSize, forKey: Self.matchesWindowSizeKey)
            resolution.setEnabled(matchesWindowSize, at: Self.now)
            scheduleResolution()
        }
    }
    /// Points (the default) or, for a sharper picture, pixels; remembered.
    var resolutionUnits = UserDefaults.standard.string(forKey: PlaybackModel.resolutionUnitsKey)
        .flatMap(ResolutionFollower.Units.init) ?? .points {
        didSet {
            UserDefaults.standard.set(resolutionUnits.rawValue, forKey: Self.resolutionUnitsKey)
            resolution.setUnits(resolutionUnits, at: Self.now)
            scheduleResolution()
        }
    }
    private static let matchesWindowSizeKey = "matchesWindowSize"
    private static let resolutionUnitsKey = "resolutionUnits"
    private var resolution = ResolutionFollower(isEnabled: true, units: .points)
    private var resolutionTimer: Task<Void, Never>?
    /// The session plays audio (SessionAccept described a format we decode).
    private(set) var hasAudio = false
    /// The host takes the microphone (`microphone` in effect, a format we encode).
    private(set) var hasMicrophone = false
    /// Off at the start of every session; only the user turns it on (§10.1).
    private(set) var isMicrophoneOn = false
    /// Why turning the microphone on failed, for an alert.
    var microphoneError: String?

    let presenter: VideoPresenter?
    /// The session's input, while there is a session to send it to.
    private(set) var input: SessionInput?
    /// The session's clipboard sync, once established with `clipboard` in effect (gdp-spec.md §7.9).
    var clipboard: ClipboardSync? { clipboardInEffect ? clipboardSync : nil }
    private var clipboardSync: ClipboardSync?
    private var clipboardInEffect = false
    /// The session's gamepads, once established with `gamepad` in effect (gdp-spec.md §8.5).
    private(set) var gamepads: GamepadForwarder?
    private let mailbox = FrameMailbox()
    private let stats: PlaybackStats
    private var player: StreamPlayer?
    private var loopback: LoopbackHost?
    private var remote: RemoteSession?
    private var remoteConfig: GDPSession.Configuration?
    /// Set for a session opened from the login screen: called once when it ends.
    private var onEnded: ((String) -> Void)?

    /// Where a lost session's next configuration comes from.
    enum Reconnection {
        case configuration(GDPSession.Configuration)
        /// Not this time (no answer, the host busy): wait and try again.
        case retry(String)
        /// Trying again won't help: end with this message.
        case stop(String)
        /// Signing in again needs the user (a new question, a device gone):
        /// the login screen takes over.
        case userNeeded
    }
    /// Set for a session opened from the login screen, whose token can't be
    /// used twice (§4.8): signs in again, `allowTakeOver` if the session
    /// may be taken over without asking. Without it the last configuration
    /// is used again (a static token, the loopback host).
    var reconnection: ((_ allowTakeOver: Bool) async -> Reconnection)?
    /// Called when signing in again needs the user.
    var onNeedsLogin: ((String) -> Void)?
    /// The configuration of the session (or attempt) last connected.
    private var lastConfig: GDPSession.Configuration?
    private var reconnectTask: Task<Void, Never>?
    /// The outcome of the reconnect attempt under way.
    private var attempt: CheckedContinuation<RemoteSession.State, Never>?
    /// When this client's connection was lost without being closed (the
    /// host may still count it as attached), for take-over (ReconnectPolicy).
    private var lostAt: Date?
    /// Set when the background time ran out and this client closed the connection itself.
    private var closedForBackground = false
    /// Skips the rest of the wait before the next attempt (the app back in
    /// front, the network back).
    private var retryNow = false
    private let pathMonitor = NWPathMonitor()
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif
    private var endReported = false
    /// The user disconnected, logged out or gave up reconnecting: the
    /// session ends without the failure card.
    private var userEnded = false
    private var streams: [VideoCodec: TestStream] = [:]
    private var ticker: Task<Void, Never>?
    private let bench: BenchOptions?
    private var benchScreen: Int?
    private var hostInputPrinted = 0
    private var hostClipboardPrinted: UInt32 = 0
    private var hostClipboard: String?
    private var terminationObserver: NSObjectProtocol?
    /// Held while a stream plays: keeps App Nap from throttling the timers
    /// and queues a session runs on (StatsReport every 250 ms, §7.5) when
    /// the window is in the background. Idle system sleep still happens.
    private var activity: NSObjectProtocol?

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
        resolution = ResolutionFollower(isEnabled: matchesWindowSize, units: resolutionUnits)
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
        hostClipboard = value("--host-clipboard")
        if let target = value("--connect") {
            let parts = target.split(separator: ":")
            if parts.count == 2, let port = UInt16(parts[1]), let token = value("--token"),
               let fp = value("--fingerprint").flatMap({ CertificateFingerprint(hex: $0.lowercased()) }) {
                var config = GDPSession.Configuration(host: String(parts[0]), port: port, token: token, certificate: fp,
                                                      codecs: ["h265", "h264"])
                config.decoders = ["videotoolbox"]
                remoteConfig = config
                streamInfo = target
                title = target
                source = .remote
            } else {
                failure = "--connect HOST:PORT needs --token and --fingerprint (64 hex digits)"
            }
        }
        if let failure { phase = .failed(failure) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryNow = true }
        }
        pathMonitor.start(queue: .main)
        #if os(iOS)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.enteredBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.enteringForeground() }
            },
        ]
        #endif
    }

    isolated deinit {
        pathMonitor.cancel()
        #if os(iOS)
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }

    /// A session opened from the login screen.
    convenience init(session config: GDPSession.Configuration, title: String,
         onEnded: @escaping (String) -> Void) {
        self.init(arguments: [])
        remoteConfig = config
        source = .remote
        streamInfo = title
        self.title = title
        self.onEnded = onEnded
    }

    /// Detach: the desktop session keeps running (gdp-spec.md §7.10).
    /// The session window is going away (closed, not the session ending):
    /// end the session properly rather than leave it to the host's idle timeout.
    func windowClosed() {
        guard remote != nil || player != nil || loopback != nil else { return }
        ticker?.cancel()
        stopAll()
    }

    /// The app is about to exit: release what is held and close the
    /// connection before the process goes, taking the close with it.
    private func appWillTerminate() {
        input?.end()
        remote?.session?.closeAndWait(timeout: 0.5)
    }

    /// Turns the microphone on or off; the first time on asks for permission.
    func toggleMicrophone() {
        guard let remote else { return }
        let on = !isMicrophoneOn
        Task {
            do throws(MicrophoneCapture.Failure) {
                try await remote.setMicrophone(on)
                guard remote === self.remote else { return }
                isMicrophoneOn = on
                print("session: microphone \(on ? "on" : "off")")
            } catch {
                isMicrophoneOn = false
                if case .permissionDenied = error {
                    microphoneError = String(localized: "Spectre isn't allowed to use the microphone. Turn it on in System Settings → Privacy & Security → Microphone.")
                } else {
                    microphoneError = String(localized: "The microphone didn't start: \(String(describing: error)).")
                }
            }
        }
    }

    func disconnect() {
        userEnded = true
        if reconnectTask != nil { return cancelReconnect() }
        if case .failed = phase { return reportEnded("Disconnected.") }
        guard let remote else { return reportEnded("Disconnected.") }
        input?.end() // §8.2: release what is held before detaching
        remote.close()
    }

    /// End the desktop session itself; the host closes with SESSION_ENDED.
    func logOut() {
        userEnded = true
        input?.end()
        remote?.session?.sendLogout()
    }

    var isRemoteSession: Bool { source == .remote }

    /// Statistics start shown for the test sources, where they are the
    /// point, and hidden over a real host's desktop.
    var showsStatisticsByDefault: Bool { !isRemoteSession }

    /// Given the last picture, as a thumbnail (640 pixels at most), when the
    /// session ends or the app goes to the background.
    var onSnapshot: ((CGImage) -> Void)?

    private func takeSnapshot() {
        guard let onSnapshot, let image = presenter?.snapshot(maxDimension: 640) else { return }
        onSnapshot(image)
    }

    private func reportEnded(_ message: String) {
        guard let onEnded, !endReported else { return }
        endReported = true
        takeSnapshot()
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
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        resolutionTimer?.cancel()
        resolutionTimer = nil
        endSession()
        player?.stop()
        player = nil
        loopback?.stop()
        loopback = nil
        hostInputPrinted = 0
        hostClipboardPrinted = 0
        sessionText = ""
    }

    /// Lets go of the session (not the test sources): what a reconnect replaces.
    private func endSession() {
        input?.end()
        input = nil
        endClipboard()
        endGamepads()
        remote?.close()
        remote = nil
        hasAudio = false
        hasMicrophone = false
        isMicrophoneOn = false
    }

    private func play() async {
        stopAll()
        guard presenter != nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Remote desktop session")
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
                    // No test tone in a bench run: it measures video.
                    let host = try LoopbackHost(stream: stream, audio: bench == nil, clipboard: hostClipboard)
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
        remote.isAudioMuted = isAudioMuted
        remote.onPictureChange = { [weak presenter, weak self] picture in
            Task { @MainActor in
                presenter?.displaySize = picture.size
                presenter?.color = picture.color
                self?.input?.pictureChanged(picture.size)
                self?.resolution.outputChanged(ResolutionFollower.Size(width: UInt32(picture.size.width),
                                                                       height: UInt32(picture.size.height)))
                print("session: output \(Int(picture.size.width))×\(Int(picture.size.height))")
            }
        }
        remote.onCursorShape = { [weak self] shape in
            Task { @MainActor in self?.input?.hostCursorShape(shape) }
        }
        remote.onCursorPosition = { [weak self] position in
            Task { @MainActor in self?.input?.hostCursorPosition(position) }
        }
        remote.onClipboardText = { [weak self] text in
            Task { @MainActor in
                print("clipboard: host sent \(text.utf8.count) bytes")
                self?.clipboardSync?.hostChanged(text)
            }
        }
        remote.onStateChange = { [weak self] state in
            Task { @MainActor in self?.sessionStateChanged(state, remote: remote) }
        }
        self.remote = remote
        // Created now, not at SessionAccept: the host's clipboard follows
        // the accept immediately (§7.9) and must find it there.
        clipboardSync = ClipboardSync(pasteboard: SystemPasteboard()) { [weak remote] text in
            print("clipboard: sent \(text.utf8.count) bytes")
            remote?.session?.sendClipboardText(text)
        }
        if terminationObserver == nil {
            #if os(macOS)
            let name = NSApplication.willTerminateNotification
            #else
            let name = UIApplication.willTerminateNotification
            #endif
            terminationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.appWillTerminate() }
            }
        }
        lastConfig = config
        var config = config
        for capability in [GDPSession.Capability.clipboard, GDPSession.Capability.gamepad]
            where !config.capabilities.contains(capability) {
            config.capabilities.append(capability)
        }
        // The size the view wants, asked for in SessionHello (§6.2): the
        // first picture comes at it, without a second encoder start. The
        // test sources stream at a fixed size.
        if isRemoteSession, let size = resolution.sizeForConnection() {
            config.display = GDPSession.DisplayRequest(width: size.width, height: size.height)
            print("session: asking for \(size)")
        }
        do {
            try remote.connect(config)
            input = remote.session.map { SessionInput(sink: $0, presenter: presenter) }
        } catch {
            if let attempt {
                // A reconnect attempt that couldn't even start: as good as lost.
                self.attempt = nil
                attempt.resume(returning: .ended(GDPSession.Ending(code: 0, reason: error.description, connectionLost: true)))
            } else {
                phase = .failed("connect: \(error)")
            }
        }
    }

    private func sessionStateChanged(_ state: RemoteSession.State, remote: RemoteSession) {
        guard remote === self.remote else { return } // a session we already replaced
        switch state {
        case .connecting:
            if attempt == nil { phase = .connecting(streamInfo) } // reconnecting shows its own progress
        case let .established(accept):
            lostAt = nil
            closedForBackground = false
            if let attempt {
                self.attempt = nil
                attempt.resume(returning: state)
            }
            let size = accept.outputs.first.map { "\($0.width)×\($0.height)" } ?? "?"
            print("session: accepted \(accept.codec) \(size), encoder \(accept.encoder), host \(accept.hostName)")
            hasAudio = remote.audio != nil
            hasMicrophone = remote.microphoneFormat != nil
            if !hasMicrophone { print("session: no microphone: \(remote.microphoneUnavailable ?? "?")") }
            if let a = remote.audio?.format {
                print("session: audio opus \(a.sampleRate) Hz, \(a.channels) ch, \(a.frameMilliseconds) ms")
            } else {
                print("session: no audio: \(remote.audioUnavailable ?? "?")")
            }
            if source == .remote { streamInfo = "\(title) — \(accept.codec) \(size), \(accept.encoder)" }
            if accept.capabilities.contains(GDPSession.Capability.clipboard) {
                clipboardInEffect = true
                clipboardSync?.start()
            }
            if accept.capabilities.contains(GDPSession.Capability.gamepad), let session = remote.session {
                let forwarder = GamepadForwarder(sink: session)
                forwarder.start()
                gamepads = forwarder
            }
            stats.reset()
            phase = .playing
            startTicker()
            scheduleResolution() // the view may have changed while connecting
        case let .ended(ending):
            print("session: ended: \(ending)")
            input?.end()
            input = nil
            endClipboard()
            endGamepads()
            if let attempt {
                self.attempt = nil
                attempt.resume(returning: state)
                return
            }
            if canReconnect, ReconnectPolicy.reconnects(after: ending) || closedForBackground {
                // Lost without a close, the host may still count this client attached.
                if !closedForBackground { lostAt = Date() }
                startReconnecting(reason: closedForBackground ? String(localized: "The app was in the background.") : ending.reason)
                return
            }
            if onEnded != nil {
                endOrShowFailure(Self.explain(ending))
            } else if !(phase == .idle) {
                phase = .failed("session ended: \(ending)")
            }
        }
    }

    // MARK: - Resolution

    /// The session view's size (points) and scale: what the remote desktop
    /// is kept the size of (docs/resolution.md).
    func sessionViewChanged(_ size: CGSize, scale: CGFloat) {
        resolution.viewChanged(size, scale: scale, at: Self.now)
        scheduleResolution()
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Sends a ResolutionChange (§7.2) once the view has settled, while a
    /// remote session is up; otherwise the next connection's SessionHello
    /// carries the size.
    private func scheduleResolution() {
        resolutionTimer?.cancel()
        resolutionTimer = nil
        guard isRemoteSession, let deadline = resolution.nextDeadline else { return }
        resolutionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline - Self.now, 0)))
            guard !Task.isCancelled, let self, phase == .playing, let session = remote?.session else { return }
            resolutionTimer = nil
            guard let size = resolution.update(at: Self.now) else { return }
            print("session: asking for \(size)")
            session.requestResolution(width: size.width, height: size.height)
        }
    }

    // MARK: - Reconnecting

    /// A session that can be opened again: a real or loopback host, not the decoder test.
    private var canReconnect: Bool { (source == .remote || source == .loopback) && bench == nil }

    private func startReconnecting(reason: String) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.reconnect(reason: reason) }
    }

    /// The user gave up waiting.
    func cancelReconnect() {
        userEnded = true
        reconnectTask?.cancel()
        reconnectTask = nil
        end("Disconnected.")
    }

    private func reconnect(reason: String) async {
        var reason = reason // the latest failure, shown on the card
        let delays = ReconnectPolicy.delays
        for (i, delay) in delays.enumerated() {
            phase = .reconnecting(attempt: i + 1, of: delays.count, reason: reason)
            guard await wait(delay) else { return }
            let takeOver = ReconnectPolicy.takesOverAutomatically(lostAt: lostAt)
            var config: GDPSession.Configuration
            if let reconnection {
                switch await reconnection(takeOver) {
                case let .configuration(c): config = c
                case let .retry(why):
                    print("session: reconnect \(i + 1) of \(delays.count): \(why)")
                    reason = why
                    continue
                case let .stop(message):
                    reconnectTask = nil
                    return end(message)
                case .userNeeded:
                    reconnectTask = nil
                    let handOff = onNeedsLogin
                    stopAll()
                    handOff?(String(localized: "The connection was lost. Sign in again to continue."))
                    return
                }
            } else if let last = lastConfig {
                config = last
                config.takeOver = takeOver
            } else {
                return
            }
            if Task.isCancelled { return }
            print("session: reconnect \(i + 1) of \(delays.count)\(takeOver ? " (may take over)" : "")")
            let outcome = await withCheckedContinuation { continuation in
                attempt = continuation
                endSession()
                connect(config)
            }
            switch outcome {
            case .established:
                reconnectTask = nil
                return
            case let .ended(ending) where ReconnectPolicy.reconnects(after: ending):
                if lostAt == nil, !closedForBackground { lostAt = Date() }
                reason = ending.reason
                continue
            case let .ended(ending):
                reconnectTask = nil
                return end(Self.explain(ending))
            case .connecting:
                continue
            }
        }
        reconnectTask = nil
        end(String(localized: "The connection was lost and could not be restored."))
    }

    /// Ends a session that won't come back: back to the login screen, or
    /// (the command line's sources) a message over the picture.
    private func end(_ message: String) {
        endSession()
        if onEnded != nil { endOrShowFailure(message) } else { phase = .failed(message) }
    }

    /// A session that ended on its own (lost and not restored, refused, closed
    /// by the host). On iOS it stays on screen, the last picture dimmed under
    /// a card with Close and Retry (docs/ipad-layout.md); on the Mac, and when
    /// the user ended it, it goes back to the login screen at once.
    private func endOrShowFailure(_ message: String) {
        #if os(iOS)
        if !userEnded {
            phase = .failed(message)
            return
        }
        #endif
        reportEnded(message)
    }

    /// Whether ``retry()`` has a way back in: a login to replay, or the
    /// configuration last connected.
    var canRetry: Bool { canReconnect && (reconnection != nil || lastConfig != nil) }

    /// Retry from the failure card: the reconnect attempts again, from the first.
    func retry() {
        guard case let .failed(message) = phase, canRetry else { return }
        userEnded = false
        startReconnecting(reason: message)
    }

    /// Whether there is a login screen to go back to (not for `--connect`).
    var canClose: Bool { onEnded != nil }

    /// Close from the failure card: back to the login screen with why.
    func closeFailure() {
        guard case let .failed(message) = phase else { return }
        reportEnded(message)
    }

    /// Waits `delay`, cut short by `retryNow`; on iOS also until the app is
    /// in front (a suspended app's attempt would only time out). False if cancelled.
    private func wait(_ delay: Duration) async -> Bool {
        retryNow = false
        let end = ContinuousClock.now + delay
        while ContinuousClock.now < end, !retryNow {
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return false }
        }
        #if os(iOS)
        while UIApplication.shared.applicationState != .active {
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return false }
        }
        #endif
        return !Task.isCancelled
    }

    // MARK: - Background (iOS)

    #if os(iOS)
    /// In the background an app may not draw and is soon suspended: stop
    /// decoding and keep the connection for the time the system gives
    /// (about 30 s), enough for a quick visit to another app.
    private func enteredBackground() {
        guard let remote, phase == .playing else { return }
        takeSnapshot()
        remote.suspendVideo()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Remote desktop session") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTimeRanOut() }
        }
        print("session: in the background, video paused")
    }

    /// Before the system suspends the app: close properly, so the host
    /// knows the viewer left (the desktop session keeps running), and
    /// reconnect on return.
    private func backgroundTimeRanOut() {
        print("session: background time ran out, closing")
        closedForBackground = true
        input?.end()
        remote?.session?.closeAndWait(timeout: 0.5)
        endBackgroundTask()
    }

    private func enteringForeground() {
        endBackgroundTask()
        retryNow = true
        if let remote, phase == .playing, !closedForBackground {
            remote.resumeVideo()
            print("session: back in front, video resumed")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private func endGamepads() {
        gamepads?.stop()
        gamepads = nil
    }

    private func endClipboard() {
        clipboardSync?.stop()
        clipboardSync = nil
        clipboardInEffect = false
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
        text += "\n" + audioOverlay()
        text += "\n" + microphoneOverlay()
        if let host = testHost?.observed {
            text += String(format: "\nhost saw: %u reports, frame %u acked, decode %u µs, present %u µs, %u lost",
                           host.statsReports, host.lastHighestFrameID, host.lastDecodeMicroseconds,
                           host.lastPresentMicroseconds,
                           host.lostFrameIDs.count)
            text += "\n" + Self.inputOverlay(host)
        }
        return text
    }

    /// The session's audio (docs/audio.md): buffering, repairs, and the A/V
    /// offset, audio's playout − pts less video's on-screen − pts (the
    /// clocks' unknown offset cancels; positive: audio is heard later).
    private func audioOverlay() -> String {
        guard let remote else { return "" }
        guard let player = remote.audio else { return "audio: none (\(remote.audioUnavailable ?? "connecting"))" }
        if let failure = player.failure { return "audio: \(failure)" }
        let s = player.pipeline.statistics, c = s.counters
        let buffered = Double(s.queuedPackets) * player.format.packetDuration + s.ringSeconds
        var text = String(format: "audio %@%.0f ms buffered, played %d, concealed %d, late %d, underruns %d, trimmed %d, drift -%d/+%d",
                          isAudioMuted ? "(muted) " : (s.isPlaying ? "" : "(buffering) "), buffered * 1000,
                          c.played, c.concealed, c.late, c.underruns, c.trimmed, c.dropped, c.inserted)
        if let audio = s.playoutMinusPTS, let video = stats.presentMinusPTS {
            text += String(format: ", A/V %+.0f ms", Double(audio &- video) / 1000)
        }
        return text
    }

    /// The microphone (docs/audio.md): on or off, packets sent and the
    /// level; with the in-process test host, what it received and heard.
    private func microphoneOverlay() -> String {
        guard let remote else { return "" }
        guard remote.microphoneFormat != nil else { return "mic: none (\(remote.microphoneUnavailable ?? "connecting"))" }
        var text: String
        if let s = remote.microphone?.statistics, s.isRunning {
            text = String(format: "mic on (%.0f Hz, %d ch), %d packets, level %.0f dBFS", s.deviceSampleRate,
                          s.deviceChannels, s.packets, s.level)
        } else {
            text = "mic off"
        }
        if let link = remote.linkStats() {
            text += String(format: ", sent %llu, dropped %llu", link.microphoneSent, link.microphoneDropped)
        }
        if let host = testHost {
            // The level of the latest packet the host got, decoded on its own:
            // what the remote desktop would be hearing.
            var level: Float = -160
            if let packet = host.latestMicrophonePacket, let format = remote.microphoneFormat,
               let decoder = OpusDecoder(format) {
                decoder.decode(packet.opus) { level = MicrophoneEncoder.rms($0) }
            }
            text += String(format: " | host received %u, latest %.0f dBFS", host.observed.microphonePackets, level)
        }
        return text
    }

    /// The in-process test host behind this session, if any (loopback).
    private var testHost: GDPTestHost? { loopback?.host }

    /// Prints each input event the in-process test host received since the last call.
    private func printHostInput() {
        guard let host = testHost else { return }
        let events = host.inputEvents(from: hostInputPrinted)
        hostInputPrinted += events.count
        for e in events { print("host input: \(e)") }
        let clipboardMessages = host.observed.clipboardMessages
        if clipboardMessages != hostClipboardPrinted {
            hostClipboardPrinted = clipboardMessages
            let text = String(decoding: host.lastClipboard, as: UTF8.self)
            let shown = text.count > 80 ? String(text.prefix(80)) + "…" : text
            print("host clipboard: \(shown.debugDescription) (\(host.observed.lastClipboardMime), \(text.utf8.count) bytes)")
        }
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

    /// Words for how a session ended (gdp-spec.md §12), in the user's
    /// language; the transport's own reason is quoted as it came.
    static func explain(_ e: GDPSession.Ending) -> String {
        if e.certificateRejected {
            return String(localized: "The session host presented a different certificate than the login promised.")
        }
        switch e.code {
        case 0:
            return e.reason == "closed" || e.reason.isEmpty
                ? String(localized: "Disconnected.") : String(localized: "Disconnected: \(e.reason).")
        case 13: return String(localized: "The host can't send any video format this device decodes.")
        case 20: return String(localized: "The session refused the login token. Sign in again.")
        case 24: return String(localized: "Someone else is viewing this session. Sign in again and choose to take it over.")
        case 40: return String(localized: "The session ended.")
        case 41: return String(localized: "You logged in at the host itself, which ended this session.")
        case 42: return String(localized: "Another client took this session over.")
        default: return String(localized: "The session ended: \(e.reason) (code \(Int(clamping: e.code))).")
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
