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
/// host back.
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

        public var isFinished: Bool {
            switch state {
            case .waiting, .offered, .sending: false
            case .saved, .failed, .cancelled: true
            }
        }
        public var fraction: Double { size == 0 ? (isFinished ? 1 : 0) : Double(sent) / Double(size) }
    }

    public enum Failure: Sendable, Equatable {
        /// A folder (not sent in this version).
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
    }

    /// What the host's user copied (§7.12), to download.
    public struct HostFiles: Sendable, Equatable {
        public var listID: UInt64
        public var files: [GDPSession.FileListEntry]
        /// Those that can be downloaded (not folders).
        public var downloadable: [GDPSession.FileListEntry] { files.filter { !$0.isDirectory } }
        /// Whether they are fetched for the clipboard as soon as they are
        /// listed: files only, ``FileTransfers/clipboardLimit`` at most in all.
        public var fitsClipboard: Bool {
            var total: UInt64 = 0
            for file in files {
                guard !file.isDirectory, file.size <= FileTransfers.clipboardLimit else { return false }
                total += file.size
            }
            return !files.isEmpty && total <= FileTransfers.clipboardLimit
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
    public var items: [Item] { allItems.filter { !$0.isForClipboard } }
    private var allItems: [Item] = []
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
        /// GDPSession.Handlers.fileList, fileSending and fileData.
        public func fileList(_ listID: UInt64, _ files: [GDPSession.FileListEntry]) {
            transfers?.listed(listID, files, generation)
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
    /// own caches (a sandboxed app's are its own anyway).
    private nonisolated static let clipboardCacheRoot = FileManager.default.urls(for: .cachesDirectory,
                                                                                 in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? "SpectreKit", directoryHint: .isDirectory)
        .appending(path: "Copied Files", directoryHint: .isDirectory)
    /// What the app's last run fetched for the clipboard goes once, with the first window.
    private nonisolated static let cacheCleared: Void = {
        try? FileManager.default.removeItem(at: clipboardCacheRoot)
    }()

    /// Sends through `sender` from now on: a session with `file` in effect.
    /// Its file events go to the link returned.
    @discardableResult
    public func attach(_ sender: FileSender) -> Link {
        detach()
        generation += 1
        self.sender = sender
        budget = UploadBudget { [weak sender] in sender?.linkStats()?.rttMicroseconds }
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
        isAvailable = false
        dropClipboardFetch()
        clipboardFetch = nil
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
        queue.removeAll { if case .download = $0.job { true } else { false } }
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

    /// Downloads every file of ``hostFiles`` into ``downloadDirectory``; a
    /// folder shows up as failed right away.
    public func downloadCopiedFiles() {
        guard let hostFiles else { return }
        for (index, file) in hostFiles.files.enumerated() {
            nextID += 1
            allItems.append(Item(id: nextID, direction: .download, name: file.name, size: file.size))
            if file.isDirectory {
                update(nextID) { $0.state = .failed(.folder) }
                batchFailed.append(file.name)
            } else {
                queue.append((nextID, .download(listID: hostFiles.listID, index: UInt32(index), directory: nil)))
            }
        }
        startNext()
        finishBatchIfDone()
    }

    public func cancel(_ id: Int) {
        guard let item = allItems.first(where: { $0.id == id }), !item.isFinished else { return }
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
            self.hostFiles = files.isEmpty ? nil : HostFiles(listID: listID, files: files)
            self.fetchForClipboard()
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
        while let sender, busy.count < GDPSession.fileStreamsAtOnce, !queue.isEmpty {
            let (id, job) = queue.removeFirst()
            guard case .upload(let source) = job else {
                if case .download(let listID, let index, let directory) = job {
                    startDownload(id, listID: listID, index: index, into: directory ?? downloadDirectory, sender)
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
        guard let item = allItems.first(where: { $0.id == id }) else { return }
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
        guard let id = found, let item = allItems.first(where: { $0.id == id }), !item.isFinished else { return }
        switch result {
        case .success(let url):
            update(id) {
                $0.sent = $0.size
                $0.state = .saved(name: url.lastPathComponent)
                $0.localURL = url
            }
            if !item.isForClipboard { batchDownloaded.append(url.lastPathComponent) }
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
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        update(id) { $0.sent = max($0.sent, acknowledged) }
    }

    private func finished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome, of generation: Int) {
        guard generation == self.generation, let id = itemIDs[wire] else { return }
        finish(wire)
        busy.remove(id)
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
        guard let item = allItems.first(where: { $0.id == id }), !item.isFinished else { return }
        update(id) { $0.state = .failed(failure) }
        if !item.isForClipboard { batchFailed.append(item.name) }
        finishBatchIfDone()
    }

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
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        change(&allItems[index])
        if allItems[index].isForClipboard, allItems[index].isFinished { clipboardFetchProgressed() }
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
        for (index, file) in hostFiles.files.enumerated() {
            nextID += 1
            allItems.append(Item(id: nextID, direction: .download, name: file.name, size: file.size,
                                 isForClipboard: true))
            queue.append((nextID, .download(listID: hostFiles.listID, index: UInt32(index), directory: directory)))
            ids.append(nextID)
        }
        pendingFetch = (hostFiles.listID, mark, directory, ids)
        clipboardFetch = ClipboardFetch(listID: hostFiles.listID, state: .fetching)
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
    public func fileList(_ listID: UInt64, _ files: [GDPSession.FileListEntry]) {
        let link: FileTransfers.Link? = state.withLock {
            if $0.link == nil { $0.pendingList = (listID, files) }
            return $0.link
        }
        link?.fileList(listID, files)
    }
}

