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

/// A host that takes files into a fresh directory, and a session to it
/// whose file events go to a ``FileTransfers``.
@MainActor
private final class Harness {
    let directory: URL
    let host: GDPTestHost
    let session: GDPSession
    let transfers: FileTransfers

    init(_ configure: (inout GDPTestHost.Configuration) -> Void = { _ in }) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "spectrekit-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var hc = GDPTestHost.Configuration()
        hc.capabilities = [GDPSession.Capability.file]
        hc.fileDirectory = directory
        configure(&hc)
        host = try GDPTestHost(hc)
        let box = Mutex<FileTransfers?>(nil)
        var handlers = GDPSession.Handlers()
        handlers.fileAccepted = { id in box.withLock { $0 }?.fileAccepted(id) }
        handlers.fileProgress = { id, acked in box.withLock { $0 }?.fileProgress(id, acked) }
        handlers.fileFinished = { id, outcome in box.withLock { $0 }?.fileFinished(id, outcome) }
        session = GDPSession(handlers: handlers)
        transfers = FileTransfers(sender: session)
        box.withLock { $0 = transfers }
        var config = host.sessionConfiguration(codecs: ["h264"])
        config.capabilities = [GDPSession.Capability.file]
        try session.connect(config)
        #expect(await until { self.host.observed.accepted })
        // Accepted on the host's side a moment before the client knows.
        try await Task.sleep(for: .milliseconds(50))
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

private func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ $0 >> 9) }
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
        let content = bytes(24 << 20, seed: 7)
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

    @Test func whatHadntGoneWhenTheSessionEndedFails() async throws {
        let h = try await Harness { $0.fileIgnoreOffers = true }
        defer { h.done() }
        h.transfers.send((0..<6).map { MemorySource(name: "f\($0)", bytes: [UInt8($0)]) })
        #expect(await h.until { h.transfers.items.filter { $0.state == .offered }.count == 4 })
        h.host.close(code: 0)
        h.transfers.sessionEnded()
        #expect(await h.until { h.allFinished })
        #expect(h.transfers.items.allSatisfy { $0.state == .failed(.notSent) })
        // And anything added afterwards fails at once.
        h.transfers.send([MemorySource(name: "late", bytes: [1])])
        #expect(h.transfers.items.last?.state == .failed(.notSent))
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
