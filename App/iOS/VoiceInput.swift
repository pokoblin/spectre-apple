import SpectreKit
import SwiftUI
import UIKit

/// Voice input in a session (docs/voice-input.md): the microphone key's
/// gesture, the dictation, and what is said sent to the host's cursor the
/// way the prompt panel sends text.
@MainActor
@Observable
final class VoiceInputModel {
    let dictation = VoiceDictation()
    private(set) var gesture = DictationGesture()
    /// The languages this device can write out, once asked.
    private(set) var supported: [Locale] = []
    /// What it listens for; remembered.
    var locale: Locale? {
        didSet { UserDefaults.standard.set(locale?.identifier, forKey: Self.localeKey) }
    }
    /// Press Return on the host after what was said; remembered.
    var pressesReturn = UserDefaults.standard.bool(forKey: VoiceInputModel.pressesReturnKey) {
        didSet { UserDefaults.standard.set(pressesReturn, forKey: Self.pressesReturnKey) }
    }
    /// The last failure, shown a few seconds under the key's overlay.
    private(set) var failure: Failure?

    struct Failure: Equatable {
        var message: String
        var serial: Int
    }

    @ObservationIgnored weak var model: PlaybackModel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let localeKey = "dictationLocale"
    private static let pressesReturnKey = "dictationPressesReturn"

    /// `--dictation-file PATH` (Debug builds): that recording instead of the
    /// microphone, for the simulator, whose microphone records silence here.
    private static let debugFile: URL? = debugArgument("--dictation-file").map { URL(fileURLWithPath: $0) }
    /// `--dictation-script TEXT` (Debug builds): that text, said word by word,
    /// for trying voice input in the simulator, where Speech has no models.
    private static let debugScript = debugArgument("--dictation-script")

    private static func debugArgument(_ name: String) -> String? {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    var isAvailable: Bool { locale != nil }

    init() {
        Task { await loadLanguages() }
        // Leaving the app ends a dictation: its audio stops in the background.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func loadLanguages() async {
        supported = await VoiceDictation.supportedLocales.sorted {
            DictationLanguage.displayName($0, among: []).localizedStandardCompare(DictationLanguage.displayName($1, among: []))
                == .orderedAscending
        }
        locale = DictationLanguage.choose(saved: UserDefaults.standard.string(forKey: Self.localeKey),
                                          preferred: Locale.preferredLanguages, supported: supported)
    }

    // MARK: The key

    func down(at time: TimeInterval) { perform(gesture.down(at: time)) }
    func moved(distance: CGFloat) { gesture.moved(distance: distance) }
    func up(at time: TimeInterval) { perform(gesture.up(at: time)) }
    func touchCancelled() { perform(gesture.touchCancelled()) }
    func activate() { perform(gesture.activate()) }

    private func perform(_ command: DictationGesture.Command?) {
        switch command {
        case .start?: start()
        case .send?: send()
        case .cancel?: cancel()
        case nil: break
        }
    }

    private func start() {
        guard let locale, let input = model?.input else { return gesture.reset() }
        // Nothing stays held on the host while the user talks.
        input.typer.releaseModifiers()
        model?.isQuietForDictation = true
        if let script = Self.debugScript {
            dictation.startScripted(script)
        } else {
            dictation.start(locale: locale, file: Self.debugFile)
        }
    }

    private func send() {
        let pressesReturn = pressesReturn
        Task {
            let text = await dictation.finish()
            model?.isQuietForDictation = false
            noteFailure()
            guard !text.isEmpty, let model, let input = model.input else { return }
            let method = UserDefaults.standard.string(forKey: PasteMethod.key).flatMap(PasteMethod.init) ?? .ctrlShiftV
            PromptModel.deliver(text, pressingReturn: pressesReturn, input: input, clipboard: model.clipboard, method: method)
        }
    }

    func cancel() {
        gesture.reset()
        dictation.cancel()
        model?.isQuietForDictation = false
    }

    private func noteFailure() {
        if let message = dictation.failure {
            failure = Failure(message: message, serial: (failure?.serial ?? 0) + 1)
        }
    }

    /// The dictation stopped on its own (a failure): the key goes back.
    func dictationEnded() {
        guard dictation.phase == .idle, gesture.isListening else { return }
        gesture.reset()
        model?.isQuietForDictation = false
        noteFailure()
    }
}

// MARK: - The key

/// Hold to talk, lift to send; tap to keep listening, tap again to send;
/// slide off and lift to cancel. A drag gesture rather than a button, to
/// tell the finger coming down from it lifting.
struct VoiceKey: View {
    let voice: VoiceInputModel
    @State private var start: CGPoint?

    var body: some View {
        let phase = voice.dictation.phase
        let cancelling = voice.gesture.isCancelling
        let active = phase != .idle
        ZStack {
            if phase == .preparing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: active ? "mic.fill" : "mic")
                    .symbolEffect(.pulse, isActive: phase == .listening && !cancelling)
            }
        }
        .keyCap(isLit: active && !cancelling, isPressed: start != nil)
        .background {
            if cancelling { Capsule().fill(.red) }
        }
        .foregroundStyle(cancelling ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .overlay(alignment: .topTrailing) {
            if let locale = voice.locale {
                Text(verbatim: DictationLanguage.abbreviation(locale))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
        }
        .opacity(voice.isAvailable ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard voice.isAvailable else { return }
                if start == nil {
                    start = value.startLocation
                    voice.down(at: ProcessInfo.processInfo.systemUptime)
                }
                voice.moved(distance: hypot(value.translation.width, value.translation.height))
            }
            .onEnded { _ in
                guard start != nil else { return }
                start = nil
                voice.up(at: ProcessInfo.processInfo.systemUptime)
            })
        .onChange(of: phase) { voice.dictationEnded() }
        .accessibilityElement()
        .accessibilityLabel(phase == .idle ? Text("Voice Input") : Text("Send What You Said"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { voice.activate() }
    }
}

// MARK: - The overlay

/// What is being heard, above the key bar: a meter and a line saying what
/// lifting the finger does, then the words, settled ones darker.
struct VoiceOverlay: View {
    let voice: VoiceInputModel
    @State private var shownFailure: String?

    var body: some View {
        let dictation = voice.dictation
        let visible = dictation.phase != .idle || shownFailure != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Meter(level: dictation.level, active: dictation.phase == .listening)
                status
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(voice.gesture.isCancelling || shownFailure != nil ? .red : .primary)
            }
            if !dictation.text.isEmpty {
                (Text(verbatim: dictation.finalText) + Text(verbatim: dictation.volatileText).foregroundStyle(.secondary))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 84)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 40)
        .animation(.smooth(duration: 0.25), value: visible)
        .allowsHitTesting(false)
        .task(id: voice.failure) {
            guard let failure = voice.failure else { return }
            shownFailure = failure.message
            try? await Task.sleep(for: .seconds(4))
            if shownFailure == failure.message { shownFailure = nil }
        }
    }

    @ViewBuilder private var status: some View {
        if let shownFailure, voice.dictation.phase == .idle {
            Text(verbatim: shownFailure)
        } else {
            switch voice.dictation.phase {
            case .preparing:
                Text("Getting ready…")
            case .finishing:
                Text("Sending…")
            case .listening, .idle:
                if voice.gesture.isCancelling {
                    Text("Release to cancel")
                } else if voice.gesture.state == .latched {
                    Text("Listening. Tap the microphone to send.")
                } else {
                    Text("Listening. Release to send, slide away to cancel.")
                }
            }
        }
    }
}

/// Five bars rising and falling with the voice.
private struct Meter: View {
    let level: Double
    let active: Bool
    private static let shape: [Double] = [0.5, 0.8, 1, 0.75, 0.55]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: 4 + 14 * (active ? level : 0) * Self.shape[i])
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

// MARK: - More

/// Voice input's settings in the session's More menu.
struct VoiceInputSection: View {
    @Bindable var voice: VoiceInputModel

    var body: some View {
        if !voice.supported.isEmpty {
            Section("Voice Input") {
                Picker(selection: Binding(get: { voice.locale?.identifier ?? "" },
                                          set: { id in voice.locale = voice.supported.first { $0.identifier == id } })) {
                    ForEach(voice.supported, id: \.identifier) { locale in
                        Text(verbatim: DictationLanguage.displayName(locale, among: voice.supported)).tag(locale.identifier)
                    }
                } label: {
                    Label("Language", systemImage: "globe")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $voice.pressesReturn) {
                    Label("Press Return After", systemImage: "return")
                }
            }
        }
    }
}
