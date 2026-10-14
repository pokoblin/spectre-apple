import Foundation
import GDPCore

/// A real QUIC connection over loopback through libgdp's transport (ngtcp2 +
/// OpenSSL), both ends in this process: certificate pinning input, a framed
/// Ping/Pong on the control stream and one video frame as datagrams.
public enum QUICSelfTest {
    public struct Report: Sendable, CustomStringConvertible {
        public let fingerprint: CertificateFingerprint?
        public let port: UInt16
        public let rttMicroseconds: UInt32
        public let maxDatagramSize: UInt16
        public let datagramsReceived: UInt32
        public let handshakeMilliseconds: Double
        public let totalMilliseconds: Double

        public var description: String {
            String(format: "QUIC loopback ok: port %u, handshake %.1f ms, total %.1f ms, RTT %u µs, "
                + "max datagram %u B, %u datagrams, cert %@",
                   port, handshakeMilliseconds, totalMilliseconds, rttMicroseconds, maxDatagramSize,
                   datagramsReceived, fingerprint?.hex ?? "-")
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Blocks the calling thread for up to `timeout`; call it off the main actor.
    public static func run(scratchDirectory: URL = FileManager.default.temporaryDirectory,
                           timeout: Duration = .seconds(10)) throws(Failure) -> Report {
        var r = gdpc_selftest_result()
        let ms = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        gdpc_selftest_quic_loopback(scratchDirectory.path(percentEncoded: false), ms, &r)
        guard r.ok else {
            throw Failure(description: withUnsafeBytes(of: r.error) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        let hex = withUnsafeBytes(of: r.cert_sha256) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return Report(fingerprint: CertificateFingerprint(hex: hex), port: r.port, rttMicroseconds: r.rtt_us,
                      maxDatagramSize: r.max_datagram_size, datagramsReceived: r.datagrams_received,
                      handshakeMilliseconds: r.handshake_ms, totalMilliseconds: r.total_ms)
    }
}
