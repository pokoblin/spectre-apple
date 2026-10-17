import Foundation
import Synchronization

/// Writes one of the host's files as it arrives (gdp-spec.md §7.12): into a
/// hidden temporary file in the download folder, renamed into place once
/// every byte is down, never over an existing file ("name 2.ext", as the
/// Finder names copies). The session's bytes are gathered into 256 KiB
/// writes on a queue of its own, and handed back to the session
/// (``FileSender/consumeFileData(_:_:)``) only once written: a disk slower
/// than the network holds the host back instead of filling memory.
final class FileSink: @unchecked Sendable {
    private let wire: UInt64
    private let name: String
    private let directory: URL
    private let sender: FileSender
    private let onProgress: @Sendable (UInt64) -> Void
    private let onFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "spectre.file-sink", qos: .userInitiated)
    /// Filled on the session's queue, written out on `queue`.
    private let buffer = Mutex(Data())
    // Queue only.
    private var handle: FileHandle?
    private var temporary: URL?
    private var modified: Date?
    private var written: UInt64 = 0
    private var broken = false
    private var over = false

    /// `name` must already be fit to store (``fileNameForHost(_:)``).
    init(wire: UInt64, name: String, directory: URL, sender: FileSender,
         progress: @escaping @Sendable (UInt64) -> Void, failed: @escaping @Sendable () -> Void) {
        self.wire = wire
        self.name = name
        self.directory = directory
        self.sender = sender
        onProgress = progress
        onFailure = failed
    }

    /// The host is sending `size` bytes: makes the temporary file, if there is room.
    func begin(size: UInt64, modified: Date?) {
        queue.async { [self] in
            guard !over else { return }
            self.modified = modified
            let url = directory.appending(path: ".spectre-\(UUID().uuidString).download")
            let room = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            guard room.map({ $0 < 0 || UInt64($0) >= size }) ?? true,
                  FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else {
                try? FileManager.default.removeItem(at: url)
                fail()
                return
            }
            temporary = url
            self.handle = handle
        }
    }

    /// More of the file, on the session's queue: `bytes` are only valid during the call.
    func append(_ bytes: UnsafeRawBufferPointer) {
        let full: Data? = buffer.withLock { buffer in
            buffer.append(contentsOf: bytes)
            guard buffer.count >= FileTransfers.chunk else { return nil }
            defer { buffer = Data() }
            return buffer
        }
        if let full { queue.async { [self] in write(full) } }
    }

    /// Every byte has arrived: writes out the rest and puts the file in place.
    func finish(_ completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let rest = buffer.withLock { buffer in
            defer { buffer = Data() }
            return buffer
        }
        queue.async { [self] in
            if !rest.isEmpty { write(rest) }
            guard !broken, !over, let handle, let temporary else {
                completion(.failure(CocoaError(.fileWriteUnknown)))
                return
            }
            over = true
            do {
                try handle.close()
                self.handle = nil
                if let modified {
                    try? FileManager.default.setAttributes([.modificationDate: modified],
                                                           ofItemAtPath: temporary.path(percentEncoded: false))
                }
                let url = try moveIntoPlace(temporary)
                self.temporary = nil
                completion(.success(url))
            } catch {
                cleanUp()
                completion(.failure(error))
            }
        }
    }

    /// Cancelled, or the fetch failed: the partial file goes.
    func abort() {
        buffer.withLock { $0 = Data() }
        queue.async { [self] in
            over = true
            cleanUp()
        }
    }

    private func write(_ data: Data) {
        guard !broken, !over, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail()
            return
        }
        written += UInt64(data.count)
        sender.consumeFileData(wire, data.count)
        onProgress(written)
    }

    private func fail() {
        guard !broken else { return }
        broken = true
        cleanUp()
        onFailure()
    }

    private func cleanUp() {
        try? handle?.close()
        handle = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }

    /// Renames the finished file to its name, or "name 2.ext", "name 3.ext"...
    /// while that is taken; never over an existing file.
    private func moveIntoPlace(_ temporary: URL) throws -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 1...10_000 {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            let target = directory.appending(path: candidate)
            do {
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
