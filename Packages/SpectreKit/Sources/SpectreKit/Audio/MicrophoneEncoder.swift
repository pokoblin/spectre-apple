import AVFoundation

/// Microphone PCM, in whatever format the device gives, to Opus packets in
/// the session's microphone format (gdp-spec.md §6.8, §10.1; wraith asks for
/// 48 kHz mono 10 ms): converted (resampled, mixed down) by AVAudioConverter,
/// cut into packet-sized pieces, encoded by the system's Opus encoder at
/// `bitRate` (32 kb/s, as upstream's client: speech). Not for the real-time
/// thread. One thread at a time.
public final class MicrophoneEncoder {
    public let format: OpusFormat
    private let encoder: OpusEncoder
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converted: AVAudioPCMBuffer?
    /// Converted samples not yet a full packet.
    private var pending: [Float] = []
    /// RMS level of the latest packet, dBFS (−160 for silence).
    public private(set) var level: Float = -160

    public init?(format: OpusFormat, bitRate: Int = 32_000) {
        guard let encoder = OpusEncoder(format, bitRate: bitRate) else { return nil }
        self.format = format
        self.encoder = encoder
        target = format.pcmFormat
    }

    /// Takes one buffer from the device and calls `onPacket` for every
    /// packet it completes.
    public func append(_ input: AVAudioPCMBuffer, _ onPacket: ([UInt8]) -> Void) {
        guard input.frameLength > 0 else { return }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.downmix = true
            converted = nil
        }
        guard let converter else { return }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        if converted.map({ $0.frameCapacity < capacity }) ?? true {
            converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        }
        guard let out = converted else { return }
        out.frameLength = 0
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard status != .error else { return }
        pending += UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength) * format.channels)

        let n = format.framesPerPacket * format.channels
        var start = 0
        while pending.count - start >= n {
            pending.withUnsafeBufferPointer { all in
                let packet = UnsafeBufferPointer(rebasing: all[start..<start + n])
                level = Self.rms(packet)
                for p in encoder.encode(packet) { onPacket(p) }
            }
            start += n
        }
        pending.removeFirst(start)
    }

    /// Forget buffered audio and the converter's state (the device stopped).
    public func reset() {
        pending.removeAll()
        converter?.reset()
        level = -160
    }

    /// RMS level of `x`, dBFS (−160 for silence).
    public static func rms(_ x: UnsafeBufferPointer<Float>) -> Float {
        guard !x.isEmpty else { return -160 }
        var sum: Float = 0
        for v in x { sum += v * v }
        let rms = (sum / Float(x.count)).squareRoot()
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}
