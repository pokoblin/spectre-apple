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
    var files: [URL] = []
    func writeFiles(_ urls: [URL]) {
        text = nil
        files = urls
        copiedFiles = nil
        changeCount += 1
    }
    /// Files copied in the Finder: with their names as text, as it puts them.
    var copiedFiles: [URL]?
    func readFileURLs() -> [URL]? { copiedFiles }
    func copyFiles(_ urls: [URL]) {
        copiedFiles = urls
        text = urls.map(\.lastPathComponent).joined(separator: "\r")
        changeCount += 1
    }
    /// A copy in some app.
    func copy(_ text: String?) {
        self.text = text
        copiedFiles = nil
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

    @Test func textForPastingGoesEvenWithSharingOffAndIsNotEchoed() {
        let pb = FakePasteboard()
        let (off, sentOff) = make(pb, enabled: false)
        off.start()
        #expect(off.sendForPaste("prompt"))
        #expect(sentOff() == ["prompt"])
        #expect(off.lastTransfer == nil)

        let (sync, _) = make(pb)
        sync.start()
        #expect(sync.sendForPaste("prompt"))
        sync.hostChanged("prompt") // the host's clipboard now holds it and says so
        #expect(pb.text == nil)
        #expect(!sync.sendForPaste(""))
        #expect(!sync.sendForPaste(String(repeating: "x", count: GDPSession.maxClipboardBytes + 1)))
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

    @Test func copiedFilesGoOnTheClipboardUnlessSomethingWasCopiedMeanwhile() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        #expect(sync.markForCopiedFiles() == nil) // not watching yet
        sync.start()
        let files = [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b.txt")]
        let mark = try! #require(sync.markForCopiedFiles())
        #expect(sync.putCopiedFiles(files, ifUnchangedSince: mark))
        #expect(pb.files == files)
        #expect(sync.lastTransfer?.direction == .fromHost)
        sync.checkLocal() // our own write is not a copy to send
        #expect(sent().isEmpty)

        let later = try! #require(sync.markForCopiedFiles())
        pb.copy("copied here meanwhile")
        #expect(!sync.putCopiedFiles([URL(filePath: "/tmp/c.txt")], ifUnchangedSince: later))
        #expect(pb.text == "copied here meanwhile")

        sync.isEnabled = false
        #expect(sync.markForCopiedFiles() == nil)
    }

    // MARK: Files copied here (§7.12, file-clipboard)

    @Test func copiedFilesGoAsFilesNotText() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        var lists: [[URL]] = []
        sync.start()
        sync.sendFiles = { lists.append($0) }
        let files = [URL(filePath: "/Users/me/a.pdf"), URL(filePath: "/Users/me/B")]
        pb.copyFiles(files)
        sync.checkLocal()
        #expect(lists == [files] && sent().isEmpty)
        #expect(sync.lastTransfer?.direction == .toHost)
        // Copying text after: the list is taken back, then the text goes.
        pb.copy("words")
        sync.checkLocal()
        #expect(lists == [files, []] && sent() == ["words"])
        // Another text: nothing more to take back.
        pb.copy("more")
        sync.checkLocal()
        #expect(lists.count == 2 && sent() == ["words", "more"])
    }

    @Test func withoutFileClipboardTheNamesGoAsBefore() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        sync.start()
        pb.copyFiles([URL(filePath: "/Users/me/a.pdf")])
        sync.checkLocal()
        #expect(sent() == ["a.pdf"])
    }

    @Test func theHostsOwnFilesAreNotOfferedBack() {
        let pb = FakePasteboard()
        let (sync, sent) = make(pb)
        var lists: [[URL]] = []
        sync.start()
        sync.sendFiles = { lists.append($0) }
        sync.ownFiles = URL(filePath: "/tmp/spectre-cache", directoryHint: .isDirectory)
        pb.copyFiles([URL(filePath: "/tmp/spectre-cache/123/notes.txt")])
        sync.checkLocal()
        #expect(lists.isEmpty && sent().isEmpty)
    }

    @Test func theHostsCopyOrTextTakesTheListBack() {
        let pb = FakePasteboard()
        let (sync, _) = make(pb)
        var lists: [[URL]] = []
        sync.start()
        sync.sendFiles = { lists.append($0) }
        pb.copyFiles([URL(filePath: "/Users/me/a.pdf")])
        sync.checkLocal()
        sync.hostChanged("from the host")
        #expect(lists.count == 2 && lists[1].isEmpty)
        pb.copyFiles([URL(filePath: "/Users/me/b.pdf")])
        sync.checkLocal()
        let mark = try! #require(sync.markForCopiedFiles())
        #expect(sync.putCopiedFiles([URL(filePath: "/tmp/x")], ifUnchangedSince: mark))
        #expect(lists.count == 4 && lists[3].isEmpty)
        // Turning sharing off takes it back too.
        pb.copyFiles([URL(filePath: "/Users/me/c.pdf")])
        sync.checkLocal()
        sync.isEnabled = false
        #expect(lists.count == 6 && lists[5].isEmpty)
    }
}

@Suite("Client name")
struct ClientNameTests {
    @Test func sanitized() {
        #expect(ClientName.sanitized("Kbys-Mac-mini") == "Kbys-Mac-mini")
        #expect(ClientName.sanitized("a/b") == "")
        #expect(ClientName.sanitized("") == "")
        let long = ClientName.sanitized(String(repeating: "é", count: 40))
        #expect(long.utf8.count <= ClientName.maxBytes && long.utf8.count == 64)
        #expect(ClientName.sanitized("e\u{301}") == "\u{e9}")
    }

    @Test func currentIsUsable() {
        let name = ClientName.current()
        #expect(name.isEmpty || GDPSession.isValidFileName(name))
    }
}
