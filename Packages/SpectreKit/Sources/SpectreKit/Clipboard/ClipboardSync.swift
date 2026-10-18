import Foundation
import GDPKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Which clipboard text may cross, so that applying the peer's text is not
/// taken for a fresh local copy and sent back (gdp-spec.md §7.9).
///
/// It remembers one string: the text both sides are believed to hold, the
/// last one sent or applied. libgdp's `ClipboardEcho` remembers the last
/// sent and the last applied separately and refuses either, so after
/// sending A and applying B, copying A again is never sent and the host
/// keeps B. Here A differs from what both sides hold (B), so it goes.
public struct ClipboardEchoFilter: Sendable {
    public private(set) var synced: String?

    public init() {}

    /// Whether a local copy goes to the host; if so, it is now what both hold.
    /// Never empty or over ``GDPSession/maxClipboardBytes``, never what the host already has.
    public mutating func shouldSend(_ text: String) -> Bool {
        guard Self.isSendable(text), text != synced else { return false }
        synced = text
        return true
    }

    /// A copy the user explicitly asked to send: goes even if it is what the host already has.
    public mutating func shouldSendExplicitly(_ text: String) -> Bool {
        guard Self.isSendable(text) else { return false }
        synced = text
        return true
    }

    /// Whether the host's text replaces the local clipboard. Not when it is
    /// what both already hold: that is the host echoing our own copy.
    public mutating func shouldApply(_ text: String) -> Bool {
        guard !text.isEmpty, text != synced else { return false }
        synced = text
        return true
    }

    public mutating func reset() { synced = nil }

    static func isSendable(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= GDPSession.maxClipboardBytes
    }
}

/// The local clipboard, as ``ClipboardSync`` uses it.
@MainActor
public protocol LocalPasteboard: AnyObject {
    /// Changes whenever the clipboard's contents do; reading it reads no contents.
    var changeCount: Int { get }
    /// Whether there is text, without reading it (no paste prompt on iOS).
    var hasText: Bool { get }
    /// The text, or nil if there is none or it must not leave the device
    /// (marked concealed or transient by a password manager).
    func readText() -> String?
    func writeText(_ text: String)
    /// Replaces the contents with these files (the host's copied files, fetched).
    func writeFiles(_ urls: [URL])
    /// The files copied in another app (the Finder), if that is what the
    /// clipboard holds; nil otherwise.
    func readFileURLs() -> [URL]?
    /// Whether the clipboard holds what the Files app copied (iOS), without
    /// reading it: no paste prompt.
    var holdsCopiedFiles: Bool { get }
    /// What the Files app copied, as copies of the app's own in `directory`
    /// (iOS gives no access to the originals); the system asks the user
    /// first unless pasting is allowed in Settings. Nil if nothing came.
    func copyCopiedFiles(into directory: URL) async -> [URL]?
}

public extension LocalPasteboard {
    var holdsCopiedFiles: Bool { false }
    func copyCopiedFiles(into directory: URL) async -> [URL]? { nil }
}

/// One session's clipboard sync (gdp-spec.md §7.9, capability `clipboard`).
///
/// The host's text is written to the local clipboard as it arrives. Local
/// changes are found by watching the pasteboard's change count, when the app
/// becomes active and twice a second while it is. On iOS, where reading
/// another app's text shows the system's paste prompt, that happens only if
/// the user turned on ``sendsAutomatically``; otherwise the user sends with
/// an explicit ``send(_:)`` from a paste button. What was on the clipboard
/// before the session (or before the user turned syncing on) is never sent:
/// connecting must not overwrite the desktop's clipboard (§7.9).
///
/// With ``sendFiles`` (`file-clipboard`, §7.12), files copied here go to the
/// host as a list of copied files, to paste there, instead of their names
/// as text; the host reads them as the paste wants them. When the clipboard
/// stops holding them the list is taken back. On iOS, what the Files app
/// copies is read whether or not text goes automatically (the system asks
/// each time, unless allowed in Settings), into copies of the app's own:
/// the latest few, while the session lasts.
@MainActor
@Observable
public final class ClipboardSync: CopiedFilesClipboard {
    public static let enabledKey = "clipboardSync"
    public static let sendsAutomaticallyKey = "clipboardSendsAutomatically"

    /// The user's switch for the whole feature (the spec's privacy notes: a
    /// client SHOULD let its user turn it off); off by default, remembered
    /// across sessions.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { takeBackFiles() }
            rebaseline()
        }
    }

    /// Where copied files go to the host (`file-clipboard` in effect); nil:
    /// they don't, and their names go as text as before. An empty list takes
    /// the last one back.
    @ObservationIgnored public var sendFiles: (([URL]) -> Void)?
    /// Files in here are never offered: the host's own, fetched for the clipboard.
    @ObservationIgnored public var ownFiles: URL?
    /// Whether the host holds a list of files copied here.
    @ObservationIgnored private var filesShared = false
    /// Called once files copied here have gone to the host: `asked` if the
    /// system seems to have shown its paste prompt first (the app was
    /// interrupted, or a small copy took long enough for someone to answer).
    @ObservationIgnored public var onFilesSent: ((_ asked: Bool) -> Void)?
    /// Where copies of what the Files app copied wait for the host: this
    /// sync's own folder, and the folders of its latest copies, oldest first.
    @ObservationIgnored private let stagingFolder = ClipboardSync.stagingRoot
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    @ObservationIgnored private var staged: [URL] = []
    @ObservationIgnored private var isStaging = false
    /// The host keeps answering a few earlier lists (§7.12): their copies stay as long.
    static let stagedCopiesKept = 5
    static let stagingRoot = FileManager.default.temporaryDirectory
        .appending(path: "Copied Files", directoryHint: .isDirectory)
    /// What a run before this one left there goes once, with the first sync.
    private static let stagingCleared: Void = { try? FileManager.default.removeItem(at: stagingRoot) }()

    /// Whether local changes are found and sent without the user asking.
    /// Always on the Mac; on iOS a choice, off by default (the paste prompt).
    public var sendsAutomatically: Bool {
        didSet {
            guard sendsAutomatically != oldValue else { return }
            if Self.automaticIsOptional { defaults.set(sendsAutomatically, forKey: Self.sendsAutomaticallyKey) }
            rebaseline()
        }
    }

    #if os(macOS)
    public static let automaticIsOptional = false
    #else
    public static let automaticIsOptional = true
    #endif

    /// Text that crossed, last time some did, for a notice on screen;
    /// `serial` tells repeats apart.
    public struct Transfer: Equatable, Sendable {
        public enum Direction: Sendable { case fromHost, toHost }
        public var direction: Direction
        public var serial: Int
    }
    public private(set) var lastTransfer: Transfer?

    @ObservationIgnored private let pasteboard: LocalPasteboard
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sendText: (String) -> Void
    @ObservationIgnored private var filter = ClipboardEchoFilter()
    @ObservationIgnored private var seenChangeCount: Int
    @ObservationIgnored private var isWatching = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?

    public init(pasteboard: LocalPasteboard, defaults: UserDefaults = .standard, send: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        sendText = send
        seenChangeCount = pasteboard.changeCount
        _ = Self.stagingCleared
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        sendsAutomatically = Self.automaticIsOptional ? defaults.bool(forKey: Self.sendsAutomaticallyKey) : true
    }

    /// The host's clipboard changed (or, right after SessionAccept, what it was).
    public func hostChanged(_ text: String) {
        guard isEnabled, filter.shouldApply(text) else { return }
        takeBackFiles()
        pasteboard.writeText(text)
        // Our own write is not a local copy.
        seenChangeCount = pasteboard.changeCount
        noteTransfer(.fromHost)
    }

    /// Looks for a local change and sends it. Cheap when nothing changed: it
    /// reads only the change count.
    public func checkLocal() {
        guard isWatching, isEnabled else { return }
        let count = pasteboard.changeCount
        guard count != seenChangeCount else { return }
        if sendFiles != nil, pasteboard.holdsCopiedFiles {
            guard !isStaging else { return } // looked at again once that is done
            seenChangeCount = count
            stageCopiedFiles(count)
            return
        }
        guard sendsAutomatically else {
            // Not read; but the files the host was told about are gone.
            takeBackFiles()
            return
        }
        seenChangeCount = count
        if let sendFiles, let urls = pasteboard.readFileURLs(), !urls.isEmpty {
            let own = ownFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false) }
            let theirs = urls.filter { url in
                guard let own else { return true }
                return !url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false).hasPrefix(own)
            }
            // The host's files fetched here: nothing new to tell it.
            guard !theirs.isEmpty else { return }
            sendFiles(theirs)
            filesShared = true
            // Not also their names as text (§7.12).
            filter.reset()
            noteTransfer(.toHost)
            return
        }
        takeBackFiles()
        guard pasteboard.hasText, let text = pasteboard.readText(), filter.shouldSend(text) else { return }
        sendText(text)
        noteTransfer(.toHost)
    }

    /// Copies what the Files app copied, then lists it to the host, unless
    /// something else was copied meanwhile.
    private func stageCopiedFiles(_ count: Int) {
        isStaging = true
        let directory = stagingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let interrupted = Interruption()
        let started = ContinuousClock.now
        Task { @MainActor in
            let urls = await pasteboard.copyCopiedFiles(into: directory)
            interrupted.stop()
            let took = ContinuousClock.now - started
            isStaging = false
            guard isWatching, isEnabled, let sendFiles, pasteboard.changeCount == count, let urls else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            staged.append(directory)
            while staged.count > Self.stagedCopiesKept { try? FileManager.default.removeItem(at: staged.removeFirst()) }
            sendFiles(urls)
            filesShared = true
            filter.reset()
            noteTransfer(.toHost)
            onFilesSent?(interrupted.happened || (took > answerTime && Self.size(of: directory) < Self.smallCopy))
        }
    }

    /// Longer than copying a small copy takes, unless someone was asked.
    @ObservationIgnored var answerTime: Duration = .seconds(1.5)
    static let smallCopy: UInt64 = 50_000_000

    /// How much is in `folder`, all told.
    private static func size(of folder: URL) -> UInt64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total: UInt64 = 0
        while let url = files?.nextObject() as? URL {
            total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The clipboard no longer holds the files the host was told about.
    private func takeBackFiles() {
        guard filesShared else { return }
        filesShared = false
        sendFiles?([])
    }

    /// Text the user explicitly sent (a paste button).
    public func send(_ text: String) {
        guard isEnabled, filter.shouldSendExplicitly(text) else { return }
        sendText(text)
        noteTransfer(.toHost)
    }

    /// Text to be pasted on the host (the prompt panel): put on the host's
    /// clipboard whether or not the user shares the clipboard, since they
    /// asked for exactly this text to go. Not noted as a transfer (the
    /// panel says what it did), and the host echoing it back doesn't
    /// replace the local clipboard. False if it can't go (empty, too long).
    public func sendForPaste(_ text: String) -> Bool {
        guard filter.shouldSendExplicitly(text) else { return false }
        sendText(text)
        return true
    }

    /// Copied files are put on the clipboard while it is shared.
    public func markForCopiedFiles() -> Int? {
        guard isWatching, isEnabled else { return nil }
        return pasteboard.changeCount
    }

    /// The host's copied files, fetched: on the local clipboard, as text from
    /// the host is, unless something was copied here since `mark` (§7.12).
    public func putCopiedFiles(_ urls: [URL], ifUnchangedSince mark: Int) -> Bool {
        guard isWatching, isEnabled, !urls.isEmpty, pasteboard.changeCount == mark else { return false }
        takeBackFiles()
        pasteboard.writeFiles(urls)
        // Our own write is not a local copy.
        seenChangeCount = pasteboard.changeCount
        noteTransfer(.fromHost)
        return true
    }

    private func noteTransfer(_ direction: Transfer.Direction) {
        lastTransfer = Transfer(direction: direction, serial: (lastTransfer?.serial ?? 0) + 1)
    }

    /// Starts watching the local clipboard: once the session is established
    /// with `clipboard` in effect.
    public func start() {
        guard !isWatching else { return }
        isWatching = true
        rebaseline()
        let center = NotificationCenter.default
        #if os(macOS)
        let names = [NSApplication.didBecomeActiveNotification]
        #else
        // changedNotification doesn't report another app's copy while this
        // one stays active (Split View, Universal Clipboard): the poll does.
        let names = [UIApplication.didBecomeActiveNotification, UIPasteboard.changedNotification]
        #endif
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkLocal() }
            })
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                #if os(macOS)
                guard NSApplication.shared.isActive else { return }
                #else
                guard UIApplication.shared.applicationState == .active else { return }
                #endif
                self?.checkLocal()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stop() {
        isWatching = false
        // The session's lists go with it, and the copies made for them.
        filesShared = false
        sendFiles = nil
        staged = []
        try? FileManager.default.removeItem(at: stagingFolder)
        pollTimer?.invalidate()
        pollTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    isolated deinit { stop() }

    /// From now on only later copies count, and nothing is assumed about what the host holds.
    private func rebaseline() {
        seenChangeCount = pasteboard.changeCount
        filter.reset()
    }
}

#if os(macOS)
/// `NSPasteboard.general`.
public final class SystemPasteboard: LocalPasteboard {
    /// nspasteboard.org's markers: password managers put these on secrets,
    /// and clipboard tools leave such content alone.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]
    private let pasteboard = NSPasteboard.general

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }
    public var hasText: Bool { pasteboard.availableType(from: [.string]) != nil }

    public func readText() -> String? {
        if let types = pasteboard.types, !Self.privateTypes.isDisjoint(with: types) { return nil }
        return pasteboard.string(forType: .string)
    }

    public func writeText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func writeFiles(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    public func readFileURLs() -> [URL]? {
        if let types = pasteboard.types, !Self.privateTypes.isDisjoint(with: types) { return nil }
        guard pasteboard.availableType(from: [.fileURL]) != nil else { return nil }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL]).flatMap { $0.isEmpty ? nil : $0 }
    }
}
#else
/// `UIPasteboard.general`. Reading text another app copied shows the
/// system's paste prompt unless the user allowed pasting from other apps
/// in Settings; ``hasText`` and ``changeCount`` never do.
public final class SystemPasteboard: LocalPasteboard {
    private let pasteboard = UIPasteboard.general

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }
    public var hasText: Bool { pasteboard.hasStrings }
    public func readText() -> String? { pasteboard.string }
    public func writeText(_ text: String) { pasteboard.string = text }
    public func writeFiles(_ urls: [URL]) { pasteboard.urls = urls }
    /// Nothing: what the Files app copies comes as item providers, see ``copyCopiedFiles(into:)``.
    public func readFileURLs() -> [URL]? { nil }

    /// The Files app marks its copies with these types; reading the types asks nothing.
    public var holdsCopiedFiles: Bool {
        pasteboard.types.contains { $0.hasPrefix("com.apple.DocumentManager.FINode") }
    }

    public func copyCopiedFiles(into directory: URL) async -> [URL]? {
        var urls: [URL] = []
        for (index, provider) in pasteboard.itemProviders.enumerated() {
            guard let type = Self.fileType(of: provider) else { continue }
            // A folder each: two copies can have the same name.
            let place = directory.appending(path: "\(index)", directoryHint: .isDirectory)
            if let url = await Self.copy(provider, as: type, into: place) { urls.append(url) }
        }
        return urls.isEmpty ? nil : urls
    }

    /// The type to read an item as: a folder, or the file's own type (not the Files app's markers).
    private static func fileType(of provider: NSItemProvider) -> String? {
        let types = provider.registeredTypeIdentifiers
        if types.contains(UTType.folder.identifier) { return UTType.folder.identifier }
        return types.first { id in
            !id.hasPrefix("com.apple.DocumentManager.") && id != "com.apple.uikit.useractivity"
                && UTType(id)?.conforms(to: .item) == true
        }
    }

    /// The system's copy goes when its handler returns: moved (the same
    /// volume, so at once) into `place` first.
    private static func copy(_ provider: NSItemProvider, as type: String, into place: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                do {
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    let target = place.appending(path: url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
#endif

/// Whether the app stopped being active between this being made and
/// ``stop()``: on iOS, the sign that the system showed its paste prompt.
@MainActor
private final class Interruption {
    private(set) var happened = false
    private var observer: NSObjectProtocol?

    init() {
        #if os(iOS)
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.happened = true }
        }
        #endif
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
