import AVFoundation
import Synchronization

/// iOS's one AVAudioSession, set from what the session uses: `.playback`
/// while only the host's audio plays, `.playAndRecord` while the microphone
/// is on too. Both mix with other apps' audio and play through the speaker
/// (not the receiver); Bluetooth headphones stay in A2DP, so they only
/// listen and the device's own microphone records (HFP would record from the
/// headset but drop playback to call quality). Activated while either is in
/// use. On macOS there is no audio session and this does nothing.
public final class AudioSessionCoordinator: Sendable {
    public static let shared = AudioSessionCoordinator()

    private struct State {
        var playing = 0
        var recording = 0
    }
    private let state = Mutex(State())

    /// Playback starts (true) or stops (false). Throws if the session can't
    /// be set up.
    public func playback(_ on: Bool) throws {
        try update { $0.playing += on ? 1 : -1 }
    }

    /// The microphone opens (true) or closes (false).
    public func recording(_ on: Bool) throws {
        try update { $0.recording += on ? 1 : -1 }
    }

    /// After an interruption: set up and activate again for what is in use.
    public func reactivate() throws {
        try update { _ in }
    }

    private func update(_ change: (inout State) -> Void) throws {
        #if os(iOS)
        try state.withLock { s in
            change(&s)
            s.playing = max(0, s.playing)
            s.recording = max(0, s.recording)
            let session = AVAudioSession.sharedInstance()
            if s.playing == 0 && s.recording == 0 {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            if s.recording > 0 {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try? session.setPreferredSampleRate(48000)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        }
        #else
        state.withLock { change(&$0) }
        #endif
    }
}
