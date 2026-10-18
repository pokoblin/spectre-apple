import Foundation
import GDPKit

/// A file to send to the host (gdp-spec.md §7.12): what to call it, how
/// big it is, and a way to read it. ``LocalFile`` is the real one; tests
/// make their own.
public protocol FileSource: Sendable {
    /// The file's own name, as the user knows it (not yet made fit for the wire).
    var name: String { get }
    var size: UInt64 { get }
    var modified: Date? { get }
    /// Opens it for reading from the start. Called off the main thread: it
    /// may wait for the file (an iCloud file being downloaded).
    func open() throws -> FileReader
}

/// Reads one file from start to end, on one queue at a time.
public protocol FileReader: AnyObject, Sendable {
    /// Up to `count` bytes; fewer only at the end of the file.
    func read(upTo count: Int) throws -> Data
    /// The file's size now, to catch one that changed while being read.
    func currentSize() throws -> UInt64
    func close()
}

/// A file on this device, picked or dropped by the user.
public struct LocalFile: FileSource {
    public enum Problem: Error, Equatable, Sendable {
        /// A folder, or a package (an .app or a Keynote document is a folder too).
        case folder
        /// It isn't there, or can't be read.
        case unreadable
    }

    public let url: URL
    public let name: String
    public let size: UInt64
    public let modified: Date?

    /// Looks at `url` (security-scoped access included). Throws for a folder
    /// or a file that can't be read.
    public init(url: URL) throws(Problem) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw .unreadable }
        if values.isDirectory == true || values.isPackage == true { throw .folder }
        self.url = url
        name = url.lastPathComponent
        size = UInt64(max(values.fileSize ?? 0, 0))
        modified = values.contentModificationDate
    }

    public func open() throws -> FileReader {
        try LocalFileReader(url: url)
    }
}

final class LocalFileReader: FileReader, @unchecked Sendable {
    private let url: URL
    private let scoped: Bool
    private var handle: FileHandle?

    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        // A coordinated read waits for the file to be whole: an iCloud file
        // is downloaded first, one being saved is finished first. The
        // descriptor opened inside stays good after it.
        var coordinationError: NSError?
        var openError: Error?
        var opened: FileHandle?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) {
            do { opened = try FileHandle(forReadingFrom: $0) } catch { openError = error }
        }
        guard let opened else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw coordinationError ?? openError ?? CocoaError(.fileReadUnknown)
        }
        handle = opened
    }

    func read(upTo count: Int) throws -> Data {
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        var data = Data()
        // read(upToCount:) may return less than asked before the end.
        while data.count < count, let more = try handle.read(upToCount: count - data.count), !more.isEmpty {
            data.append(more)
        }
        return data
    }

    func currentSize() throws -> UInt64 {
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        let offset = try handle.offset()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: offset)
        return end
    }

    func close() {
        try? handle?.close()
        handle = nil
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    deinit { close() }
}

/// What a name becomes on the wire (gdp-spec.md §7.12): NFC, with the
/// characters the host can't take (`/`, `\`, control characters) replaced
/// by `_`, and shortened to 255 bytes, keeping the extension. Nil if
/// nothing usable is left ("", ".", "..").
public func fileNameForHost(_ name: String) -> String? {
    var cleaned = String(String.UnicodeScalarView(name.precomposedStringWithCanonicalMapping.unicodeScalars.map {
        $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F ? "_" : $0
    }))
    let limit = GDPSession.maxFileNameBytes
    if cleaned.utf8.count > limit {
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 32 ? "" : "." + ext
        var stem = String(cleaned.dropLast(suffix.count))
        // Whole characters off the end until it fits.
        while !stem.isEmpty, stem.utf8.count + suffix.utf8.count > limit { stem.removeLast() }
        cleaned = stem + suffix
    }
    return GDPSession.isValidFileName(cleaned) ? cleaned : nil
}

/// `size` bytes of an open file from `offset`, for the host reading one of
/// this side's files (gdp-spec.md §7.12, `file-clipboard`): the descriptor
/// GDPKit opened, checked and handed over. Its size is that of the range,
/// smaller only if the file shrank into it meanwhile.
final class DescriptorReader: FileReader, @unchecked Sendable {
    private var handle: FileHandle?
    private let offset: UInt64
    private let size: UInt64

    init(descriptor: Int32, offset: UInt64, size: UInt64) {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.seek(toOffset: offset)
        self.handle = handle
        self.offset = offset
        self.size = size
    }

    func read(upTo count: Int) throws -> Data {
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        var data = Data()
        while data.count < count, let more = try handle.read(upToCount: count - data.count), !more.isEmpty {
            data.append(more)
        }
        return data
    }

    func currentSize() throws -> UInt64 {
        guard let handle else { throw CocoaError(.fileReadUnknown) }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let length = UInt64(max(0, info.st_size))
        return min(length > offset ? length - offset : 0, size)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
