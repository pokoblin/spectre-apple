import Foundation
import GDPKit
import Observation

/// What ``SharedFolders`` needs of a session: ``GDPSession`` itself.
public protocol FolderSharer: AnyObject, Sendable {
    func shareFolder(_ folder: URL, name: String, includeHidden: Bool) -> UInt64?
    func unshareFolder(_ id: UInt64)
}

extension GDPSession: FolderSharer {}

/// The folders a session window shares with the host, read-only
/// (gdp-spec.md §7.12, `file-share`). The host reads them as the user there
/// opens them; nothing is ever written here.
///
/// A share outlives a connection: ``attach(_:)`` shares every folder with
/// the session (a reconnect shares them again), ``detach()`` forgets the
/// session's ids. Folders are shared only while the app runs: none is
/// shared again on the next launch, but those stopped this run are offered
/// in ``recent``. Hidden files are left out.
@MainActor
@Observable
public final class SharedFolders {
    public struct Folder: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let url: URL
        /// What the host shows it as.
        public let name: String
        /// Shared with the session attached.
        public var isShared: Bool { shareID != nil }
        var shareID: UInt64?
    }

    public private(set) var folders: [Folder] = []
    /// Folders shared earlier this run, most recent first, to share again.
    public private(set) var recent: [URL] = []
    /// Whether there is a session with `file-share` in effect to share with.
    public private(set) var isAvailable = false
    /// A folder that couldn't be shared, for a notice.
    public private(set) var lastFailure: String?

    @ObservationIgnored private var sharer: FolderSharer?
    /// Folders whose security scope is open (the picker's URLs), by id.
    @ObservationIgnored private var scoped: Set<UUID> = []

    public init() {}

    /// Shares with `sharer` from now on: every folder, again.
    public func attach(_ sharer: FolderSharer) {
        detach()
        self.sharer = sharer
        isAvailable = true
        for index in folders.indices {
            folders[index].shareID = share(folders[index].url, as: folders[index].name, with: sharer)
        }
    }

    /// The session ended: its shares went with it.
    public func detach() {
        sharer = nil
        isAvailable = false
        for index in folders.indices { folders[index].shareID = nil }
    }

    /// Shares the folder the user picked (once: a folder shared already stays as it is).
    public func share(_ url: URL) {
        guard !folders.contains(where: { $0.url == url }) else { return }
        let id = UUID()
        if url.startAccessingSecurityScopedResource() { scoped.insert(id) }
        var name = fileNameForHost(url.lastPathComponent) ?? "Folder"
        // Two shares of the same name: the host numbers them, but say which.
        if folders.contains(where: { $0.name == name }) { name = fileNameForHost("\(name) (\(folders.count + 1))") ?? name }
        var folder = Folder(id: id, url: url, name: name)
        if let sharer {
            folder.shareID = share(url, as: name, with: sharer)
            if folder.shareID == nil {
                if scoped.remove(id) != nil { url.stopAccessingSecurityScopedResource() }
                lastFailure = url.lastPathComponent
                return
            }
        }
        folders.append(folder)
        recent.removeAll { $0 == url }
    }

    /// Stops sharing it; it is offered in ``recent`` from now on.
    public func stop(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let folder = folders.remove(at: index)
        if let shareID = folder.shareID { sharer?.unshareFolder(shareID) }
        if scoped.remove(id) != nil { folder.url.stopAccessingSecurityScopedResource() }
        recent.insert(folder.url, at: 0)
        recent = Array(recent.prefix(5))
    }

    public func stopAll() {
        for folder in folders { stop(folder.id) }
    }

    public func dismissFailure() { lastFailure = nil }

    private func share(_ url: URL, as name: String, with sharer: FolderSharer) -> UInt64? {
        sharer.shareFolder(url, name: name, includeHidden: false)
    }
}
