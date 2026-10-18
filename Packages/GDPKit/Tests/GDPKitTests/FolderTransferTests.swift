import Foundation
import Testing
@testable import GDPKit

/// A host and session with `file`, `clipboard` and `file-clipboard`.
private func treeHost(_ configure: (inout GDPTestHost.Configuration) -> Void = { _ in }) throws -> GDPTestHost {
    var hc = GDPTestHost.Configuration()
    hc.capabilities = [GDPSession.Capability.clipboard, GDPSession.Capability.file, GDPSession.Capability.fileClipboard]
    configure(&hc)
    return try GDPTestHost(hc)
}

private func treeSession(_ host: GDPTestHost, _ rec: Recorder,
                         capabilities: [String] = [GDPSession.Capability.clipboard, GDPSession.Capability.file,
                                                   GDPSession.Capability.fileClipboard]) async throws -> GDPSession {
    try await connected(host, rec) { $0.capabilities = capabilities }
}

/// Hands every byte back as it arrives until fetch `id` ends.
private func drain(_ session: GDPSession, _ rec: Recorder, _ id: UInt64) async -> GDPSession.FileOutcome? {
    var consumed = 0
    _ = await eventually(.seconds(10)) {
        let got = rec.snapshot.fetched[id]?.count ?? 0
        if got > consumed {
            session.consumeFileData(id, got - consumed)
            consumed = got
        }
        return rec.snapshot.filesFinished[id] != nil
    }
    return rec.snapshot.filesFinished[id]
}

/// A/x.txt, A/B/y.txt and a 10 000-byte file.
private func tree() throws -> (dir: URL, folder: URL, file: URL, data: Data) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "gdpkit-tree-\(UUID().uuidString)")
    let folder = dir.appending(path: "A")
    try FileManager.default.createDirectory(at: folder.appending(path: "B"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: folder.appending(path: "x.txt"))
    try Data("yy".utf8).write(to: folder.appending(path: "B/y.txt"))
    let file = dir.appending(path: "f.bin")
    let data = Data(randomFrame(10_000))
    try data.write(to: file)
    return (dir, folder, file, data)
}

@Suite("Copied folders and ranges (§7.12)")
struct FolderTransferTests {
    @Test func aCopiedFolderComesWithWhatIsInIt() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost { $0.hostFiles = [t.folder] }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(rec.snapshot.accept?.capabilities.contains("file-clipboard") == true)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let list = rec.snapshot.fileLists[0].1
        #expect(list.map(\.name) == ["A", "B", "x.txt", "y.txt"])
        #expect(list.map(\.parent) == [0, 1, 1, 2])
        #expect(list.map(\.isDirectory) == [true, true, false, false])
        #expect(!list.contains { $0.isUnlisted })
        // A file inside it is fetched by its index like any other.
        let id = try #require(session.requestFile(listID: rec.snapshot.fileLists[0].0, index: 3))
        #expect(await drain(session, rec, id) == .saved(name: "y.txt"))
        #expect(rec.snapshot.fetched[id] == Array("yy".utf8))
        session.close()
    }

    @Test func anUnlistedFolderIsListedOnRequest() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost {
            $0.hostFiles = [t.folder]
            $0.fileListBudget = 1
        }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let (listID, list) = rec.snapshot.fileLists[0]
        #expect(list.map(\.name) == ["A"] && list[0].isUnlisted)
        let id = try #require(session.requestListing(listID: listID, index: 0))
        #expect(await eventually { rec.snapshot.filesFinished[id] != nil })
        #expect(rec.snapshot.filesFinished[id] == .saved(name: ""))
        let batches = rec.snapshot.listings[id] ?? []
        #expect(batches.first?.firstIndex == 1)
        let entries = batches.flatMap(\.files)
        #expect(entries.map(\.name) == ["B", "x.txt"])
        #expect(entries[0].isDirectory && entries[0].isUnlisted)
        // Its entries take indices 1 and 2 of the list: B can be listed in turn.
        let again = try #require(session.requestListing(listID: listID, index: 1))
        #expect(await eventually { rec.snapshot.filesFinished[again] != nil })
        #expect(rec.snapshot.listings[again]?.flatMap(\.files).map(\.name) == ["y.txt"])
        #expect(host.observed.listingsRequested == 2)
        session.close()
    }

    @Test func aFileHasNoListing() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost { $0.hostFiles = [t.file] }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let id = try #require(session.requestListing(listID: rec.snapshot.fileLists[0].0, index: 0))
        #expect(await eventually { rec.snapshot.filesFinished[id] != nil })
        #expect(rec.snapshot.filesFinished[id] == .refused(.gone))
        #expect(host.observed.listingsRefused == 1)
        session.close()
    }

    @Test func noListingWithoutFileClipboard() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost { $0.hostFiles = [t.folder] }
        let rec = Recorder()
        let session = try await treeSession(host, rec, capabilities: [GDPSession.Capability.clipboard,
                                                                      GDPSession.Capability.file])
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        // The old shape: what was copied, nothing of what is in it.
        #expect(rec.snapshot.fileLists[0].1.map(\.name) == ["A"])
        #expect(session.requestListing(listID: rec.snapshot.fileLists[0].0, index: 0) == nil)
        session.close()
    }

    @Test func aRangeIsWhatWasAskedFor() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost { $0.hostFiles = [t.file] }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let listID = rec.snapshot.fileLists[0].0
        let id = try #require(session.requestFile(listID: listID, index: 0, offset: 4000, length: 1000))
        #expect(await drain(session, rec, id) == .saved(name: "f.bin"))
        #expect(rec.snapshot.fetchHeaders[id]?.size == 1000)
        #expect(rec.snapshot.fetchRanges[id]?.offset == 4000 && rec.snapshot.fetchRanges[id]?.fileSize == 10_000)
        #expect(rec.snapshot.fetched[id] == Array(t.data[4000..<5000]))
        // Past the end: nothing, which is not an error.
        let past = try #require(session.requestFile(listID: listID, index: 0, offset: 20_000))
        #expect(await drain(session, rec, past) == .saved(name: "f.bin"))
        #expect(rec.snapshot.fetchHeaders[past]?.size == 0 && rec.snapshot.fetched[past] == nil)
        session.close()
    }

    @Test func aHostThatIgnoresRangesStillGivesTheRange() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost {
            $0.hostFiles = [t.file]
            $0.fileIgnoreRanges = true
        }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let listID = rec.snapshot.fileLists[0].0
        let tail = try #require(session.requestFile(listID: listID, index: 0, offset: 4000))
        #expect(await drain(session, rec, tail) == .saved(name: "f.bin"))
        #expect(rec.snapshot.fetchHeaders[tail]?.size == 6000)
        #expect(rec.snapshot.fetchRanges[tail]?.offset == 4000)
        #expect(rec.snapshot.fetched[tail] == Array(t.data[4000...]))
        let middle = try #require(session.requestFile(listID: listID, index: 0, offset: 100, length: 50))
        #expect(await drain(session, rec, middle) == .saved(name: "f.bin"))
        #expect(rec.snapshot.fetched[middle] == Array(t.data[100..<150]))
        session.close()
    }
}

extension FolderTransferTests {
    @Test func anEarlierListKeptByTheHostStillAnswers() async throws {
        let t = try tree()
        defer { try? FileManager.default.removeItem(at: t.dir) }
        let host = try treeHost {
            $0.hostFiles = [t.file]
            $0.fileKeptLists = 5
        }
        let rec = Recorder()
        let session = try await treeSession(host, rec)
        #expect(await eventually { !rec.snapshot.fileLists.isEmpty })
        let first = rec.snapshot.fileLists[0].0
        host.sendFileList([t.folder])
        #expect(await eventually { rec.snapshot.fileLists.count == 2 })
        let id = try #require(session.requestFile(listID: first, index: 0, offset: 9990))
        #expect(await drain(session, rec, id) == .saved(name: "f.bin"))
        #expect(rec.snapshot.fetched[id] == Array(t.data[9990...]))
        session.close()
    }
}
