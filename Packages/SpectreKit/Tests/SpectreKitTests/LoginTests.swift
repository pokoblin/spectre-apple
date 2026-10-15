import Foundation
import GDPKit
import Testing
@testable import SpectreKit

@Suite("Server address")
struct ServerAddressTests {
    @Test(arguments: [
        ("ghost.example", "ghost.example", UInt16(4442)),
        ("Ghost.Example:5000", "ghost.example", 5000),
        ("192.0.2.7", "192.0.2.7", 4442),
        ("192.0.2.7:4443", "192.0.2.7", 4443),
        ("[2001:db8::1]", "2001:db8::1", 4442),
        ("[2001:db8::1]:9000", "2001:db8::1", 9000),
        ("2001:db8::1", "2001:db8::1", 4442),
        ("  host  ", "host", 4442),
    ])
    func parses(text: String, host: String, port: UInt16) throws {
        let a = try #require(ServerAddress(parsing: text))
        #expect(a.host == host && a.port == port)
    }

    @Test(arguments: ["", "host:", "host:0", "host:70000", "[::1", "[]:1", "a b", ":4442"])
    func rejects(text: String) {
        #expect(ServerAddress(parsing: text) == nil)
    }

    @Test func describesWithoutTheDefaultPort() {
        #expect(ServerAddress(host: "h").description == "h")
        #expect(ServerAddress(host: "h", port: 1).description == "h:1")
        #expect(ServerAddress(host: "::1", port: 1).description == "[::1]:1")
    }
}

@Suite("Known hosts")
struct KnownHostsTests {
    @Test func pinsPersistPerHostAndPort() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let fp = CertificateFingerprint(certificateDER: Array("cert".utf8))
        KnownHosts(file: file).trust(fp, for: ServerAddress(host: "a", port: 1))
        let reloaded = KnownHosts(file: file)
        #expect(reloaded.pin(for: ServerAddress(host: "A", port: 1)) == fp) // names compare case-insensitively
        #expect(reloaded.pin(for: ServerAddress(host: "a", port: 2)) == nil) // §2.3: per name and port
        reloaded.forget(ServerAddress(host: "a", port: 1))
        #expect(KnownHosts(file: file).pin(for: ServerAddress(host: "a", port: 1)) == nil)
    }
}

@MainActor
@Suite("Login flow", .serialized)
struct LoginFlowTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString).json")

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func lobby(_ configure: (inout GDPTestLobby.Configuration) -> Void = { _ in }) throws -> (GDPTestLobby, GDPTestHost) {
        let host = try GDPTestHost()
        var config = GDPTestLobby.Configuration()
        config.redirect(to: host)
        configure(&config)
        return (try GDPTestLobby(config), host)
    }

    @Test func firstLoginAsksToTrustThenSignsIn() async throws {
        let (server, host) = try lobby()
        let flow = LoginFlow(knownHosts: KnownHosts(file: file), savedLogins: MemorySavedLogins())
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        flow.start(server: address, username: "demo")

        #expect(await until { if case .trustNewHost = flow.step { true } else { false } })
        guard case let .trustNewHost(request) = flow.step else { return }
        #expect(request.presented == server.certificate && request.pinned == nil)
        #expect(!server.observed.helloReceived, "nothing is sent before the user trusts the server")

        flow.trustAndContinue()
        #expect(flow.knownHosts.pin(for: address) == server.certificate)
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        guard case let .prompt(prompt) = flow.step else { return }
        #expect(prompt == .init(text: "Password: ", echo: false))

        flow.answer("demo")
        #expect(await until { if case .chooseSession = flow.step { true } else { false } })
        guard case let .chooseSession(choice) = flow.step else { return }
        #expect(!choice.needsTakeOver && choice.list.types.count == 2)

        flow.open(type: "plasma", takeOver: false)
        #expect(await until { if case .redirected = flow.step { true } else { false } })
        guard case let .redirected(ticket) = flow.step else { return }
        #expect(ticket.configuration.host == "127.0.0.1" && ticket.configuration.port == host.port)
        #expect(ticket.configuration.certificate == host.certificate)
        #expect(!ticket.configuration.takeOver)
        #expect(ticket.configuration.codecs == ["h265", "h264"])
        #expect(server.observed.openedType == "plasma")
        try? FileManager.default.removeItem(at: file)
    }

    @Test func pinnedServerIsNotAskedAgain() async throws {
        let (server, _) = try lobby()
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        let flow = LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins())
        flow.start(server: address, username: "demo")
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        try? FileManager.default.removeItem(at: file)
    }

    @Test func changedCertificateIsRefused() async throws {
        let (server, _) = try lobby()
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        let old = CertificateFingerprint(certificateDER: Array("the old one".utf8))
        known.trust(old, for: address)
        let flow = LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins())
        flow.start(server: address, username: "demo")
        #expect(await until { if case .certificateChanged = flow.step { true } else { false } })
        guard case let .certificateChanged(request) = flow.step else { return }
        #expect(request.pinned == old && request.presented == server.certificate)
        #expect(!server.observed.helloReceived)
        // There is no "trust anyway" from here; forgetting the pin starts over as a new server.
        flow.trustAndContinue()
        #expect(known.pin(for: address) == old)
        flow.forgetPinnedCertificate()
        #expect(known.pin(for: address) == nil)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func viewedSessionNeedsTakeOver() async throws {
        let (server, _) = try lobby {
            $0.runningSession = true
            $0.viewerAttached = true
        }
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        let flow = LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins())
        flow.start(server: address, username: "demo")
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        flow.answer("demo")
        #expect(await until { if case .chooseSession = flow.step { true } else { false } })
        guard case let .chooseSession(choice) = flow.step else { return }
        #expect(choice.needsTakeOver && choice.runningTypeName == "GNOME")
        flow.open(type: nil, takeOver: false) // refused without the user's agreement
        if case .chooseSession = flow.step {} else { Issue.record("opened without take-over") }
        flow.open(type: nil, takeOver: true)
        #expect(await until { if case .redirected = flow.step { true } else { false } })
        guard case let .redirected(ticket) = flow.step else { return }
        #expect(ticket.configuration.takeOver)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func wrongPasswordIsExplained() async throws {
        let (server, _) = try lobby()
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        let flow = LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins())
        flow.start(server: address, username: "demo")
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        flow.answer("wrong")
        #expect(await until { if case .failed = flow.step { true } else { false } })
        guard case let .failed(failure) = flow.step else { return }
        #expect(failure.code == 20 && failure.message == "Wrong username or password.")
        try? FileManager.default.removeItem(at: file)
    }

    @Test func brokerDevicesAreOffered() async throws {
        let (server, _) = try lobby {
            $0.broker = true
            $0.devices = [.init(id: "ws", name: "Workstation")]
        }
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        let flow = LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins())
        flow.start(server: address, username: "demo")
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        flow.answer("demo")
        #expect(await until { if case .chooseDevice = flow.step { true } else { false } })
        guard case let .chooseDevice(devices) = flow.step else { return }
        flow.select(device: devices[0])
        #expect(await until { if case .chooseSession = flow.step { true } else { false } })
        #expect(server.observed.selectedDevice == "ws")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Replay (signing in again after a lost connection)

    func pinned(_ server: GDPTestLobby) -> (LoginFlow, ServerAddress) {
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        return (LoginFlow(knownHosts: known, savedLogins: MemorySavedLogins()), address)
    }

    func redirected(_ flow: LoginFlow) async -> LoginFlow.SessionTicket? {
        _ = await until { if case .redirected = flow.step { true } else { false } }
        if case let .redirected(ticket) = flow.step { return ticket }
        return nil
    }

    @Test func anInteractiveLoginIsRecordedAndReplayedWithoutTheUser() async throws {
        let (server, _) = try lobby()
        let (flow, address) = pinned(server)
        flow.start(server: address, username: "demo")
        #expect(await until { if case .prompt = flow.step { true } else { false } })
        flow.answer("demo")
        #expect(await until { if case .chooseSession = flow.step { true } else { false } })
        flow.open(type: "plasma", takeOver: false)
        #expect(await redirected(flow) != nil)
        let recipe = try #require(flow.recipe)
        #expect(recipe.answers.map(\.text) == ["demo"] && recipe.sessionType == "plasma")

        flow.replay(recipe, allowTakeOver: false)
        #expect(flow.isReplaying)
        let ticket = await redirected(flow)
        #expect(ticket != nil)
        #expect(!flow.isReplaying)
        #expect(server.observed.openedType == "plasma")
        try? FileManager.default.removeItem(at: file)
    }

    @Test func aQuestionTheRecipeLacksIsLeftToTheUserThenTheReplayGoesOn() async throws {
        let (server, _) = try lobby {
            $0.prompts = [.init("Password: ", expected: "demo"), .init("Verification code: ", echo: true, expected: "123456")]
        }
        let (flow, address) = pinned(server)
        let recipe = LoginFlow.Recipe(server: address, username: "demo",
                                      answers: [.init(prompt: .init(text: "Password: ", echo: false), text: "demo", remember: false)])
        flow.replay(recipe, allowTakeOver: false)
        #expect(await until { if case .prompt(let p) = flow.step { p.text == "Verification code: " } else { false } })
        #expect(flow.isReplaying) // waiting for the user, not over
        flow.answer("123456")
        #expect(await redirected(flow) != nil) // the session choice was made for the user again
        try? FileManager.default.removeItem(at: file)
    }

    @Test func aRecordedPasswordThatNoLongerWorksFails() async throws {
        let (server, _) = try lobby()
        let (flow, address) = pinned(server)
        let recipe = LoginFlow.Recipe(server: address, username: "demo",
                                      answers: [.init(prompt: .init(text: "Password: ", echo: false), text: "old", remember: false)])
        flow.replay(recipe, allowTakeOver: false)
        #expect(await until { if case .failed = flow.step { true } else { false } })
        guard case let .failed(failure) = flow.step else { return }
        #expect(failure.code == 20)
        #expect(!flow.isReplaying)
        try? FileManager.default.removeItem(at: file)
    }

    @Test(arguments: [false, true])
    func aViewedSessionIsTakenOverOnlyIfAllowed(allow: Bool) async throws {
        let (server, _) = try lobby {
            $0.runningSession = true
            $0.viewerAttached = true
        }
        let (flow, address) = pinned(server)
        let recipe = LoginFlow.Recipe(server: address, username: "demo",
                                      answers: [.init(prompt: .init(text: "Password: ", echo: false), text: "demo", remember: false)])
        flow.replay(recipe, allowTakeOver: allow)
        if allow {
            let ticket = await redirected(flow)
            #expect(ticket?.configuration.takeOver == true)
        } else {
            #expect(await until { if case .chooseSession = flow.step { true } else { false } })
            #expect(flow.isReplaying) // the user decides
        }
        try? FileManager.default.removeItem(at: file)
    }

    @Test(arguments: [("ws", true), ("gone", false)])
    func theRecordedDeviceIsChosenIfStillThere(device: String, chosen: Bool) async throws {
        let (server, _) = try lobby {
            $0.broker = true
            $0.devices = [.init(id: "ws", name: "Workstation")]
        }
        let (flow, address) = pinned(server)
        let recipe = LoginFlow.Recipe(server: address, username: "demo",
                                      answers: [.init(prompt: .init(text: "Password: ", echo: false), text: "demo", remember: false)], deviceID: device)
        flow.replay(recipe, allowTakeOver: false)
        if chosen {
            #expect(await redirected(flow) != nil)
            #expect(server.observed.selectedDevice == "ws")
        } else {
            #expect(await until { if case .chooseDevice = flow.step { true } else { false } })
        }
        try? FileManager.default.removeItem(at: file)
    }

    @Test func cancellingStopsTheReplay() async throws {
        let (server, _) = try lobby()
        let (flow, address) = pinned(server)
        flow.replay(LoginFlow.Recipe(server: address, username: "demo"), allowTakeOver: false)
        flow.cancel()
        #expect(!flow.isReplaying)
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
@Suite("Saved logins in the login flow", .serialized)
struct SavedLoginFlowTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "known-\(UUID().uuidString).json")
    let saved = MemorySavedLogins()

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func setUp(_ configure: (inout GDPTestLobby.Configuration) -> Void = { _ in }) throws
        -> (LoginFlow, GDPTestLobby, ServerAddress, GDPTestHost) {
        let host = try GDPTestHost()
        var config = GDPTestLobby.Configuration()
        config.redirect(to: host)
        configure(&config)
        let server = try GDPTestLobby(config)
        let known = KnownHosts(file: file)
        let address = ServerAddress(host: "127.0.0.1", port: server.port)
        known.trust(server.certificate, for: address)
        return (LoginFlow(knownHosts: known, savedLogins: saved), server, address, host)
    }

    func step(_ flow: LoginFlow, is test: (LoginFlow.Step) -> Bool) async -> Bool { await until { test(flow.step) } }

    @Test func aTickedPasswordIsSavedOnceSignedIn() async throws {
        let (flow, server, address, host) = try setUp()
        defer { withExtendedLifetime((server, host)) { try? FileManager.default.removeItem(at: file) } }
        flow.start(server: address, username: "demo")
        #expect(await step(flow) { if case .prompt = $0 { true } else { false } })
        flow.answer("demo", remember: true)
        #expect(!saved.contains(server: address, username: "demo")) // not before the server accepted it
        #expect(await step(flow) { if case .chooseSession = $0 { true } else { false } })
        flow.open(type: "plasma", takeOver: false)
        #expect(await step(flow) { if case .redirected = $0 { true } else { false } })
        #expect(saved.load(server: address, username: "demo") ==
                SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "demo")], sessionType: "plasma"))
    }

    @Test func signingInWithoutTickingForgetsASavedLogin() async throws {
        let (flow, server, address, host) = try setUp()
        defer { withExtendedLifetime((server, host)) { try? FileManager.default.removeItem(at: file) } }
        saved.save(SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "demo")]), server: address, username: "demo")
        flow.start(server: address, username: "demo")
        #expect(await step(flow) { if case .prompt = $0 { true } else { false } })
        flow.answer("demo") // not ticked this time
        #expect(await step(flow) { if case .chooseSession = $0 { true } else { false } })
        flow.open(type: nil, takeOver: false)
        #expect(await step(flow) { if case .redirected = $0 { true } else { false } })
        #expect(!saved.contains(server: address, username: "demo"))
    }

    @Test func oneTapSignInReplaysTheSavedLogin() async throws {
        let (flow, server, address, host) = try setUp()
        defer { withExtendedLifetime((server, host)) { try? FileManager.default.removeItem(at: file) } }
        saved.save(SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "demo")], sessionType: "plasma"),
                   server: address, username: "demo")
        #expect(flow.hasSavedLogin(server: address, username: "demo"))
        #expect(flow.signInWithSaved(server: address, username: "demo"))
        #expect(await step(flow) { if case .redirected = $0 { true } else { false } })
        #expect(server.observed.openedType == "plasma")
        #expect(saved.contains(server: address, username: "demo")) // kept, refreshed
        #expect(!flow.signInWithSaved(server: address, username: "nobody"))
    }

    @Test func aOneTimeCodeIsAskedEveryTimeAndNeverSaved() async throws {
        let (flow, server, address, host) = try setUp {
            $0.prompts = [.init("Password: ", expected: "demo"), .init("Code: ", echo: false, expected: "123456")]
        }
        defer { withExtendedLifetime((server, host)) { try? FileManager.default.removeItem(at: file) } }
        saved.save(SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "demo")]), server: address, username: "demo")
        flow.signInWithSaved(server: address, username: "demo")
        #expect(await step(flow) { if case .prompt(let p) = $0 { p.text == "Code: " } else { false } })
        flow.answer("123456") // not ticked
        #expect(await step(flow) { if case .redirected = $0 { true } else { false } })
        #expect(saved.load(server: address, username: "demo")?.answers.map(\.prompt) == ["Password: "])
    }

    @Test func aSavedPasswordThatStoppedWorkingIsForgottenAndAsked() async throws {
        let (flow, server, address, host) = try setUp()
        defer { withExtendedLifetime((server, host)) { try? FileManager.default.removeItem(at: file) } }
        saved.save(SavedLogin(answers: [.init(prompt: "Password: ", echo: false, text: "old")]), server: address, username: "demo")
        flow.signInWithSaved(server: address, username: "demo")
        #expect(await step(flow) { if case .prompt = $0 { true } else { false } })
        #expect(!saved.contains(server: address, username: "demo"))
        #expect(flow.notice == "The saved password no longer works. Sign in again.")
        #expect(!flow.isReplaying)
        flow.answer("demo")
        #expect(await step(flow) { if case .chooseSession = $0 { true } else { false } })
    }
}

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    @Test func onlyALostConnectionIsReconnected() {
        typealias E = GDPSession.Ending
        #expect(ReconnectPolicy.reconnects(after: E(code: 0, reason: "connection error (Timer expired)", connectionLost: true)))
        #expect(!ReconnectPolicy.reconnects(after: E(code: 0, reason: "closed")))
        #expect(!ReconnectPolicy.reconnects(after: E(code: 42, reason: "taken over")))
        #expect(!ReconnectPolicy.reconnects(after: E(code: 40, reason: "session ended")))
        #expect(!ReconnectPolicy.reconnects(after: E(code: 0, reason: "cert", certificateRejected: true, connectionLost: true)))
    }

    @Test func loginFailuresWorthRetrying() {
        #expect(ReconnectPolicy.retries(loginFailure: 0))  // no answer
        #expect(ReconnectPolicy.retries(loginFailure: 30)) // host offline
        #expect(!ReconnectPolicy.retries(loginFailure: 20)) // wrong password
        #expect(!ReconnectPolicy.retries(loginFailure: 10)) // protocol
    }

    @Test func takeOverWithoutAskingOnlyJustAfterLosingItsOwnConnection() {
        let now = Date()
        #expect(ReconnectPolicy.takesOverAutomatically(lostAt: now.addingTimeInterval(-5), now: now))
        #expect(!ReconnectPolicy.takesOverAutomatically(lostAt: now.addingTimeInterval(-120), now: now))
        #expect(!ReconnectPolicy.takesOverAutomatically(lostAt: nil, now: now)) // closed it ourselves
    }

    @Test func aboutAMinuteOfAttempts() {
        let total = ReconnectPolicy.delays.reduce(Duration.zero, +)
        #expect(total >= .seconds(50) && total <= .seconds(70))
        #expect(ReconnectPolicy.delays.first == .zero)
    }
}
