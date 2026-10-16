import Foundation
import GDPKit
import Testing
@testable import SpectreKit

/// A pasteboard in memory that counts changes like the system's.
@MainActor
final class FakePasteboard: LocalPasteboard {
    var changeCount = 0
    var text: String?
    var concealed = false
    var reads = 0

    var hasText: Bool { text != nil }
    func readText() -> String? {
        reads += 1
        return concealed ? nil : text
    }
    func writeText(_ text: String) { copy(text) }
    /// A copy in some app.
    func copy(_ text: String?) {
        self.text = text
        changeCount += 1
    }
}

@Suite("Clipboard echo filter (§7.9)")
struct ClipboardEchoFilterTests {
    // Each test is a sequence of calls and what each returned.

    @Test func appliedTextIsNotSentBack() {
        var f = ClipboardEchoFilter()
        let results = [
            f.shouldApply("from host"),
            f.shouldSend("from host"), // the local change notification of our own write
            f.shouldSend("copied here"),
            f.shouldApply("copied here"), // the host echoing it back
        ]
        #expect(results == [true, false, true, false])
    }

    @Test func recopyingAfterTheHostChangedIsSent() {
        // libgdp's ClipboardEcho refuses the second A: it was the last text sent.
        var f = ClipboardEchoFilter()
        let results = [f.shouldSend("A"), f.shouldApply("B"), f.shouldSend("A"), f.shouldApply("B")]
        #expect(results == [true, true, true, true])
    }

    @Test func emptyAndOversizedNeverGo() {
        var f = ClipboardEchoFilter()
        let largest = String(repeating: "a", count: GDPSession.maxClipboardBytes)
        let results = [
            f.shouldSend(""),
            f.shouldSendExplicitly(""),
            f.shouldApply(""),
            f.shouldSend(largest),
            f.shouldSend(largest + "a"),
            f.shouldSend(String(repeating: "é", count: GDPSession.maxClipboardBytes / 2 + 1)), // counted in UTF-8 bytes
        ]
        #expect(results == [false, false, false, true, false, false])
    }

    @Test func explicitSendRepeats() {
        var f = ClipboardEchoFilter()
        let results = [f.shouldSendExplicitly("A"), f.shouldSendExplicitly("A"), f.shouldSend("A")]
        #expect(results == [true, true, false])
    }
}

@MainActor
@Suite("Clipboard sync (§7.9)")
struct ClipboardSyncTests {
    let defaults: UserDefaults

    init() {
        let name = "ClipboardSyncTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func make(_ pb: FakePasteboard, enabled: Bool = true, automatic: Bool = true) -> (ClipboardSync, () -> [String]) {
        defaults.set(enabled, forKey: ClipboardSync.enabledKey)
        defaults.set(automatic, forKey: ClipboardSync.sendsAutomaticallyKey)
        var sent: [String] = []
        let sync = ClipboardSync(pasteboard: pb, defaults: defaults) { sent.append($0) }
        return (sync, { sent })
    }

    @Test func offByDefault() {
        let sync = ClipboardSync(pasteboard: FakePasteboard(), defaults: defaults) { _ in }
        #expect(!sync.isEnabled)
        #expect(sync.sendsAutomatically == !ClipboardSync.automaticIsOptional)
    }

    @Test func whatWasThereBeforeTheSessionIsNotSent() {
        let pb = FakePasteboard()
        pb.copy("old")
        let (sync, sent) = make(pb)
        sync.start()
        sync.checkLocal()
        #expect(sent().isEmpty)
        #expect(pb.reads == 0) // nothing changed: the contents are not even read
        pb.copy("new")
        sync.checkLocal()
        sync.checkLocal()
        #expect(sent() == ["new"])
    }

    @Test func hostTextIsWrittenAndNotEchoed() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        sync.hostChanged("from host") // may arrive before start(): right after SessionAccept
        sync.start()
        #expect(pb.text == "from host")
        sync.checkLocal()
        #expect(sent().isEmpty)
        // Our own copy, echoed back by the host, doesn't rewrite the clipboard.
        pb.copy("mine")
        sync.checkLocal()
        let changes = pb.changeCount
        sync.hostChanged("mine")
        #expect(pb.changeCount == changes)
        #expect(sent() == ["mine"])
    }

    @Test func concealedAndNonTextAreNotSent() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        sync.start()
        pb.copy("hunter2")
        pb.concealed = true
        sync.checkLocal()
        pb.concealed = false
        pb.copy(nil) // an image, say
        sync.checkLocal()
        #expect(sent().isEmpty)
    }

    @Test func disabledDoesNothingAndEnablingDoesNotSendTheCurrentText() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb, enabled: false)
        sync.start()
        sync.hostChanged("from host")
        #expect(pb.text == nil)
        pb.copy("while off")
        sync.checkLocal()
        sync.isEnabled = true
        #expect(defaults.bool(forKey: ClipboardSync.enabledKey))
        sync.checkLocal()
        #expect(sent().isEmpty)
        pb.copy("after")
        sync.checkLocal()
        #expect(sent() == ["after"])
    }

    @Test func manualModeSendsOnlyWhenAsked() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb, automatic: false)
        guard ClipboardSync.automaticIsOptional else { return } // the Mac always sends automatically
        sync.start()
        pb.copy("copied")
        sync.checkLocal()
        #expect(pb.reads == 0) // no paste prompt
        sync.send("copied")
        sync.send("copied")
        #expect(sent() == ["copied", "copied"])
    }

    @Test func eachTransferIsNotedForTheNotice() {
        let pb = FakePasteboard()
        let (sync, _) = make(pb)
        sync.start()
        #expect(sync.lastTransfer == nil)
        sync.hostChanged("from host")
        #expect(sync.lastTransfer == ClipboardSync.Transfer(direction: .fromHost, serial: 1))
        sync.hostChanged("from host") // the same text again: nothing crossed
        #expect(sync.lastTransfer?.serial == 1)
        pb.copy("mine")
        sync.checkLocal()
        #expect(sync.lastTransfer == ClipboardSync.Transfer(direction: .toHost, serial: 2))
        sync.send("mine") // an explicit send goes, and is noted, even if the host has it
        #expect(sync.lastTransfer == ClipboardSync.Transfer(direction: .toHost, serial: 3))
    }

    @Test func nothingIsWatchedBeforeStartOrAfterStop() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        pb.copy("early")
        sync.checkLocal()
        sync.start()
        sync.stop()
        pb.copy("late")
        sync.checkLocal()
        #expect(sent().isEmpty)
    }
}
