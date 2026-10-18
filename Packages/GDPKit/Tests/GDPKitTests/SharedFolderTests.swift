import Foundation
import Testing
@testable import GDPKit

/// Folders the viewer shares with the host, read-only (§7.12, file-share).
@Suite("Shared folders (§7.12)")
struct SharedFolderTests {
    private static let capabilities = [GDPSession.Capability.file, GDPSession.Capability.fileShare]

    private func setUp(capabilities: [String] = SharedFolderTests.capabilities)
        async throws -> (GDPTestHost, Recorder, GDPSession) {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = Self.capabilities
        let host = try GDPTestHost(hc)
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = capabilities }
        return (host, rec, session)
    }

    /// S/a.txt, S/.hidden, S/sub/b.txt, S/out -> /etc, S/fifo, S/sub/up -> ..
    private func folder() throws -> (dir: URL, shared: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gdpkit-share-\(UUID().uuidString)")
        let s = dir.appending(path: "S")
        try FileManager.default.createDirectory(at: s.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: s.appending(path: "a.txt"))
        try Data("h".utf8).write(to: s.appending(path: ".hidden"))
        try Data("bb".utf8).write(to: s.appending(path: "sub/b.txt"))
        try FileManager.default.createSymbolicLink(atPath: s.appending(path: "out").path(percentEncoded: false),
                                                   withDestinationPath: "/etc")
        try FileManager.default.createSymbolicLink(atPath: s.appending(path: "sub/up").path(percentEncoded: false),
                                                   withDestinationPath: "..")
        #expect(mkfifo(s.appending(path: "fifo").path(percentEncoded: false), 0o600) == 0)
        return (dir, s)
    }

    private func result(_ host: GDPTestHost, _ request: GDPTestHost.FetchRequest) async -> GDPTestHost.FetchResult? {
        let id = host.fetch(request)
        _ = await eventually(.seconds(10)) { host.fetchResult(id).map { $0.finished || $0.state == .reset } ?? false }
        return host.fetchResult(id)
    }

    @Test func aSharedFolderIsListedAndRead() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S"))
        #expect(await eventually { host.clientShares[id] == "S" })
        let root = try #require(await result(host, .init(listing: true, shareID: id, path: "")))
        // No hidden file, no link, no FIFO; a folder's contents come when asked.
        #expect(root.state == .listing && root.firstIndex == 0 && root.entries == ["a.txt", "sub/"])
        let sub = try #require(await result(host, .init(listing: true, shareID: id, path: "sub")))
        #expect(sub.entries == ["b.txt"])
        let b = try #require(await result(host, .init(shareID: id, path: "sub/b.txt")))
        #expect(b.state == .sending && b.name == "b.txt" && b.data == Array("bb".utf8))
        let part = try #require(await result(host, .init(offset: 1, shareID: id, path: "sub/b.txt")))
        #expect(part.offset == 1 && part.data == Array("b".utf8) && part.fileSize == 2)
        session.close()
    }

    @Test func nothingOutsideItCanBeReached() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S"))
        for path in ["..", "sub/..", "./a.txt", "sub//b.txt", "sub/", "/a.txt", "out", "out/passwd", "sub/up/a.txt",
                     "fifo", "a.txt\u{1}x", "a\u{7f}", ".hidden", "nothing", "a.txt/x"] {
            for listing in [false, true] {
                let r = try #require(await result(host, .init(listing: listing, shareID: id, path: path)))
                #expect(r.state == .refused && r.error == .gone && r.data.isEmpty, "\(path.debugDescription) \(listing)")
            }
        }
        // A folder has no bytes; a file has no listing.
        let dir = try #require(await result(host, .init(shareID: id, path: "sub")))
        #expect(dir.state == .refused && dir.error == .gone)
        let file = try #require(await result(host, .init(listing: true, shareID: id, path: "a.txt")))
        #expect(file.state == .refused && file.error == .gone)
        let other = try #require(await result(host, .init(listing: true, shareID: id + 9, path: "")))
        #expect(other.state == .refused && other.error == .gone)
        session.close()
    }

    @Test func hiddenFilesWhenAskedFor() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S", includeHidden: true))
        let root = try #require(await result(host, .init(listing: true, shareID: id, path: "")))
        #expect(root.entries == [".hidden", "a.txt", "sub/"])
        let hidden = try #require(await result(host, .init(shareID: id, path: ".hidden")))
        #expect(hidden.data == Array("h".utf8))
        session.close()
    }

    @Test func unsharingTakesItBack() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S"))
        #expect(await eventually { host.clientShares[id] != nil })
        session.unshareFolder(id)
        #expect(await eventually { host.clientShares.isEmpty && host.observed.shareMessages == 2 })
        let r = try #require(await result(host, .init(shareID: id, path: "a.txt")))
        #expect(r.state == .refused && r.error == .gone)
        session.close()
    }

    @Test func theFolderItselfIsWhatIsShared() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S"))
        // Moved away, and a link to elsewhere put in its place: still the folder shared.
        let moved = f.dir.appending(path: "moved")
        try FileManager.default.moveItem(at: f.shared, to: moved)
        try FileManager.default.createSymbolicLink(atPath: f.shared.path(percentEncoded: false), withDestinationPath: "/etc")
        let r = try #require(await result(host, .init(shareID: id, path: "a.txt")))
        #expect(r.state == .sending && r.data == Array("a".utf8))
        let passwd = try #require(await result(host, .init(shareID: id, path: "passwd")))
        #expect(passwd.state == .refused)
        session.close()
    }

    @Test func badNamesAndNoCapabilityShareNothing() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (_, _, session) = try await setUp()
        #expect(session.shareFolder(f.shared, name: "a/b") == nil)
        #expect(session.shareFolder(f.shared, name: "") == nil)
        #expect(session.shareFolder(f.shared.appending(path: "a.txt"), name: "file") == nil)
        session.close()
        let (_, _, plain) = try await setUp(capabilities: [GDPSession.Capability.file])
        #expect(plain.shareFolder(f.shared, name: "S") == nil)
        plain.close()
    }

    @Test func aDecomposedNameIsListedComposedAndFoundAgain() async throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try Data("é".utf8).write(to: f.shared.appending(path: "e\u{301}.txt"))
        let (host, _, session) = try await setUp()
        let id = try #require(session.shareFolder(f.shared, name: "S"))
        let root = try #require(await result(host, .init(listing: true, shareID: id, path: "")))
        #expect(root.entries.contains { Array($0.utf8) == Array("\u{e9}.txt".utf8) })
        let r = try #require(await result(host, .init(shareID: id, path: "\u{e9}.txt")))
        #expect(r.state == .sending && r.data == Array("é".utf8))
        session.close()
    }
}
