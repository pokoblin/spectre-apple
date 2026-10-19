import Foundation
import GDPKit
import Synchronization

/// A lobby server as the user typed it: `host`, `host:port`, `[v6]` or
/// `[v6]:port`. The host string is kept exactly (lowercased), since the
/// session connection must dial the same name (gdp-spec.md §4.7).
public struct ServerAddress: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = GDPLobby.defaultPort) {
        self.host = host.lowercased()
        self.port = port
    }

    public init?(parsing text: String, defaultPort: UInt16 = GDPLobby.defaultPort) {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty { self.init(host: host, port: defaultPort); return }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            self.init(host: host, port: port)
            return
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1 {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
            self.init(host: String(parts[0]), port: port)
        } else {
            // No colon, or a bare IPv6 address (several): no port given.
            guard !s.contains(where: { $0 == "/" || $0 == " " }) else { return nil }
            self.init(host: s, port: defaultPort)
        }
    }

    public var description: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return port == GDPLobby.defaultPort ? h : "\(h):\(port)"
    }

    /// Always with the port: what pins are keyed by (§2.3: per host name and port).
    var key: String {
        let h = host.contains(":") ? "[\(host)]" : host
        return "\(h):\(port)"
    }
}

/// Trust-on-first-use pins for lobby servers (gdp-spec.md §2.3): the
/// fingerprint the user accepted, per host name and port, in a JSON file.
/// Session certificates are never stored: they arrive in each Redirect.
public final class KnownHosts: Sendable {
    public let file: URL
    private let pins: Mutex<[String: String]>

    /// Posted, with this object, after a pin is trusted or forgotten, on the
    /// thread that changed it: the Mac's Settings lists the pins while
    /// signing in changes them.
    public static let didChange = Notification.Name("KnownHosts.didChange")

    public init(file: URL) {
        self.file = file
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        pins = Mutex(loaded ?? [:])
    }

    /// `~/Library/Application Support/Spectre/known_hosts.json` (inside the sandbox container).
    public static func standard() -> KnownHosts {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Spectre", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return KnownHosts(file: dir.appending(path: "known_hosts.json"))
    }

    public func pin(for server: ServerAddress) -> CertificateFingerprint? {
        pins.withLock { $0[server.key] }.flatMap { CertificateFingerprint(hex: $0) }
    }

    public func trust(_ fingerprint: CertificateFingerprint, for server: ServerAddress) {
        save { $0[server.key] = fingerprint.hex }
    }

    public func forget(_ server: ServerAddress) {
        save { $0.removeValue(forKey: server.key) }
    }

    /// A server the user trusted, and the fingerprint they accepted.
    public struct Pin: Hashable, Sendable, Identifiable {
        public let server: ServerAddress
        public let fingerprint: CertificateFingerprint
        public var id: String { server.key }
    }

    /// Every pin, by host name and port (the Trusted Servers list).
    public var all: [Pin] {
        pins.withLock { $0 }.sorted { $0.key < $1.key }.compactMap { key, hex in
            // Keys are written by ServerAddress.key, which parses back.
            guard let server = ServerAddress(parsing: key), let fingerprint = CertificateFingerprint(hex: hex) else { return nil }
            return Pin(server: server, fingerprint: fingerprint)
        }
    }

    private func save(_ change: (inout [String: String]) -> Void) {
        let data: Data? = pins.withLock {
            change(&$0)
            return try? JSONEncoder().encode($0)
        }
        try? data?.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
