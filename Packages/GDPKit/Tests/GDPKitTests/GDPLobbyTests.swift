import Foundation
import Synchronization
import Testing
@testable import GDPKit

/// Drives a GDPLobby through a scripted user and records what it saw.
final class LobbyScript: Sendable {
    struct State: Sendable {
        var certificates: [(CertificateFingerprint?, Bool)] = []
        var prompts: [(String, Bool)] = []
        var devices: [GDPLobby.Device]?
        var sessionList: GDPLobby.SessionList?
        var redirect: GDPLobby.Redirect?
        var failure: GDPLobby.Failure?
    }

    let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
    var done: Bool { snapshot.redirect != nil || snapshot.failure != nil }

    /// `trust`: the certificate decision; `answers`: one per prompt, in order;
    /// `device`/`type`: the choices to make.
    func lobby(trust: @escaping @Sendable (CertificateFingerprint?) -> Bool, answers: [String],
               device: String? = nil, type: String? = nil) -> GDPLobby {
        let remaining = Mutex(answers)
        let box = Mutex<GDPLobby?>(nil)
        var h = GDPLobby.Handlers()
        h.certificate = { fp, ca in
            self.state.withLock { $0.certificates.append((fp, ca)) }
            return trust(fp)
        }
        h.authPrompt = { prompt, echo in
            self.state.withLock { $0.prompts.append((prompt, echo)) }
            let answer = remaining.withLock { $0.isEmpty ? "" : $0.removeFirst() }
            box.withLock { $0 }?.respond(answer)
        }
        h.deviceList = { devices in
            self.state.withLock { $0.devices = devices }
            if let device { box.withLock { $0 }?.selectDevice(device) }
        }
        h.sessionList = { list in
            self.state.withLock { $0.sessionList = list }
            box.withLock { $0 }?.openSession(type: type)
        }
        h.redirect = { r in self.state.withLock { $0.redirect = r } }
        h.failed = { f in self.state.withLock { $0.failure = f } }
        let lobby = GDPLobby(handlers: h)
        box.withLock { $0 = lobby }
        return lobby
    }
}

@Suite("Lobby (§4, §5)")
struct LobbyTests {
    func pinning(_ lobby: GDPTestLobby) -> @Sendable (CertificateFingerprint?) -> Bool {
        let pin = lobby.certificate
        return { $0 == pin }
    }

    /// §4.2: after Redirect the server closes with code 0. The client keeps
    /// the connection until then instead of dropping it under that close.
    @Test func redirectWaitsForTheServersClose() async throws {
        let host = try GDPTestHost()
        var config = GDPTestLobby.Configuration()
        config.redirect(to: host)
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.snapshot.redirect != nil })
        // Ended by the server's close, well before the linger limit.
        #expect(await eventually(.seconds(1)) { !lobby.isLingering })
        #expect(lobby.endedByServerClose)
    }

    @Test func passwordLoginRedirectsToAWorkingSession() async throws {
        let host = try GDPTestHost()
        var config = GDPTestLobby.Configuration()
        config.redirect(to: host)
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })

        let s = script.snapshot
        #expect(s.failure == nil, "\(s.failure.map(String.init(describing:)) ?? "")")
        #expect(s.certificates.count == 1 && s.certificates[0].0 == server.certificate && !s.certificates[0].1)
        #expect(s.prompts.map(\.0) == ["Password: "] && s.prompts.map(\.1) == [false])
        #expect(s.sessionList?.types.map(\.id) == ["gnome", "plasma"])
        #expect(s.sessionList?.defaultType == "gnome")
        #expect(s.sessionList?.running.isEmpty == true)
        let r = try #require(s.redirect)
        #expect(r.host == "127.0.0.1") // §4.7: the host as dialed stands in for an empty Redirect.host
        #expect(r.port == host.port && r.token == "test-token" && r.certificate == host.certificate)
        #expect(abs(r.expiry.timeIntervalSinceNow - 30) < 5)

        let seen = server.observed
        #expect(seen.username == "demo" && seen.protocolVersion == 1 && !seen.clientID.isEmpty)
        #expect(seen.sessionOpenReceived && seen.openedType == "") // empty = the default type

        // The redirect is everything a session needs (§4.7).
        let rec = Recorder()
        let session = GDPSession(handlers: rec.handlers())
        try session.connect(GDPSession.Configuration(host: r.host, port: r.port, token: r.token,
                                                     certificate: try #require(r.certificate), codecs: ["h264"]))
        #expect(await eventually { rec.snapshot.accept != nil })
        withExtendedLifetime(session) {}
    }

    @Test func everyPromptIsAnsweredInOrder() async throws {
        var config = GDPTestLobby.Configuration()
        config.prompts = [.init("Password: ", expected: "demo"), .init("Verification code: ", echo: true, expected: "123456")]
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo", "123456"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        #expect(script.snapshot.prompts.map(\.0) == ["Password: ", "Verification code: "])
        #expect(script.snapshot.prompts.map(\.1) == [false, true])
        #expect(script.snapshot.redirect != nil)
        #expect(server.observed.lastResponse == "123456")
    }

    @Test func wrongPasswordIsAuthFailed() async throws {
        var config = GDPTestLobby.Configuration()
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["nope"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        let f = try #require(script.snapshot.failure)
        #expect(f.code == 20 && !f.certificateRejected)
        #expect(script.snapshot.sessionList == nil)
        withExtendedLifetime(lobby) {}
    }

    @Test func refusedCertificateSendsNothing() async throws {
        var config = GDPTestLobby.Configuration()
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: { _ in false }, answers: [])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        #expect(script.snapshot.failure?.certificateRejected == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(server.observed.connections == 1)
        #expect(!server.observed.helloReceived, "the username must not reach an untrusted server")
        withExtendedLifetime(lobby) {}
    }

    @Test func brokerLetsTheUserPickAHost() async throws {
        var config = GDPTestLobby.Configuration()
        config.broker = true
        config.devices = [.init(id: "ws", name: "Workstation", hasSession: true, sessionType: "plasma"),
                          .init(id: "lab", name: "Lab box", online: false)]
        config.devicePrompts = [.init("Verification code: ", echo: true, expected: "424242")]
        config.redirectHost = "ws.example"
        config.redirectPort = 9000
        config.redirectToken = "gateway-token"
        config.redirectCertificate = String(repeating: "ab", count: 32)
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo", "424242"], device: "ws", type: "plasma")
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        let s = script.snapshot
        let devices = try #require(s.devices)
        #expect(devices.map(\.id) == ["ws", "lab"])
        #expect(devices[0].online && devices[0].hasSession && devices[0].sessionType == "plasma")
        #expect(devices[0].types.map(\.name) == ["GNOME", "KDE Plasma"])
        #expect(!devices[1].online && devices[1].types.isEmpty)
        #expect(s.prompts.map(\.0) == ["Password: ", "Verification code: "]) // the host's second factor, relayed
        #expect(server.observed.selectedDevice == "ws" && server.observed.openedType == "plasma")
        let r = try #require(s.redirect)
        #expect(r.host == "ws.example" && r.port == 9000 && r.token == "gateway-token") // §5.4: a broker sets host
    }

    @Test(arguments: [
        ("lab", nil as String?, UInt64(30)),   // HOST_OFFLINE
        ("elsewhere", nil, UInt64(22)),        // NOT_ENTITLED
        ("ws", "fluxbox", UInt64(14)),         // UNKNOWN_SESSION_TYPE
    ])
    func refusals(device: String, type: String?, code: UInt64) async throws {
        var config = GDPTestLobby.Configuration()
        config.broker = true
        config.devices = [.init(id: "ws", name: "Workstation"), .init(id: "lab", name: "Lab box", online: false)]
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo"], device: device, type: type)
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        #expect(script.snapshot.failure?.code == code)
        #expect(script.snapshot.failure?.message.isEmpty == false)
        withExtendedLifetime(lobby) {}
    }

    @Test func refusalAfterAuthentication() async throws {
        var config = GDPTestLobby.Configuration()
        config.refuseAfterAuth = 23 // LOCAL_SESSION_ACTIVE (§4.5)
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        #expect(script.snapshot.failure?.code == 23)
        withExtendedLifetime(lobby) {}
    }

    @Test func runningSessionWithAViewerIsReported() async throws {
        var config = GDPTestLobby.Configuration()
        config.runningSession = true
        config.runningType = "plasma"
        config.viewerAttached = true
        config.redirectPort = 1
        let server = try GDPTestLobby(config)
        let script = LobbyScript()
        let lobby = script.lobby(trust: pinning(server), answers: ["demo"])
        try lobby.connect(host: "127.0.0.1", port: server.port, username: "demo", trustSystemCAs: false)
        #expect(await eventually { script.done })
        let running = try #require(script.snapshot.sessionList?.running.first)
        #expect(running.sessionType == "plasma" && running.viewerAttached)
        #expect(running.startedAt < running.lastActive)
        withExtendedLifetime(lobby) {}
    }

    @Test func badArgumentsFailToConnect() {
        let lobby = GDPLobby(handlers: .init())
        #expect(throws: GDPLobby.ConnectError.self) { try lobby.connect(host: "", username: "demo") }
        #expect(throws: GDPLobby.ConnectError.self) { try lobby.connect(host: "127.0.0.1", username: "") }
    }
}
