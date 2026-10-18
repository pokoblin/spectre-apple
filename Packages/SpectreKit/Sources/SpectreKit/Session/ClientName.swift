import Foundation
import GDPKit
#if os(macOS)
import SystemConfiguration
#endif

/// What SessionHello says this machine is called (gdp-spec.md §6.2): its
/// host name without a domain. The host labels the folders this client
/// shares with it ("Desktop (Kbys-Mac-mini)", §7.12).
public enum ClientName {
    /// The longest name a host takes; a longer one counts as none (§6.2).
    public static let maxBytes = 64

    /// This machine's name: the Mac's local host name (the one Sharing
    /// settings show, without ".local"); "iPad" or "iPhone" elsewhere, since
    /// iOS doesn't tell apps the name its user gave the device.
    public static func current() -> String {
        #if os(macOS)
        let local = SCDynamicStoreCopyLocalHostName(nil) as String?
        let name = local ?? ProcessInfo.processInfo.hostName
        return sanitized(String(name.prefix { $0 != "." }))
        #else
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine()
        return model.hasPrefix("iPhone") ? "iPhone" : "iPad"
        #endif
    }

    /// `name` as SessionHello can carry it: NFC, at most ``maxBytes`` (whole
    /// characters off the end), and following §7.12's name rules; "" if it
    /// can't.
    public static func sanitized(_ name: String) -> String {
        var name = name.precomposedStringWithCanonicalMapping
        while name.utf8.count > maxBytes { name.removeLast() }
        return GDPSession.isValidFileName(name) ? name : ""
    }

    #if !os(macOS)
    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    #endif
}
