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

    public private(set) var step: Step = .idle
    public private(set) var server: ServerAddress?
    public private(set) var username = ""
    public let knownHosts: KnownHosts
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

    public init(knownHosts: KnownHosts = .standard(), codecs: [String] = ["h265", "h264"]) {
        self.knownHosts = knownHosts
        self.codecs = codecs
    }

    public func start(server: ServerAddress, username: String) {
        cancel()
        let gen = generation
        self.server = server
        self.username = username
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

    public func answer(_ text: String) {
        guard case .prompt = step, let lobby else { return }
        step = .working("Signing in…")
        lobby.respond(text)
    }

    public func select(device: GDPLobby.Device) {
        guard case .chooseDevice = step, let lobby else { return }
        step = .working("Signing in to \(device.name)…")
        lobby.selectDevice(device.id)
    }

    /// `type`: an offered id, or nil for the server's default. `takeOver`
    /// must be true to open a session someone else is viewing.
    public func open(type: String?, takeOver: Bool) {
        guard case let .chooseSession(choice) = step, let lobby else { return }
        if choice.needsTakeOver && !takeOver { return }
        self.takeOver = takeOver
        step = .working("Starting the session…")
        lobby.openSession(type: type)
    }

    public func cancel() {
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
        step = .redirected(ticket)
        onRedirect?(ticket)
    }

    private func failed(_ f: GDPLobby.Failure) {
        lobby = nil
        if f.certificateRejected, let request = refusedCertificate.request.withLock({ $0 }) {
            step = request.pinned == nil ? .trustNewHost(request) : .certificateChanged(request)
            return
        }
        step = .failed(Failure(message: Self.explain(f), code: f.code))
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
