import Dispatch
import Foundation
import GDPCore

/// The lobby phase (gdp-spec.md §4, §5) over libgdp's LobbyClient: log in
/// to a host agent or a broker and come away with a ``Redirect`` to a
/// session. Driven from one serial queue, which runs every handler; the
/// answers (``respond(_:)`` and friends) may be called from any thread.
public final class GDPLobby: @unchecked Sendable {
    public struct SessionType: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
    }

    public struct RunningSession: Sendable {
        public let sessionID: String
        public let sessionType: String
        public let startedAt: Date
        public let lastActive: Date
        /// Another client is viewing it: connecting needs take-over (§6.4).
        public let viewerAttached: Bool
    }

    public struct SessionList: Sendable {
        public let types: [SessionType]
        public let defaultType: String
        /// Zero or one: a host runs at most one session per user (§4.6).
        public let running: [RunningSession]
    }

    public struct Device: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let online: Bool
        public let hasSession: Bool
        public let sessionType: String
        public let types: [SessionType]
        public let defaultType: String
    }

    public struct Redirect: Sendable {
        /// Never empty: the lobby's own host is substituted (§4.7).
        public let host: String
        public let port: UInt16
        public let token: String
        public let expiry: Date
        /// The certificate the session must present; nil if the server sent a malformed one,
        /// in which case no session may be opened (§2.3).
        public let certificate: CertificateFingerprint?
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        /// The LobbyError's or the close's §12 code; 0 for a local failure or a refused certificate.
        public let code: UInt64
        public let message: String
        public let certificateRejected: Bool
        public var description: String { code == 0 ? message : "\(message) (code \(code))" }
    }

    /// Called on the queue, never the main thread: hop to the main actor yourself.
    public struct Handlers: Sendable {
        /// §2.3: trust this certificate? Decided before anything is sent.
        public var certificate: (@Sendable (_ fingerprint: CertificateFingerprint?, _ caVerified: Bool) -> Bool)?
        /// Answer with ``GDPLobby/respond(_:)``.
        public var authPrompt: (@Sendable (_ prompt: String, _ echo: Bool) -> Void)?
        /// A broker's hosts; answer with ``GDPLobby/selectDevice(_:)``.
        public var deviceList: (@Sendable ([Device]) -> Void)?
        /// Answer with ``GDPLobby/openSession(type:)``.
        public var sessionList: (@Sendable (SessionList) -> Void)?
        public var redirect: (@Sendable (Redirect) -> Void)?
        public var failed: (@Sendable (Failure) -> Void)?

        public init() {}
    }

    public struct ConnectError: Error, CustomStringConvertible {
        public let description: String
    }

    /// The UDP port ghostd's lobby listens on unless configured otherwise.
    public static let defaultPort: UInt16 = 4442

    /// Whether the platform's CAs can be checked: libgdp reads macOS's
    /// /etc/ssl/cert.pem, which iOS doesn't have (see docs/prototype-findings.md).
    public static let systemCAsAvailable: Bool = {
        #if os(macOS)
        true
        #else
        false
        #endif
    }()

    public let queue: DispatchQueue
    private let handlers: Handlers
    private let queueKey = DispatchSpecificKey<Void>()
    private var handle: OpaquePointer?          // queue only
    private var readSource: DispatchSourceRead? // queue only
    private var finished = false                // queue only
    /// After a Redirect: this object keeps itself alive, pumping, until the
    /// server closes the connection (§4.2) or ``lingerLimit`` passes.
    private var lingering: GDPLobby?            // queue only
    /// Whether the last exchange ended with the server closing after its
    /// Redirect, as §4.2 has it, rather than the linger limit (for tests).
    private(set) var closedByServer = false     // queue only
    static let lingerLimit: TimeInterval = 2

    public init(queue: DispatchQueue = DispatchQueue(label: "spectre.lobby", qos: .userInitiated), handlers: Handlers) {
        self.queue = queue
        self.handlers = handlers
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    public func connect(host: String, port: UInt16 = GDPLobby.defaultPort, username: String,
                        trustSystemCAs: Bool = GDPLobby.systemCAsAvailable,
                        extraCAFile: URL? = nil) throws(ConnectError) {
        let error: String? = onQueue {
            guard handle == nil else { return "already connected" }
            var cb = gdpc_lobby_callbacks()
            cb.ctx = Unmanaged.passUnretained(self).toOpaque()
            cb.certificate = { ctx, sha, ca in
                let lobby = GDPLobby.from(ctx)
                return lobby.handlers.certificate?(CertificateFingerprint(hex: String(cString: sha!)), ca) ?? false
            }
            cb.auth_prompt = { ctx, prompt, echo in GDPLobby.from(ctx).handlers.authPrompt?(String(cString: prompt!), echo) }
            cb.device_list = { ctx, devices, count in
                let list = UnsafeBufferPointer(start: devices, count: count).map { d in
                    Device(id: String(cString: d.id), name: String(cString: d.name), online: d.online,
                           hasSession: d.has_session, sessionType: String(cString: d.session_type),
                           types: GDPLobby.types(d.types, d.type_count), defaultType: String(cString: d.default_type))
                }
                GDPLobby.from(ctx).handlers.deviceList?(list)
            }
            cb.session_list = { ctx, l in
                let l = l!.pointee
                let running = UnsafeBufferPointer(start: l.running, count: l.running_count).map { r in
                    RunningSession(sessionID: String(cString: r.session_id), sessionType: String(cString: r.session_type),
                                   startedAt: Date(timeIntervalSince1970: TimeInterval(r.started_at_unix)),
                                   lastActive: Date(timeIntervalSince1970: TimeInterval(r.last_active_unix)),
                                   viewerAttached: r.viewer_attached)
                }
                GDPLobby.from(ctx).handlers.sessionList?(SessionList(types: GDPLobby.types(l.types, l.type_count),
                                                                     defaultType: String(cString: l.default_type),
                                                                     running: running))
            }
            cb.redirect = { ctx, r in
                let r = r!.pointee
                let lobby = GDPLobby.from(ctx)
                lobby.linger()
                lobby.handlers.redirect?(Redirect(host: String(cString: r.host), port: r.port,
                                                  token: String(cString: r.token),
                                                  expiry: Date(timeIntervalSince1970: TimeInterval(r.expiry_unix)),
                                                  certificate: CertificateFingerprint(hex: String(cString: r.cert_sha256))))
            }
            cb.error = { ctx, code, message, cert in
                let lobby = GDPLobby.from(ctx)
                lobby.finish()
                lobby.handlers.failed?(Failure(code: code, message: String(cString: message!), certificateRejected: cert))
            }
            _ = GDP.ignoreBrokenPipes
            let h = gdpc_lobby_create(&cb)!
            var errorBuffer = [CChar](repeating: 0, count: 256)
            let ok = withOptionalCString(extraCAFile?.path(percentEncoded: false)) { caFile in
                gdpc_lobby_connect(h, host, port, username, trustSystemCAs, caFile, &errorBuffer, errorBuffer.count)
            }
            guard ok else {
                gdpc_lobby_destroy(h)
                return string(fromNulTerminated: errorBuffer)
            }
            handle = h
            let read = DispatchSource.makeReadSource(fileDescriptor: gdpc_lobby_notify_fd(h), queue: queue)
            read.setEventHandler { [weak self] in
                guard let self, let handle = self.handle else { return }
                gdpc_lobby_dispatch(handle)
                if self.lingering != nil, gdpc_lobby_connection_closed(handle) {
                    self.closedByServer = true
                    self.endLinger()
                }
            }
            read.resume()
            readSource = read
            return nil
        }
        if let error { throw ConnectError(description: error) }
    }

    /// The answer to the latest prompt (§4.5).
    public func respond(_ answer: String) { async { gdpc_lobby_respond($0, answer) } }
    public func selectDevice(_ id: String) { async { gdpc_lobby_select_device($0, id) } }
    /// `type`: one of the offered ids, or nil for the server's default (§4.6).
    public func openSession(type: String?) { async { gdpc_lobby_open_session($0, type ?? "") } }

    /// Abandons the login.
    public func cancel() { onQueue { teardown() } }

    /// Still holding the connection after a Redirect (for tests).
    var isLingering: Bool { onQueue { lingering != nil } }
    /// The connection ended with the server's close after the Redirect (for tests).
    var endedByServerClose: Bool { onQueue { closedByServer } }

    // MARK: - Internals

    private static func from(_ ctx: UnsafeMutableRawPointer?) -> GDPLobby {
        Unmanaged<GDPLobby>.fromOpaque(ctx!).takeUnretainedValue()
    }

    private static func types(_ p: UnsafePointer<gdpc_session_type>?, _ n: Int) -> [SessionType] {
        UnsafeBufferPointer(start: p, count: n).map { SessionType(id: String(cString: $0.id), name: String(cString: $0.name)) }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        DispatchQueue.getSpecific(key: queueKey) != nil ? body() : queue.sync(execute: body)
    }

    private func async(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        queue.async { [self] in
            if let handle, !finished { body(handle) }
        }
    }

    /// The exchange succeeded: stop taking commands, but keep pumping until
    /// the server's close (§4.2: it closes with code 0 after Redirect).
    /// Dropping the connection there and then races that close, and the
    /// server logs a lost connection. The session connection opens
    /// meanwhile; this only lets the lobby connection end cleanly.
    private func linger() {
        finished = true
        lingering = self
        queue.asyncAfter(deadline: .now() + Self.lingerLimit) { [weak self] in self?.endLinger() }
    }

    private func endLinger() {
        guard lingering != nil else { return }
        lingering = nil
        teardown()
    }

    /// The exchange is over (a failure): stop pumping. The handle stays
    /// until teardown, since we may be inside its dispatch().
    private func finish() {
        finished = true
        readSource?.cancel()
    }

    private func teardown() {
        finish()
        readSource = nil
        if let handle {
            gdpc_lobby_destroy(handle)
            self.handle = nil
        }
    }
}

/// A minimal lobby server on 127.0.0.1 (§4, §5), for tests.
public final class GDPTestLobby: @unchecked Sendable {
    public struct Prompt: Sendable {
        public var text: String
        public var echo: Bool
        public var expected: String
        public init(_ text: String, echo: Bool = false, expected: String) {
            self.text = text
            self.echo = echo
            self.expected = expected
        }
    }

    public struct Device: Sendable {
        public var id: String
        public var name: String
        public var online = true
        public var hasSession = false
        public var sessionType = ""
        public init(id: String, name: String, online: Bool = true, hasSession: Bool = false, sessionType: String = "") {
            self.id = id
            self.name = name
            self.online = online
            self.hasSession = hasSession
            self.sessionType = sessionType
        }
    }

    public struct Configuration: Sendable {
        public var username = "demo"
        public var prompts = [Prompt("Password: ", expected: "demo")]
        public var sessionTypes: [(id: String, name: String)] = [("gnome", "GNOME"), ("plasma", "KDE Plasma")]
        public var defaultType = "gnome"
        public var runningSession = false
        public var runningType = "gnome"
        public var viewerAttached = false
        public var refuseAfterAuth: UInt64 = 0
        public var broker = false
        public var devices: [Device] = []
        public var devicePrompts: [Prompt] = []
        /// Where the Redirect points; empty host = the lobby's own (§4.7).
        public var redirectHost = ""
        public var redirectPort: UInt16 = 0
        public var redirectToken = ""
        public var redirectCertificate = ""
        public var scratchDirectory = FileManager.default.temporaryDirectory

        public init() {}

        /// Redirect to `host`, an in-process session host.
        public mutating func redirect(to host: GDPTestHost, token: String = "test-token") {
            redirectPort = host.port
            redirectToken = token
            redirectCertificate = host.certificate.hex
        }
    }

    public struct Observed: Sendable {
        public var connections: UInt32
        public var helloReceived: Bool
        public var protocolVersion: UInt32
        public var clientID: String
        public var username: String
        public var responseCount: UInt32
        public var lastResponse: String
        public var selectedDevice: String
        public var sessionOpenReceived: Bool
        public var openedType: String
        public var redirected: Bool
        public var errorCode: UInt64
    }

    private let handle: OpaquePointer
    public let port: UInt16
    public let certificate: CertificateFingerprint

    public init(_ config: Configuration) throws(GDPTestHost.Failure) {
        _ = GDP.ignoreBrokenPipes
        var error = [CChar](repeating: 0, count: 256)
        // Every C string the configuration needs, kept alive for the call.
        var storage: [UnsafeMutablePointer<CChar>] = []
        defer { storage.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            storage.append(p)
            return UnsafePointer(p)
        }
        let prompts = config.prompts.map { gdpc_test_prompt(text: c($0.text), echo: $0.echo, expected: c($0.expected)) }
        let devicePrompts = config.devicePrompts.map {
            gdpc_test_prompt(text: c($0.text), echo: $0.echo, expected: c($0.expected))
        }
        let types = config.sessionTypes.map { gdpc_session_type(id: c($0.id), name: c($0.name)) }
        let devices = config.devices.map {
            gdpc_test_device(id: c($0.id), name: c($0.name), online: $0.online, has_session: $0.hasSession,
                             session_type: c($0.sessionType))
        }
        let h: OpaquePointer? = prompts.withUnsafeBufferPointer { p in
            devicePrompts.withUnsafeBufferPointer { dp in
                types.withUnsafeBufferPointer { t in
                    devices.withUnsafeBufferPointer { d in
                        var cfg = gdpc_test_lobby_config()
                        cfg.scratch_dir = c(config.scratchDirectory.path(percentEncoded: false))
                        cfg.username = c(config.username)
                        cfg.prompts = p.baseAddress
                        cfg.prompt_count = p.count
                        cfg.session_types = t.baseAddress
                        cfg.session_type_count = t.count
                        cfg.default_type = c(config.defaultType)
                        cfg.running_session = config.runningSession
                        cfg.running_type = c(config.runningType)
                        cfg.viewer_attached = config.viewerAttached
                        cfg.refuse_after_auth = config.refuseAfterAuth
                        cfg.broker = config.broker
                        cfg.devices = d.baseAddress
                        cfg.device_count = d.count
                        cfg.device_prompts = dp.baseAddress
                        cfg.device_prompt_count = dp.count
                        cfg.redirect_host = c(config.redirectHost)
                        cfg.redirect_port = config.redirectPort
                        cfg.redirect_token = c(config.redirectToken)
                        cfg.redirect_cert_sha256 = c(config.redirectCertificate)
                        return gdpc_test_lobby_create(&cfg, &error, error.count)
                    }
                }
            }
        }
        guard let h else { throw GDPTestHost.Failure(description: string(fromNulTerminated: error)) }
        handle = h
        port = gdpc_test_lobby_port(h)
        var hex = [CChar](repeating: 0, count: Int(GDPC_SHA256_HEX_LEN) + 1)
        gdpc_test_lobby_cert_sha256(h, &hex)
        certificate = CertificateFingerprint(hex: string(fromNulTerminated: hex))!
    }

    deinit { gdpc_test_lobby_destroy(handle) }

    public var observed: Observed {
        var o = gdpc_test_lobby_observed()
        gdpc_test_lobby_get_observed(handle, &o)
        func s<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        return Observed(connections: o.connections, helloReceived: o.hello_received, protocolVersion: o.protocol_version,
                        clientID: s(o.client_id), username: s(o.username), responseCount: o.response_count,
                        lastResponse: s(o.last_response), selectedDevice: s(o.selected_device),
                        sessionOpenReceived: o.session_open_received, openedType: s(o.opened_type),
                        redirected: o.redirected, errorCode: o.error_code)
    }
}
