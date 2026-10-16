import Foundation
import GDPKit
import Observation
import Synchronization

/// What ``FileTransfers`` needs of a session: ``GDPSession`` itself.
public protocol FileSender: AnyObject, Sendable {
    func offerFile(name: String, size: UInt64, modified: Date?) -> UInt64?
    func sendFileData(_ id: UInt64, _ data: Data)
    func cancelFile(_ id: UInt64)
    func linkStats() -> GDPSession.LinkStats?
}

extension GDPSession: FileSender {}

/// One session's files on their way to the host (gdp-spec.md §7.12): a
/// queue the user adds to, at most ``GDPSession/fileStreamsAtOnce`` offered
/// at once, each read as the host takes it in.
///
/// A file is opened (off the main thread) before it is offered, so one that
/// can't be read never reaches the host. Once the host accepts it, its
/// bytes are read in 256 KiB pieces and sent as the session's
/// ``UploadWindow`` allows; each acknowledgement makes room for the next.
/// Nothing reads a whole file into memory.
///
/// The session's file events (``fileAccepted(_:)``, ``fileProgress(_:_:)``,
/// ``fileFinished(_:_:)``) come from its queue; everything the interface
/// reads is on the main actor.
@MainActor
@Observable
public final class FileTransfers {
    public struct Item: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable {
            /// In the queue, or being opened.
            case waiting
            /// Offered, waiting for the host's answer.
            case offered
            case sending
            /// Stored by the host under `name`.
            case saved(name: String)
            case failed(Failure)
            case cancelled
        }

        public let id: Int
        /// As the user knows it.
        public let name: String
        public let size: UInt64
        /// Bytes the host has acknowledged.
        public internal(set) var sent: UInt64 = 0
        public internal(set) var state: State = .waiting

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
        /// The session ended (or the host stopped taking files) before it went.
        case notSent
    }

    public private(set) var items: [Item] = []

    /// Bytes still to go, over everything unfinished.
    public var remaining: UInt64 {
        items.filter { !$0.isFinished }.reduce(0) { $0 + ($1.size - min($1.sent, $1.size)) }
    }
    public var hasActive: Bool { items.contains { !$0.isFinished } }

    /// Read pieces: big enough for few syscalls, small against the window.
    nonisolated static let chunk = 256 * 1024

    @ObservationIgnored private let sender: FileSender
    @ObservationIgnored private let budget: UploadBudget
    @ObservationIgnored private var nextID = 0
    /// Files waiting to be opened and offered, oldest first.
    @ObservationIgnored private var queue: [(id: Int, source: FileSource)] = []
    /// Item ids being opened or offered (counted against the stream limit).
    @ObservationIgnored private var busy: Set<Int> = []
    /// The session's id for each offered item, and back.
    @ObservationIgnored private var wireIDs: [Int: UInt64] = [:]
    @ObservationIgnored private var itemIDs: [UInt64: Int] = [:]
    @ObservationIgnored private var ended = false
    /// The pumps by the session's id: reached from its queue too.
    @ObservationIgnored nonisolated private let pumps = Mutex<[UInt64: FilePump]>([:])

    public init(sender: FileSender) {
        self.sender = sender
        budget = UploadBudget { [weak sender] in sender?.linkStats()?.rttMicroseconds }
    }

    /// Adds files to the queue; they go in order, a few at a time.
    public func send(_ sources: [FileSource]) {
        for source in sources {
            nextID += 1
            items.append(Item(id: nextID, name: source.name, size: source.size))
            if ended {
                update(nextID) { $0.state = .failed(.notSent) }
            } else {
                queue.append((nextID, source))
            }
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
                items.append(Item(id: nextID, name: url.lastPathComponent, size: 0,
                                  state: .failed(error == .folder ? .folder : .unreadable)))
            }
        }
        send(sources)
    }

    public func cancel(_ id: Int) {
        guard let item = items.first(where: { $0.id == id }), !item.isFinished else { return }
        queue.removeAll { $0.id == id }
        if let wire = wireIDs[id] {
            sender.cancelFile(wire)
            finish(wire)
        }
        busy.remove(id)
        update(id) { $0.state = .cancelled }
        startNext()
    }

    public func cancelAll() {
        for item in items where !item.isFinished { cancel(item.id) }
    }

    /// Drops finished items from the list.
    public func clearFinished() {
        items.removeAll(where: \.isFinished)
    }

    /// The session ended: nothing more can go. What was on its way is
    /// reported through ``fileFinished(_:_:)``; what was still queued ends here.
    public func sessionEnded() {
        ended = true
        for (id, _) in queue { update(id) { $0.state = .failed(.notSent) } }
        queue = []
        for id in busy where wireIDs[id] == nil { update(id) { $0.state = .failed(.notSent) } }
        busy = busy.filter { wireIDs[$0] != nil }
    }

    // MARK: - The session's events (its queue)

    public nonisolated func fileAccepted(_ wire: UInt64) {
        pumps.withLock { $0[wire] }?.start()
        Task { @MainActor in self.accepted(wire) }
    }

    public nonisolated func fileProgress(_ wire: UInt64, _ acknowledged: UInt64) {
        pumps.withLock { $0[wire] }?.acknowledged(acknowledged)
        Task { @MainActor in self.progress(wire, acknowledged) }
    }

    public nonisolated func fileFinished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome) {
        pumps.withLock { $0.removeValue(forKey: wire) }?.close()
        Task { @MainActor in self.finished(wire, outcome) }
    }

    // MARK: - Internals

    private func startNext() {
        while !ended, busy.count < GDPSession.fileStreamsAtOnce, !queue.isEmpty {
            let (id, source) = queue.removeFirst()
            busy.insert(id)
            guard let wireName = fileNameForHost(source.name) else {
                busy.remove(id)
                update(id) { $0.state = .failed(.badName) }
                continue
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                let reader = try? source.open()
                await self?.opened(id, source: source, wireName: wireName, reader: reader)
            }
        }
    }

    private func opened(_ id: Int, source: FileSource, wireName: String, reader: FileReader?) {
        // Cancelled, or the session ended, while it was opening.
        guard busy.contains(id), !ended else {
            reader?.close()
            return
        }
        guard let reader else {
            busy.remove(id)
            update(id) { $0.state = .failed(.unreadable) }
            startNext()
            return
        }
        guard let wire = sender.offerFile(name: wireName, size: source.size, modified: source.modified) else {
            reader.close()
            busy.remove(id)
            update(id) { $0.state = .failed(.notSent) }
            startNext()
            return
        }
        let pump = FilePump(wire: wire, size: source.size, reader: reader, sender: sender, budget: budget) {
            [weak self] in
            Task { @MainActor in self?.changedWhileSending(wire) }
        }
        pumps.withLock { $0[wire] = pump }
        wireIDs[id] = wire
        itemIDs[wire] = id
        update(id) { $0.state = .offered }
    }

    private func accepted(_ wire: UInt64) {
        guard let id = itemIDs[wire] else { return }
        // The acceptance can beat opened() to the pump table, when the host
        // answers before the main actor gets back to it: starting twice is
        // harmless.
        pumps.withLock { $0[wire] }?.start()
        update(id) { if $0.state == .offered { $0.state = .sending } }
    }

    private func progress(_ wire: UInt64, _ acknowledged: UInt64) {
        guard let id = itemIDs[wire] else { return }
        update(id) { $0.sent = max($0.sent, acknowledged) }
    }

    private func finished(_ wire: UInt64, _ outcome: GDPSession.FileOutcome) {
        guard let id = itemIDs[wire] else { return }
        finish(wire)
        busy.remove(id)
        update(id) {
            switch outcome {
            case .saved(let name):
                $0.sent = $0.size
                $0.state = .saved(name: name)
            case .refused(let error): $0.state = .failed(.refused(error))
            case .failed(let error): $0.state = .failed(.hostFailed(error))
            case .cancelledByHost: $0.state = .failed(.cancelledByHost)
            case .timedOut: $0.state = .failed(.timedOut)
            case .connectionEnded: $0.state = .failed(.notSent)
            }
        }
        startNext()
    }

    /// The file's size moved while it was read: the host must not keep a mixture.
    private func changedWhileSending(_ wire: UInt64) {
        guard let id = itemIDs[wire] else { return }
        sender.cancelFile(wire)
        finish(wire)
        busy.remove(id)
        update(id) { $0.state = .failed(.changed) }
        startNext()
    }

    /// Forgets the session's id; closes its pump if it is still open.
    private func finish(_ wire: UInt64) {
        pumps.withLock { $0.removeValue(forKey: wire) }?.close()
        if let id = itemIDs.removeValue(forKey: wire) { wireIDs.removeValue(forKey: id) }
    }

    private func update(_ id: Int, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
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
