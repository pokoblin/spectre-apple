@preconcurrency import AVFoundation
import Observation
import Speech
import Synchronization

/// Voice input (docs/voice-input.md): speech from the microphone, written
/// out on this device by Speech's `SpeechAnalyzer` and `SpeechTranscriber`,
/// for the app to type on the host. Nothing leaves the device but the text.
///
/// While it listens it reports the words settled so far (`finalText`), the
/// ones still changing (`volatileText`) and how loud the input is
/// (`level`). ``finish()`` waits for the last words and returns the text;
/// ``cancel()`` drops it. A file can stand in for the microphone (the
/// simulator records silence on a Mac whose input is muted; tests).
@MainActor
@Observable
public final class VoiceDictation {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Getting the language's model (downloaded the first time) and the microphone.
        case preparing
        case listening
        /// Stopped listening, the last words being written out.
        case finishing
    }

    public private(set) var phase = Phase.idle
    public private(set) var finalText = ""
    public private(set) var volatileText = ""
    /// The input's loudness, 0 (silence) to 1, for the meter.
    public private(set) var level: Double = 0
    /// Why the last dictation stopped short, for the user.
    public private(set) var failure: String?

    public var text: String { finalText + volatileText }

    /// Whether this device can write out speech at all.
    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }
    public static var supportedLocales: [Locale] { get async { await SpeechTranscriber.supportedLocales } }

    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Never>?
    @ObservationIgnored private var audio: DictationAudio?
    /// Bumped by every start and cancel: work for an older dictation stops.
    @ObservationIgnored private var generation = 0

    public init() {}

    /// Starts listening for `locale`, to the microphone or to `file`.
    public func start(locale: Locale, file: URL? = nil) {
        guard phase == .idle else { return }
        generation += 1
        let generation = generation
        phase = .preparing
        finalText = ""
        volatileText = ""
        level = 0
        failure = nil
        starting = Task { [weak self] in
            do {
                try await self?.begin(locale: locale, file: file, generation: generation)
            } catch {
                guard let self, self.generation == generation else { return }
                self.fail(String(describing: error))
            }
        }
    }

    private func begin(locale: Locale, file: URL?, generation: Int) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError.noAudioFormat
        }
        if file == nil {
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphoneDenied }
        }
        guard self.generation == generation else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard self.generation == generation else { return }
        self.analyzer = analyzer
        self.input = input
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.finalText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                // Cancelled, or the analyzer stopped: what came stays.
            }
        }
        try await analyzer.start(inputSequence: stream)
        let audio = DictationAudio(format: format, input: input) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        if let file {
            try audio.play(file)
        } else {
            try audio.listen()
        }
        guard self.generation == generation else { return audio.stop() }
        self.audio = audio
        phase = .listening
    }

    /// Stops listening and returns all that was said, once the last words are
    /// written out (empty if nothing was, or it failed).
    public func finish() async -> String {
        guard phase == .preparing || phase == .listening else { return "" }
        let generation = generation
        phase = .finishing
        await starting?.value
        guard self.generation == generation else { return "" }
        audio?.stop()
        audio = nil
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        guard self.generation == generation else { return "" }
        let text = (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        return text
    }

    /// Stops listening and drops what was said.
    public func cancel() {
        guard phase != .idle else { return }
        let analyzer = analyzer
        reset()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func fail(_ message: String) {
        let analyzer = analyzer
        reset()
        failure = message
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func reset() {
        generation += 1
        starting?.cancel()
        starting = nil
        audio?.stop()
        audio = nil
        input?.finish()
        input = nil
        results?.cancel()
        results = nil
        analyzer = nil
        phase = .idle
        level = 0
        finalText = ""
        volatileText = ""
    }
}

enum DictationError: Error, CustomStringConvertible {
    case noAudioFormat
    case microphoneDenied
    case noMicrophone

    var description: String {
        switch self {
        case .noAudioFormat: String(localized: "Speech recognition isn't available for this language.", bundle: .module)
        case .microphoneDenied:
            String(localized: "Spectre isn't allowed to use the microphone. Turn it on in Settings › Privacy & Security › Microphone.",
                   bundle: .module)
        case .noMicrophone: String(localized: "There is no microphone to listen to.", bundle: .module)
        }
    }
}

/// The sound for a dictation, converted to the analyzer's format: the
/// microphone through an AVAudioEngine tap, or a file played in real time.
/// Its callbacks run on the audio thread.
final class DictationAudio: @unchecked Sendable {
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private var engine: AVAudioEngine?
    private var player: Task<Void, Never>?
    private let converter = Mutex<AVAudioConverter?>(nil)
    private var usesSession = false

    init(format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Double) -> Void) {
        self.format = format
        self.input = input
        self.onLevel = onLevel
    }

    func listen() throws {
        try AudioSessionCoordinator.shared.recording(true)
        usesSession = true
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw DictationError.noMicrophone }
        node.installTap(onBus: 0, bufferSize: 4096, format: natural) { [self] buffer, _ in
            self.deliver(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// The file as if it were being spoken now: a tenth of a second at a time.
    func play(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        player = Task.detached { [self] in
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                      (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                self.deliver(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.onLevel(0)
        }
    }

    func stop() {
        player?.cancel()
        player = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if usesSession {
            usesSession = false
            try? AudioSessionCoordinator.shared.recording(false)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        return converter.withLock { converter -> AVAudioPCMBuffer? in
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return nil }
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            return error == nil && out.frameLength > 0 ? out : nil
        }
    }

    /// Loudness for the meter: the RMS in dBFS, -50…0 mapped onto 0…1.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        let mean = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let db = 10 * log10(max(Double(mean), 1e-10))
        return min(max((db + 50) / 50, 0), 1)
    }
}
