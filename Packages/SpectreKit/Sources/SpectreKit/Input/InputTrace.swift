import Foundation

/// A trace of input for debugging against a real host, on stdout:
/// `SPECTRE_INPUT_LOG=1` prints each platform event as it arrives (raw
/// values: key codes, modifier flags, scroll deltas) and each event sent
/// to the host.
public enum InputTrace {
    public static let enabled = ProcessInfo.processInfo.environment["SPECTRE_INPUT_LOG"] != nil
    private static let start = Date()

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print(String(format: "input %8.3f ", Date().timeIntervalSince(start)) + message())
    }
}
