import Foundation
import GDPKit
import Observation
import Synchronization

/// What ``FileTransfers`` needs of a session: ``GDPSession`` itself.
public protocol FileSender: AnyObject, Sendable {
    func offerFile(name: String, size: UInt64, modified: Date?) -> UInt64?
    func sendFileData(_ id: UInt64, _ data: Data)
    func cancelFile(_ id: UInt64)
    func requestFile(listID: UInt64, index: UInt32) -> UInt64?
    func requestListing(listID: UInt64, index: UInt32) -> UInt64?
    func consumeFileData(_ id: UInt64, _ count: Int)
    func linkStats() -> GDPSession.LinkStats?
}

extension GDPSession: FileSender {}

/// A session window's files on their way to the host, and the host's
/// copied files on their way here (gdp-spec.md §7.12): one queue, at most
/// ``GDPSession/fileStreamsAtOnce`` going at once, each read as the host
/// takes it in, or written as it arrives.
///
/// It outlives a connection: ``attach(_:)`` gives it the session to send
/// through (one with `file` in effect), ``detach()`` takes it away when the
/// connection ends. What was on its way then fails; what was still queued
/// waits for the next session (a reconnect) and goes on.
///
/// A file is opened (off the main thread) before it is offered, so one that
/// can't be read never reaches the host. Once the host accepts it, its
/// bytes are read in 256 KiB pieces and sent as the session's
/// ``UploadWindow`` allows; each acknowledgement makes room for the next.
/// Nothing reads a whole file into memory.
///
/// The host lists what its user copies (``hostFiles``);
/// ``downloadCopiedFiles()`` fetches them into ``downloadDirectory``, each
/// through a hidden temporary file there, renamed into place ("name 2.ext"
/// when the name is taken) once every byte is down. A file's bytes are
/// handed back to the session only once written, so a slow disk holds the
/// host back. With `file-clipboard` in effect a copied folder comes too: one
/// item, whose folders are listed (asking the host for those its list had
/// no room for), made here, and filled file by file; its files are not
/// items of their own.
///
/// With a ``clipboard`` to put them on, a list that is small enough
/// (``HostFiles/fitsClipboard``) is fetched as soon as it comes, into a
/// cache folder of its own, and the files go on the local clipboard once
/// every one is down: pasting in the Finder pastes them. Those fetches
/// are not among ``items``; ``clipboardFetch`` says how the latest went.
///
/// The session's file events reach it through the ``Link`` that
/// ``attach(_:)`` returns, from the session's queue; everything the
/// interface reads is on the main actor.
@MainActor
@Observable
public final class FileTransfers {
    public enum Direction: Sendable, Equatable {
        /// To the host.
        case upload
        /// From the host: one of its copied files.
        case download
    }

    public struct Item: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable {
            /// In the queue, or being opened.
            case waiting
            /// Offered (or asked for), waiting for the host's answer.
            case offered
            case sending
            /// An upload: stored by the host under `name`. A download:
            /// stored here under `name`, at ``Item/localURL``.
            case saved(name: String)
            case failed(Failure)
            case cancelled
        }

        public let id: Int
        public internal(set) var direction: Direction = .upload
        /// As the user knows it (a download: as the host named it).
        public let name: String
        public internal(set) var size: UInt64
        /// Bytes the host has acknowledged, or (a download) written here.
        public internal(set) var sent: UInt64 = 0
        public internal(set) var state: State = .waiting
        /// A download, once stored.
        public internal(set) var localURL: URL?
        /// An upload, once stored: the host's folder it is in (an absolute
        /// path there), if the host said.
        public internal(set) var hostDirectory: String?
        /// Fetched for the clipboard (not shown, not part of a batch).
        var isForClipboard = false
        /// A download of a copied folder, and all that is in it.
        public internal(set) var isFolder = false
        /// One file of a folder's download (or a listing of one of its
        /// folders): the folder item's id. Not shown, not part of a batch.
        var group: Int?
        var isShown: Bool { !isForClipboard && group == nil }

        public var isFinished: Bool {
            switch state {
            case .waiting, .offered, .sending: false
            case .saved, .failed, .cancelled: true
            }
        }
        public var fraction: Double { size == 0 ? (isFinished ? 1 : 0) : Double(sent) / Double(size) }
    }

    public enum Failure: Sendable, Equatable {
        /// A folder: not sent in this version, and not fetched from a host
        /// without `file-clipboard`.
        case folder
        /// It couldn't be read.
        case unreadable
        /// Its name has nothing usable left for the host.
        case badName
        /// It changed while being sent.
        case changed
        /// The host said no, or gave up part way.
        case refused(GDPSession.FileError)
        case hostFailed(GDPSession.FileError)
        case cancelledByHost
        case timedOut
        /// The connection ended (or the host stopped taking files) before it went.
        case notSent
        /// A download: it couldn't be written here.
        case couldntSave
        /// A folder's download: some of what is in it didn't come.
        case incomplete
        /// A folder's download: more in it than a list may hold.
        case tooMany
    }

    /// What the host's user copied (§7.12), to download.
    public struct HostFiles: Sendable, Equatable {
        public var listID: UInt64
        /// The whole list: what was copied and, with `file-clipboard`, what
        /// is in its folders (``GDPSession/FileListEntry/parent``).
        public var files: [GDPSession.FileListEntry]
        /// `file-clipboard` is in effect: a folder's contents can be had.
        public var foldersHaveContents = false

        public init(listID: UInt64, files: [GDPSession.FileListEntry], foldersHaveContents: Bool = false) {
            self.listID = listID
            self.files = files
            self.foldersHaveContents = foldersHaveContents
        }

        /// What the host's user copied, in order.
        public var copied: [GDPSession.FileListEntry] { files.filter { $0.parent == 0 } }
        /// Those that can be downloaded: files, and folders with `file-clipboard`.
        public var downloadable: [GDPSession.FileListEntry] {
            copied.filter { !$0.isDirectory || foldersHaveContents }
        }
        /// Whether they are fetched for the clipboard as soon as they are
        /// listed: ``FileTransfers/clipboardLimit`` at most in all, folders
        /// only with all of their contents in the list.
        public var fitsClipboard: Bool {
            let tree = HostFileTree(files)
            var total: UInt64 = 0
            var any = false
            for (i, file) in files.enumerated() where file.parent == 0 {
                any = true
                if file.isDirectory {
                    guard foldersHaveContents, tree.unlisted(under: UInt32(i)).isEmpty else { return false }
                    total += tree.totalSize(under: UInt32(i))
                } else {
                    total += file.size
                }
                if total > FileTransfers.clipboardLimit { return false }
            }
            return any
        }
    }

    /// How the latest list's fetch for the clipboard went.
    public struct ClipboardFetch: Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case fetching
            /// Every file is down and on the clipboard.
            case onClipboard
            /// One couldn't be fetched, or the clipboard changed meanwhile.
            case notOnClipboard
        }
        public var listID: UInt64
        public var state: State
    }

    /// The most a list of copied files may come to, to be fetched for the clipboard.
    public nonisolated static let clipboardLimit: UInt64 = 100_000_000

    /// A run of transfers that has just finished (nothing left going), for
    /// a notice; `serial` tells one from the next.
    public struct Batch: Sendable, Equatable {
        public var serial: Int
        /// The host's names of what was saved, the names of what was
        /// downloaded here, and of what didn't go either way.
        public var saved: [String]
        public var failed: [String]
        public var downloaded: [String] = []
        /// The host's folder every saved file went to, if the host said
        /// and it is one folder.
        public var hostDirectory: String?
    }

    /// What the user sent and downloaded, oldest first.
    public var items: [Item] { allItems.filter(\.isShown) }
    private var allItems: [Item] = []
    /// The files of folders being downloaded, and listings of their folders,
    /// by id: kept apart, since a folder may hold thousands.
    @ObservationIgnored private var subs: [Int: Item] = [:]
    /// Folders being downloaded, by their item's id.
    @ObservationIgnored private var folders: [Int: FolderJob] = [:]
    /// The listing request behind each listing's session id.
    @ObservationIgnored private var listingWires: [UInt64: (folder: Int, index: UInt32)] = [:]
    /// Whether the session attached has `file-clipboard` in effect: copied
    /// folders come with their contents, and the host reads this side's
    /// copied files (one stream is kept free for that).
    @ObservationIgnored private var fileClipboard = false
    /// The most a folder's download lists (gdp-spec.md §7.12).
    nonisolated static let maxFolderEntries = 100_000

    /// The host reading this side's copied files (`file-clipboard`), while
    /// it does: how many, and how far they have got together.
    public struct Serving: Sendable, Equatable {
        public var files: Int
        public var size: UInt64
        public var sent: UInt64
    }
    public private(set) var serving: Serving?
    /// Each file the host is reading, by the session's id: its size and how much it has.
    @ObservationIgnored private var serves: [UInt64: (size: UInt64, sent: UInt64)] = [:]
    /// What a file the host reads is sent through, reached from the session's
    /// queue: its pump starts there, before any event about it can come.
    private struct Plumbing {
        var generation = 0
        var sender: FileSender?
        var budget: UploadBudget?
    }
    @ObservationIgnored nonisolated private let plumbing = Mutex(Plumbing())
    /// The host's copied files, while it has some (nil: none, or no session).
    public private(set) var hostFiles: HostFiles?
    /// Where downloads go: the user's Downloads folder unless set.
    @ObservationIgnored public var downloadDirectory: URL = FileManager.default.urls(for: .downloadsDirectory,
                                                                                   in: .userDomainMask)[0]
    public private(set) var lastBatch: Batch?
    /// Where the host's copied files go as soon as they are listed (see
    /// ``HostFiles/fitsClipboard``); nil: nowhere, they wait for
    /// ``downloadCopiedFiles()``.
    @ObservationIgnored public weak var clipboard: CopiedFilesClipboard?
    /// The latest list's fetch for the clipboard, if it had one.
    public private(set) var clipboardFetch: ClipboardFetch?
    /// Whether there is a session to send through.
    public private(set) var isAvailable = false

    /// Bytes still to go, over everything unfinished.
    public var remaining: UInt64 {
        items.filter { !$0.isFinished }.reduce(0) { $0 + ($1.size - min($1.sent, $1.size)) }
    }
    public var hasActive: Bool { items.contains { !$0.isFinished } }

    /// Read pieces: big enough for few syscalls, small against the window.
    nonisolated static let chunk = 256 * 1024

    @ObservationIgnored private var sender: FileSender?
    @ObservationIgnored private var budget: UploadBudget?
    /// Changes with every attach and detach: an open finishing after one is stale.
    @ObservationIgnored private var generation = 0
    /// What the batch going on so far has come to.
    @ObservationIgnored private var batchSaved: [String] = []
    @ObservationIgnored private var batchFailed: [String] = []
    @ObservationIgnored private var batchDownloaded: [String] = []
    /// The host's folder of each file saved in the batch (nil: not said).
    @ObservationIgnored private var batchDirectories: [String?] = []
    @ObservationIgnored private var nextID = 0
    /// What one item does: offer a file, or fetch one of the host's.
    private enum Job {
        case upload(FileSource)
        /// Into `directory`, or (nil) ``downloadDirectory``.
        case download(listID: UInt64, index: UInt32, directory: URL?)
        /// What is in folder `index`, for the download of folder item `folder`.
        case listing(listID: UInt64, index: UInt32, folder: Int)
    }

    /// A copied folder on its way here.
    private struct FolderJob {
        var listID: UInt64
        var root: UInt32
        var tree: HostFileTree
        /// Where it goes, and (once all of it is listed) the folder made there.
        var base: URL
        var localURL: URL?
        /// Listings going, by item id: the folder each lists.
        var listings: [Int: UInt32] = [:]
        /// Its files' items, how many of them are done, how those that
        /// didn't come failed, and how many entries had unusable names.
        var children: [Int] = []
        var done = 0
        var failures: [Failure] = []
        var skipped = 0
    }
    /// Items waiting to go, oldest first.
    @ObservationIgnored private var queue: [(id: Int, job: Job)] = []
    /// Every unfinished upload's source, to queue it again after a detach.
    @ObservationIgnored private var sources: [Int: FileSource] = [:]
    /// The fetch for the clipboard going on: the list's, the clipboard's
    /// mark when it started, its folder in the cache, its items.
    @ObservationIgnored private var pendingFetch: (listID: UInt64, mark: Int, directory: URL, ids: [Int])?
    /// This window's folder for files fetched for the clipboard: one of
    /// its own, since each window's are put on the one clipboard.
    @ObservationIgnored private let clipboardCache = FileTransfers.clipboardCacheRoot
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    /// Item ids being opened or offered (counted against the stream limit).
    @ObservationIgnored private var busy: Set<Int> = []
    /// The session's id for each offered item, and back.
    @ObservationIgnored private var wireIDs: [Int: UInt64] = [:]
    @ObservationIgnored private var itemIDs: [UInt64: Int] = [:]
    /// The pumps by attachment and the session's id: reached from its queue too.
    @ObservationIgnored nonisolated private let pumps = Mutex<[PumpKey: FilePump]>([:])
    /// The same for downloads: where each one's bytes are written.
    @ObservationIgnored nonisolated private let sinks = Mutex<[PumpKey: FileSink]>([:])
    private struct PumpKey: Hashable { var generation: Int; var wire: UInt64 }

    /// Where one attached session's file events go. They count only while
    /// that session is the one attached: a session's ids start at 1, so a
    /// late event of the last one must not be taken for the next one's.
    public final class Link: Sendable {
        fileprivate let generation: Int
        fileprivate weak let transfers: FileTransfers?

        fileprivate init(generation: Int, transfers: FileTransfers) {
            self.generation = generation
            self.transfers = transfers
        }

        /// GDPSession.Handlers.fileAccepted, on the session's queue.
        public func fileAccepted(_ wire: UInt64) { transfers?.accepted(wire, generation) }
        public func fileProgress(_ wire: UInt64, _ acknowledged: UInt64) {
            transfers?.progress(wire, acknowledged, generation)
        }
        public func fileFinished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome) {
            transfers?.finished(wire, outcome, generation)
        }
        /// GDPSession.Handlers.fileList, fileSending, fileData and fileListing.
        public func fileList(_ listID: UInt64, _ files: [GDPSession.FileListEntry]) {
            transfers?.listed(listID, files, generation)
        }
        public func fileListing(_ wire: UInt64, _ firstIndex: UInt32, _ files: [GDPSession.FileListEntry]) {
            transfers?.folderListed(wire, firstIndex, files, generation)
        }
        /// GDPSession.Handlers.fileServe: the host reads one of this side's
        /// copied files. The descriptor is closed here, whatever happens.
        public func fileServe(_ wire: UInt64, _ descriptor: Int32, _ offset: UInt64, _ size: UInt64) {
            guard let transfers else {
                Darwin.close(descriptor)
                return
            }
            transfers.serve(wire, descriptor, offset, size, generation)
        }
        public func fileSending(_ wire: UInt64, _ name: String, _ size: UInt64, _ modified: Date?) {
            transfers?.sending(wire, name, size, modified, generation)
        }
        public func fileData(_ wire: UInt64, _ bytes: UnsafeRawBufferPointer) {
            transfers?.received(wire, bytes, generation)
        }
    }

    public init() {
        _ = Self.cacheCleared
    }

    /// Where windows keep files fetched for the clipboard: in the app's
    /// own caches (a sandboxed app's are its own anyway). What is in it is
    /// never offered back to the host as a copy of this side's.
    public nonisolated static let clipboardCacheRoot = FileManager.default.urls(for: .cachesDirectory,
                                                                                 in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "SpectreKit", directoryHint: .isDirectory)
        .appending(path: "Copied Files", directoryHint: .isDirectory)
    /// What the app's last run fetched for the clipboard goes once, with the first window.
    private nonisolated static let cacheCleared: Void = {
        try? FileManager.default.removeItem(at: clipboardCacheRoot)
    }()

    /// Sends through `sender` from now on: a session with `file` in effect,
    /// and `fileClipboard` if `file-clipboard` is too. Its file events go to
    /// the link returned.
    @discardableResult
    public func attach(_ sender: FileSender, fileClipboard: Bool = false) -> Link {
        detach()
        generation += 1
        self.sender = sender
        self.fileClipboard = fileClipboard
        let budget = UploadBudget { [weak sender] in sender?.linkStats()?.rttMicroseconds }
        self.budget = budget
        plumbing.withLock { $0 = Plumbing(generation: generation, sender: sender, budget: budget) }
        isAvailable = true
        startNext()
        return Link(generation: generation, transfers: self)
    }

    /// The session ended (or is being replaced): what was offered fails,
    /// what was being opened goes back to the front of the queue, and the
    /// queue waits for the next ``attach(_:)``. The session's own file
    /// events for what was offered may still come; they are ignored.
    public func detach() {
        guard sender != nil else { return }
        generation += 1
        sender = nil
        budget = nil
        plumbing.withLock { $0 = Plumbing(generation: generation) }
        serves = [:]
        serving = nil
        isAvailable = false
        dropClipboardFetch()
        clipboardFetch = nil
        for id in Array(folders.keys) { failFolder(id, .notSent) }
        let gone = pumps.withLock { pumps in
            defer { pumps = [:] }
            return Array(pumps.values)
        }
        gone.forEach { $0.close() }
        let unwritten = sinks.withLock { sinks in
            defer { sinks = [:] }
            return Array(sinks.values)
        }
        unwritten.forEach { $0.abort() }
        hostFiles = nil
        for id in itemIDs.values { fail(id, .notSent) }
        wireIDs = [:]
        itemIDs = [:]
        busy = []
        // Downloads still queued name a list of the session that went.
        for (id, job) in queue {
            if case .download = job { fail(id, .notSent) }
        }
        queue.removeAll {
            switch $0.job {
            case .upload: false
            case .download, .listing: true
            }
        }
        listingWires = [:]
        // Uploads still opening: again, first, next time.
        let queued = Set(queue.map(\.id))
        let reopening = allItems.filter { $0.direction == .upload && $0.state == .waiting && !queued.contains($0.id) }
        queue.insert(contentsOf: reopening.compactMap { item in sources[item.id].map { (item.id, .upload($0)) } },
                     at: 0)
        finishBatchIfDone()
    }

    /// Adds files to the queue; they go in order, a few at a time, as soon
    /// as there is a session.
    public func send(_ sources: [FileSource]) {
        for source in sources {
            nextID += 1
            allItems.append(Item(id: nextID, name: source.name, size: source.size))
            queue.append((nextID, .upload(source)))
            self.sources[nextID] = source
        }
        startNext()
    }

    /// Adds files the user picked or dropped; a folder or an unreadable one
    /// shows up as failed right away.
    public func send(urls: [URL]) {
        var sources: [FileSource] = []
        for url in urls {
            do {
                sources.append(try LocalFile(url: url))
            } catch {
                nextID += 1
                allItems.append(Item(id: nextID, name: url.lastPathComponent, size: 0,
                                  state: .failed(error == .folder ? .folder : .unreadable)))
                // Part of the batch the rest of these start, not one of its own.
                batchFailed.append(url.lastPathComponent)
            }
        }
        send(sources)
        finishBatchIfDone()
    }

    /// Downloads everything of ``hostFiles`` into ``downloadDirectory``; a
    /// folder shows up as failed right away, unless `file-clipboard` is in
    /// effect and it comes with what is in it.
    public func downloadCopiedFiles() {
        guard let hostFiles else { return }
        let tree = HostFileTree(hostFiles.files)
        for (index, file) in hostFiles.files.enumerated() where file.parent == 0 {
            nextID += 1
            allItems.append(Item(id: nextID, direction: .download, name: file.name, size: file.size,
                                 isFolder: file.isDirectory))
            if file.isDirectory, !hostFiles.foldersHaveContents {
                update(nextID) { $0.state = .failed(.folder) }
                batchFailed.append(file.name)
            } else if file.isDirectory {
                startFolder(nextID, listID: hostFiles.listID, index: UInt32(index), tree: tree, into: downloadDirectory)
            } else {
                queue.append((nextID, .download(listID: hostFiles.listID, index: UInt32(index), directory: nil)))
            }
        }
        startNext()
        finishBatchIfDone()
    }

    public func cancel(_ id: Int) {
        guard let item = allItems.first(where: { $0.id == id }), !item.isFinished else { return }
        if let job = folders.removeValue(forKey: id) {
            for sub in Array(job.listings.keys) + job.children { stopSub(sub) }
            if let made = job.localURL { try? FileManager.default.removeItem(at: made) }
        }
        queue.removeAll { $0.id == id }
        if let wire = wireIDs[id] {
            sender?.cancelFile(wire)
            sinks.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.abort()
            finish(wire)
        }
        busy.remove(id)
        sources[id] = nil
        update(id) { $0.state = .cancelled }
        finishBatchIfDone()
        startNext()
    }

    public func cancelAll() {
        for item in items where !item.isFinished { cancel(item.id) }
    }

    /// Drops finished items from the list.
    public func clearFinished() {
        allItems.removeAll { $0.isFinished && !$0.isForClipboard }
    }

    // MARK: - The session's events (its queue, through a Link)

    nonisolated fileprivate func accepted(_ wire: UInt64, _ generation: Int) {
        pumps.withLock { $0[PumpKey(generation: generation, wire: wire)] }?.start()
        Task { @MainActor in self.accepted(wire, of: generation) }
    }

    nonisolated fileprivate func progress(_ wire: UInt64, _ acknowledged: UInt64, _ generation: Int) {
        pumps.withLock { $0[PumpKey(generation: generation, wire: wire)] }?.acknowledged(acknowledged)
        Task { @MainActor in self.progress(wire, acknowledged, of: generation) }
    }

    nonisolated fileprivate func finished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome, _ generation: Int) {
        let key = PumpKey(generation: generation, wire: wire)
        pumps.withLock { $0.removeValue(forKey: key) }?.close()
        if let sink = sinks.withLock({ $0.removeValue(forKey: key) }) {
            if case .saved = outcome {
                // Written out, then put in place: reported once it is.
                sink.finish { [weak self] result in
                    Task { @MainActor in self?.downloaded(wire, result, of: generation) }
                }
                Task { @MainActor in self.fetched(wire, of: generation) }
                return
            }
            sink.abort()
        }
        Task { @MainActor in self.finished(wire, outcome, of: generation) }
    }

    nonisolated fileprivate func listed(_ listID: UInt64, _ files: [GDPSession.FileListEntry], _ generation: Int) {
        Task { @MainActor in
            guard generation == self.generation else { return }
            self.hostFiles = files.isEmpty ? nil : HostFiles(listID: listID, files: files,
                                                             foldersHaveContents: self.fileClipboard)
            self.fetchForClipboard()
        }
    }

    nonisolated fileprivate func folderListed(_ wire: UInt64, _ firstIndex: UInt32, _ files: [GDPSession.FileListEntry],
                                              _ generation: Int) {
        Task { @MainActor in
            guard generation == self.generation, let listing = self.listingWires[wire],
                  var job = self.folders[listing.folder] else { return }
            job.tree.merge(folder: listing.index, firstIndex: firstIndex, files: files)
            self.folders[listing.folder] = job
        }
    }

    nonisolated fileprivate func sending(_ wire: UInt64, _ name: String, _ size: UInt64, _ modified: Date?,
                                         _ generation: Int) {
        sinks.withLock { $0[PumpKey(generation: generation, wire: wire)] }?.begin(size: size, modified: modified)
        Task { @MainActor in
            guard generation == self.generation, let id = self.itemIDs[wire] else { return }
            self.update(id) {
                $0.size = size
                $0.state = .sending
            }
        }
    }

    nonisolated fileprivate func received(_ wire: UInt64, _ bytes: UnsafeRawBufferPointer, _ generation: Int) {
        sinks.withLock { $0[PumpKey(generation: generation, wire: wire)] }?.append(bytes)
    }

    // MARK: - Internals

    private func startNext() {
        // With file-clipboard one stream stays free: the host's reads of this
        // side's files are answered on streams of ours, and wait 30 s at most.
        let streams = GDPSession.fileStreamsAtOnce - (fileClipboard ? 1 : 0)
        while let sender, busy.count < streams, !queue.isEmpty {
            let (id, job) = queue.removeFirst()
            guard case .upload(let source) = job else {
                if case .download(let listID, let index, let directory) = job {
                    startDownload(id, listID: listID, index: index, into: directory ?? downloadDirectory, sender)
                } else if case .listing(let listID, let index, let folder) = job {
                    startListing(id, listID: listID, index: index, folder: folder, sender)
                }
                continue
            }
            guard let wireName = fileNameForHost(source.name) else {
                fail(id, .badName)
                continue
            }
            busy.insert(id)
            let generation = generation
            Task.detached(priority: .userInitiated) { [weak self] in
                let reader = try? source.open()
                await self?.opened(id, source: source, wireName: wireName, reader: reader, generation: generation)
            }
        }
    }

    private func startDownload(_ id: Int, listID: UInt64, index: UInt32, into directory: URL, _ sender: FileSender) {
        guard let item = item(id) else { return }
        guard let wire = sender.requestFile(listID: listID, index: index) else {
            fail(id, .notSent)
            return
        }
        busy.insert(id)
        let generation = generation
        let sink = FileSink(wire: wire, name: fileNameForHost(item.name) ?? "Download", directory: directory,
                            sender: sender) { [weak self] written in
            Task { @MainActor in self?.wrote(wire, written, of: generation) }
        } failed: { [weak self] in
            Task { @MainActor in self?.couldntSave(wire, of: generation) }
        }
        sinks.withLock { $0[PumpKey(generation: generation, wire: wire)] = sink }
        wireIDs[id] = wire
        itemIDs[wire] = id
        update(id) { $0.state = .offered }
    }

    private func wrote(_ wire: UInt64, _ written: UInt64, of generation: Int) {
        let key = PumpKey(generation: generation, wire: wire)
        guard let id = pendingDownloads[key] ?? (generation == self.generation ? itemIDs[wire] : nil) else { return }
        update(id) { $0.sent = max($0.sent, written) }
    }

    /// Every byte arrived; the file is still being written out and put in
    /// place, and its stream's slot is free for the next.
    private func fetched(_ wire: UInt64, of generation: Int) {
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        pendingDownloads[PumpKey(generation: generation, wire: wire)] = id
        finish(wire)
        busy.remove(id)
        startNext()
    }

    /// Written out and in place (or not). Kept across a detach: the bytes are all here.
    private func downloaded(_ wire: UInt64, _ result: Result<URL, Error>, of generation: Int) {
        let key = PumpKey(generation: generation, wire: wire)
        var found = pendingDownloads.removeValue(forKey: key)
        if found == nil, generation == self.generation, let live = itemIDs[wire] {
            // Before fetched() got to it.
            found = live
            finish(wire)
            busy.remove(live)
            startNext()
        }
        // Cancelled while being written out: left as the user said.
        guard let id = found, let item = item(id), !item.isFinished else { return }
        switch result {
        case .success(let url):
            update(id) {
                $0.sent = $0.size
                $0.state = .saved(name: url.lastPathComponent)
                $0.localURL = url
            }
            if item.isShown { batchDownloaded.append(url.lastPathComponent) }
            finishBatchIfDone()
        case .failure:
            fail(id, .couldntSave)
        }
    }

    /// Writing a download failed: it is stopped, and its partial file gone.
    private func couldntSave(_ wire: UInt64, of generation: Int) {
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        sender?.cancelFile(wire)
        sinks.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.abort()
        finish(wire)
        busy.remove(id)
        fail(id, .couldntSave)
        startNext()
    }

    private func opened(_ id: Int, source: FileSource, wireName: String, reader: FileReader?, generation: Int) {
        // Cancelled, or the session went (it is queued again), while it was opening.
        guard busy.contains(id), generation == self.generation, let sender, let budget else {
            reader?.close()
            return
        }
        guard let reader else {
            busy.remove(id)
            fail(id, .unreadable)
            startNext()
            return
        }
        guard let wire = sender.offerFile(name: wireName, size: source.size, modified: source.modified) else {
            reader.close()
            busy.remove(id)
            fail(id, .notSent)
            startNext()
            return
        }
        let pump = FilePump(wire: wire, size: source.size, reader: reader, sender: sender, budget: budget) {
            [weak self] in
            Task { @MainActor in self?.changedWhileSending(wire, of: generation) }
        }
        pumps.withLock { $0[PumpKey(generation: generation, wire: wire)] = pump }
        wireIDs[id] = wire
        itemIDs[wire] = id
        update(id) { $0.state = .offered }
    }

    /// Downloads whose bytes have all arrived, until written out.
    @ObservationIgnored private var pendingDownloads: [PumpKey: Int] = [:]

    private func accepted(_ wire: UInt64, of generation: Int) {
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        // The acceptance can beat opened() to the pump table, when the host
        // answers before the main actor gets back to it: starting twice is
        // harmless.
        pumps.withLock { $0[PumpKey(generation: generation, wire: wire)] }?.start()
        update(id) { if $0.state == .offered { $0.state = .sending } }
    }

    private func progress(_ wire: UInt64, _ acknowledged: UInt64, of generation: Int) {
        guard generation == self.generation else { return }
        if serves[wire] != nil {
            serves[wire]?.sent = acknowledged
            servingChanged()
            return
        }
        guard let id = itemIDs[wire] else { return }
        update(id) { $0.sent = max($0.sent, acknowledged) }
    }

    private func finished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome, of generation: Int) {
        guard generation == self.generation else { return }
        if serves.removeValue(forKey: wire) != nil {
            servingChanged()
            return
        }
        guard let id = itemIDs[wire] else { return }
        finish(wire)
        busy.remove(id)
        if let listing = listingWires.removeValue(forKey: wire) {
            if case .saved = outcome {
                listingEnded(id, folder: listing.folder, failure: nil)
            } else {
                listingEnded(id, folder: listing.folder, failure: Self.failure(outcome) ?? .notSent)
            }
            startNext()
            return
        }
        switch outcome {
        case .saved(let name, let directory):
            update(id) {
                $0.sent = $0.size
                $0.state = .saved(name: name)
                $0.hostDirectory = directory
            }
            sources[id] = nil
            batchSaved.append(name)
            batchDirectories.append(directory)
            finishBatchIfDone()
        case .refused(let error): fail(id, .refused(error))
        case .failed(let error): fail(id, .hostFailed(error))
        case .cancelledByHost: fail(id, .cancelledByHost)
        case .timedOut: fail(id, .timedOut)
        case .connectionEnded: fail(id, .notSent)
        }
        startNext()
    }

    /// The file's size moved while it was read: the host must not keep a mixture.
    private func changedWhileSending(_ wire: UInt64, of generation: Int) {
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        sender?.cancelFile(wire)
        finish(wire)
        busy.remove(id)
        fail(id, .changed)
        startNext()
    }

    private func fail(_ id: Int, _ failure: Failure) {
        sources[id] = nil
        guard let item = item(id), !item.isFinished else { return }
        update(id) { $0.state = .failed(failure) }
        if item.isShown { batchFailed.append(item.name) }
        finishBatchIfDone()
    }

    /// How a transfer that didn't end saved failed.
    private static func failure(_ outcome: GDPSession.FileOutcome) -> Failure? {
        switch outcome {
        case .saved: nil
        case .refused(let error): .refused(error)
        case .failed(let error): .hostFailed(error)
        case .cancelledByHost: .cancelledByHost
        case .timedOut: .timedOut
        case .connectionEnded: .notSent
        }
    }

    private func item(_ id: Int) -> Item? { subs[id] ?? allItems.first { $0.id == id } }

    /// Nothing left going: what the batch came to, for a notice.
    private func finishBatchIfDone() {
        guard !hasActive, !batchSaved.isEmpty || !batchFailed.isEmpty || !batchDownloaded.isEmpty else { return }
        let folders = Set(batchDirectories)
        lastBatch = Batch(serial: (lastBatch?.serial ?? 0) + 1, saved: batchSaved, failed: batchFailed,
                          downloaded: batchDownloaded, hostDirectory: folders.count == 1 ? folders.first! : nil)
        batchSaved = []
        batchDirectories = []
        batchFailed = []
        batchDownloaded = []
    }

    /// Forgets the session's id; closes its pump if it is still open.
    private func finish(_ wire: UInt64) {
        pumps.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.close()
        if let id = itemIDs.removeValue(forKey: wire) { wireIDs.removeValue(forKey: id) }
    }

    private func update(_ id: Int, _ change: (inout Item) -> Void) {
        if let before = subs[id] {
            var sub = before
            change(&sub)
            subs[id] = sub
            if let folder = sub.group { subChanged(sub, from: before, of: folder) }
            return
        }
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        change(&allItems[index])
        if allItems[index].isForClipboard, allItems[index].isFinished { clipboardFetchProgressed() }
    }

    // MARK: - The host reading this side's files

    /// Starts sending what the host asked for, from the session's queue.
    nonisolated fileprivate func serve(_ wire: UInt64, _ descriptor: Int32, _ offset: UInt64, _ size: UInt64,
                                       _ generation: Int) {
        let plumbing = plumbing.withLock { $0 }
        guard plumbing.generation == generation, let sender = plumbing.sender, let budget = plumbing.budget else {
            Darwin.close(descriptor)
            return
        }
        let reader = DescriptorReader(descriptor: descriptor, offset: offset, size: size)
        let pump = FilePump(wire: wire, size: size, reader: reader, sender: sender, budget: budget) { [weak self] in
            // It changed under us: the host gets a reset, not a mixture.
            sender.cancelFile(wire)
            Task { @MainActor in self?.serveEnded(wire, of: generation) }
        }
        pumps.withLock { $0[PumpKey(generation: generation, wire: wire)] = pump }
        pump.start()
        Task { @MainActor in
            guard generation == self.generation else { return }
            self.serves[wire] = (size, 0)
            self.servingChanged()
        }
    }

    /// Stops sending the host every file it is reading (it gets resets).
    public func stopServing() {
        for wire in serves.keys {
            sender?.cancelFile(wire)
            pumps.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.close()
        }
        serves = [:]
        servingChanged()
    }

    private func serveEnded(_ wire: UInt64, of generation: Int) {
        guard generation == self.generation else { return }
        pumps.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.close()
        serves[wire] = nil
        servingChanged()
    }

    private func servingChanged() {
        serving = serves.isEmpty ? nil : Serving(files: serves.count, size: serves.values.reduce(0) { $0 + $1.size },
                                                 sent: serves.values.reduce(0) { $0 + min($1.sent, $1.size) })
    }

    // MARK: - Folders

    /// Item `id` downloads folder `index` of list `listID` into `base`.
    private func startFolder(_ id: Int, listID: UInt64, index: UInt32, tree: HostFileTree, into base: URL) {
        folders[id] = FolderJob(listID: listID, root: index, tree: tree, base: base)
        update(id) { $0.state = .offered }
        continueFolder(id)
    }

    /// Asks for the contents of every folder in it not listed yet; once
    /// none is left, makes its folders and queues its files.
    private func continueFolder(_ id: Int) {
        guard var job = folders[id] else { return }
        guard job.tree.count <= Self.maxFolderEntries else { return failFolder(id, .tooMany) }
        let asked = Set(job.listings.values)
        for index in job.tree.unlisted(under: job.root) where !asked.contains(index) {
            nextID += 1
            subs[nextID] = Item(id: nextID, direction: .download, name: "", size: 0, group: id)
            job.listings[nextID] = index
            queue.append((nextID, .listing(listID: job.listID, index: index, folder: id)))
        }
        folders[id] = job
        if job.listings.isEmpty { fill(id) } else { startNext() }
    }

    private func startListing(_ id: Int, listID: UInt64, index: UInt32, folder: Int, _ sender: FileSender) {
        guard let wire = sender.requestListing(listID: listID, index: index) else {
            listingEnded(id, folder: folder, failure: .notSent)
            return
        }
        busy.insert(id)
        wireIDs[id] = wire
        itemIDs[wire] = id
        listingWires[wire] = (folder, index)
    }

    private func listingEnded(_ id: Int, folder: Int, failure: Failure?) {
        subs[id] = nil
        guard var job = folders[folder] else { return }
        job.listings[id] = nil
        folders[folder] = job
        if let failure { return failFolder(folder, failure) }
        continueFolder(folder)
    }

    /// Everything in it is listed: its folders are made (the top one named
    /// as the host's, "name 2" when that is taken), and its files queued.
    private func fill(_ id: Int) {
        guard var job = folders[id], job.localURL == nil, let entry = job.tree.entries[job.root] else { return }
        let (inner, files, skipped) = job.tree.contents(of: job.root)
        guard let top = Self.makeFolder(named: fileNameForHost(entry.name) ?? "Folder", in: job.base) else {
            return failFolder(id, .couldntSave)
        }
        job.localURL = top
        for path in inner {
            let url = path.reduce(top) { $0.appending(path: $1, directoryHint: .isDirectory) }
            guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil else {
                folders[id] = job
                return failFolder(id, .couldntSave)
            }
        }
        job.skipped = skipped
        for file in files {
            nextID += 1
            subs[nextID] = Item(id: nextID, direction: .download, name: file.path.last ?? "", size: file.size,
                                group: id)
            job.children.append(nextID)
            let directory = file.path.dropLast().reduce(top) { $0.appending(path: $1, directoryHint: .isDirectory) }
            queue.append((nextID, .download(listID: job.listID, index: file.index, directory: directory)))
        }
        folders[id] = job
        update(id) {
            $0.size = files.reduce(0) { $0 + $1.size }
            $0.localURL = top
            $0.state = .sending
        }
        folderDoneIfComplete(id)
        startNext()
    }

    /// A file of folder `folder` moved on: its progress, and whether it is done.
    private func subChanged(_ sub: Item, from before: Item, of folder: Int) {
        guard var job = folders[folder] else { return }
        if sub.sent > before.sent {
            let delta = sub.sent - before.sent
            update(folder) { $0.sent += delta }
        }
        guard sub.isFinished, !before.isFinished, job.children.contains(sub.id) else { return }
        job.done += 1
        if case .failed(let failure) = sub.state { job.failures.append(failure) }
        folders[folder] = job
        folderDoneIfComplete(folder)
    }

    /// Every file of it done: saved if all came, failed if any didn't.
    private func folderDoneIfComplete(_ id: Int) {
        guard let job = folders[id], let made = job.localURL, job.listings.isEmpty,
              job.done == job.children.count else { return }
        folders[id] = nil
        for child in job.children { subs[child] = nil }
        if job.failures.isEmpty, job.skipped == 0 {
            update(id) {
                $0.sent = $0.size
                $0.state = .saved(name: made.lastPathComponent)
            }
            if item(id)?.isShown == true { batchDownloaded.append(made.lastPathComponent) }
            finishBatchIfDone()
        } else {
            let lost = !job.failures.isEmpty && job.failures.allSatisfy { $0 == .notSent }
            fail(id, lost ? .notSent : .incomplete)
        }
    }

    /// It can't go on: what of it is going stops; what came is kept.
    private func failFolder(_ id: Int, _ failure: Failure) {
        guard let job = folders.removeValue(forKey: id) else { return }
        for sub in Array(job.listings.keys) + job.children { stopSub(sub) }
        fail(id, failure)
    }

    /// Stops one of a folder's files or listings, and forgets it.
    private func stopSub(_ id: Int) {
        queue.removeAll { $0.id == id }
        if let wire = wireIDs[id] {
            sender?.cancelFile(wire)
            sinks.withLock { $0.removeValue(forKey: PumpKey(generation: generation, wire: wire)) }?.abort()
            listingWires[wire] = nil
            finish(wire)
        }
        busy.remove(id)
        subs[id] = nil
    }

    /// A new folder called `name` in `directory`, or "name 2", "name 3"...
    private static func makeFolder(named name: String, in directory: URL) -> URL? {
        for n in 1...10_000 {
            let url = directory.appending(path: n == 1 ? name : "\(name) \(n)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    // MARK: - Fetching for the clipboard

    /// A new list (or none): what was being fetched for the last one stops,
    /// and this one is fetched if it fits and there is a clipboard to put it on.
    private func fetchForClipboard() {
        dropClipboardFetch()
        clipboardFetch = nil
        guard let hostFiles, hostFiles.fitsClipboard, sender != nil,
              let mark = clipboard?.markForCopiedFiles() else { return }
        let directory = clipboardCache.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return
        }
        var ids: [Int] = []
        var copiedFolders: [(id: Int, index: UInt32)] = []
        for (index, file) in hostFiles.files.enumerated() where file.parent == 0 {
            nextID += 1
            allItems.append(Item(id: nextID, direction: .download, name: file.name, size: file.size,
                                 isForClipboard: true, isFolder: file.isDirectory))
            if file.isDirectory {
                copiedFolders.append((nextID, UInt32(index)))
            } else {
                queue.append((nextID, .download(listID: hostFiles.listID, index: UInt32(index), directory: directory)))
            }
            ids.append(nextID)
        }
        pendingFetch = (hostFiles.listID, mark, directory, ids)
        clipboardFetch = ClipboardFetch(listID: hostFiles.listID, state: .fetching)
        let tree = HostFileTree(hostFiles.files)
        for folder in copiedFolders {
            startFolder(folder.id, listID: hostFiles.listID, index: folder.index, tree: tree, into: directory)
        }
        startNext()
    }

    /// Stops the fetch for the clipboard going on, and forgets it.
    private func dropClipboardFetch() {
        guard let fetch = pendingFetch else { return }
        pendingFetch = nil
        for id in fetch.ids { cancel(id) }
        allItems.removeAll { fetch.ids.contains($0.id) }
        try? FileManager.default.removeItem(at: fetch.directory)
    }

    /// One of the fetch's files is done: once all are, they go on the
    /// clipboard if every one is down, and the clipboard still holds what
    /// it did when the fetch began.
    private func clipboardFetchProgressed() {
        guard let fetch = pendingFetch else { return }
        let fetched = allItems.filter { fetch.ids.contains($0.id) }
        guard fetched.allSatisfy(\.isFinished) else { return }
        pendingFetch = nil
        allItems.removeAll { fetch.ids.contains($0.id) }
        let urls = fetched.compactMap(\.localURL)
        if urls.count == fetch.ids.count, clipboard?.putCopiedFiles(urls, ifUnchangedSince: fetch.mark) == true {
            // What an earlier fetch put on the clipboard is no longer there.
            let earlier = (try? FileManager.default.contentsOfDirectory(at: clipboardCache,
                                                                        includingPropertiesForKeys: nil)) ?? []
            for folder in earlier where folder.lastPathComponent != fetch.directory.lastPathComponent {
                try? FileManager.default.removeItem(at: folder)
            }
            clipboardFetch = ClipboardFetch(listID: fetch.listID, state: .onClipboard)
        } else {
            try? FileManager.default.removeItem(at: fetch.directory)
            clipboardFetch = ClipboardFetch(listID: fetch.listID, state: .notOnClipboard)
        }
    }
}

/// Where ``FileTransfers`` puts the host's copied files once fetched:
/// ``ClipboardSync``.
@MainActor
public protocol CopiedFilesClipboard: AnyObject {
    /// Nil if copied files don't go on the clipboard now; otherwise a mark
    /// of what it holds, for ``putCopiedFiles(_:ifUnchangedSince:)``.
    func markForCopiedFiles() -> Int?
    /// Puts the files on the clipboard, unless something else was copied
    /// since `mark` (that is newer). Whether they went.
    func putCopiedFiles(_ urls: [URL], ifUnchangedSince mark: Int) -> Bool
}

/// Reads one accepted file and feeds it to the session, as the budget
/// allows. Everything runs on its own serial queue.
final class FilePump: @unchecked Sendable {
    private let wire: UInt64
    private let size: UInt64
    private let reader: FileReader
    private let sender: FileSender
    private let budget: UploadBudget
    private let onChanged: @Sendable () -> Void
    private let queue = DispatchQueue(label: "spectre.file-pump", qos: .userInitiated)
    // Queue only.
    private var started = false
    private var closed = false
    private var sent: UInt64 = 0
    private var acked: UInt64 = 0

    init(wire: UInt64, size: UInt64, reader: FileReader, sender: FileSender, budget: UploadBudget,
         onChanged: @escaping @Sendable () -> Void) {
        self.wire = wire
        self.size = size
        self.reader = reader
        self.sender = sender
        self.budget = budget
        self.onChanged = onChanged
    }

    func start() {
        queue.async { [self] in
            started = true
            fill()
        }
    }

    func acknowledged(_ total: UInt64) {
        queue.async { [self] in
            guard !closed, total > acked else { return }
            let delta = Int(min(total, sent) - min(acked, sent))
            acked = total
            budget.release(delta)
            fill()
        }
    }

    func close() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            // Room held for bytes the host will never acknowledge now.
            budget.release(Int(sent - min(acked, sent)))
            reader.close()
        }
    }

    private func fill() {
        while started, !closed, sent < size {
            let wanted = Int(min(UInt64(FileTransfers.chunk), size - sent))
            let room = budget.reserve(wanted) { [weak self] in
                guard let self else { return }
                self.queue.async { self.fill() }
            }
            guard room > 0 else { return }
            let data: Data
            do {
                data = try reader.read(upTo: room)
                // Shorter than asked: the file shrank. Before its last
                // piece: one that grew is caught too.
                guard data.count == room else { throw CocoaError(.fileReadUnknown) }
                if sent + UInt64(data.count) == size, try reader.currentSize() != size {
                    throw CocoaError(.fileReadUnknown)
                }
            } catch {
                budget.release(room)
                closed = true
                reader.close()
                onChanged()
                return
            }
            sender.sendFileData(wire, data)
            sent += UInt64(data.count)
        }
    }
}

/// Carries a session's file events to the ``FileTransfers/Link`` of the
/// moment, from the session's queue. The host lists its copied files right
/// after SessionAccept, before the interface has attached a session to its
/// transfers: the latest list is kept until there is a link to give it to.
public final class FileEventRelay: Sendable {
    private struct State {
        var link: FileTransfers.Link?
        var pendingList: (UInt64, [GDPSession.FileListEntry])?
    }
    private let state = Mutex(State())

    public init() {}

    /// Where events go from now on (nil: nowhere, until the next one). A
    /// list that came before it is handed over now.
    public func connect(_ link: FileTransfers.Link?) {
        let pending: (UInt64, [GDPSession.FileListEntry])? = state.withLock {
            $0.link = link
            guard link != nil else { return nil }
            defer { $0.pendingList = nil }
            return $0.pendingList
        }
        if let link, let (listID, files) = pending { link.fileList(listID, files) }
    }

    /// Forgets a list kept for a link that never came (the session ended first).
    public func reset() {
        state.withLock { $0 = State() }
    }

    private var link: FileTransfers.Link? { state.withLock { $0.link } }

    public func fileAccepted(_ wire: UInt64) { link?.fileAccepted(wire) }
    public func fileProgress(_ wire: UInt64, _ acknowledged: UInt64) { link?.fileProgress(wire, acknowledged) }
    public func fileFinished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome) { link?.fileFinished(wire, outcome) }
    public func fileSending(_ wire: UInt64, _ name: String, _ size: UInt64, _ modified: Date?) {
        link?.fileSending(wire, name, size, modified)
    }
    public func fileData(_ wire: UInt64, _ bytes: UnsafeRawBufferPointer) { link?.fileData(wire, bytes) }
    public func fileListing(_ wire: UInt64, _ firstIndex: UInt32, _ files: [GDPSession.FileListEntry]) {
        link?.fileListing(wire, firstIndex, files)
    }
    public func fileServe(_ wire: UInt64, _ descriptor: Int32, _ offset: UInt64, _ size: UInt64) {
        guard let link else {
            Darwin.close(descriptor)
            return
        }
        link.fileServe(wire, descriptor, offset, size)
    }
    public func fileList(_ listID: UInt64, _ files: [GDPSession.FileListEntry]) {
        let link: FileTransfers.Link? = state.withLock {
            if $0.link == nil { $0.pendingList = (listID, files) }
            return $0.link
        }
        link?.fileList(listID, files)
    }
}

