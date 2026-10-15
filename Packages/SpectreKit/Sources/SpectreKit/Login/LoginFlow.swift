import Foundation
import GDPKit
import Observation
import Synchronization

/// Logging in, from a server address and a username to a ready-to-open
/// session (gdp-spec.md §4, §5), as a state machine a UI renders one step at
/// a time. Certificates follow §2.3: a CA-verified one is accepted outright,
/// an unknown one is shown to the user before anything is sent, a changed
/// one is refused.
@MainActor
@Observable
public final class LoginFlow {
    public struct TrustRequest: Sendable, Equatable {
        public let server: ServerAddress
        public let presented: CertificateFingerprint
        /// The fingerprint saved for this server, when it differs from `presented`.
        public let pinned: CertificateFingerprint?
    }

    public struct Prompt: Sendable, Equatable {
        public let text: String
        /// False for secrets: don't show what is typed (§4.3).
        public let echo: Bool
    }

    public struct SessionChoice: Sendable {
        public let list: GDPLobby.SessionList
        /// A running session another client is viewing: opening it takes it
        /// over (§6.4), which the user must agree to first (§4.6).
        public var needsTakeOver: Bool { list.running.first?.viewerAttached ?? false }
        public var runningTypeName: String? {
            list.running.first.map { r in list.types.first { $0.id == r.sessionType }?.name ?? r.sessionType }
        }
    }

    /// Everything needed to open the session; open it right away (the token lives about 30 s, §4.8).
    public struct SessionTicket: Sendable {
        public let server: ServerAddress
        public let username: String
        public let configuration: GDPSession.Configuration
    }

    /// What an interactive login answered and chose, in order: enough to
    /// sign in again without the user after a lost connection. Lives in
    /// memory only (it holds the password); see docs/reconnect.md.
    public struct Recipe: Sendable {
        public struct Answer: Sendable, Equatable {
            public let prompt: Prompt
            public let text: String
            /// For a secret: the user asked to keep it (saved logins, docs/saved-logins.md).
            public let remember: Bool
        }

        public let server: ServerAddress
        public let username: String
        public fileprivate(set) var answers: [Answer] = []
        public fileprivate(set) var deviceID: String?
        public fileprivate(set) var sessionType: String?

        init(server: ServerAddress, username: String, answers: [Answer] = [],
             deviceID: String? = nil, sessionType: String? = nil) {
            self.server = server
            self.username = username
            self.answers = answers
            self.deviceID = deviceID
            self.sessionType = sessionType
        }

        /// What to keep of it: the secrets the user ticked, and then also the
        /// rest (questions that aren't secret, the device, the desktop);
        /// nil if no secret was ticked.
        var toSave: SavedLogin? {
            guard answers.contains(where: { !$0.prompt.echo && $0.remember }) else { return nil }
            let kept = answers.filter { $0.prompt.echo || $0.remember }
            return SavedLogin(answers: kept.map { .init(prompt: $0.prompt.text, echo: $0.prompt.echo, text: $0.text) },
                              deviceID: deviceID, sessionType: sessionType)
        }

        init(_ saved: SavedLogin, server: ServerAddress, username: String) {
            self.init(server: server, username: username,
                      answers: saved.answers.map { Answer(prompt: Prompt(text: $0.prompt, echo: $0.echo), text: $0.text,
                                                          remember: !$0.echo) },
                      deviceID: saved.deviceID, sessionType: saved.sessionType)
        }
    }

    public struct Failure: Sendable, Equatable {
        public let message: String
        public let code: UInt64
    }

    public enum Step: Sendable {
        case idle
        case working(String)
        case trustNewHost(TrustRequest)
        case certificateChanged(TrustRequest)
        case prompt(Prompt)
        case chooseDevice([GDPLobby.Device])
        case chooseSession(SessionChoice)
        case redirected(SessionTicket)
        case failed(Failure)
    }

    public private(set) var step: Step = .idle {
        didSet { if replay != nil { advanceReplay() } }
    }
    /// What this login answered and chose so far; complete once redirected.
    public private(set) var recipe: Recipe?
    /// Whether a replay is driving this login (it stops at whatever the
    /// recipe can't answer, leaving that step to the user).
    public var isReplaying: Bool { replay != nil }
    private var replay: (recipe: Recipe, nextAnswer: Int, allowTakeOver: Bool)?
    /// The replay answers from a saved login: if the server refuses it, it is forgotten.
    private var replayingSaved = false
    public private(set) var server: ServerAddress?
    public private(set) var username = ""
    public let knownHosts: KnownHosts
    /// Logins the user asked to remember (docs/saved-logins.md).
    public let savedLogins: SavedLogins
    /// Something to tell the user on the current step (a saved password that stopped working).
    public private(set) var notice: String?
    /// Video codecs offered in SessionHello, most preferred first.
    public var codecs: [String]
    /// Called with the ticket when the login succeeds; open the session right away.
    public var onRedirect: ((SessionTicket) -> Void)?

    private var lobby: GDPLobby?
    private var takeOver = false
    /// Bumped by every start and cancel: callbacks of an abandoned login are dropped.
    private var generation = 0
    /// Set by the certificate handler (on the lobby's queue) when it refuses.
    private final class Refused: Sendable {
        let request = Mutex<TrustRequest?>(nil)
    }
    private let refusedCertificate = Refused()

    public init(knownHosts: KnownHosts = .standard(), savedLogins: SavedLogins = KeychainSavedLogins(),
                codecs: [String] = ["h265", "h264"]) {
        self.knownHosts = knownHosts
        self.savedLogins = savedLogins
        self.codecs = codecs
    }

    public func start(server: ServerAddress, username: String) {
        let replay = self.replay, replayingSaved = self.replayingSaved, notice = self.notice
        cancel()
        self.replay = replay
        self.replayingSaved = replayingSaved
        self.notice = notice
        let gen = generation
        self.server = server
        self.username = username
        recipe = Recipe(server: server, username: username)
        takeOver = false
        refusedCertificate.request.withLock { $0 = nil }
        step = .working("Connecting to \(server)…")

        let knownHosts = knownHosts
        let refused = refusedCertificate
        var h = GDPLobby.Handlers()
        h.certificate = { presented, caVerified in
            guard let presented else { return false }
            let pinned = knownHosts.pin(for: server)
            if pinned == presented { return true }
            // §2.3: a CA-verified certificate needs no pin, and overrides a stale one.
            if caVerified { return true }
            refused.request.withLock { $0 = TrustRequest(server: server, presented: presented, pinned: pinned) }
            return false
        }
        h.authPrompt = { [weak self] text, echo in
            Task { @MainActor in if self?.generation == gen { self?.step = .prompt(Prompt(text: text, echo: echo)) } }
        }
        h.deviceList = { [weak self] devices in
            Task { @MainActor in if self?.generation == gen { self?.step = .chooseDevice(devices) } }
        }
        h.sessionList = { [weak self] list in
            Task { @MainActor in if self?.generation == gen { self?.step = .chooseSession(SessionChoice(list: list)) } }
        }
        h.redirect = { [weak self] redirect in
            Task { @MainActor in if self?.generation == gen { self?.redirected(redirect) } }
        }
        h.failed = { [weak self] failure in
            Task { @MainActor in if self?.generation == gen { self?.failed(failure) } }
        }
        let lobby = GDPLobby(handlers: h)
        self.lobby = lobby
        do {
            try lobby.connect(host: server.host, port: server.port, username: username)
        } catch {
            step = .failed(Failure(message: error.description, code: 0))
        }
    }

    /// The user accepted a new server's certificate: pin it and log in again.
    public func trustAndContinue() {
        guard case let .trustNewHost(request) = step else { return }
        knownHosts.trust(request.presented, for: request.server)
        start(server: request.server, username: username)
    }

    /// The user chose to drop the saved fingerprint of a server whose
    /// certificate changed. The next login asks again, as for a new server.
    public func forgetPinnedCertificate() {
        guard case let .certificateChanged(request) = step else { return }
        knownHosts.forget(request.server)
        step = .idle
    }

    /// Signs in again as `recipe` did, answering and choosing for the user
    /// wherever the server asks what it asked then. `allowTakeOver`: open a
    /// session someone is viewing without asking (it is most likely this
    /// client's own connection, just lost).
    public func replay(_ recipe: Recipe, allowTakeOver: Bool) {
        replay = (recipe, 0, allowTakeOver)
        start(server: recipe.server, username: recipe.username)
    }

    /// Whether a login is saved for this user and server (reads no secret).
    public func hasSavedLogin(server: ServerAddress, username: String) -> Bool {
        savedLogins.contains(server: server, username: username)
    }

    /// Signs in with the saved login, the way a replay does: whatever it
    /// doesn't answer (a one-time code, a session someone is viewing) is
    /// left to the user. False if none is saved (or it can't be read).
    @discardableResult
    public func signInWithSaved(server: ServerAddress, username: String) -> Bool {
        guard let saved = savedLogins.load(server: server, username: username) else { return false }
        cancel()
        replayingSaved = true
        replay(Recipe(saved, server: server, username: username), allowTakeOver: false)
        return true
    }

    /// `remember`: for a secret, keep it in the saved login once signed in.
    public func answer(_ text: String, remember: Bool = false) {
        guard case let .prompt(prompt) = step, let lobby else { return }
        recipe?.answers.append(.init(prompt: prompt, text: text, remember: remember && !prompt.echo))
        step = .working("Signing in…")
        lobby.respond(text)
    }

    public func select(device: GDPLobby.Device) {
        guard case .chooseDevice = step, let lobby else { return }
        recipe?.deviceID = device.id
        step = .working("Signing in to \(device.name)…")
        lobby.selectDevice(device.id)
    }

    /// `type`: an offered id, or nil for the server's default. `takeOver`
    /// must be true to open a session someone else is viewing.
    public func open(type: String?, takeOver: Bool) {
        guard case let .chooseSession(choice) = step, let lobby else { return }
        if choice.needsTakeOver && !takeOver { return }
        self.takeOver = takeOver
        recipe?.sessionType = type
        step = .working("Starting the session…")
        lobby.openSession(type: type)
    }

    public func cancel() {
        replay = nil
        replayingSaved = false
        notice = nil
        generation += 1
        lobby?.cancel()
        lobby = nil
        step = .idle
    }

    private func redirected(_ r: GDPLobby.Redirect) {
        lobby = nil
        guard let server else { return }
        // §2.3: no session connection for a missing or malformed fingerprint.
        guard let certificate = r.certificate else {
            step = .failed(Failure(message: "The server sent no valid certificate fingerprint for the session.", code: 0))
            return
        }
        var config = GDPSession.Configuration(host: r.host, port: r.port, token: r.token, certificate: certificate,
                                              codecs: codecs)
        config.takeOver = takeOver
        config.decoders = ["videotoolbox"]
        let ticket = SessionTicket(server: server, username: username, configuration: config)
        replay = nil
        replayingSaved = false
        notice = nil
        rememberLogin()
        step = .redirected(ticket)
        onRedirect?(ticket)
    }

    private func failed(_ f: GDPLobby.Failure) {
        lobby = nil
        replay = nil
        if replayingSaved, f.code == 20, let server {
            // §12 AUTH_FAILED: the saved password no longer works. Forget it
            // and ask, as a login without one would.
            replayingSaved = false
            savedLogins.delete(server: server, username: username)
            notice = "The saved password no longer works. Sign in again."
            start(server: server, username: username)
            return
        }
        replayingSaved = false
        if f.certificateRejected, let request = refusedCertificate.request.withLock({ $0 }) {
            step = request.pinned == nil ? .trustNewHost(request) : .certificateChanged(request)
            return
        }
        step = .failed(Failure(message: Self.explain(f), code: f.code))
    }

    /// After a successful login: keep what the user ticked, or forget a
    /// saved login the user signed in to without ticking anything.
    private func rememberLogin() {
        guard let recipe else { return }
        if let saved = recipe.toSave {
            savedLogins.save(saved, server: recipe.server, username: recipe.username)
        } else if recipe.answers.contains(where: { !$0.prompt.echo }) {
            savedLogins.delete(server: recipe.server, username: recipe.username)
        }
    }

    /// Takes the step a replay can take; leaves the rest to the user.
    private func advanceReplay() {
        guard let (recipe, next, allowTakeOver) = replay else { return }
        switch step {
        case let .prompt(prompt):
            // The recorded answers in order: one for the same question, or the user.
            guard let i = recipe.answers.indices.dropFirst(next).first(where: { recipe.answers[$0].prompt == prompt })
            else { return }
            replay?.nextAnswer = i + 1
            answer(recipe.answers[i].text, remember: recipe.answers[i].remember)
        case let .chooseDevice(devices):
            guard let id = recipe.deviceID, let device = devices.first(where: { $0.id == id && $0.online }) else { return }
            select(device: device)
        case let .chooseSession(choice):
            if choice.needsTakeOver && !allowTakeOver { return }
            open(type: recipe.sessionType, takeOver: choice.needsTakeOver)
        default:
            break // working, a certificate to confirm (always the user's), redirected, failed
        }
    }

    /// Words for the §12 codes a login can end with.
    static func explain(_ f: GDPLobby.Failure) -> String {
        switch f.code {
        case 10: "The server speaks a different protocol version."
        case 14: "That desktop is not available on this host."
        case 20: "Wrong username or password."
        case 21: "The host refused the password, though the broker accepted it."
        case 22: "That host is not one of yours."
        case 23: "You are logged in at the host itself. Log out there first."
        case 30: "That host is offline."
        case 31: "The host has no room for another session."
        case 32: "The session could not be started."
        default: f.message.isEmpty ? "The login failed." : f.message.prefix(1).uppercased() + f.message.dropFirst()
        }
    }
}
