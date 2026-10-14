import AVFoundation
import Foundation
import GDPKit
import Testing
@testable import SpectreKit

/// A device-format buffer: `frames` of a 440 Hz sine (amplitude 0.5) on every
/// channel, continuing from frame `start`.
private func deviceBuffer(rate: Double, channels: AVAudioChannelCount, start: Int, frames: Int,
                          amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    b.frameLength = AVAudioFrameCount(frames)
    for c in 0..<Int(channels) {
        for i in 0..<frames {
            b.floatChannelData![c][i] = amplitude * Float(sin(2 * .pi * 440 * Double(start + i) / rate))
        }
    }
    return b
}

private let microphone = OpusFormat(sampleRate: 48000, channels: 1, frameMilliseconds: 10)!

/// Feeds one second in uneven chunks; returns the packets and the decoded audio.
private func encodeSecond(rate: Double, channels: AVAudioChannelCount, encoder: MicrophoneEncoder,
                          amplitude: Float = 0.5) -> (packets: [[UInt8]], decoded: [Float]) {
    var packets: [[UInt8]] = []
    var at = 0
    let total = Int(rate)
    let chunks = [512, 333, 1024, 97, 480]
    var k = 0
    while at < total {
        let n = min(chunks[k % chunks.count], total - at)
        encoder.append(deviceBuffer(rate: rate, channels: channels, start: at, frames: n, amplitude: amplitude)) {
            packets.append($0)
        }
        at += n
        k += 1
    }
    let decoder = OpusDecoder(microphone)!
    var decoded: [Float] = []
    for p in packets { decoder.decode(p) { decoded += $0 } }
    return (packets, decoded)
}

@Suite("Microphone encoder")
struct MicrophoneEncoderTests {
    @Test func sessionFormatIsWraiths() {
        #expect(OpusFormat(GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 1, frameMilliseconds: 10))
                == microphone)
        #expect(microphone.framesPerPacket == 480)
    }

    @Test func fortyEightKilohertzMonoInUnevenChunks() throws {
        let encoder = try #require(MicrophoneEncoder(format: microphone))
        let (packets, decoded) = encodeSecond(rate: 48000, channels: 1, encoder: encoder)
        #expect(packets.count == 100)
        // 32 kb/s: about 40 bytes a packet.
        let bytes = packets.map(\.count).reduce(0, +)
        #expect(bytes > 3000 && bytes < 6000)
        #expect(abs(frequency(decoded[12000..<36000], sampleRate: 48000) - 440) < 3)
        // RMS of a 0.5 sine: −9.03 dBFS.
        #expect(abs(encoder.level - -9.03) < 0.5)
    }

    /// A 44.1 kHz stereo device (a USB headset, say): resampled and mixed
    /// down to 48 kHz mono.
    @Test func otherRatesAndChannelsAreConverted() throws {
        let encoder = try #require(MicrophoneEncoder(format: microphone))
        let (packets, decoded) = encodeSecond(rate: 44100, channels: 2, encoder: encoder)
        #expect((98...100).contains(packets.count)) // the resampler holds a few frames back
        #expect(abs(frequency(decoded[12000..<36000], sampleRate: 48000) - 440) < 3)
        let peak = decoded[12000..<36000].map(abs).max()!
        #expect(peak > 0.4 && peak < 0.6) // mixing down keeps the level
    }

    @Test func theDeviceFormatMayChange() throws {
        let encoder = try #require(MicrophoneEncoder(format: microphone))
        let first = encodeSecond(rate: 48000, channels: 1, encoder: encoder).packets.count
        encoder.reset()
        let second = encodeSecond(rate: 16000, channels: 1, encoder: encoder)
        #expect(first == 100)
        #expect((98...100).contains(second.packets.count))
        #expect(abs(frequency(second.decoded[12000..<36000], sampleRate: 48000) - 440) < 3)
    }

    @Test func silenceIsQuiet() throws {
        let encoder = try #require(MicrophoneEncoder(format: microphone))
        let (packets, decoded) = encodeSecond(rate: 48000, channels: 1, encoder: encoder, amplitude: 0)
        #expect(packets.count == 100)
        #expect(encoder.level == -160)
        #expect(decoded.map(abs).max()! < 0.001)
    }
}

@Suite("Audio ring (non-interleaved input)")
struct AudioRingInputTests {
    @Test func interleavesAndRoundTrips() {
        let ring = AudioRing(channels: 2, minimumCapacity: 8)
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer {
            for b in abl { b.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        for c in 0..<2 {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: 5)
            for i in 0..<5 { p[i] = Float(c == 0 ? i : -i) }
            abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 20, mData: p)
        }
        for _ in 0..<3 {
            #expect(ring.write(from: abl, frames: 5) == 5)
            let out = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!,
                                       frameCapacity: 5)!
            #expect(ring.read(into: UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList), frames: 5) == 5)
            #expect(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: 5)) == [0, 1, 2, 3, 4])
            #expect(Array(UnsafeBufferPointer(start: out.floatChannelData![1], count: 5)) == [0, -1, -2, -3, -4])
        }
        // Full: only what fits.
        #expect(ring.write(from: abl, frames: 5) == 5)
        #expect(ring.write(from: abl, frames: 5) == 3)
    }
}
