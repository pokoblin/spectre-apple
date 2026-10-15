import Foundation
import Security
import Testing
@testable import SpectreKit

@Suite("Saved logins")
struct SavedLoginsTests {
    static let login = SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "s3cret"),
                                            .init(prompt: "Domain: ", echo: true, text: "lab")],
                                  deviceID: "ws", sessionType: "gnome")

    /// Whether this test process may use the Keychain at all: not on the iOS
    /// simulator, where a package's tests run without a host app and so
    /// without the application-identifier entitlement (errSecMissingEntitlement).
    /// The app itself has it; docs/saved-logins.md checks it there.
    static let keychainAvailable: Bool = {
        let probe = KeychainSavedLogins(service: "org.ghost.spectre.apple.tests.probe.\(UUID().uuidString)")
        let server = ServerAddress(host: "probe")
        defer { probe.delete(server: server, username: "probe") }
        return probe.save(SavedLogin(answers: []), server: server, username: "probe") || probe.lastStatus != errSecMissingEntitlement
    }()

    /// The real Keychain, under a service of the test's own, emptied afterwards.
    @Test(.enabled(if: keychainAvailable, "no Keychain entitlement (package tests on the iOS simulator)"))
    func keychainRoundTrip() {
        let store = KeychainSavedLogins(service: "org.ghost.spectre.apple.tests.\(UUID().uuidString)")
        let server = ServerAddress(host: "Host.Example", port: 4443)
        defer {
            store.delete(server: server, username: "alice")
            store.delete(server: server, username: "bob")
        }
        #expect(!store.contains(server: server, username: "alice"))
        #expect(store.load(server: server, username: "alice") == nil)

        let saved = store.save(Self.login, server: server, username: "alice")
        #expect(saved, "SecItemAdd: \(store.lastStatus)")
        #expect(store.contains(server: server, username: "alice"))
        #expect(store.load(server: ServerAddress(host: "host.example", port: 4443), username: "alice") == Self.login)
        #expect(!store.contains(server: server, username: "bob"))                              // per user
        #expect(!store.contains(server: ServerAddress(host: "host.example"), username: "alice")) // per port

        var changed = Self.login
        changed.answers[0].text = "n3w"
        store.save(changed, server: server, username: "alice") // replaces
        #expect(store.load(server: server, username: "alice") == changed)

        store.delete(server: server, username: "alice")
        #expect(!store.contains(server: server, username: "alice"))
        #expect(store.load(server: server, username: "alice") == nil)
    }

    @Test func memoryStoreBehavesAlike() {
        let store = MemorySavedLogins()
        let server = ServerAddress(host: "h")
        store.save(Self.login, server: server, username: "alice")
        #expect(store.contains(server: server, username: "alice") && store.load(server: server, username: "alice") == Self.login)
        store.delete(server: server, username: "alice")
        #expect(!store.contains(server: server, username: "alice"))
    }
}
