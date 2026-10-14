import AVFoundation
import Foundation
import Synchronization
#if os(iOS)
import UIKit
#endif

/// The local microphone as Opus packets for the host (gdp-spec.md §10.1).
///
/// An AVAudioEngine of its own: the input node feeds an AVAudioSinkNode,
/// which on Core Audio's real-time thread only copies into an ``AudioRing``;
/// an encode thread takes it from there through a ``MicrophoneEncoder`` and
/// hands each packet to `onPacket`. (An input tap would be simpler but hands
/// over audio in chunks of about 100 ms, all of it added delay.)
///
/// Nothing is opened before ``start()``, and ``stop()`` releases the device,
/// so the system's microphone indicator shows exactly when it records. A
/// device change (macOS) restarts it in the new device's format; on iOS an
/// interruption pauses it, and it resumes after.
public final class MicrophoneCapture: @unchecked Sendable {
    public enum Permission: Sendable {
        case granted, denied, undetermined
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case permissionDenied
        case noInputDevice
        case unsupportedFormat
        case engine(String)

        public var description: String {
            switch self {
            case .permissionDenied: "microphone access is not allowed"
            case .noInputDevice: "no microphone"
            case .unsupportedFormat: "the system's Opus encoder can't produce the host's microphone format"
            case .engine(let e): "microphone: \(e)"
            }
        }
    }

    public struct Statistics: Sendable, Equatable {
        public var isRunning = false
        public var packets = 0
        /// RMS of the latest packet, dBFS.
        public var level: Float = -160
        /// The device's sample rate and channel count.
        public var deviceSampleRate: Double = 0
        public var deviceChannels = 0
    }

    public static var permission: Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    /// Asks the user the first time; afterwards answers at once.
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public let format: OpusFormat
    private let onPacket: @Sendable ([UInt8]) -> Void
    private let control = DispatchQueue(label: "spectre.microphone.control", qos: .userInitiated)
    // Control queue only.
    private var engine: AVAudioEngine?
    private var thread: EncodeThread?
    private var observers: [NSObjectProtocol] = []
    private var wanted = false
    private var claimedAudioSession = false
    private final class StatsBox: Sendable {
        let value = Mutex(Statistics())
    }
    private let stats = StatsBox()

    public init(format: OpusFormat, onPacket: @escaping @Sendable ([UInt8]) -> Void) {
        self.format = format
        self.onPacket = onPacket
    }

    deinit {
        thread?.stop()
        engine?.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        if claimedAudioSession { try? AudioSessionCoordinator.shared.recording(false) }
    }

    public var statistics: Statistics { stats.value.withLock { $0 } }

    /// Opens the microphone. Ask for ``requestPermission()`` first.
    public func start() throws(Failure) {
        let result: Result<Void, Failure> = control.sync {
            guard engine == nil else { return .success(()) }
            guard Self.permission == .granted else { return .failure(.permissionDenied) }
            guard MicrophoneEncoder(format: format) != nil else { return .failure(.unsupportedFormat) }
            wanted = true
            observe()
            do throws(Failure) {
                try open()
                return .success(())
            } catch {
                wanted = false
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Closes the microphone (the device is released).
    public func stop() {
        control.sync {
            wanted = false
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            close()
        }
    }

    // MARK: - Control queue

    private func open() throws(Failure) {
        if !claimedAudioSession {
            do {
                try AudioSessionCoordinator.shared.recording(true)
            } catch {
                throw .engine("audio session: \(error)")
            }
            claimedAudioSession = true
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let deviceFormat = input.outputFormat(forBus: 0)
        guard deviceFormat.sampleRate > 0, deviceFormat.channelCount > 0,
              let bufferFormat = AVAudioFormat(standardFormatWithSampleRate: deviceFormat.sampleRate,
                                               channels: deviceFormat.channelCount),
              let encoder = MicrophoneEncoder(format: format)
        else {
            releaseAudioSession()
            throw .noInputDevice
        }
        // A second of the device's audio between the threads.
        let ring = AudioRing(channels: Int(deviceFormat.channelCount), minimumCapacity: Int(deviceFormat.sampleRate))
        let wake = DispatchSemaphore(value: 0)
        let sink = AVAudioSinkNode { _, frameCount, data in
            ring.write(from: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data)),
                       frames: Int(frameCount))
            wake.signal()
            return noErr
        }
        engine.attach(sink)
        do {
            try engine.connectNode(input, to: sink, format: bufferFormat)
            engine.prepare()
            try engine.start()
        } catch {
            releaseAudioSession()
            throw .engine("\(error)")
        }
        let thread = EncodeThread(ring: ring, wake: wake, format: bufferFormat, encoder: encoder,
                                  stats: stats, onPacket: onPacket)
        thread.start()
        self.engine = engine
        self.thread = thread
        stats.value.withLock {
            $0.isRunning = true
            $0.deviceSampleRate = deviceFormat.sampleRate
            $0.deviceChannels = Int(deviceFormat.channelCount)
        }
    }

    private func close() {
        thread?.stop()
        thread = nil
        engine?.stop()
        engine = nil
        stats.value.withLock {
            $0.isRunning = false
            $0.level = -160
        }
        releaseAudioSession()
    }

    private func releaseAudioSession() {
        guard claimedAudioSession else { return }
        try? AudioSessionCoordinator.shared.recording(false)
        claimedAudioSession = false
    }

    private func reopen() {
        guard wanted else { return }
        close()
        try? open()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: AnyObject? = nil, _ body: @escaping @Sendable (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: nil, using: body))
        }
        // Another input device, or its format changed: the engine has stopped.
        on(.AVAudioEngineConfigurationChange) { [weak self] n in
            guard let self else { return }
            let changed = (n.object as AnyObject?).map(ObjectIdentifier.init)
            control.async {
                guard let engine = self.engine, changed == ObjectIdentifier(engine) else { return }
                self.reopen()
            }
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        on(AVAudioSession.interruptionNotification, session) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            control.async {
                try? AudioSessionCoordinator.shared.reactivate()
                self.reopen()
            }
        }
        on(UIApplication.willEnterForegroundNotification) { [weak self] _ in
            self?.control.async { self?.reopen() }
        }
        #endif
    }

    // MARK: - Encode thread

    /// Drains the ring into the encoder, woken by each real-time callback.
    private final class EncodeThread: @unchecked Sendable {
        private let ring: AudioRing
        private let wake: DispatchSemaphore
        private let buffer: AVAudioPCMBuffer
        private let encoder: MicrophoneEncoder
        private let stats: StatsBox
        private let onPacket: @Sendable ([UInt8]) -> Void
        private let stopped = Atomic<Bool>(false)

        init(ring: AudioRing, wake: DispatchSemaphore, format: AVAudioFormat, encoder: MicrophoneEncoder,
             stats: StatsBox, onPacket: @escaping @Sendable ([UInt8]) -> Void) {
            self.ring = ring
            self.wake = wake
            self.buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            self.encoder = encoder
            self.stats = stats
            self.onPacket = onPacket
        }

        func start() {
            let thread = Thread { [self] in
                while !stopped.load(ordering: .relaxed) {
                    _ = wake.wait(timeout: .now() + .milliseconds(20))
                    drain()
                }
            }
            thread.name = "spectre.microphone.encode"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        func stop() {
            stopped.store(true, ordering: .relaxed)
            wake.signal()
        }

        private func drain() {
            while ring.available > 0, !stopped.load(ordering: .relaxed) {
                let n = ring.read(into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                                  frames: Int(buffer.frameCapacity))
                buffer.frameLength = AVAudioFrameCount(n)
                var sent = 0
                encoder.append(buffer) { packet in
                    onPacket(packet)
                    sent += 1
                }
                if sent > 0 {
                    let level = encoder.level
                    stats.value.withLock {
                        $0.packets += sent
                        $0.level = level
                    }
                }
            }
        }
    }
}
