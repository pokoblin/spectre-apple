import Foundation
import GDPKit
import ImageIO
import Observation
import SpectreKit
import UniformTypeIdentifiers

/// The app's two screens: signing in, and a session. Command-line runs
/// (`--bench`, `--source`, `--connect`) skip the login and play directly.
@MainActor
@Observable
final class AppModel {
    enum Screen {
        case login
        case session(PlaybackModel)
    }

    struct RecentLogin: Codable, Hashable, Identifiable {
        var server: String
        var username: String
        var id: String { "\(username)@\(server)" }
        /// As the list shows it, the same in every language.
        var title: String { "\(username) @ \(server)" }
    }

    /// A server and an account on it: what the iPad's home screen lists
    /// as a host (docs/ipad-layout.md). Kept on this device; its password,
    /// if saved, is in the Keychain (docs/saved-logins.md).
    struct SavedHost: Codable, Hashable, Identifiable {
        var id = UUID()
        /// The user's name for it; empty: the server's address.
        var name = ""
        var server: String
        var username: String
        var lastConnected: Date?

        var title: String { name.isEmpty ? server : name }
        /// As the lists show it, the same in every language.
        var account: String { "\(username) @ \(server)" }
        var address: ServerAddress? { ServerAddress(parsing: server) }
    }

    private(set) var screen: Screen = .login
    let login = LoginFlow()
    /// Why the last session ended, for the login screen.
    private(set) var lastSessionEnd: String?
    private(set) var recent: [RecentLogin] = []
    /// The recent logins with a saved login in the Keychain (docs/saved-logins.md).
    private(set) var savedRecent: Set<RecentLogin> = []
    /// What the session's login answered and chose, to sign in again after
    /// a lost connection. Memory only, gone when the session ends.
    private var recipe: LoginFlow.Recipe?
    /// A replayed login is under way: its redirect is a reconnect's, not a new session.
    private var signingInAgain = false

    private static let recentKey = "recentLogins"
    private static let hostsKey = "savedHosts"

    private(set) var hosts: [SavedHost] = []
    /// The host being signed in to: the iPad's login sheet is up while it is set.
    var loginHost: SavedHost.ID?
    /// The host of the session, or of the one that last ended (whose
    /// ending the home screen says).
    private(set) var sessionHost: SavedHost.ID?
    /// Bumped when a thumbnail is written, so the home screen reloads it.
    private(set) var thumbnailRevision = 0

    init(arguments: [String] = CommandLine.arguments) {
        let direct = ["--bench", "--source", "--connect"]
        if arguments.contains(where: direct.contains) {
            screen = .session(PlaybackModel(arguments: arguments))
        }
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([RecentLogin].self, from: data) {
            recent = saved
        }
        login.onRedirect = { [weak self] ticket in self?.open(ticket) }
        loadHosts()
        refreshSaved()
    }

    // MARK: Hosts (the iPad's home screen)

    private func loadHosts() {
        if let data = UserDefaults.standard.data(forKey: Self.hostsKey),
           let saved = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = saved
        } else {
            // First run with hosts: the recent logins become them.
            hosts = recent.map { SavedHost(server: $0.server, username: $0.username) }
            saveHosts()
        }
    }

    private func saveHosts() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: Self.hostsKey) }
    }

    func host(_ id: SavedHost.ID?) -> SavedHost? { hosts.first { $0.id == id } }

    /// Adds a host, or replaces the one with its id.
    func saveHost(_ host: SavedHost) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            let old = hosts[i]
            hosts[i] = host
            // A different server or account: the old one's password goes.
            if old.server != host.server || old.username != host.username { forgetPassword(old) }
        } else {
            hosts.append(host)
        }
        saveHosts()
    }

    /// Deletes a host with its saved password, thumbnail and region alert.
    func deleteHost(_ host: SavedHost) {
        forgetPassword(host)
        hosts.removeAll { $0.id == host.id }
        try? FileManager.default.removeItem(at: Self.thumbnailURL(host.id))
        RegionAlertStore.shared[host: host.id] = nil
        saveHosts()
    }

    func hasSavedPassword(_ host: SavedHost) -> Bool {
        _ = savedRevision
        return host.address.map { login.hasSavedLogin(server: $0, username: host.username) } ?? false
    }

    func forgetPassword(_ host: SavedHost) {
        if let server = host.address { login.savedLogins.delete(server: server, username: host.username) }
        savedRevision += 1
        refreshSaved()
    }

    /// Bumped when a saved password goes, so ``hasSavedPassword(_:)`` is read again.
    private var savedRevision = 0

    /// Connect: the login sheet comes up, already signing in if the
    /// password is saved. False if the saved one couldn't be read.
    @discardableResult
    func connect(_ host: SavedHost) -> Bool {
        lastSessionEnd = nil
        recipe = nil
        login.cancel()
        loginHost = host.id
        guard hasSavedPassword(host), let server = host.address else { return true }
        return login.signInWithSaved(server: server, username: host.username)
    }

    /// The login sheet's Connect: `password` answers the server's first secret prompt.
    func signIn(_ host: SavedHost, password: String, remember: Bool) {
        guard let server = host.address else { return }
        signIn(server: server, username: host.username, password: password, remember: remember)
    }

    /// The login sheet went away without a session.
    func cancelLogin() {
        login.cancel()
        loginHost = nil
    }

    /// The session's host connected: it moves to the top of Recent.
    private func touchHost(server: String, username: String) -> SavedHost.ID {
        let i = hosts.firstIndex { $0.id == loginHost }
            ?? hosts.firstIndex { $0.server == server && $0.username == username }
        if let i {
            hosts[i].lastConnected = Date()
            saveHosts()
            return hosts[i].id
        }
        let host = SavedHost(server: server, username: username, lastConnected: Date())
        hosts.append(host)
        saveHosts()
        return host.id
    }

    // MARK: Thumbnails

    /// The last picture of a host's remote desktop, on this device only
    /// (Caches: the system may clear it).
    static func thumbnailURL(_ id: SavedHost.ID) -> URL {
        URL.cachesDirectory.appending(path: "Thumbnails").appending(path: "\(id.uuidString).jpg")
    }

    private func saveThumbnail(_ image: CGImage, for id: SavedHost.ID) {
        let url = Self.thumbnailURL(id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if CGImageDestinationFinalize(destination) { thumbnailRevision += 1 }
    }

    /// Which recent logins have a saved login (reads no secret).
    private func refreshSaved() {
        savedRecent = Set(recent.filter { entry in
            ServerAddress(parsing: entry.server).map { login.hasSavedLogin(server: $0, username: entry.username) } ?? false
        })
    }

    /// One tap on a recent login with a saved one: signs in with it. False
    /// if it couldn't be read (on the Mac, keychain access not allowed).
    func signInWithSaved(_ entry: RecentLogin) -> Bool {
        guard let server = ServerAddress(parsing: entry.server) else { return false }
        lastSessionEnd = nil
        recipe = nil
        return login.signInWithSaved(server: server, username: entry.username)
    }

    /// Forgets the saved password, keeps the recent login.
    func forgetSavedLogin(_ entry: RecentLogin) {
        if let server = ServerAddress(parsing: entry.server) {
            login.savedLogins.delete(server: server, username: entry.username)
        }
        refreshSaved()
    }

    /// `password`: the form's, for the server's first secret prompt (empty: none).
    func signIn(server: ServerAddress, username: String, password: String, remember: Bool) {
        lastSessionEnd = nil
        recipe = nil
        login.start(server: server, username: username, password: password, remember: remember)
    }

    private func open(_ ticket: LoginFlow.SessionTicket) {
        guard !signingInAgain else { return } // signInAgain takes it
        recipe = login.recipe
        remember(RecentLogin(server: ticket.server.description, username: ticket.username))
        let hostID = touchHost(server: ticket.server.description, username: ticket.username)
        sessionHost = hostID
        loginHost = nil
        // The host's own name when it has one (the iPad's back button shows it).
        let title = host(hostID).flatMap { $0.name.isEmpty ? nil : $0.name } ?? "\(ticket.username)@\(ticket.server)"
        let model = PlaybackModel(session: ticket.configuration, title: title) { [weak self] message in
            self?.sessionEnded(message)
        }
        model.onSnapshot = { [weak self] image in self?.saveThumbnail(image, for: hostID) }
        model.hostKey = hostID.uuidString
        model.reconnection = { [weak self] allowTakeOver in
            await self?.signInAgain(allowTakeOver: allowTakeOver) ?? .stop("Disconnected.")
        }
        model.onNeedsLogin = { [weak self] message in self?.needsLogin(message) }
        screen = .session(model)
    }

    private func sessionEnded(_ message: String) {
        lastSessionEnd = message
        recipe = nil
        login.cancel()
        refreshSaved()
        screen = .login
    }

    /// A lost session's new token: the login replayed (docs/reconnect.md).
    private func signInAgain(allowTakeOver: Bool) async -> PlaybackModel.Reconnection {
        guard let recipe else { return .stop(String(localized: "The connection was lost. Sign in again.")) }
        signingInAgain = true
        defer { signingInAgain = false }
        login.replay(recipe, allowTakeOver: allowTakeOver)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            switch login.step {
            case let .redirected(ticket):
                self.recipe = login.recipe ?? recipe
                return .configuration(ticket.configuration)
            case let .failed(failure):
                return ReconnectPolicy.retries(loginFailure: failure.code) ? .retry(failure.message) : .stop(failure.message)
            case .prompt, .chooseDevice, .chooseSession, .trustNewHost, .certificateChanged:
                return .userNeeded // the replay stopped there for the user
            case .idle, .working:
                break
            }
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                login.cancel()
                return .stop(String(localized: "Disconnected."))
            }
        }
        login.cancel()
        return .retry(String(localized: "The server did not answer."))
    }

    /// Signing in again needs the user: the login screen, at the step the
    /// replay stopped on; finishing it opens the session as usual.
    private func needsLogin(_ message: String) {
        lastSessionEnd = message
        refreshSaved()
        loginHost = sessionHost // the iPad's login sheet, at the step the replay stopped on
        screen = .login
    }

    /// The servers whose certificate the user trusted (docs/login.md).
    var trustedServers: [KnownHosts.Pin] { _ = trustedRevision; return login.knownHosts.all }
    /// Bumped when a pin is forgotten here, so the list redraws.
    private var trustedRevision = 0

    /// Forgets a trusted server's fingerprint: its next connection asks again
    /// (§2.3). Its recent login and saved password stay.
    func forgetTrusted(_ pin: KnownHosts.Pin) {
        login.knownHosts.forget(pin.server)
        trustedRevision += 1
    }

    /// Forgets a recent login, and its saved password with it.
    func forgetRecent(_ entry: RecentLogin) {
        forgetSavedLogin(entry)
        recent.removeAll { $0 == entry }
        save()
        refreshSaved()
    }

    private func remember(_ entry: RecentLogin) {
        recent.removeAll { $0 == entry }
        recent.insert(entry, at: 0)
        recent = Array(recent.prefix(5))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Self.recentKey) }
    }
}
