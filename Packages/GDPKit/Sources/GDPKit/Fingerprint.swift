import GDPCore

/// Protocol constants (gdp-spec.md §2.1).
public enum GDP {
    /// The ALPN token, `gdp/1`.
    public static var alpn: String { String(cString: gdpc_alpn()) }
    public static var wireVersion: UInt32 { gdpc_wire_version() }
}

public enum SHA256 {
    /// libgdp's own SHA-256 (gdp/cert_fingerprint.hpp).
    public static func digest(_ bytes: some Collection<UInt8>) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        bytes.withContiguousBytes { buf in
            out.withUnsafeMutableBufferPointer { o in
                gdpc_sha256(buf.baseAddress, buf.count, o.baseAddress)
            }
        }
        return out
    }
}

/// A certificate fingerprint as GDP pins it (gdp-spec.md §2.3): the SHA-256
/// of the certificate's DER, written as 64 lowercase hex digits.
public struct CertificateFingerprint: Hashable, Sendable, CustomStringConvertible {
    /// The wire and storage form (`Redirect.cert_sha256`).
    public let hex: String

    /// Accepts only a well-formed wire value: 64 lowercase hex digits.
    public init?(hex: String) {
        guard gdpc_is_sha256_hex(hex) else { return nil }
        self.hex = hex
    }

    public init(certificateDER der: some Collection<UInt8>) {
        var out = [CChar](repeating: 0, count: Int(GDPC_SHA256_HEX_LEN) + 1)
        der.withContiguousBytes { buf in
            gdpc_sha256_hex(buf.baseAddress, buf.count, &out)
        }
        hex = String(cString: out)
    }

    /// The form shown to a person: `AB:CD:...`, as `openssl x509 -fingerprint` prints it.
    public var displayString: String {
        var out = [CChar](repeating: 0, count: Int(GDPC_FINGERPRINT_DISPLAY_LEN) + 1)
        _ = gdpc_format_fingerprint(hex, &out)
        return String(cString: out)
    }

    public var description: String { hex }
}

extension Collection<UInt8> {
    /// Runs `body` over contiguous storage, copying only when the collection has none.
    func withContiguousBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        if let result = try withContiguousStorageIfAvailable(body) {
            return result
        }
        return try Array(self).withUnsafeBufferPointer(body)
    }
}
