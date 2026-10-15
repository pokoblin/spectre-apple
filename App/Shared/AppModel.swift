import Foundation
import GDPKit
import Observation
import SpectreKit

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
        refreshSaved()
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

    func signIn(server: ServerAddress, username: String) {
        lastSessionEnd = nil
        recipe = nil
        login.start(server: server, username: username)
    }

    private func open(_ ticket: LoginFlow.SessionTicket) {
        guard !signingInAgain else { return } // signInAgain takes it
        recipe = login.recipe
        remember(RecentLogin(server: ticket.server.description, username: ticket.username))
        let title = "\(ticket.username)@\(ticket.server)"
        let model = PlaybackModel(session: ticket.configuration, title: title) { [weak self] message in
            self?.sessionEnded(message)
        }
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
        screen = .login
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
