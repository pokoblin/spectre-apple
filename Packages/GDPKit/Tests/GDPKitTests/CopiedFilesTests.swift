import Foundation
import Testing
@testable import GDPKit

/// The viewer's copied files, read by the host (§7.12, file-clipboard).
@Suite("The client's copied files (§7.12)")
struct CopiedFilesTests {
    private static let capabilities = [GDPSession.Capability.clipboard, GDPSession.Capability.file,
                                       GDPSession.Capability.fileClipboard]

    private func setUp(_ configure: (inout GDPTestHost.Configuration) -> Void = { _ in },
                       capabilities: [String] = CopiedFilesTests.capabilities)
        async throws -> (GDPTestHost, Recorder, GDPSession) {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = Self.capabilities
        configure(&hc)
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = capabilities }
        return (host, rec, session)
    }

    /// f.bin (10 000 bytes), D/a.txt, D/sub/b.txt, D/link -> /etc, top-link -> f.bin.
    private func files() throws -> (dir: URL, file: URL, folder: URL, link: URL, data: Data) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gdpkit-copies-\(UUID().uuidString)")
        let folder = dir.appending(path: "D")
        try FileManager.default.createDirectory(at: folder.appending(path: "sub"), withIntermediateDirectories: true)
        let file = dir.appending(path: "f.bin")
        let data = Data(randomFrame(10_000))
        try data.write(to: file)
        try Data("a".utf8).write(to: folder.appending(path: "a.txt"))
        try Data("bb".utf8).write(to: folder.appending(path: "sub/b.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path(percentEncoded: false),
                                                   withDestinationPath: "/etc")
        let link = dir.appending(path: "top-link")
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false),
                                                   withDestinationPath: file.path(percentEncoded: false))
        return (dir, file, folder, link, data)
    }

    private func result(_ host: GDPTestHost, _ id: UInt64,
                        until done: @escaping (GDPTestHost.FetchResult) -> Bool = { $0.finished || $0.state == .reset })
        async -> GDPTestHost.FetchResult? {
        _ = await eventually(.seconds(10)) { host.fetchResult(id).map(done) ?? false }
        return host.fetchResult(id)
    }

    @Test func copiedFilesAreListedWithWhatIsInTheirFolders() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([f.file, f.folder])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let (listID, entries) = host.clientFileList
        #expect(listID != 0)
        // Breadth-first, parents first; the link inside the folder left out.
        #expect(entries == ["0 f.bin", "0 D/", "2 a.txt", "2 sub/", "4 b.txt"])
        session.close()
    }

    @Test func aFileIsReadWholeOrInPart() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, rec, session) = try await setUp()
        session.setCopiedFiles([f.file])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let listID = host.clientFileList.listID
        let whole = host.fetch(.init(listID: listID, index: 0))
        let r = try #require(await result(host, whole))
        #expect(r.state == .sending && r.finished)
        #expect(r.name == "f.bin" && r.size == 10_000 && r.offset == 0 && r.fileSize == 10_000)
        #expect(Data(r.data) == f.data)
        // Reported done once the host has it all.
        #expect(await eventually { rec.snapshot.filesFinished.values.contains(.saved(name: "f.bin", directory: nil)) })

        let part = try #require(await result(host, host.fetch(.init(listID: listID, index: 0, offset: 4000, length: 1000))))
        #expect(part.offset == 4000 && part.size == 1000 && part.fileSize == 10_000)
        #expect(Data(part.data) == f.data[4000..<5000])
        let past = try #require(await result(host, host.fetch(.init(listID: listID, index: 0, offset: 20_000))))
        #expect(past.state == .sending && past.size == 0 && past.finished && past.data.isEmpty)
        session.close()
    }

    @Test func whatIsntAFileOfTheListIsGone() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([f.file, f.folder])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let listID = host.clientFileList.listID
        for request in [GDPTestHost.FetchRequest(listID: listID, index: 1), // a folder's bytes
                        .init(listID: listID, index: 99), // past the end
                        .init(listID: listID + 7, index: 0), // a list never sent
                        .init(listID: listID, index: 0, listing: true), // a file's listing
                        .init(shareID: 3, path: "")] { // no shares (file-share not in effect)
            let r = try #require(await result(host, host.fetch(request)))
            #expect(r.state == .refused && r.error == .gone && r.finished, "\(request)")
        }
        session.close()
    }

    @Test func aCopiedLinkIsFollowedOneInsideIsNot() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([f.link])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let r = try #require(await result(host, host.fetch(.init(listID: host.clientFileList.listID, index: 0))))
        #expect(r.name == "top-link" && Data(r.data) == f.data)
        session.close()
    }

    @Test func anUnlistedFolderIsListedOnRequest() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        // Long names, many of them: the list (512 KiB) has no room for them.
        let big = f.dir.appending(path: "big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        let stem = String(repeating: "n", count: 200)
        for i in 0..<3000 { FileManager.default.createFile(atPath: big.appending(path: "\(stem) \(i)").path(), contents: nil) }
        let (host, _, session) = try await setUp()
        let start = ContinuousClock.now
        session.setCopiedFiles([big])
        #expect(ContinuousClock.now - start < .milliseconds(50)) // listed off the session's queue
        #expect(await eventually(.seconds(20)) { host.observed.clientFileLists == 1 })
        let (listID, entries) = host.clientFileList
        #expect(entries == ["0 big/?"])
        let r = try #require(await result(host, host.fetch(.init(listID: listID, index: 0, listing: true))))
        #expect(r.state == .listing && r.firstIndex == 1 && r.entries.count == 3000)
        // Its files can be read by their new indices.
        let last = try #require(await result(host, host.fetch(.init(listID: listID, index: 3000))))
        #expect(last.state == .sending && last.size == 0)
        session.close()
    }

    @Test func aFolderIsListedOnRequestToo() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([f.folder])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let listID = host.clientFileList.listID
        let r = try #require(await result(host, host.fetch(.init(listID: listID, index: 0, listing: true))))
        #expect(r.state == .listing && r.firstIndex == 1 && r.entries == ["a.txt", "sub/"])
        let inner = try #require(await result(host, host.fetch(.init(listID: listID, index: 3))))
        #expect(inner.name == "b.txt" && inner.data == Array("bb".utf8))
        session.close()
    }

    @Test func earlierListsAreKeptAWhile() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        var ids: [UInt64] = []
        for n in 1...6 {
            session.setCopiedFiles([f.file])
            #expect(await eventually { host.observed.clientFileLists == UInt32(n) })
            ids.append(host.clientFileList.listID)
        }
        #expect(Set(ids).count == 6)
        // The newest five are answered; the first is gone.
        let first = try #require(await result(host, host.fetch(.init(listID: ids[0], index: 0))))
        #expect(first.state == .refused && first.error == .gone)
        let second = try #require(await result(host, host.fetch(.init(listID: ids[1], index: 0))))
        #expect(second.state == .sending && Data(second.data) == f.data)
        session.close()
    }

    @Test func takingItBackSendsAnEmptyList() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([f.file])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let first = host.clientFileList.listID
        session.setCopiedFiles([])
        #expect(await eventually { host.observed.clientFileLists == 2 })
        #expect(host.clientFileList.listID != first && host.clientFileList.entries.isEmpty)
        session.close()
    }

    @Test func aDecomposedNameGoesComposed() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let nfd = f.dir.appending(path: "e\u{301}te\u{301}.txt")
        try Data("été".utf8).write(to: nfd)
        let (host, _, session) = try await setUp()
        session.setCopiedFiles([nfd])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let entry = try #require(host.clientFileList.entries.first)
        #expect(Array(entry.utf8) == Array("0 \u{e9}t\u{e9}.txt".utf8))
        let r = try #require(await result(host, host.fetch(.init(listID: host.clientFileList.listID, index: 0))))
        #expect(Array(r.name.utf8) == Array("\u{e9}t\u{e9}.txt".utf8) && r.data == Array("été".utf8))
        session.close()
    }

    @Test func theHostStoppingWantingItEndsTheServe() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, rec, session) = try await setUp()
        rec.serveTarget.withLock { $0.hold = true }
        session.setCopiedFiles([f.file])
        #expect(await eventually { host.observed.clientFileLists == 1 })
        let id = host.fetch(.init(listID: host.clientFileList.listID, index: 0))
        #expect(await eventually { !rec.snapshot.served.isEmpty })
        let serve = try #require(rec.snapshot.served.first?.key)
        #expect(await eventually { host.fetchResult(id)?.state == .sending })
        host.resetFetch(id)
        #expect(await eventually { rec.snapshot.filesFinished[serve] == .cancelledByHost })
        // And the next one goes as usual.
        rec.serveTarget.withLock { $0.hold = false }
        let again = try #require(await result(host, host.fetch(.init(listID: host.clientFileList.listID, index: 0))))
        #expect(Data(again.data) == f.data)
        session.close()
    }

    @Test func nothingWithoutFileClipboard() async throws {
        let f = try files()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp(capabilities: [GDPSession.Capability.clipboard,
                                                                GDPSession.Capability.file])
        session.setCopiedFiles([f.file])
        let id = host.fetch(.init(listID: 1, index: 0))
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.observed.clientFileLists == 0 && host.observed.fetchAnswers == 0)
        #expect(host.fetchResult(id)?.state == .waiting)
        session.close()
    }
}
