import AVFoundation
import GDPKit

/// The session audio's format (gdp-spec.md §6.8), checked against what the
/// system's Opus codec handles. wraith sends `{48000, 2, 10, "opus"}`.
public struct OpusFormat: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let frameMilliseconds: Int

    /// Opus decodes at these rates (RFC 6716 §2).
    static let sampleRates: Set<Int> = [8000, 12000, 16000, 24000, 48000]
    /// Opus frame durations; `frame_ms` is an integer, so 2.5 ms can't be named.
    static let frameDurations: Set<Int> = [5, 10, 20, 40, 60]

    public init?(sampleRate: Int, channels: Int, frameMilliseconds: Int) {
        guard Self.sampleRates.contains(sampleRate), (1...2).contains(channels),
              Self.frameDurations.contains(frameMilliseconds)
        else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameMilliseconds = frameMilliseconds
    }

    /// nil for a codec other than `opus` or a format Opus doesn't have: the
    /// session then runs without audio (§6.8).
    public init?(_ config: GDPSession.AudioConfig) {
        guard config.codec == "opus" else { return nil }
        self.init(sampleRate: Int(config.sampleRate), channels: Int(config.channels),
                  frameMilliseconds: Int(config.frameMilliseconds))
    }

    public static let session = OpusFormat(sampleRate: 48000, channels: 2, frameMilliseconds: 10)!

    public var framesPerPacket: Int { sampleRate * frameMilliseconds / 1000 }
    public var packetDuration: Double { Double(frameMilliseconds) / 1000 }

    /// Interleaved Float32: what the decoder produces and the ring holds.
    var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                      channels: AVAudioChannelCount(channels), interleaved: true)!
    }

    var opusFormat: AVAudioFormat? {
        var d = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
                                            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)
    }
}

/// Opus packets to PCM through the system codec (AudioToolbox's
/// `kAudioFormatOpus`, via AVAudioConverter), one packet per call, as they
/// come off the jitter buffer. Not for the real-time audio thread: the
/// converter allocates and locks. One thread at a time.
///
/// The decoder trims Opus's pre-skip from the first packet after it is
/// created or reset (360 of 480 frames at 48 kHz, 10 ms), so the frame
/// count per call varies; callers take whatever comes out.
public final class OpusDecoder {
    public let format: OpusFormat
    private let converter: AVAudioConverter
    private let input: AVAudioCompressedBuffer
    private let output: AVAudioPCMBuffer

    /// The largest packet taken in one piece (RFC 6716 §3.4: 1275 bytes a
    /// frame, and a 10 ms packet holds at most a few frames).
    static let maxPacketBytes = 4096

    public init?(_ format: OpusFormat) {
        guard let opus = format.opusFormat, let converter = AVAudioConverter(from: opus, to: format.pcmFormat),
              let output = AVAudioPCMBuffer(pcmFormat: format.pcmFormat,
                                            frameCapacity: AVAudioFrameCount(format.framesPerPacket * 2))
        else { return nil }
        self.format = format
        self.converter = converter
        self.input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: Self.maxPacketBytes)
        self.output = output
    }

    /// Decodes one packet, or with nil conceals one lost packet (Opus PLC:
    /// an empty packet). Calls `body` with the interleaved samples, if any.
    /// Returns false if the codec failed.
    @discardableResult
    public func decode(_ packet: UnsafeRawBufferPointer?, _ body: (UnsafeBufferPointer<Float>) -> Void) -> Bool {
        let count = packet?.count ?? 0
        guard count <= Self.maxPacketBytes else { return false }
        if let packet, count > 0 { input.data.copyMemory(from: packet.baseAddress!, byteCount: count) }
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(count))
        input.packetCount = 1
        input.byteLength = UInt32(count)
        output.frameLength = 0

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [input] _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard status != .error else { return false }
        let samples = Int(output.frameLength) * format.channels
        if samples > 0 { body(UnsafeBufferPointer(start: output.floatChannelData![0], count: samples)) }
        return true
    }

    @discardableResult
    public func decode(_ packet: [UInt8]?, _ body: (UnsafeBufferPointer<Float>) -> Void) -> Bool {
        guard let packet else { return decode(nil as UnsafeRawBufferPointer?, body) }
        return packet.withUnsafeBytes { decode($0, body) }
    }

    /// Forget the decoder's state (as at creation).
    public func reset() { converter.reset() }
}

/// PCM to Opus packets through the system codec: the loopback
/// host's test tone, and the tests' packets. One packet per call.
public final class OpusEncoder {
    public let format: OpusFormat
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    public init?(_ format: OpusFormat, bitRate: Int = 128_000) {
        guard let opus = format.opusFormat, let converter = AVAudioConverter(from: format.pcmFormat, to: opus),
              let input = AVAudioPCMBuffer(pcmFormat: format.pcmFormat, frameCapacity: AVAudioFrameCount(format.framesPerPacket))
        else { return nil }
        converter.bitRate = bitRate
        self.format = format
        self.converter = converter
        self.input = input
        self.output = AVAudioCompressedBuffer(format: opus, packetCapacity: 4,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
    }

    /// Encodes exactly one packet's worth of interleaved samples
    /// (`framesPerPacket × channels`). Returns the packets that came out:
    /// normally one.
    public func encode(_ samples: UnsafeBufferPointer<Float>) -> [[UInt8]] {
        precondition(samples.count == format.framesPerPacket * format.channels)
        input.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        input.frameLength = AVAudioFrameCount(format.framesPerPacket)
        output.packetCount = 0
        output.byteLength = 0

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [input] _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard status != .error else { return [] }
        return (0..<Int(output.packetCount)).map { i in
            let d = output.packetDescriptions![i]
            let start = output.data.advanced(by: Int(d.mStartOffset)).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: start, count: Int(d.mDataByteSize)))
        }
    }

    public func encode(_ samples: [Float]) -> [[UInt8]] { samples.withUnsafeBufferPointer { encode($0) } }
}
