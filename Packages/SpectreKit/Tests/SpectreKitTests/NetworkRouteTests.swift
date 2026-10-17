import Darwin
import GDPKit
import Testing
@testable import SpectreKit

@Suite("Network route (gdp-spec.md §6.6)")
struct NetworkRouteTests {
    @Test func pyroWaveGoesOverFastWiredLinksAndToThisMachine() {
        func route(_ kind: NetworkRoute.Kind, _ speed: UInt64?, onLink: Bool = true) -> NetworkRoute {
            NetworkRoute(interface: "en0", kind: kind, linkSpeed: speed, isOnLink: onLink)
        }
        #expect(route(.local, nil).carriesPyroWave)
        #expect(route(.wired, 1_000_000_000).carriesPyroWave)
        #expect(route(.wired, 2_500_000_000).carriesPyroWave)
        #expect(!route(.wired, 100_000_000).carriesPyroWave)
        #expect(!route(.wired, nil).carriesPyroWave) // a speed it can't vouch for
        #expect(!route(.wired, 2_500_000_000, onLink: false).carriesPyroWave) // past a router: an uplink, maybe
        #expect(!route(.wifi, 2_400_000_000).carriesPyroWave)
        #expect(!route(.cellular, 1_000_000_000).carriesPyroWave)
        #expect(!route(.other, 10_000_000_000).carriesPyroWave) // a VPN tunnel
    }

    @Test(arguments: ["127.0.0.1", "::1", "localhost"])
    func loopbackIsThisMachine(host: String) throws {
        let route = try #require(NetworkRoute.to(host: host, port: 4433))
        #expect(route.kind == .local)
        #expect(route.carriesPyroWave)
    }

    /// One of this machine's own LAN addresses is this machine too, not the LAN.
    @Test func ownAddressIsThisMachine() throws {
        guard let own = Self.ownIPv4Address() else { return } // no network here
        let route = try #require(NetworkRoute.to(host: own, port: 4433))
        #expect(route.kind == .local, "\(own) via \(route.interface)")
    }

    @Test func noRouteToANameThatDoesntResolve() {
        #expect(NetworkRoute.to(host: "no-such-host.invalid", port: 4433) == nil)
    }

    /// Where a route leaves by an interface, its kind comes from the system
    /// and its speed from the interface (here, whatever this machine has).
    @Test func aRouteOutOfThisMachineNamesItsInterface() throws {
        // A documentation address (RFC 5737): routed by default, never answered; nothing is sent.
        guard let route = NetworkRoute.to(host: "192.0.2.1", port: 4433) else { return } // no default route
        #expect(route.kind != .local)
        #expect(!route.interface.isEmpty)
        #expect(!route.isOnLink) // reached through the default router
        #expect(!route.carriesPyroWave)
        print("route to 192.0.2.1: \(route.interface), \(route.kind), \(route.linkSpeed.map { "\($0 / 1_000_000) Mbit/s" } ?? "no speed")")
    }

    @Test func turnedOffItIsntOffered() async throws {
        let stream = try TestStreamEncoder.encode(codec: .h264, width: 320, height: 180, frameCount: 1)
        let loopback = try LoopbackHost(stream: stream, audio: false)
        let remote = RemoteSession(mailbox: FrameMailbox(), stats: PlaybackStats(mailbox: FrameMailbox())) {}
        remote.offersPyroWave = false
        try remote.connect(loopback.sessionConfiguration())
        loopback.start()
        defer {
            remote.close()
            loopback.stop()
        }
        for _ in 0..<300 where !loopback.host.observed.helloReceived {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loopback.host.observed.helloReceived)
        #expect(!loopback.host.observed.codecs.contains("pyrowave"))
        #expect(loopback.host.observed.decoders == ["videotoolbox"])
        #expect(remote.pyroWaveRoute == nil)
    }

    static func ownIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = list
        while let e = entry {
            if let addr = e.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               e.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, e.pointee.ifa_flags & UInt32(IFF_UP) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            entry = e.pointee.ifa_next
        }
        return nil
    }
}
