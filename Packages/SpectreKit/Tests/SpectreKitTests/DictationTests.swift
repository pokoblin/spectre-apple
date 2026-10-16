import CoreGraphics
import Foundation
import Speech
import Testing
@testable import SpectreKit

@Suite("Voice input: the key's gestures")
struct DictationGestureTests {
    var g = DictationGesture()

    @Test mutating func holdToTalkLiftToSend() {
        #expect(g.down(at: 0) == .start)
        g.moved(distance: 20) // a finger wobbles
        #expect(g.up(at: 1.5) == .send)
        #expect(g.state == .idle)
    }

    @Test mutating func aTapKeepsListeningAndTheNextTapSends() {
        #expect(g.down(at: 0) == .start)
        #expect(g.up(at: 0.1) == nil)
        #expect(g.state == .latched)
        #expect(g.down(at: 3) == nil)
        #expect(g.up(at: 3.1) == .send)
        #expect(!g.isListening)
    }

    @Test mutating func slidingOffCancelsAndSlidingBackUndoesIt() {
        _ = g.down(at: 0)
        g.moved(distance: 80)
        #expect(g.isCancelling)
        g.moved(distance: 30)
        #expect(!g.isCancelling)
        g.moved(distance: 90)
        #expect(g.up(at: 2) == .cancel)
        #expect(g.state == .idle)
    }

    @Test mutating func aLatchedDictationCanBeCancelledToo() {
        _ = g.down(at: 0)
        _ = g.up(at: 0.1)
        _ = g.down(at: 2)
        g.moved(distance: 100)
        #expect(g.state == .cancelling(latched: true))
        g.moved(distance: 0)
        #expect(g.state == .latchedHeld)
        g.moved(distance: 100)
        #expect(g.up(at: 2.5) == .cancel)
    }

    @Test mutating func aTouchTheSystemTakesCancels() {
        _ = g.down(at: 0)
        #expect(g.touchCancelled() == .cancel)
        _ = g.down(at: 1)
        _ = g.up(at: 1.1)
        #expect(g.touchCancelled() == nil) // latched, no finger: it goes on
        #expect(g.state == .latched)
    }

    @Test mutating func voiceOverStartsThenSends() {
        #expect(g.activate() == .start)
        #expect(g.state == .latched)
        #expect(g.activate() == .send)
        #expect(g.state == .idle)
    }
}

@Suite("Voice input: the language")
struct DictationLanguageTests {
    let supported = ["en_US", "en_GB", "es_ES", "ja_JP", "yue_CN", "zh_CN", "zh_HK", "zh_TW"].map(Locale.init(identifier:))

    @Test func theFirstPreferredLanguageTheRecognizerHas() {
        #expect(DictationLanguage.choose(saved: nil, preferred: ["zh-Hans-CN", "en-US"], supported: supported)?.identifier == "zh_CN")
        #expect(DictationLanguage.choose(saved: nil, preferred: ["zh-Hant-TW"], supported: supported)?.identifier == "zh_TW")
        #expect(DictationLanguage.choose(saved: nil, preferred: ["zh-Hant"], supported: supported)?.identifier == "zh_TW")
        #expect(DictationLanguage.choose(saved: nil, preferred: ["en-GB"], supported: supported)?.identifier == "en_GB")
        #expect(DictationLanguage.choose(saved: nil, preferred: ["fr-FR", "ja-JP"], supported: supported)?.identifier == "ja_JP")
    }

    @Test func aSavedChoiceWinsAndEnglishIsTheFallback() {
        #expect(DictationLanguage.choose(saved: "es_ES", preferred: ["zh-Hans-CN"], supported: supported)?.identifier == "es_ES")
        #expect(DictationLanguage.choose(saved: "fr_FR", preferred: ["de-DE"], supported: supported)?.identifier == "en_US")
        #expect(DictationLanguage.choose(saved: nil, preferred: [], supported: []) == nil)
    }

    @Test func theBadge() {
        let badges = ["zh_CN", "zh_TW", "yue_CN", "ja_JP", "en_US", "es_ES"]
            .map { DictationLanguage.abbreviation(Locale(identifier: $0)) }
        #expect(badges == ["中", "繁", "粤", "日", "EN", "ES"])
    }
}

/// A Mac that can speak (`say`) and write speech out.
private let canSpeakAndListen = FileManager.default.isExecutableFile(atPath: "/usr/bin/say")

/// Speech made with `say`, written out by the real recognizer (its model is
/// downloaded the first time).
@MainActor
@Suite("Voice input: end to end", .enabled(if: canSpeakAndListen))
struct VoiceDictationEndToEnd {
    static func speech(_ text: String, voice: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path(), text]
        try say.run()
        say.waitUntilExit()
        return url
    }

    func transcribe(_ file: URL, locale: String) async throws -> (String, VoiceDictation) {
        let audio = try AVAudioFile(forReading: file)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        let dictation = VoiceDictation()
        dictation.start(locale: Locale(identifier: locale), file: file)
        var heardSomething = false
        var listeningSince: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + .seconds(60) // the model may be downloaded first
        // Until the file has been played out: it goes at speaking pace.
        while ContinuousClock.now < deadline, dictation.phase != .idle {
            if dictation.phase == .listening {
                listeningSince = listeningSince ?? .now
                if dictation.level > 0.2 { heardSomething = true }
                if let since = listeningSince, ContinuousClock.now - since > .seconds(seconds + 0.5) { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(heardSomething, "the meter never moved: \(dictation.failure ?? "")")
        return (await dictation.finish(), dictation)
    }

    @Test(.timeLimit(.minutes(2))) func english() async throws {
        let file = try Self.speech("Hello from the iPad. Please list the files.", voice: "Samantha")
        defer { try? FileManager.default.removeItem(at: file) }
        let (text, dictation) = try await transcribe(file, locale: "en_US")
        #expect(text.lowercased().contains("hello"), "got \"\(text)\"")
        #expect(text.lowercased().contains("files"), "got \"\(text)\"")
        #expect(dictation.phase == .idle)
    }

    @Test(.timeLimit(.minutes(2))) func chinese() async throws {
        let file = try Self.speech("你好，请列出当前目录的文件。", voice: "Tingting")
        defer { try? FileManager.default.removeItem(at: file) }
        let (text, _) = try await transcribe(file, locale: "zh_CN")
        #expect(text.contains("你好"), "got \"\(text)\"")
        #expect(text.contains("文件"), "got \"\(text)\"")
    }

    /// The older model, which devices without the newer one (and the
    /// simulator's builds) use.
    @Test(.timeLimit(.minutes(2))) func theOlderModelToo() async throws {
        VoiceDictation.prefersDictationTranscriber = true
        defer { VoiceDictation.prefersDictationTranscriber = false }
        let file = try Self.speech("Open the terminal and run the tests.", voice: "Samantha")
        defer { try? FileManager.default.removeItem(at: file) }
        let (text, _) = try await transcribe(file, locale: "en_US")
        #expect(text.lowercased().contains("terminal"), "got \"\(text)\"")
        #expect(text.lowercased().contains("test"), "got \"\(text)\"")
    }

    @Test func aScriptComesOutAsIfSaid() async throws {
        let dictation = VoiceDictation()
        dictation.startScripted("列出当前目录的文件")
        for _ in 0..<50 where dictation.text.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(dictation.phase == .listening)
        #expect(!dictation.text.isEmpty)
        let text = await dictation.finish()
        #expect("列出当前目录的文件".hasPrefix(text) && !text.isEmpty)
        #expect(dictation.phase == .idle)
    }

    @Test func cancellingDropsWhatWasSaid() async throws {
        let dictation = VoiceDictation()
        let file = try Self.speech("This is dropped.", voice: "Samantha")
        defer { try? FileManager.default.removeItem(at: file) }
        dictation.start(locale: Locale(identifier: "en_US"), file: file)
        try await Task.sleep(for: .milliseconds(500))
        dictation.cancel()
        #expect(dictation.phase == .idle)
        #expect(dictation.text.isEmpty)
        #expect(await dictation.finish() == "")
    }
}
