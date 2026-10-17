import Darwin
import Dispatch
import Network
import Synchronization

/// How this device reaches a host: the interface its packets would leave
/// by, what kind it is, how fast its link is and whether the host is on
/// that link. What decides whether to offer PyroWave (gdp-spec.md §6.6):
/// only to a host reached directly over a wired interface of 1 Gbit/s or
/// more, or to the client's own machine. Directly is taken to mean on the
/// interface's own subnet: past a router the path may be far slower than
/// the cable (an internet uplink), and PyroWave's rate is hundreds of Mbit/s.
public struct NetworkRoute: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The host is this machine.
        case local
        case wired
        case wifi
        case cellular
        /// Anything else: a VPN tunnel, a bridge, an interface the system didn't type.
        case other
    }

    /// The BSD name of the interface, e.g. `en0`.
    public var interface: String
    public var kind: Kind
    /// The link's speed in bits per second, if the interface reports one.
    public var linkSpeed: UInt64?
    /// Whether the host's address is in the interface's subnet: no router between.
    public var isOnLink: Bool

    public init(interface: String, kind: Kind, linkSpeed: UInt64?, isOnLink: Bool) {
        self.interface = interface
        self.kind = kind
        self.linkSpeed = linkSpeed
        self.isOnLink = isOnLink
    }

    /// The slowest wired link PyroWave is offered over (gdp-spec.md §6.6).
    public static let pyroWaveMinimumSpeed: UInt64 = 1_000_000_000

    /// Whether a host reached this way is one to offer PyroWave to.
    public var carriesPyroWave: Bool {
        switch kind {
        case .local: true
        case .wired: isOnLink && (linkSpeed ?? 0) >= Self.pyroWaveMinimumSpeed
        case .wifi, .cellular, .other: false
        }
    }

    /// The route to `host` (a name or an address) as the system would take
    /// it now; nil if it doesn't resolve or there is no route. Sends nothing:
    /// a UDP socket is connected only to learn its local address. May block
    /// on name resolution, as connecting to the host would.
    public static func to(host: String, port: UInt16) -> NetworkRoute? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let e = entry {
            if let addr = e.pointee.ai_addr, let remote = SocketAddress(addr),
               let local = localAddress(toward: addr, length: e.pointee.ai_addrlen, family: e.pointee.ai_family) {
                if local == remote || local.isLoopback {
                    return NetworkRoute(interface: local.isLoopback ? "lo0" : interface(of: local)?.name ?? "lo0",
                                        kind: .local, linkSpeed: nil, isOnLink: true)
                }
                guard let (name, mask) = interface(of: local) else { return nil }
                return NetworkRoute(interface: name, kind: NetworkInterfaces.shared.kind(of: name),
                                    linkSpeed: linkSpeed(of: name),
                                    isOnLink: mask.map { remote.masked(by: $0) == local.masked(by: $0) } ?? false)
            }
            entry = e.pointee.ai_next
        }
        return nil
    }

    /// The address a UDP socket connected to `addr` would send from.
    private static func localAddress(toward addr: UnsafePointer<sockaddr>, length: socklen_t,
                                     family: Int32) -> SocketAddress? {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard connect(fd, addr, length) == 0 else { return nil }
        var storage = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) == 0 }
        }
        guard ok else { return nil }
        return withUnsafePointer(to: &storage) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SocketAddress($0) } }
    }

    /// The interface that has `address`, and that address's netmask.
    private static func interface(of address: SocketAddress) -> (name: String, mask: SocketAddress?)? {
        var found: (String, SocketAddress?)?
        forEachInterface { ifa in
            guard found == nil, let addr = ifa.ifa_addr, SocketAddress(addr) == address else { return }
            found = (String(cString: ifa.ifa_name), ifa.ifa_netmask.flatMap { SocketAddress($0, family: address.family) })
        }
        return found
    }

    /// The link speed the interface reports (its `if_data`), nil if none.
    static func linkSpeed(of interface: String) -> UInt64? {
        var speed: UInt64?
        forEachInterface { ifa in
            guard speed == nil, let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: ifa.ifa_name) == interface, let data = ifa.ifa_data else { return }
            let baudrate = UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate)
            speed = baudrate > 0 ? baudrate : nil
        }
        return speed
    }

    private static func forEachInterface(_ body: (ifaddrs) -> Void) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return }
        defer { freeifaddrs(list) }
        var entry: UnsafeMutablePointer<ifaddrs>? = list
        while let e = entry {
            body(e.pointee)
            entry = e.pointee.ifa_next
        }
    }
}

/// An IPv4 or IPv6 address, port aside, for comparing addresses.
private struct SocketAddress: Equatable {
    let family: Int32
    let bytes: [UInt8]

    /// `family` overrides the address's own: a netmask from getifaddrs may
    /// leave it unset.
    init?(_ addr: UnsafePointer<sockaddr>, family: Int32? = nil) {
        switch family ?? Int32(addr.pointee.sa_family) {
        case AF_INET:
            self.family = AF_INET
            var a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            self.bytes = withUnsafeBytes(of: &a) { Array($0) }
        case AF_INET6:
            self.family = AF_INET6
            var a = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            self.bytes = withUnsafeBytes(of: &a) { Array($0) }
        default:
            return nil
        }
    }

    private init(family: Int32, bytes: [UInt8]) {
        self.family = family
        self.bytes = bytes
    }

    /// The address with only the bits `mask` keeps.
    func masked(by mask: SocketAddress) -> SocketAddress {
        SocketAddress(family: family, bytes: zip(bytes, mask.bytes).map { $0 & $1 })
    }

    var isLoopback: Bool {
        family == AF_INET ? bytes.first == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
    }
}

/// What kind each network interface is, as the system's path monitor
/// reports it, kept current by one monitor for the life of the process.
final class NetworkInterfaces: Sendable {
    static let shared = NetworkInterfaces()

    private let monitor = NWPathMonitor()
    private let kinds = Mutex<[String: NetworkRoute.Kind]?>(nil)
    private let firstPath = DispatchSemaphore(value: 0)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            var map: [String: NetworkRoute.Kind] = [:]
            for interface in path.availableInterfaces {
                map[interface.name] = switch interface.type {
                case .wiredEthernet: .wired
                case .wifi: .wifi
                case .cellular: .cellular
                case .loopback: .local
                default: .other
                }
            }
            let first = self.kinds.withLock {
                defer { $0 = map }
                return $0 == nil
            }
            if first { self.firstPath.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "spectre.interfaces"))
    }

    /// The interface's kind; waits briefly for the monitor's first report
    /// the first time. `.other` for one the system doesn't list.
    func kind(of interface: String) -> NetworkRoute.Kind {
        if kinds.withLock({ $0 == nil }) { _ = firstPath.wait(timeout: .now() + .milliseconds(500)) }
        return kinds.withLock { $0?[interface] } ?? .other
    }
}
