// Where the parts the prototype leaves out plug into a session. Nothing here
// is implemented yet; the shapes record the intended seams so the video path
// built now doesn't have to be reworked for them.
//
// Session (to come): a C++ SessionClient in Packages/GDPKit/Native, written
// from gdp-spec.md §6-§8 (upstream's is GPL), behind the C ABI. Its receive
// queue hands reassembled frames to VideoDecoder (as StreamPlayer does
// today) and calls the components below; it sends StatsReport every 250 ms
// with the decode and present times PlaybackStats measures.

/// Session audio out (gdp-spec.md §10): Opus packets through a jitter
/// buffer into AVAudioEngine.
public protocol AudioSink: AnyObject, Sendable {
    func receive(sequence: UInt16, pts: UInt32, opusPacket: UnsafeRawBufferPointer)
}

/// Microphone to the host (gdp-spec.md §10.1, capability `microphone`).
public protocol MicrophoneSource: AnyObject, Sendable {
    var onPacket: (@Sendable (UnsafeRawBufferPointer) -> Void)? { get set }
}

/// Keyboard, pointer and touch input forwarded on the input stream (gdp-spec.md §8.2, §8.3).
public protocol InputForwarder: AnyObject {
    func key(hidUsage: UInt32, pressed: Bool)
    func pointerMotion(dx: Double, dy: Double, absolute: Bool)
    func pointerButton(_ button: UInt32, pressed: Bool)
    func pointerAxis(horizontal: Double, vertical: Double)
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
