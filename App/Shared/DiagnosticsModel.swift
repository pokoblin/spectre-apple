import Foundation
import GDPKit
import Observation

/// Proves at launch that libgdp is linked and works on this platform: a
/// fingerprint through libgdp's SHA-256 and a loopback QUIC connection
/// through its transport (ngtcp2 + OpenSSL).
@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var lines: [String] = []

    func run() async {
        let fingerprint = CertificateFingerprint(certificateDER: Array("abc".utf8))
        report("GDPKit \(GDP.alpn) v\(GDP.wireVersion), sha256(\"abc\") \(fingerprint.hex.prefix(16))…")
        let result = await Task.detached(priority: .utility) { () -> Result<QUICSelfTest.Report, QUICSelfTest.Failure> in
            do throws(QUICSelfTest.Failure) {
                return .success(try QUICSelfTest.run(timeout: .seconds(10)))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(r):
            report(String(format: "QUIC loopback ok: handshake %.1f ms, RTT %u µs, max datagram %u B, %u datagrams",
                          r.handshakeMilliseconds, r.rttMicroseconds, r.maxDatagramSize, r.datagramsReceived))
        case let .failure(f):
            report("QUIC loopback FAILED: \(f)")
        }
    }

    private func report(_ line: String) {
        lines.append(line)
        print("diagnostics: \(line)")
    }
}
