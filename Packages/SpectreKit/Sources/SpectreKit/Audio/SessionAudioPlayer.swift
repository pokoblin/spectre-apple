import AVFoundation
import Foundation
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Plays a session's audio (gdp-spec.md §10): packets go into an
/// ``AudioPipeline``; a decode thread keeps its ring topped up; an
/// AVAudioSourceNode pulls from the ring on Core Audio's real-time thread
/// into the engine's main mixer.
///
/// Muting sets the mixer's volume to 0 and keeps everything else running,
/// so unmuting plays what is current, not what was buffered when muted.
/// The host isn't told.
///
/// The engine stops when the output device changes (macOS:
/// `AVAudioEngineConfigurationChange`) or on an interruption (iOS: a call);
/// the player restarts it and re-buffers. On iOS it also stops in the
/// background (the app is suspended there; there is no background audio
/// mode) and restarts in the foreground. iOS's audio session is
/// `.playback` with `.mixWithOthers`: heard with the ring/silent switch on,
/// and other apps' audio keeps playing.
public final class SessionAudioPlayer: @unchecked Sendable {
    public enum Output: Sendable {
        /// The system's default output device.
        case device
        /// Offline manual rendering, for tests: nothing plays, no decode
        /// thread runs, and ``renderOffline(frames:)`` pumps and renders.
        case manual
    }

    public let pipeline: AudioPipeline
    public var format: OpusFormat { pipeline.format }
    private let output: Output
    // Engine, observers and the decode thread: `control` queue only.
    private let control = DispatchQueue(label: "spectre.audio.control", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var pumpStop: StopFlag?
    private let wake = DispatchSemaphore(value: 0)
    private let muted = Atomic<Bool>(false)
    private let lastError = Mutex<String?>(nil)

    public init?(format: OpusFormat, output: Output = .device, configuration: AudioJitterBuffer.Configuration? = nil) {
        guard let pipeline = AudioPipeline(format: format, configuration: configuration) else { return nil }
        self.pipeline = pipeline
        self.output = output
    }

    deinit {
        pumpStop?.set()
        wake.signal()
        engine?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Any thread.
    public func receive(sequence: UInt16, pts: UInt32, opus: UnsafeRawBufferPointer) {
        pipeline.receive(sequence: sequence, pts: pts, opus: opus, now: Self.now())
        wake.signal()
    }

    public var isMuted: Bool {
        get { muted.load(ordering: .relaxed) }
        set {
            muted.store(newValue, ordering: .relaxed)
            control.async { [self] in engine?.mainMixerNode.outputVolume = newValue ? 0 : 1 }
        }
    }

    /// Why the engine isn't running, if it failed to start.
    public var failure: String? { lastError.withLock { $0 } }

    public var isRunning: Bool { control.sync { engine?.isRunning ?? false } }

    public func start() {
        control.sync {
            guard engine == nil else { return }
            observe()
            buildAndStart()
            if output == .device { startPumpThread() }
        }
    }

    public func stop() {
        control.sync {
            pumpStop?.set()
            pumpStop = nil
            wake.signal()
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            engine?.stop()
            engine = nil
            #if os(iOS)
            if output == .device { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            #endif
        }
    }

    // MARK: - Manual rendering (tests)

    /// Pumps, then renders `frames` frames offline; interleaving isn't
    /// applied: the result is the engine's (non-interleaved) output.
    public func renderOffline(frames: Int) throws -> AVAudioPCMBuffer {
        try control.sync {
            guard let engine, output == .manual else { throw PlayerError("not in manual rendering mode") }
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                          frameCapacity: AVAudioFrameCount(frames))!
            var done = 0
            while done < frames {
                pipeline.pump(now: Self.now())
                let chunk = min(frames - done, Int(engine.manualRenderingMaximumFrameCount), 240)
                let part = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(chunk))!
                guard try engine.renderOffline(AVAudioFrameCount(chunk), to: part) == .success else {
                    throw PlayerError("manual render failed")
                }
                for c in 0..<Int(buffer.format.channelCount) {
                    (buffer.floatChannelData![c] + done).update(from: part.floatChannelData![c], count: Int(part.frameLength))
                }
                done += Int(part.frameLength)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            return buffer
        }
    }

    struct PlayerError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    // MARK: - Engine (control queue)

    private func buildAndStart() {
        let engine = AVAudioEngine()
        let renderFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                         channels: AVAudioChannelCount(max(format.channels, 2)))!
        let pipeline = pipeline, wake = wake
        let source = AVAudioSourceNode(format: renderFormat) { isSilence, timestamp, frameCount, data in
            let ts = timestamp.pointee
            let hostTime = ts.mFlags.contains(.hostTimeValid) ? ts.mHostTime : 0
            let silent = pipeline.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(data),
                                         hostTime: hostTime)
            isSilence.pointee = ObjCBool(silent)
            wake.signal()
            return noErr
        }
        engine.attach(source)
        engine.mainMixerNode.outputVolume = isMuted ? 0 : 1
        do {
            try engine.connectNode(source, to: engine.mainMixerNode, format: renderFormat)
            switch output {
            case .manual:
                try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 1024)
            case .device:
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try? session.setPreferredSampleRate(Double(format.sampleRate))
                try? session.setPreferredIOBufferDuration(0.005)
                try session.setActive(true)
                #endif
            }
            engine.prepare()
            try engine.start()
            lastError.withLock { $0 = nil }
        } catch {
            lastError.withLock { $0 = "\(error)" }
        }
        self.engine = engine
        updateLatency()
    }

    private func restart(_ why: String) {
        guard let engine else { return }
        engine.stop()
        pipeline.flush()
        do {
            engine.prepare()
            try engine.start()
            lastError.withLock { $0 = nil }
        } catch {
            lastError.withLock { $0 = "restart after \(why): \(error)" }
        }
        updateLatency()
    }

    private func updateLatency() {
        guard let engine, output == .device else { return }
        var seconds = engine.outputNode.presentationLatency
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        seconds = max(seconds, session.outputLatency + session.ioBufferDuration)
        #endif
        pipeline.setOutputLatency(seconds)
    }

    private func observe() {
        guard output == .device else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: AnyObject? = nil, _ body: @escaping @Sendable (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: nil, using: body))
        }
        // The output device changed, or its format: the engine has stopped.
        on(.AVAudioEngineConfigurationChange) { [weak self] n in
            guard let self else { return }
            let changed = (n.object as AnyObject?).map(ObjectIdentifier.init)
            control.async {
                guard let engine = self.engine, changed == ObjectIdentifier(engine) else { return }
                self.restart("configuration change")
            }
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        on(AVAudioSession.interruptionNotification, session) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            control.async {
                try? AVAudioSession.sharedInstance().setActive(true)
                self.restart("interruption")
            }
        }
        on(AVAudioSession.routeChangeNotification, session) { [weak self] _ in
            self?.control.async { self?.updateLatency() }
        }
        on(AVAudioSession.mediaServicesWereResetNotification, session) { [weak self] _ in
            guard let self else { return }
            control.async {
                self.engine?.stop()
                self.engine = nil
                self.pipeline.flush()
                self.buildAndStart()
            }
        }
        on(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.control.async { self?.engine?.stop() }
        }
        on(UIApplication.willEnterForegroundNotification) { [weak self] _ in
            guard let self else { return }
            control.async {
                try? AVAudioSession.sharedInstance().setActive(true)
                self.restart("foreground")
            }
        }
        #endif
    }

    // MARK: - Decode thread

    private final class StopFlag: Sendable {
        private let stopped = Atomic<Bool>(false)
        func set() { stopped.store(true, ordering: .relaxed) }
        var isSet: Bool { stopped.load(ordering: .relaxed) }
    }

    private func startPumpThread() {
        let stop = StopFlag()
        let pipeline = pipeline, wake = wake, period = format.packetDuration / 2
        let thread = Thread {
            while !stop.isSet {
                // Woken by each render and each packet; the timeout keeps it
                // going while the engine is stopped.
                _ = wake.wait(timeout: .now() + period)
                pipeline.pump(now: Self.now())
            }
        }
        thread.name = "spectre.audio.decode"
        thread.qualityOfService = .userInteractive
        thread.start()
        pumpStop = stop
    }

    /// Seconds on the monotonic clock the pipeline's arrival times use.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
