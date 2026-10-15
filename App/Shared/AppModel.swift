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
    }

    private(set) var screen: Screen = .login
    let login = LoginFlow()
    /// Why the last session ended, for the login screen.
    private(set) var lastSessionEnd: String?
    private(set) var recent: [RecentLogin] = []
    private(set) var demo: DemoServer?
    private(set) var demoStatus: String?
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
        let keep: [AnyObject] = demo.map { [$0] } ?? []
        let model = PlaybackModel(session: ticket.configuration, title: "\(ticket.username)@\(ticket.server)",
                                  keepAlive: keep) { [weak self] message in
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
        screen = .login
    }

    /// A lost session's new token: the login replayed (docs/reconnect.md).
    private func signInAgain(allowTakeOver: Bool) async -> PlaybackModel.Reconnection {
        guard let recipe else { return .stop("The connection was lost. Sign in again.") }
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
                return .stop("Disconnected.")
            }
        }
        login.cancel()
        return .retry("the server did not answer")
    }

    /// Signing in again needs the user: the login screen, at the step the
    /// replay stopped on; finishing it opens the session as usual.
    private func needsLogin(_ message: String) {
        lastSessionEnd = message
        screen = .login
    }

    /// Starts the in-process demo servers and returns where to sign in.
    func startDemo() async -> (server: ServerAddress, username: String, password: String)? {
        if let demo { return (demo.address, DemoServer.username, DemoServer.password) }
        demoStatus = "Preparing the demo host…"
        defer { demoStatus = nil }
        do {
            let server = try await DemoServer.start()
            demo = server
            return (server.address, DemoServer.username, DemoServer.password)
        } catch {
            lastSessionEnd = "The demo could not start: \(error)"
            return nil
        }
    }

    func forgetRecent(_ entry: RecentLogin) {
        recent.removeAll { $0 == entry }
        save()
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

/// A host and a lobby in this process, so the login and the session can be
/// tried without a server: a test lobby (password "demo") that redirects to
/// a loopback host streaming the test pattern over real QUIC.
final class DemoServer: Sendable {
    static let username = "demo"
    static let password = "demo"

    let host: LoopbackHost
    let lobby: GDPTestLobby
    let address: ServerAddress

    private init(host: LoopbackHost, lobby: GDPTestLobby) {
        self.host = host
        self.lobby = lobby
        address = ServerAddress(host: "127.0.0.1", port: lobby.port)
    }

    deinit { host.stop() }

    static func start() async throws -> DemoServer {
        let stream = try await Task.detached(priority: .userInitiated) {
            try TestStreamEncoder.encode(codec: .h264, frameCount: 300) // 5 s, looped
        }.value
        let host = try LoopbackHost(stream: stream)
        var config = GDPTestLobby.Configuration()
        config.username = username
        config.prompts = [.init("Password: ", expected: password)]
        config.sessionTypes = [("gnome", "GNOME"), ("plasma", "KDE Plasma"), ("sway", "Sway")]
        config.redirect(to: host.host)
        let lobby = try GDPTestLobby(config)
        host.start()
        return DemoServer(host: host, lobby: lobby)
    }
}
