import Foundation
import GDPKit
import Synchronization
import Testing
@testable import SpectreKit

/// A session that takes shares, numbering them as GDPKit does.
private final class FakeSharer: FolderSharer, @unchecked Sendable {
    var shared: [(UInt64, URL, String)] = []
    var removed: [UInt64] = []
    var refuses = false
    private var next: UInt64 = 1

    func shareFolder(_ folder: URL, name: String, includeHidden: Bool) -> UInt64? {
        guard !refuses, !includeHidden else { return nil }
        defer { next += 1 }
        shared.append((next, folder, name))
        return next
    }

    func unshareFolder(_ id: UInt64) { removed.append(id) }
}

@Suite("Shared folders (§7.12)")
@MainActor
struct SharedFoldersTests {
    @Test func aFolderIsSharedAgainOnEachConnection() {
        let folders = SharedFolders()
        let first = FakeSharer()
        folders.attach(first)
        folders.share(URL(filePath: "/Users/me/Desktop", directoryHint: .isDirectory))
        #expect(first.shared.map(\.2) == ["Desktop"])
        #expect(folders.folders.first?.isShared == true)
        folders.detach()
        #expect(folders.folders.first?.isShared == false && !folders.isAvailable)
        let second = FakeSharer()
        folders.attach(second)
        #expect(second.shared.map(\.2) == ["Desktop"] && folders.folders.first?.isShared == true)
    }

    @Test func pickedBeforeAConnectionGoesOnceThereIsOne() {
        let folders = SharedFolders()
        folders.share(URL(filePath: "/Users/me/Work", directoryHint: .isDirectory))
        #expect(folders.folders.count == 1 && folders.folders[0].isShared == false)
        let sharer = FakeSharer()
        folders.attach(sharer)
        #expect(sharer.shared.count == 1)
    }

    @Test func stoppingTakesItBackAndOffersItAgain() {
        let folders = SharedFolders()
        let sharer = FakeSharer()
        folders.attach(sharer)
        let url = URL(filePath: "/Users/me/Desktop", directoryHint: .isDirectory)
        folders.share(url)
        folders.share(url) // once
        #expect(folders.folders.count == 1)
        folders.stop(folders.folders[0].id)
        #expect(sharer.removed == [1] && folders.folders.isEmpty && folders.recent == [url])
        folders.share(url)
        #expect(folders.recent.isEmpty && sharer.shared.count == 2)
    }

    @Test func twoFoldersOfOneNameAreToldApart() {
        let folders = SharedFolders()
        let sharer = FakeSharer()
        folders.attach(sharer)
        folders.share(URL(filePath: "/a/Photos", directoryHint: .isDirectory))
        folders.share(URL(filePath: "/b/Photos", directoryHint: .isDirectory))
        #expect(sharer.shared.map(\.2) == ["Photos", "Photos (2)"])
    }

    @Test func aFolderThatCantBeSharedSaysSo() {
        let folders = SharedFolders()
        let sharer = FakeSharer()
        sharer.refuses = true
        folders.attach(sharer)
        folders.share(URL(filePath: "/gone", directoryHint: .isDirectory))
        #expect(folders.folders.isEmpty && folders.lastFailure == "gone")
        folders.dismissFailure()
        #expect(folders.lastFailure == nil)
    }
}
