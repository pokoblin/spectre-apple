import Foundation
import Security
import Synchronization

/// The answers of a login the user asked to remember, with the device and
/// desktop chosen then: enough to sign in again with one tap, replayed as
/// a ``LoginFlow/Recipe`` (docs/saved-logins.md).
public struct SavedLogin: Codable, Sendable, Equatable {
    public struct Answer: Codable, Sendable, Equatable {
        public var prompt: String
        /// False for a secret (§4.3): only those the user ticked "Remember" on are saved.
        public var echo: Bool
        public var text: String

        public init(prompt: String, echo: Bool, text: String) {
            self.prompt = prompt
            self.echo = echo
            self.text = text
        }
    }

    public var answers: [Answer]
    public var deviceID: String?
    public var sessionType: String?

    public init(answers: [Answer], deviceID: String? = nil, sessionType: String? = nil) {
        self.answers = answers
        self.deviceID = deviceID
        self.sessionType = sessionType
    }
}

/// Where saved logins live, one per username and server.
public protocol SavedLogins: AnyObject, Sendable {
    /// Whether one is saved, without reading its secrets (on the Mac, no
    /// keychain prompt).
    func contains(server: ServerAddress, username: String) -> Bool
    func load(server: ServerAddress, username: String) -> SavedLogin?
    /// False if it couldn't be stored (the Keychain refused it).
    @discardableResult func save(_ login: SavedLogin, server: ServerAddress, username: String) -> Bool
    func delete(server: ServerAddress, username: String)
}

extension SavedLogins {
    static func account(server: ServerAddress, username: String) -> String { "\(username)@\(server.key)" }
}

/// Saved logins in the Keychain: one generic password per username@host:port,
/// on this device only. On iOS readable once the device was unlocked after
/// a restart, never synced; on the Mac in the login keychain (the data
/// protection keychain needs a team-signed app), whose access the system
/// asks the user to allow when the app's signature changes.
public final class KeychainSavedLogins: SavedLogins {
    public static let defaultService = "org.ghost.spectre.apple.login"
    public let service: String

    public init(service: String = KeychainSavedLogins.defaultService) {
        self.service = service
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func contains(server: ServerAddress, username: String) -> Bool {
        var q = query(Self.account(server: server, username: username))
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func load(server: ServerAddress, username: String) -> SavedLogin? {
        var q = query(Self.account(server: server, username: username))
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SavedLogin.self, from: data)
    }

    /// The status of the last save, for diagnosis.
    public private(set) var lastStatus: OSStatus {
        get { status.withLock { $0 } }
        set { status.withLock { $0 = newValue } }
    }
    private let status = Mutex<OSStatus>(errSecSuccess)

    @discardableResult
    public func save(_ login: SavedLogin, server: ServerAddress, username: String) -> Bool {
        guard let data = try? JSONEncoder().encode(login) else { return false }
        let account = Self.account(server: server, username: username)
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData] = data
        item[kSecAttrLabel] = "Spectre: \(account)"
        #if os(iOS)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        lastStatus = SecItemAdd(item as CFDictionary, nil)
        return lastStatus == errSecSuccess
    }

    public func delete(server: ServerAddress, username: String) {
        SecItemDelete(query(Self.account(server: server, username: username)) as CFDictionary)
    }
}

/// Saved logins in memory, for tests.
public final class MemorySavedLogins: SavedLogins {
    private let logins = Mutex<[String: SavedLogin]>([:])

    public init() {}

    public func contains(server: ServerAddress, username: String) -> Bool {
        logins.withLock { $0[Self.account(server: server, username: username)] != nil }
    }
    public func load(server: ServerAddress, username: String) -> SavedLogin? {
        logins.withLock { $0[Self.account(server: server, username: username)] }
    }
    @discardableResult
    public func save(_ login: SavedLogin, server: ServerAddress, username: String) -> Bool {
        logins.withLock { $0[Self.account(server: server, username: username)] = login }
        return true
    }
    public func delete(server: ServerAddress, username: String) {
        logins.withLock { $0[Self.account(server: server, username: username)] = nil }
    }
}
