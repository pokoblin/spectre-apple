import Darwin
import Foundation

/// A UDP relay on 127.0.0.1 between a client and a server, for tests: the
/// client talks to `port`, the relay to the server. `cut()` closes both of
/// its sockets without a word, as a network that went away would.
final class UDPRelay: @unchecked Sendable {
    let port: UInt16
    private let front: Int32 // the client's side
    private let back: Int32  // connected to the server
    private var client: sockaddr_in?
    private let lock = NSLock()
    private var thread: Thread?

    init(to serverPort: UInt16) throws {
        func socket4() throws -> Int32 {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            return fd
        }
        func address(_ port: UInt16) -> sockaddr_in {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            return a
        }
        let f = try socket4(), b = try socket4()
        var any = address(0)
        var server = address(serverPort)
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &any, { bind(f, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), len) }) == 0,
              withUnsafePointer(to: &server, { connect(b, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), len) }) == 0
        else { throw POSIXError(.EIO) }
        var bound = sockaddr_in()
        var boundLen = len
        _ = withUnsafeMutablePointer(to: &bound) {
            getsockname(f, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &boundLen)
        }
        front = f
        back = b
        port = UInt16(bigEndian: bound.sin_port)
        let t = Thread { [self] in run() }
        thread = t
        t.start()
    }

    /// The network goes away: both sockets close, nothing is said to anyone.
    func cut() {
        shutdown(front, SHUT_RDWR)
        shutdown(back, SHUT_RDWR)
        close(front)
        close(back)
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var fds = [pollfd(fd: front, events: Int16(POLLIN), revents: 0), pollfd(fd: back, events: Int16(POLLIN), revents: 0)]
            guard poll(&fds, 2, 100) >= 0 else { return }
            if fds[0].revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 { return }
            if fds[0].revents & Int16(POLLIN) != 0 {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    recvfrom(front, &buffer, buffer.count, 0, UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self), &fromLen)
                }
                if n <= 0 { return }
                lock.withLock { client = from }
                _ = send(back, buffer, n, 0)
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = recv(back, &buffer, buffer.count, 0)
                if n <= 0 { continue }
                guard var to = lock.withLock({ client }) else { continue }
                _ = withUnsafePointer(to: &to) {
                    sendto(front, buffer, n, 0, UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self),
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
