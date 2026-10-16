import Foundation
import GDPKit
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
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
@MainActor
@Observable
public final class ClipboardSync {
    public static let enabledKey = "clipboardSync"
    public static let sendsAutomaticallyKey = "clipboardSendsAutomatically"

    /// The user's switch for the whole feature (the spec's privacy notes: a
    /// client SHOULD let its user turn it off); off by default, remembered
    /// across sessions.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            rebaseline()
        }
    }

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
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        sendsAutomatically = Self.automaticIsOptional ? defaults.bool(forKey: Self.sendsAutomaticallyKey) : true
    }

    /// The host's clipboard changed (or, right after SessionAccept, what it was).
    public func hostChanged(_ text: String) {
        guard isEnabled, filter.shouldApply(text) else { return }
        pasteboard.writeText(text)
        // Our own write is not a local copy.
        seenChangeCount = pasteboard.changeCount
        noteTransfer(.fromHost)
    }

    /// Looks for a local change and sends it. Cheap when nothing changed: it
    /// reads only the change count.
    public func checkLocal() {
        guard isWatching, isEnabled, sendsAutomatically else { return }
        let count = pasteboard.changeCount
        guard count != seenChangeCount else { return }
        seenChangeCount = count
        guard pasteboard.hasText, let text = pasteboard.readText(), filter.shouldSend(text) else { return }
        sendText(text)
        noteTransfer(.toHost)
    }

    /// Text the user explicitly sent (a paste button).
    public func send(_ text: String) {
        guard isEnabled, filter.shouldSendExplicitly(text) else { return }
        sendText(text)
        noteTransfer(.toHost)
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
}
#endif
