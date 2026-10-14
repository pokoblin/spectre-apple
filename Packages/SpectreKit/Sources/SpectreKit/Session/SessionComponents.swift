// Where the parts not built yet plug into a session. The session itself is
// GDPKit's GDPSession (a C++ SessionClient written from gdp-spec.md §6-§11,
// behind the C ABI) and RemoteSession here, which runs its video path; the
// shapes below record the remaining seams so that path doesn't have to be
// reworked for them. (Done: keyboard and pointer input, Input/, see
// docs/input.md; session audio, Audio/, see docs/audio.md.) Each capability
// (§6.7) is offered in SessionHello only once it is implemented.

/// Microphone to the host (gdp-spec.md §10.1, capability `microphone`).
public protocol MicrophoneSource: AnyObject, Sendable {
    var onPacket: (@Sendable (UnsafeRawBufferPointer) -> Void)? { get set }
}

/// GameController pads (gdp-spec.md §8.5, capability `gamepad`).
public protocol GamepadForwarder: AnyObject {
    func connect(slot: Int, name: String)
    func disconnect(slot: Int)
}

/// Clipboard text in both directions (gdp-spec.md §7.9, capability `clipboard`).
public protocol ClipboardBridge: AnyObject {
    func remoteChanged(utf8 text: String)
    var onLocalChange: ((String) -> Void)? { get set }
}
