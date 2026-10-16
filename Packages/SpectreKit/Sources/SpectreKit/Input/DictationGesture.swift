import CoreGraphics
import Foundation

/// The voice input key's gestures, as a pure state machine (docs/voice-input.md):
///
/// - hold to talk, lift to send;
/// - a tap keeps listening (the hands are free); the next tap sends;
/// - slide off while holding, and lifting cancels instead (sliding back
///   in undoes that);
/// - VoiceOver's activate: the first starts and keeps listening, the next sends.
///
/// The view feeds it the finger's down, moves (distance from where it came
/// down) and up with their times, and does what comes back.
public struct DictationGesture: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        /// A finger on the key, listening since it came down.
        case held
        /// Listening after a tap, no finger on the key.
        case latched
        /// The finger that will send a latched dictation is down.
        case latchedHeld
        /// The finger slid off: lifting now cancels.
        case cancelling(latched: Bool)
    }

    public enum Command: Sendable, Equatable {
        case start, send, cancel
    }

    /// A press shorter than this is a tap: it keeps listening.
    public var tapDuration: TimeInterval
    /// How far (points) the finger slides off before lifting cancels.
    public var cancelDistance: CGFloat
    public private(set) var state = State.idle
    private var downTime: TimeInterval = 0

    public init(tapDuration: TimeInterval = 0.3, cancelDistance: CGFloat = 60) {
        self.tapDuration = tapDuration
        self.cancelDistance = cancelDistance
    }

    public var isListening: Bool { state != .idle }
    public var isCancelling: Bool { if case .cancelling = state { true } else { false } }

    public mutating func down(at time: TimeInterval) -> Command? {
        switch state {
        case .idle:
            state = .held
            downTime = time
            return .start
        case .latched:
            state = .latchedHeld
            return nil
        default:
            return nil
        }
    }

    /// `distance`: from where the finger came down.
    public mutating func moved(distance: CGFloat) {
        switch state {
        case .held where distance > cancelDistance: state = .cancelling(latched: false)
        case .latchedHeld where distance > cancelDistance: state = .cancelling(latched: true)
        case .cancelling(let latched) where distance <= cancelDistance: state = latched ? .latchedHeld : .held
        default: break
        }
    }

    public mutating func up(at time: TimeInterval) -> Command? {
        switch state {
        case .held:
            if time - downTime < tapDuration {
                state = .latched
                return nil
            }
            state = .idle
            return .send
        case .latchedHeld:
            state = .idle
            return .send
        case .cancelling:
            state = .idle
            return .cancel
        case .idle, .latched:
            return nil
        }
    }

    /// The system took the touch (a scroll, an alert): a dictation in
    /// progress is cancelled rather than sent half-way.
    public mutating func touchCancelled() -> Command? {
        switch state {
        case .held, .latchedHeld, .cancelling:
            state = .idle
            return .cancel
        case .idle, .latched:
            return nil
        }
    }

    /// VoiceOver: start and keep listening, or send.
    public mutating func activate() -> Command? {
        switch state {
        case .idle:
            state = .latched
            return .start
        case .latched:
            state = .idle
            return .send
        default:
            return nil
        }
    }

    /// The dictation ended some other way (it failed, the session went).
    public mutating func reset() { state = .idle }
}

/// Which language voice input listens for.
public enum DictationLanguage {
    /// `saved` if the recognizer has it, otherwise the first of the user's
    /// `preferred` languages it has, otherwise US English, otherwise its first.
    public static func choose(saved: String?, preferred: [String], supported: [Locale]) -> Locale? {
        if let saved, let match = supported.first(where: { $0.identifier == saved }) { return match }
        for identifier in preferred {
            if let match = match(identifier, in: supported) { return match }
        }
        return match("en-US", in: supported) ?? supported.first
    }

    /// The supported locale closest to `identifier`: the same language, then
    /// the same region, then the same script (zh-Hans is zh_CN, zh-Hant zh_TW).
    static func match(_ identifier: String, in supported: [Locale]) -> Locale? {
        let want = Locale.Language(identifier: identifier)
        let candidates = supported.filter { $0.language.languageCode == want.languageCode }
        guard !candidates.isEmpty else { return nil }
        // The region written, then the one the language implies (zh-Hant: TW).
        let implied = Locale.Language(identifier: want.maximalIdentifier).region
        for region in [want.region, implied].compactMap(\.self) {
            if let same = candidates.first(where: { $0.language.region == region }) { return same }
        }
        let script = want.maximalIdentifierScript
        if let same = candidates.first(where: { $0.language.maximalIdentifierScript == script }) {
            return same
        }
        return candidates.first
    }

    /// The key's badge: a character for Chinese, Cantonese, Japanese and
    /// Korean, otherwise the language code in capitals (EN, ES).
    public static func abbreviation(_ locale: Locale) -> String {
        let language = locale.language
        switch language.languageCode?.identifier {
        case "zh": return language.maximalIdentifierScript == "Hant" ? "繁" : "中"
        case "yue": return "粤"
        case "ja": return "日"
        case "ko": return "한"
        case let code?: return code.uppercased()
        case nil: return "?"
        }
    }

    /// The language's name in the interface's language, with the region
    /// when the recognizer has more than one (English (US), 中文（台湾）).
    public static func displayName(_ locale: Locale, among supported: [Locale]) -> String {
        let siblings = supported.filter { $0.language.languageCode == locale.language.languageCode }
        if siblings.count > 1 {
            return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
        return locale.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) }
            ?? locale.identifier
    }
}

extension Locale.Language {
    /// The script, filled in from the language and region when not written (zh_TW: Hant).
    var maximalIdentifierScript: String? {
        Locale.Language(identifier: maximalIdentifier).script?.identifier
    }
}
