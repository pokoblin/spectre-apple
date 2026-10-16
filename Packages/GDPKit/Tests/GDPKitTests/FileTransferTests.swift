import Foundation
import Testing
@testable import GDPKit

/// A test host that takes files, with `configure` applied.
private func fileHost(_ configure: (inout GDPTestHost.Configuration) -> Void = { _ in }) throws -> GDPTestHost {
    var hc = GDPTestHost.Configuration()
    hc.capabilities = [GDPSession.Capability.file]
    configure(&hc)
    return try GDPTestHost(hc)
}

private func fileSession(_ host: GDPTestHost, _ rec: Recorder,
                         configure: (inout GDPSession.Configuration) -> Void = { _ in }) async throws -> GDPSession {
    try await connected(host, rec) {
        $0.capabilities = [GDPSession.Capability.file]
        configure(&$0)
    }
}

/// Offers `data` as `name`, sends it once accepted (in chunks, keeping at
/// most `window` bytes unacknowledged), and waits for the outcome.
private func upload(_ session: GDPSession, _ rec: Recorder, name: String, data: [UInt8], modified: Date? = nil,
                    chunk: Int = 256 * 1024, window: UInt64 = 2 << 20) async throws -> GDPSession.FileOutcome {
    let id = try #require(session.offerFile(name: name, size: UInt64(data.count), modified: modified))
    #expect(await eventually { rec.snapshot.filesAccepted.contains(id) || rec.snapshot.filesFinished[id] != nil })
    if rec.snapshot.filesAccepted.contains(id) {
        var sent = 0
        let deadline = ContinuousClock.now + .seconds(20)
        // Until it's all sent, or the host has ended it early.
        while sent < data.count, rec.snapshot.filesFinished[id] == nil, ContinuousClock.now < deadline {
            let acked = rec.snapshot.fileProgress[id]?.last ?? 0
            if UInt64(sent) - acked >= window {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            let n = min(chunk, data.count - sent)
            session.sendFileData(id, Data(data[sent..<sent + n]))
            sent += n
        }
    }
    #expect(await eventually(.seconds(20)) { rec.snapshot.filesFinished[id] != nil })
    return try #require(rec.snapshot.filesFinished[id])
}

@Suite("File transfer (§7.12)")
struct FileTransferTests {
    @Test func aFileArrivesWithItsNameAndTime() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        #expect(rec.snapshot.accept?.capabilities == ["file"])
        #expect(host.observed.capabilities == ["file"])

        let data = randomFrame(70_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_000.123)
        // Decomposed é (e + U+0301): sent as NFC.
        let outcome = try await upload(session, rec, name: "cafe\u{301}.txt", data: data, modified: modified)
        #expect(outcome == .saved(name: "café.txt"))
        let received = host.receivedFiles
        #expect(received.count == 1)
        #expect(received.first?.name == "café.txt")
        #expect(Array(received.first?.name.utf8 ?? "".utf8) == Array("caf\u{e9}.txt".utf8))
        #expect(received.first?.data == data)
        #expect(received.first?.modifiedUnixMilliseconds == 1_700_000_000_123)
        // Progress counts file bytes only, and ends at the size.
        let progress = rec.snapshot.fileProgress.values.first ?? []
        #expect(progress == progress.sorted())
        #expect(await eventually { (rec.snapshot.fileProgress.values.first?.last ?? 0) == UInt64(data.count) })
        #expect(await eventually { host.observed.fileStreamsOpen == 0 })
        session.close()
    }

    @Test func aTakenNameIsNumbered() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        #expect(try await upload(session, rec, name: "report.pdf", data: [1, 2, 3]) == .saved(name: "report.pdf"))
        #expect(try await upload(session, rec, name: "report.pdf", data: [4, 5]) == .saved(name: "report (1).pdf"))
        #expect(host.receivedFiles.map(\.savedName) == ["report.pdf", "report (1).pdf"])
        session.close()
    }

    @Test func aLargeFileFollowsTheAcknowledgements() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let data = randomFrame(8 << 20)
        #expect(try await upload(session, rec, name: "big.bin", data: data) == .saved(name: "big.bin"))
        #expect(host.receivedFiles.first?.data == data)
        session.close()
    }

    @Test func anEmptyFileIsAFile() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        #expect(try await upload(session, rec, name: "empty", data: []) == .saved(name: "empty"))
        #expect(host.receivedFiles.first?.data == [])
        session.close()
    }

    @Test func moreFilesThanStreamsAllArrive() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        // The host grants 4 streams at once and replaces each that closes.
        for round in 0..<3 {
            let ids = (0..<GDPSession.fileStreamsAtOnce).compactMap {
                session.offerFile(name: "f\(round)-\($0)", size: 1, modified: nil)
            }
            #expect(ids.count == GDPSession.fileStreamsAtOnce)
            #expect(await eventually { ids.allSatisfy(rec.snapshot.filesAccepted.contains) })
            for id in ids { session.sendFileData(id, Data([UInt8(round)])) }
            #expect(await eventually { ids.allSatisfy { rec.snapshot.filesFinished[$0] != nil } })
        }
        #expect(host.observed.filesSaved == 12)
        session.close()
    }

    @Test func badNamesAreNeverOffered() async throws {
        #expect(GDPSession.isValidFileName("notes.txt"))
        #expect(GDPSession.isValidFileName(String(repeating: "a", count: 255)))
        for bad in ["", ".", "..", "../etc/passwd", "a/b", "a\\b", "tab\there", "nul\u{0}byte",
                    String(repeating: "a", count: 256), String(repeating: "✓", count: 86)] {
            #expect(!GDPSession.isValidFileName(bad), "\(bad.debugDescription)")
        }
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        #expect(session.offerFile(name: "../escape", size: 1, modified: nil) == nil)
        #expect(session.offerFile(name: "nul\u{0}byte", size: 1, modified: nil) == nil)
        #expect(host.observed.filesOffered == 0)
        session.close()
    }

    @Test func nothingIsOfferedWithoutTheCapability() async throws {
        let host = try GDPTestHost() // takes no files
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.file] }
        #expect(rec.snapshot.accept?.capabilities == [])
        #expect(session.offerFile(name: "x.txt", size: 1, modified: nil) == nil)
        session.close()

        let unconnected = GDPSession(handlers: Recorder().handlers())
        #expect(unconnected.offerFile(name: "x.txt", size: 1, modified: nil) == nil)
    }

    @Test func aRefusalSaysWhy() async throws {
        let host = try fileHost { $0.fileRefusal = .noSpace }
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        #expect(try await upload(session, rec, name: "huge.iso", data: [1]) == .refused(.noSpace))
        #expect(rec.snapshot.filesAccepted.isEmpty)
        #expect(host.observed.filesRefused == 1 && host.receivedFiles.isEmpty)
        #expect(await eventually { host.observed.fileStreamsOpen == 0 })
        session.close()
    }

    @Test func aHostThatGivesUpMidwaySaysSo() async throws {
        let host = try fileHost { $0.fileFailAfter = 1 << 20 }
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let outcome = try await upload(session, rec, name: "partial.bin", data: randomFrame(4 << 20))
        #expect(outcome == .failed(.writeFailed))
        #expect(host.observed.filesFailed == 1 && host.receivedFiles.isEmpty)
        // The session goes on: the next file still arrives.
        #expect(try await upload(session, rec, name: "next.txt", data: [7]) == .saved(name: "next.txt"))
        session.close()
    }

    @Test func anUnansweredOfferTimesOut() async throws {
        let host = try fileHost { $0.fileIgnoreOffers = true }
        let rec = Recorder()
        let session = try await fileSession(host, rec) { $0.fileReplyTimeoutMilliseconds = 300 }
        let id = try #require(session.offerFile(name: "waiting.txt", size: 3, modified: nil))
        #expect(await eventually { rec.snapshot.filesFinished[id] != nil })
        #expect(rec.snapshot.filesFinished[id] == .timedOut)
        // The stream was reset: the host sees it go.
        #expect(await eventually { host.observed.filesCancelled == 1 && host.observed.fileStreamsOpen == 0 })
        session.close()
    }

    @Test func cancellingResetsTheStreamQuietly() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let data = randomFrame(1 << 20)
        let id = try #require(session.offerFile(name: "cancelled.bin", size: UInt64(data.count) * 4, modified: nil))
        #expect(await eventually { rec.snapshot.filesAccepted.contains(id) })
        session.sendFileData(id, Data(data))
        #expect(await eventually { (rec.snapshot.fileProgress[id]?.last ?? 0) > 0 })
        session.cancelFile(id)
        #expect(await eventually { host.observed.filesCancelled == 1 && host.observed.fileStreamsOpen == 0 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.snapshot.filesFinished[id] == nil)
        #expect(host.receivedFiles.isEmpty)
        // Data for a cancelled file goes nowhere.
        session.sendFileData(id, Data([1]))
        session.close()
    }

    @Test func aTransferEndsWithTheConnection() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let id = try #require(session.offerFile(name: "unfinished.bin", size: 10, modified: nil))
        #expect(await eventually { rec.snapshot.filesAccepted.contains(id) })
        session.sendFileData(id, Data([1, 2, 3]))
        host.close(code: 0)
        #expect(await eventually { rec.snapshot.ending != nil })
        #expect(rec.snapshot.filesFinished[id] == .connectionEnded)
        // Reported before the session's own end.
        #expect(rec.snapshot.fileFinishOrder.first.map { $0.0 == id && !$0.1 } == true)
        #expect(host.receivedFiles.isEmpty)
    }

    @Test func aHostWithADirectoryWritesThere() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gdpkit-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A file of that name is already there: never replaced.
        try Data("old".utf8).write(to: dir.appending(path: "notes.txt"))
        let host = try fileHost { $0.fileDirectory = dir }
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let data = randomFrame(300_000)
        let modified = Date(timeIntervalSince1970: 1_600_000_000.5)
        #expect(try await upload(session, rec, name: "notes.txt", data: data, modified: modified)
            == .saved(name: "notes (1).txt"))
        #expect(try Data(contentsOf: dir.appending(path: "notes.txt")) == Data("old".utf8))
        let written = dir.appending(path: "notes (1).txt")
        #expect(try Data(contentsOf: written) == Data(data))
        let mtime = try FileManager.default.attributesOfItem(atPath: written.path)[.modificationDate] as? Date
        #expect(mtime.map { abs($0.timeIntervalSince1970 - 1_600_000_000.5) < 0.001 } == true)
        let received = try #require(host.receivedFiles.first)
        #expect(received.data.isEmpty && received.size == UInt64(data.count))
        #expect(received.path == written.path(percentEncoded: false))

        // Cancelled part way: its temporary file goes.
        let id = try #require(session.offerFile(name: "gone.bin", size: 1 << 20, modified: nil))
        #expect(await eventually { rec.snapshot.filesAccepted.contains(id) })
        session.sendFileData(id, Data(randomFrame(1000)))
        #expect(await eventually { (rec.snapshot.fileProgress[id]?.last ?? 0) == 1000 })
        session.cancelFile(id)
        #expect(await eventually { host.observed.filesCancelled == 1 })
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.sorted() == ["notes (1).txt", "notes.txt"])
        session.close()
    }

    @Test func bytesPastTheSizeAreNotSent() async throws {
        let host = try fileHost()
        let rec = Recorder()
        let session = try await fileSession(host, rec)
        let id = try #require(session.offerFile(name: "three.bin", size: 3, modified: nil))
        // Before acceptance nothing goes out either.
        session.sendFileData(id, Data([9]))
        #expect(await eventually { rec.snapshot.filesAccepted.contains(id) })
        session.sendFileData(id, Data([1, 2, 3, 4, 5]))
        session.sendFileData(id, Data([1, 2, 3]))
        #expect(await eventually { rec.snapshot.filesFinished[id] != nil })
        #expect(rec.snapshot.filesFinished[id] == .saved(name: "three.bin"))
        #expect(host.receivedFiles.first?.data == [1, 2, 3])
        session.close()
    }
}
