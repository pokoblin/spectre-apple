import Foundation
import GDPKit
import Synchronization
import Testing
@testable import SpectreKit

/// A source whose bytes and size the test decides: `shrinksTo` makes the
/// reader run out early, as a file truncated while being sent would.
private struct MemorySource: FileSource {
    let name: String
    let bytes: [UInt8]
    var shrinksTo: Int?
    var size: UInt64 { UInt64(bytes.count) }
    var modified: Date? { nil }

    func open() throws -> FileReader { MemoryReader(bytes: Array(bytes.prefix(shrinksTo ?? bytes.count))) }
}

private final class MemoryReader: FileReader, @unchecked Sendable {
    let bytes: [UInt8]
    var offset = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    func read(upTo count: Int) throws -> Data {
        let n = min(count, bytes.count - offset)
        defer { offset += n }
        return Data(bytes[offset..<offset + n])
    }
    func currentSize() throws -> UInt64 { UInt64(bytes.count) }
    func close() {}
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// A host that takes files into a fresh directory, and a session to it
/// whose file events go to a ``FileTransfers``.
@MainActor
private final class Harness {
    let directory: URL
    let host: GDPTestHost
    private(set) var session: GDPSession
    let transfers = FileTransfers()
    /// The current session's link, and the one before (a reconnect's stale one).
    private(set) var link: FileTransfers.Link?
    private(set) var previousLink: FileTransfers.Link?

    init(_ configure: (inout GDPTestHost.Configuration) -> Void = { _ in }) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "spectrekit-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var hc = GDPTestHost.Configuration()
        hc.capabilities = [GDPSession.Capability.file]
        hc.fileDirectory = directory
        configure(&hc)
        host = try GDPTestHost(hc)
        session = GDPSession(handlers: GDPSession.Handlers())
        try await connect()
    }

    /// A new session to the host, attached when accepted: the first, or a reconnect.
    func connect() async throws {
        let accepted = Flag()
        let relay = FileEventRelay()
        var handlers = GDPSession.Handlers()
        handlers.accepted = { _ in accepted.set() }
        handlers.fileAccepted = { relay.fileAccepted($0) }
        handlers.fileProgress = { relay.fileProgress($0, $1) }
        handlers.fileFinished = { relay.fileFinished($0, $1) }
        handlers.fileList = { relay.fileList($0, $1) }
        handlers.fileSending = { relay.fileSending($0, $1, $2, $3) }
        handlers.fileData = { relay.fileData($0, $1) }
        session = GDPSession(handlers: handlers)
        var config = host.sessionConfiguration(codecs: ["h264"])
        config.capabilities = [GDPSession.Capability.file]
        config.takeOver = true
        try session.connect(config)
        #expect(await until { accepted.isSet })
        previousLink = link
        let link = transfers.attach(session)
        relay.connect(link)
        self.link = link
    }

    func until(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    var allFinished: Bool { transfers.items.allSatisfy(\.isFinished) }

    func file(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "spectrekit-source-\(UUID().uuidString)")
            .appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    func received(_ name: String) -> Data? { try? Data(contentsOf: directory.appending(path: name)) }

    func done() {
        session.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Test contents, made cheaply (a Debug build is slow per byte, and the
/// audio tests running alongside notice the load): one 4 KiB pattern, each
/// copy stamped with its index so a piece out of place would show.
private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
    let block = (0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }
    var out = [UInt8]()
    out.reserveCapacity(count + block.count)
    var index: UInt32 = 0
    while out.count < count {
        out.append(contentsOf: block)
        withUnsafeBytes(of: index.littleEndian) { stamp in
            for (i, b) in stamp.enumerated() { out[out.count - block.count + i] = b }
        }
        index += 1
    }
    return Array(out.prefix(count))
}

@Suite("File transfers (§7.12)", .serialized)
@MainActor
struct FileTransfersTests {
    @Test func filesGoInOrderAFewAtATime() async throws {
        let h = try await Harness()
        defer { h.done() }
        let urls = try (0..<7).map { try h.file("file \($0).bin", bytes: bytes(300_000, seed: UInt8($0))) }
        h.transfers.send(urls: urls)
        var mostAtOnce = 0
        #expect(await h.until {
            let active = h.transfers.items.filter { $0.state == .offered || $0.state == .sending }.count
            mostAtOnce = max(mostAtOnce, active, Int(h.host.observed.fileStreamsOpen))
            return h.allFinished
        })
        #expect(mostAtOnce <= GDPSession.fileStreamsAtOnce)
        #expect(h.transfers.items.map(\.state) == (0..<7).map { .saved(name: "file \($0).bin") })
        #expect(h.transfers.items.allSatisfy { $0.sent == $0.size && $0.fraction == 1 })
        for i in 0..<7 { #expect(h.received("file \(i).bin") == Data(bytes(300_000, seed: UInt8(i)))) }
        #expect(h.transfers.remaining == 0 && !h.transfers.hasActive)
    }

    @Test func aLargeFileIsReadAsItGoes() async throws {
        let h = try await Harness()
        defer { h.done() }
        // Several times the initial window, so it goes in many rounds; not
        // bigger: the audio tests running alongside are timing-sensitive.
        let content = bytes(6 << 20, seed: 7)
        let url = try h.file("big.bin", bytes: content)
        h.transfers.send(urls: [url])
        var fractions: [Double] = []
        #expect(await h.until(.seconds(30)) {
            if let f = h.transfers.items.first?.fraction, f != fractions.last { fractions.append(f) }
            return h.allFinished
        })
        #expect(h.transfers.items.first?.state == .saved(name: "big.bin"))
        #expect(h.received("big.bin") == Data(content))
        #expect(fractions == fractions.sorted())
    }

    @Test func foldersAndMissingFilesFailRightAway() async throws {
        let h = try await Harness()
        defer { h.done() }
        let folder = try h.file("inside.txt", bytes: [1]).deletingLastPathComponent()
        let missing = folder.appending(path: "not-there.txt")
        h.transfers.send(urls: [folder, missing])
        #expect(h.transfers.items.map(\.state) == [.failed(.folder), .failed(.unreadable)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.host.observed.filesOffered == 0)
        #expect(h.transfers.lastBatch?.failed == [folder.lastPathComponent, "not-there.txt"])

        // With a file that goes: one batch for them all.
        let good = try h.file("good.txt", bytes: [1])
        h.transfers.send(urls: [folder, good])
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.lastBatch?.serial == 2)
        #expect(h.transfers.lastBatch?.saved == ["good.txt"] && h.transfers.lastBatch?.failed == [folder.lastPathComponent])
    }

    @Test func aFileThatCantBeOpenedIsNeverOffered() async throws {
        let h = try await Harness()
        defer { h.done() }
        let url = try h.file("gone.txt", bytes: [1, 2, 3])
        let source = try LocalFile(url: url)
        try FileManager.default.removeItem(at: url)
        h.transfers.send([source])
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.first?.state == .failed(.unreadable))
        #expect(h.host.observed.filesOffered == 0)
    }

    @Test func namesAreMadeFitForTheHost() async throws {
        #expect(fileNameForHost("report.pdf") == "report.pdf")
        #expect(fileNameForHost("a/b\\c") == "a_b_c")
        #expect(fileNameForHost("line\nbreak\u{7f}") == "line_break_")
        #expect(fileNameForHost("cafe\u{301}") == "caf\u{e9}")
        #expect(fileNameForHost("") == nil && fileNameForHost(".") == nil && fileNameForHost("..") == nil)
        let long = fileNameForHost(String(repeating: "✓", count: 100) + ".txt")
        #expect(long.map { $0.utf8.count <= 255 && $0.hasSuffix(".txt") && GDPSession.isValidFileName($0) } == true)

        let h = try await Harness()
        defer { h.done() }
        h.transfers.send([MemorySource(name: "..", bytes: [1]), MemorySource(name: "a/b.txt", bytes: [2])])
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.map(\.state) == [.failed(.badName), .saved(name: "a_b.txt")])
        #expect(h.transfers.items.map(\.name) == ["..", "a/b.txt"]) // as the user knows them
    }

    @Test func aRefusalIsShownWithItsReason() async throws {
        let h = try await Harness { $0.fileRefusal = .noSpace }
        defer { h.done() }
        h.transfers.send([MemorySource(name: "huge.iso", bytes: [1])])
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.first?.state == .failed(.refused(.noSpace)))
    }

    @Test func aFileThatShrinksIsCancelled() async throws {
        let h = try await Harness()
        defer { h.done() }
        h.transfers.send([MemorySource(name: "log.txt", bytes: bytes(1 << 20), shrinksTo: 300_000)])
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.first?.state == .failed(.changed))
        #expect(await h.until { h.host.observed.filesCancelled == 1 })
        #expect(h.received("log.txt") == nil)
    }

    @Test func cancellingWaitingAndOfferedFiles() async throws {
        // A host that never answers: the first four stay offered, the rest wait.
        let h = try await Harness { $0.fileIgnoreOffers = true }
        defer { h.done() }
        h.transfers.send((0..<6).map { MemorySource(name: "f\($0)", bytes: [UInt8($0)]) })
        #expect(await h.until { h.transfers.items.filter { $0.state == .offered }.count == 4 })
        #expect(h.transfers.items.suffix(2).allSatisfy { $0.state == .waiting })
        let waiting = h.transfers.items[5].id, offered = h.transfers.items[0].id
        h.transfers.cancel(waiting)
        h.transfers.cancel(offered)
        #expect(h.transfers.items[5].state == .cancelled && h.transfers.items[0].state == .cancelled)
        // The offered one's stream was reset; the freed slot goes to the one still waiting.
        #expect(await h.until { h.host.observed.filesCancelled == 1 && h.transfers.items[4].state == .offered })
        #expect(await h.until { h.host.observed.filesOffered == 5 })
        h.transfers.clearFinished()
        #expect(h.transfers.items.map(\.name) == ["f1", "f2", "f3", "f4"])
    }

    @Test func aLostConnectionFailsWhatWasGoingAndKeepsTheQueue() async throws {
        let h = try await Harness { $0.fileIgnoreOffers = true }
        defer { h.done() }
        h.transfers.send((0..<6).map { MemorySource(name: "f\($0)", bytes: [UInt8($0)]) })
        #expect(await h.until { h.transfers.items.filter { $0.state == .offered }.count == 4 })
        h.transfers.detach()
        #expect(!h.transfers.isAvailable)
        #expect(h.transfers.items.prefix(4).allSatisfy { $0.state == .failed(.notSent) })
        #expect(h.transfers.items.suffix(2).allSatisfy { $0.state == .waiting })
        // Added while there is no session: it waits too.
        h.transfers.send([MemorySource(name: "late", bytes: [1])])
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.transfers.items.last?.state == .waiting)
        // The old session's late events change nothing.
        h.link?.fileFinished(1, .saved(name: "f0"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.transfers.items[0].state == .failed(.notSent))
        // Back (a reconnect): the queue goes on, offered to the new session.
        let offeredBefore = h.host.observed.filesOffered
        try await h.connect()
        #expect(await h.until { h.host.observed.filesOffered == offeredBefore + 3 })
        #expect(h.transfers.items.suffix(3).allSatisfy { $0.state == .offered })
        // Nor do they once a new session has the same ids.
        h.previousLink?.fileFinished(1, .saved(name: "f4"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.transfers.items.suffix(3).allSatisfy { $0.state == .offered })
    }

    @Test func aBatchIsSummedUpWhenNothingIsLeft() async throws {
        let h = try await Harness()
        defer { h.done() }
        h.transfers.send([MemorySource(name: "a.txt", bytes: [1]), MemorySource(name: "..", bytes: [2]),
                          MemorySource(name: "b.txt", bytes: [3])])
        #expect(await h.until { h.transfers.lastBatch != nil })
        #expect(h.transfers.lastBatch == FileTransfers.Batch(serial: 1, saved: ["a.txt", "b.txt"], failed: [".."]))
        h.transfers.send([MemorySource(name: "c.txt", bytes: [4])])
        #expect(await h.until { h.transfers.lastBatch?.serial == 2 })
        #expect(h.transfers.lastBatch?.saved == ["c.txt"] && h.transfers.lastBatch?.failed == [])
    }
}

@Suite("Upload window")
struct UploadWindowTests {
    @Test func growsUnderTheTargetAndHalvesAboveIt() {
        var w = UploadWindow()
        #expect(w.bytes == UploadWindow.initial)
        // A LAN: the RTT never rises, the window grows to its ceiling.
        var t: UInt64 = 0
        for _ in 0..<200 {
            t += 1000
            w.update(rttMicroseconds: 800, now: t)
        }
        #expect(w.bytes == UploadWindow.maximum && w.baseRTT == 800)
        // The queue builds: halved, but only once per RTT.
        t += 100_000
        w.update(rttMicroseconds: 60_000, now: t)
        #expect(w.bytes == UploadWindow.maximum / 2)
        w.update(rttMicroseconds: 60_000, now: t + 10_000)
        #expect(w.bytes == UploadWindow.maximum / 2)
        w.update(rttMicroseconds: 60_000, now: t + 70_000)
        #expect(w.bytes == UploadWindow.maximum / 4)
        // Never below the floor.
        for i in 0..<100 { w.update(rttMicroseconds: 60_000, now: t + 1_000_000 * UInt64(i + 1)) }
        #expect(w.bytes == UploadWindow.minimum)
        // Within the target again: growing.
        w.update(rttMicroseconds: 20_000, now: t + 200_000_000)
        #expect(w.bytes > UploadWindow.minimum)
    }

    @Test func aBudgetWakesWhoeverWaited() {
        let budget = UploadBudget { nil }
        let window = UploadWindow.initial
        #expect(budget.reserve(window, wake: {}) == window)
        let woken = Mutex(0)
        #expect(budget.reserve(1, wake: { woken.withLock { $0 += 1 } }) == 0)
        budget.release(1000)
        #expect(woken.withLock { $0 } == 1)
        #expect(budget.reserve(5000, wake: {}) == 1000)
        #expect(budget.inFlight == window)
    }
}

/// The host's copied files, downloaded (§7.12).
@Suite("File downloads (§7.12)", .serialized)
@MainActor
struct FileDownloadTests {
    /// A host "copying" `files` (written to a folder of their own), and a
    /// download folder; both removed by `done`.
    private func harness(_ files: [(String, [UInt8])], folder: Bool = false,
                         downloads: URL? = nil) async throws -> (Harness, URL, URL) {
        let copied = FileManager.default.temporaryDirectory.appending(path: "spectrekit-copied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, content) in files {
            let url = copied.appending(path: name)
            try Data(content).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                  ofItemAtPath: url.path(percentEncoded: false))
            urls.append(url)
        }
        if folder {
            let url = copied.appending(path: "a folder")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            urls.append(url)
        }
        let h = try await Harness { $0.hostFiles = urls }
        let target = downloads ?? FileManager.default.temporaryDirectory.appending(path: "spectrekit-dl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        h.transfers.downloadDirectory = target
        #expect(await h.until { h.transfers.hostFiles != nil })
        return (h, copied, target)
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func copiedFilesAreDownloadedIntoTheFolder() async throws {
        let big = bytes(5 << 20, seed: 9)
        let (h, copied, target) = try await harness([("notes.txt", Array("copied ✓".utf8)), ("big.bin", big)],
                                                    folder: true)
        defer { h.done(); try? FileManager.default.removeItem(at: copied); try? FileManager.default.removeItem(at: target) }
        #expect(h.transfers.hostFiles?.files.map(\.name) == ["notes.txt", "big.bin", "a folder"])
        #expect(h.transfers.hostFiles?.downloadable.count == 2)
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { h.allFinished })
        let items = h.transfers.items
        #expect(items.map(\.direction) == [.download, .download, .download])
        #expect(items.map(\.state) == [.saved(name: "notes.txt"), .saved(name: "big.bin"), .failed(.folder)])
        #expect(try Data(contentsOf: target.appending(path: "notes.txt")) == Data("copied ✓".utf8))
        #expect(try Data(contentsOf: target.appending(path: "big.bin")) == Data(big))
        #expect(items[1].localURL == target.appending(path: "big.bin") && items[1].sent == UInt64(big.count))
        let mtime = try FileManager.default.attributesOfItem(atPath: target.appending(path: "notes.txt")
            .path(percentEncoded: false))[.modificationDate] as? Date
        #expect(mtime?.timeIntervalSince1970 == 1_600_000_000)
        #expect(names(in: target) == ["big.bin", "notes.txt"]) // no temporary file left
        #expect(h.transfers.lastBatch?.downloaded == ["notes.txt", "big.bin"])
        #expect(h.transfers.lastBatch?.failed == ["a folder"])
    }

    @Test func aTakenNameGetsANumber() async throws {
        let (h, copied, target) = try await harness([("report.pdf", [1, 2, 3])])
        defer { h.done(); try? FileManager.default.removeItem(at: copied); try? FileManager.default.removeItem(at: target) }
        try Data("already here".utf8).write(to: target.appending(path: "report.pdf"))
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { h.allFinished })
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.map(\.state) == [.saved(name: "report 2.pdf"), .saved(name: "report 3.pdf")])
        #expect(try Data(contentsOf: target.appending(path: "report.pdf")) == Data("already here".utf8))
        #expect(try Data(contentsOf: target.appending(path: "report 3.pdf")) == Data([1, 2, 3]))
    }

    @Test func theListFollowsTheHostsClipboard() async throws {
        let (h, copied, target) = try await harness([("a.txt", [1])])
        defer { h.done(); try? FileManager.default.removeItem(at: copied); try? FileManager.default.removeItem(at: target) }
        let first = try #require(h.transfers.hostFiles)
        let b = copied.appending(path: "b.txt")
        try Data([2]).write(to: b)
        h.host.sendFileList([b])
        #expect(await h.until { h.transfers.hostFiles?.listID != first.listID })
        #expect(h.transfers.hostFiles?.files.map(\.name) == ["b.txt"])
        h.host.sendFileList([])
        #expect(await h.until { h.transfers.hostFiles == nil })
        h.transfers.downloadCopiedFiles() // nothing to download
        #expect(h.transfers.items.isEmpty)
    }

    @Test func aCancelledOrBrokenDownloadLeavesNothingBehind() async throws {
        let big = bytes(6 << 20, seed: 2)
        let (h, copied, target) = try await harness([("big.bin", big)])
        defer { h.done(); try? FileManager.default.removeItem(at: copied); try? FileManager.default.removeItem(at: target) }
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { (h.transfers.items.first?.sent ?? 0) > 0 })
        h.transfers.cancel(h.transfers.items[0].id)
        #expect(h.transfers.items[0].state == .cancelled)
        #expect(await h.until { self.names(in: target).isEmpty })

        // The session goes mid-way: failed, and its partial file gone.
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { (h.transfers.items.last?.sent ?? 0) > 0 })
        h.transfers.detach()
        #expect(h.transfers.items.last?.state == .failed(.notSent))
        #expect(h.transfers.hostFiles == nil)
        #expect(await h.until { self.names(in: target).isEmpty })
    }

    @Test func aFolderThatCantBeWrittenFails() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "spectrekit-nowhere-\(UUID().uuidString)")
            .appending(path: "deeper")
        let (h, copied, _) = try await harness([("a.txt", [1, 2])], downloads: missing)
        defer { h.done(); try? FileManager.default.removeItem(at: copied) }
        try? FileManager.default.removeItem(at: missing) // nowhere to write
        h.transfers.downloadCopiedFiles()
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.first?.state == .failed(.couldntSave))
        #expect(h.transfers.lastBatch?.failed == ["a.txt"])
    }
}
