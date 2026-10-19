import Foundation
import GDPKit
import ImageIO
import Observation
import SpectreKit
import UniformTypeIdentifiers

/// The app's hosts, signing in, and the sessions open. On iPad and iPhone
/// one session at a time covers the home screen; on the Mac each has a
/// window of its own (docs/macos-layout.md). Command-line runs (`--bench`,
/// `--source`, `--connect`) skip the login and play directly.
@MainActor
@Observable
final class AppModel {
    enum Screen {
        case login
        case session(PlaybackModel)
    }

    /// An open session: its model, and the host it is of (none for the
    /// command line's).
    struct Session: Identifiable {
        let id: UUID
        let model: PlaybackModel
        let hostID: SavedHost.ID?
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

    private(set) var sessions: [Session] = []
    /// iOS: the session covering the home screen, if any.
    var screen: Screen { sessions.last.map { .session($0.model) } ?? .login }
    func session(_ id: UUID?) -> Session? { sessions.first { $0.id == id } }
    /// A change made in the Mac's Settings, made in every open session too.
    func applyToSessions(_ change: (PlaybackModel) -> Void) { sessions.forEach { change($0.model) } }
    /// A session opened (the Mac gives it a window).
    var onSessionOpened: ((UUID) -> Void)?
    /// Signing in needs the home window (the Mac brings it forward).
    var onShowHome: (() -> Void)?

    /// The login the home screen's sheet shows. A lost session's replayed
    /// login that stops for the user becomes it.
    private(set) var login = LoginFlow()
    /// Why the last session ended, for the login screen.
    private(set) var lastSessionEnd: String?
    private(set) var recent: [RecentLogin] = []
    /// What each session's login answered and chose, to sign in again after
    /// a lost connection. Memory only, gone when the session ends.
    private var recipes: [UUID: LoginFlow.Recipe] = [:]

    private static let recentKey = "recentLogins"
    private static let hostsKey = "savedHosts"

    private(set) var hosts: [SavedHost] = []
    /// The host being signed in to: the home screen's login sheet is up while it is set.
    var loginHost: SavedHost.ID?
    /// The trusted servers sheet is up (the Mac's app menu opens it too).
    var showsTrustedServers = false
    /// The host of the session, or of the one that last ended (whose
    /// ending the home screen says).
    private(set) var sessionHost: SavedHost.ID?
    /// Bumped when a thumbnail is written, so the home screen reloads it.
    private(set) var thumbnailRevision = 0

    init(arguments: [String] = CommandLine.arguments) {
        let direct = ["--bench", "--source", "--connect"]
        if arguments.contains(where: direct.contains) {
            let id = UUID()
            sessions = [Session(id: id, model: PlaybackModel(arguments: arguments), hostID: nil)]
        }
        if let data = UserDefaults.standard.data(forKey: Self.recentKey),
           let saved = try? JSONDecoder().decode([RecentLogin].self, from: data) {
            recent = saved
        }
        wire(login)
        loadHosts()
    }

    /// A login whose redirect opens a session.
    private func wire(_ flow: LoginFlow) {
        flow.onRedirect = { [weak self, weak flow] ticket in
            guard let self, let flow, flow === self.login else { return }
            self.open(ticket)
        }
    }

    // MARK: Hosts (the home screen)

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

    /// Adds a host, or replaces the one with its id. `password`, typed in
    /// its form (empty: none, or the saved one stays), is kept in the
    /// Keychain if `remember`, otherwise only until the app quits; either
    /// way Connect signs in with it (docs/saved-logins.md).
    func saveHost(_ host: SavedHost, password: String = "", remember: Bool = false) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) {
            let old = hosts[i]
            hosts[i] = host
            // A different server or account: the old one's password goes.
            if old.server != host.server || old.username != host.username { forgetPassword(old) }
        } else {
            hosts.append(host)
        }
        saveHosts()
        guard !password.isEmpty, let server = host.address else { return }
        if remember {
            login.savedLogins.savePassword(password, server: server, username: host.username)
            sessionPasswords[host.id] = nil
            savedRevision += 1
        } else {
            // A new password not to keep: the saved one is out of date.
            forgetPassword(host)
            sessionPasswords[host.id] = password
        }
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

    /// A password typed for this host but not kept: Connect uses it until the app quits.
    func hasSessionPassword(_ host: SavedHost) -> Bool { sessionPasswords[host.id] != nil }

    func forgetPassword(_ host: SavedHost) {
        if let server = host.address { login.savedLogins.delete(server: server, username: host.username) }
        sessionPasswords[host.id] = nil
        savedRevision += 1
    }

    /// Bumped when a saved password comes or goes, so ``hasSavedPassword(_:)`` is read again.
    private var savedRevision = 0
    /// Passwords typed but not kept in the Keychain, by host: memory only.
    private var sessionPasswords: [SavedHost.ID: String] = [:]

    /// Connect: the login sheet comes up, already signing in if the
    /// password is known (saved, or typed in the host's form this time);
    /// it asks for it otherwise. False if the saved one couldn't be read.
    @discardableResult
    func connect(_ host: SavedHost) -> Bool {
        lastSessionEnd = nil
        login.cancel()
        loginHost = host.id
        guard let server = host.address else { return true }
        if hasSavedPassword(host) {
            return login.signInWithSaved(server: server, username: host.username)
        }
        if let password = sessionPasswords[host.id] {
            login.start(server: server, username: host.username, password: password)
        }
        return true
    }

    /// The login sheet's Connect: `password` answers the server's first secret prompt.
    func signIn(_ host: SavedHost, password: String, remember: Bool) {
        guard let server = host.address else { return }
        // The latest password typed: not kept, it stands in for the form's until the app quits.
        sessionPasswords[host.id] = remember || password.isEmpty ? nil : password
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

    /// `password`: the form's, for the server's first secret prompt (empty: none).
    func signIn(server: ServerAddress, username: String, password: String, remember: Bool) {
        lastSessionEnd = nil
        login.start(server: server, username: username, password: password, remember: remember)
    }

    private func open(_ ticket: LoginFlow.SessionTicket) {
        let id = UUID()
        recipes[id] = login.recipe
        remember(RecentLogin(server: ticket.server.description, username: ticket.username))
        let hostID = touchHost(server: ticket.server.description, username: ticket.username)
        sessionHost = hostID
        loginHost = nil
        // The host's own name when it has one (the iPad's back button shows it).
        let title = host(hostID).flatMap { $0.name.isEmpty ? nil : $0.name } ?? "\(ticket.username)@\(ticket.server)"
        let model = PlaybackModel(session: ticket.configuration, title: title) { [weak self] message in
            self?.sessionEnded(id, message)
        }
        model.onSnapshot = { [weak self] image in self?.saveThumbnail(image, for: hostID) }
        model.hostKey = hostID.uuidString
        model.reconnection = { [weak self] allowTakeOver in
            await self?.signInAgain(id, allowTakeOver: allowTakeOver) ?? .stop("Disconnected.")
        }
        model.onNeedsLogin = { [weak self] message in self?.needsLogin(id, message) }
        sessions.append(Session(id: id, model: model, hostID: hostID))
        onSessionOpened?(id)
    }

    private func sessionEnded(_ id: UUID, _ message: String) {
        guard let session = session(id) else { return }
        lastSessionEnd = message
        sessionHost = session.hostID ?? sessionHost
        recipes[id] = nil
        replays[id]?.cancel()
        replays[id] = nil
        sessions.removeAll { $0.id == id }
        // The Mac: back to the home window, which says why.
        onShowHome?()
    }

    /// A session's window closed (the Mac): the session disconnects (the
    /// remote desktop keeps running) and is gone.
    func windowClosed(_ id: UUID) {
        guard let session = session(id) else { return }
        if session.model.canClose { session.model.disconnect() } else { session.model.windowClosed() }
        recipes[id] = nil
        replays[id]?.cancel()
        replays[id] = nil
        sessions.removeAll { $0.id == id }
    }

    /// The logins a lost session is replaying, one each (several sessions
    /// may be reconnecting at once on the Mac).
    private var replays: [UUID: LoginFlow] = [:]

    /// A lost session's new token: its login replayed (docs/reconnect.md).
    private func signInAgain(_ id: UUID, allowTakeOver: Bool) async -> PlaybackModel.Reconnection {
        guard let recipe = recipes[id] else { return .stop(String(localized: "The connection was lost. Sign in again.")) }
        let flow = LoginFlow(knownHosts: login.knownHosts, savedLogins: login.savedLogins, codecs: login.codecs)
        replays[id]?.cancel()
        replays[id] = flow
        flow.replay(recipe, allowTakeOver: allowTakeOver)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            switch flow.step {
            case let .redirected(ticket):
                recipes[id] = flow.recipe ?? recipe
                replays[id] = nil
                return .configuration(ticket.configuration)
            case let .failed(failure):
                replays[id] = nil
                return ReconnectPolicy.retries(loginFailure: failure.code) ? .retry(failure.message) : .stop(failure.message)
            case .prompt, .chooseDevice, .chooseSession, .trustNewHost, .certificateChanged:
                return .userNeeded // the replay stopped there for the user; needsLogin takes the flow
            case .idle, .working:
                break
            }
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                flow.cancel()
                replays[id] = nil
                return .stop(String(localized: "Disconnected."))
            }
        }
        flow.cancel()
        replays[id] = nil
        return .retry(String(localized: "The server did not answer."))
    }

    /// Signing in again needs the user: the home screen's login sheet, at
    /// the step the replay stopped on; finishing it opens the session anew.
    private func needsLogin(_ id: UUID, _ message: String) {
        let hostID = session(id)?.hostID
        if let flow = replays[id] {
            replays[id] = nil
            login.cancel()
            login = flow
            wire(flow)
        }
        recipes[id] = nil
        sessions.removeAll { $0.id == id }
        lastSessionEnd = message
        sessionHost = hostID ?? sessionHost
        loginHost = hostID
        onShowHome?()
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
