import Foundation
import Network

/// Whether the system lets the app reach a server yet: local network
/// privacy (Apple's TN3179) holds back an app that hasn't been allowed.
public enum NetworkAccess: Sendable, Equatable {
    /// Go ahead. Any other trouble on the way is the login's to report.
    case open
    /// Waiting for the user's local network permission: the alert is up,
    /// or they declined it and it's off in Settings.
    case waitingForLocalNetwork
}

/// Checked before a login opens libgdp's socket. A UDP socket the system
/// held back while its local network alert was up never recovers: libgdp
/// takes the failing sends for lost packets and retries into the defunct
/// socket until the handshake times out (docs/login.md).
public protocol NetworkAccessCheck: Sendable {
    /// What stands between the app and `server`, each time that changes,
    /// finishing with `.open`. Stops when the consumer stops listening.
    func access(to server: ServerAddress) -> AsyncStream<NetworkAccess>
}

/// The system's answer, through a UDP NWConnection to the server: starting
/// it brings up the local network alert where one is needed, without
/// sending a packet, and it waits (unsatisfied: `localNetworkDenied`)
/// until access is granted. Anything else is let through for libgdp.
public struct LocalNetworkCheck: NetworkAccessCheck {
    public init() {}

    public func access(to server: ServerAddress) -> AsyncStream<NetworkAccess> {
        AsyncStream { continuation in
            guard let port = NWEndpoint.Port(rawValue: server.port) else {
                continuation.yield(.open)
                continuation.finish()
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .udp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting where connection.currentPath?.unsatisfiedReason == .localNetworkDenied:
                    continuation.yield(.waitingForLocalNetwork)
                case .ready, .waiting, .failed:
                    continuation.yield(.open)
                    continuation.finish()
                default:
                    break // setup, preparing, cancelled
                }
            }
            continuation.onTermination = { _ in connection.cancel() }
            connection.start(queue: DispatchQueue(label: "spectre.network-access"))
        }
    }
}
