import AVFoundation
import Foundation
import GDPKit
import Testing
@testable import SpectreKit

/// What a pull returned, compactly: a packet's `seq`, or -1 for concealment.
private func pull(_ jb: inout AudioJitterBuffer, _ count: Int, now: Double = 0) -> [Int?] {
    (0..<count).map { _ in
        switch jb.next(now: now) {
        case .packet(let p)?: Int(p.sequence)
        case .conceal?: -1
        case nil: nil
        }
    }
}

private func insert(_ jb: inout AudioJitterBuffer, _ seqs: [Int], now: Double = 0) {
    for s in seqs { jb.insert(sequence: UInt16(truncatingIfNeeded: s), pts: UInt32(truncatingIfNeeded: s * 10_000), data: [UInt8(s & 0xFF)], now: now) }
}

@Suite("Audio jitter buffer")
struct AudioJitterBufferTests {
    @Test func buffersToTargetThenPlaysInOrder() {
        var jb = AudioJitterBuffer()
        insert(&jb, Array(0..<5))
        #expect(jb.next(now: 0) == nil)
        #expect(!jb.isPlaying)
        insert(&jb, [5])
        #expect(pull(&jb, 7) == [0, 1, 2, 3, 4, 5, nil])
        // Nothing more: it waits rather than concealing ahead.
        #expect(jb.isPlaying)
        #expect(jb.counters.concealed == 0)
        #expect(jb.counters.played == 6)
    }

    @Test func aShortSoundStartsAfterTheTargetTime() {
        var jb = AudioJitterBuffer()
        insert(&jb, [0, 1], now: 1.0)
        #expect(jb.next(now: 1.05) == nil)
        #expect(pull(&jb, 3, now: 1.06) == [0, 1, nil])
    }

    @Test func reorderedPacketsPlayInOrder() {
        var jb = AudioJitterBuffer()
        insert(&jb, [0, 2, 1, 3, 5, 4])
        #expect(pull(&jb, 6) == [0, 1, 2, 3, 4, 5])
        insert(&jb, [7, 6])
        #expect(pull(&jb, 2) == [6, 7])
    }

    @Test func aMissingPacketIsConcealedOnceLaterOnesAreHere() {
        var jb = AudioJitterBuffer()
        insert(&jb, [0, 1, 3, 4, 5, 6])
        #expect(pull(&jb, 7) == [0, 1, -1, 3, 4, 5, 6])
        #expect(jb.counters.concealed == 1)
        // A burst: three missing.
        insert(&jb, [10, 11])
        #expect(pull(&jb, 6) == [-1, -1, -1, 10, 11, nil])
        #expect(jb.counters.concealed == 4)
    }

    @Test func latePacketsAndDuplicatesAreDropped() {
        var jb = AudioJitterBuffer()
        insert(&jb, [0, 1, 3, 4, 5, 6, 6])
        #expect(jb.counters.duplicates == 1)
        #expect(pull(&jb, 3) == [0, 1, -1])
        insert(&jb, [2, 1]) // 2's slot was concealed; 1 was played
        #expect(jb.counters.late == 2)
        #expect(pull(&jb, 2) == [3, 4])
        insert(&jb, [5])
        #expect(jb.counters.duplicates == 2)
    }

    /// The host's `seq` stands still while it has no audio; after an
    /// underrun the buffer re-anchors on whatever arrives next, whether `seq`
    /// carries on or has jumped, and conceals nothing for the gap.
    @Test func underrunRebuffersAndReanchors() {
        var jb = AudioJitterBuffer()
        insert(&jb, Array(0..<6))
        #expect(pull(&jb, 7) == [0, 1, 2, 3, 4, 5, nil])
        jb.underrun()
        #expect(!jb.isPlaying)
        #expect(jb.counters.underruns == 1)
        jb.underrun() // not playing: not counted again
        #expect(jb.counters.underruns == 1)

        insert(&jb, Array(6..<11))
        #expect(jb.next(now: 0) == nil) // re-buffering
        insert(&jb, [11])
        #expect(pull(&jb, 7) == [6, 7, 8, 9, 10, 11, nil])

        jb.underrun()
        insert(&jb, Array(30..<36))
        #expect(pull(&jb, 7) == [30, 31, 32, 33, 34, 35, nil])
        #expect(jb.counters.concealed == 0)
    }

    @Test func sequenceNumbersWrap() {
        var jb = AudioJitterBuffer()
        insert(&jb, [65533, 65534, 0, 65535, 1, 2])
        #expect(pull(&jb, 6) == [65533, 65534, 65535, 0, 1, 2])
        insert(&jb, [65535]) // a very late one from before the wrap
        #expect(jb.counters.late == 1)
        insert(&jb, [4, 3])
        #expect(pull(&jb, 2) == [3, 4])
    }

    @Test func aPacketFarAheadStartsOver() {
        var jb = AudioJitterBuffer()
        insert(&jb, Array(0..<6))
        #expect(pull(&jb, 2) == [0, 1])
        insert(&jb, [1000])
        #expect(jb.counters.resyncs == 1)
        #expect(!jb.isPlaying)
        #expect(jb.depth == 1)
        insert(&jb, Array(1001..<1006))
        #expect(pull(&jb, 2) == [1000, 1001])
    }

    @Test func overrunDropsTheOldestBackToTarget() {
        var jb = AudioJitterBuffer()
        insert(&jb, Array(0..<6))
        #expect(pull(&jb, 2) == [0, 1])
        insert(&jb, Array(6..<14)) // 12 queued: at the limit
        #expect(jb.counters.dropped == 0)
        insert(&jb, [14]) // 13: trim to 6
        #expect(jb.counters.dropped == 7)
        #expect(jb.depth == 6)
        #expect(pull(&jb, 7) == [9, 10, 11, 12, 13, 14, nil])
    }

    /// Steady play where one side runs fast (here by 2 %, a packet every 50
    /// pulls, to keep the test short): one packet is dropped or one concealed
    /// slot inserted at a time, about once per packet of drift, and the
    /// depth stays near the first window's.
    @Test(arguments: [true, false]) func driftIsCorrectedOnePacketAtATime(hostFaster: Bool) {
        var config = AudioJitterBuffer.Configuration()
        config.driftWindow = 20
        var jb = AudioJitterBuffer(config)
        var seq = 0
        func arrive(_ n: Int) {
            insert(&jb, Array(seq..<seq + n))
            seq += n
        }
        arrive(6)
        _ = jb.next(now: 0)
        let reference = jb.depth
        var low = reference, high = reference
        for pull in 1...2000 {
            arrive(pull % 50 == 0 ? (hostFaster ? 2 : 0) : 1)
            _ = jb.next(now: 0)
            low = min(low, jb.depth)
            high = max(high, jb.depth)
        }
        let corrections = hostFaster ? jb.counters.dropped : jb.counters.inserted
        #expect((36...40).contains(corrections))
        #expect(jb.counters.dropped + jb.counters.inserted == corrections)
        #expect(reference - low <= 3 && high - reference <= 3)
        #expect(jb.counters.concealed == 0)
        #expect(jb.counters.underruns == 0)
    }

    @Test func flushStartsOver() {
        var jb = AudioJitterBuffer()
        insert(&jb, Array(0..<6))
        _ = pull(&jb, 1)
        jb.flush()
        #expect(jb.depth == 0)
        #expect(!jb.isPlaying)
        insert(&jb, Array(20..<26))
        #expect(pull(&jb, 1) == [20])
    }
}

/// A sine per channel (440 Hz left, 660 Hz right), `packets` 10 ms packets
/// encoded by the system encoder.
func opusTone(packets: Int, format: OpusFormat = .session, amplitude: Float = 0.5) -> [[UInt8]] {
    let encoder = OpusEncoder(format)!
    let n = format.framesPerPacket
    var out: [[UInt8]] = []
    for p in 0..<packets {
        var samples = [Float](repeating: 0, count: n * format.channels)
        for i in 0..<n {
            let t = Double(p * n + i) / Double(format.sampleRate)
            for c in 0..<format.channels {
                samples[i * format.channels + c] = amplitude * Float(sin(2 * .pi * (c == 0 ? 440 : 660) * t))
            }
        }
        out += encoder.encode(samples)
    }
    return out
}

/// Frequency by zero crossings.
func frequency(_ x: ArraySlice<Float>, sampleRate: Double) -> Double {
    var crossings = 0
    for i in x.indices.dropFirst() where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
    return Double(crossings) / 2 / (Double(x.count) / sampleRate)
}

@Suite("Opus codec")
struct OpusCodecTests {
    @Test func formatComesFromSessionAccept() {
        #expect(OpusFormat(GDPSession.AudioConfig(codec: "opus", sampleRate: 48000, channels: 2, frameMilliseconds: 10))
                == .session)
        #expect(OpusFormat.session.framesPerPacket == 480)
        #expect(OpusFormat(GDPSession.AudioConfig(codec: "aac", sampleRate: 48000, channels: 2, frameMilliseconds: 10)) == nil)
        #expect(OpusFormat(sampleRate: 44100, channels: 2, frameMilliseconds: 10) == nil)
        #expect(OpusFormat(sampleRate: 48000, channels: 3, frameMilliseconds: 10) == nil)
        #expect(OpusFormat(sampleRate: 48000, channels: 2, frameMilliseconds: 15) == nil)
        #expect(OpusFormat(sampleRate: 16000, channels: 1, frameMilliseconds: 20) != nil)
    }

    @Test func roundTripsATone() throws {
        let packets = opusTone(packets: 100)
        #expect(packets.count == 100)
        // CELT, full band, 10 ms, stereo, one frame: what wraith sends (RESTRICTED_LOWDELAY).
        #expect(packets[0][0] == 0xF4)
        let decoder = try #require(OpusDecoder(.session))
        var left: [Float] = [], right: [Float] = []
        var counts: [Int] = []
        for p in packets {
            #expect(decoder.decode(p) { s in
                counts.append(s.count / 2)
                for i in stride(from: 0, to: s.count, by: 2) {
                    left.append(s[i])
                    right.append(s[i + 1])
                }
            })
        }
        // The first packet loses Opus's pre-skip.
        #expect(counts.first == 360)
        #expect(counts.dropFirst().allSatisfy { $0 == 480 })
        let mid = left.count / 4..<left.count * 3 / 4
        #expect(abs(frequency(left[mid], sampleRate: 48000) - 440) < 3)
        #expect(abs(frequency(right[mid], sampleRate: 48000) - 660) < 3)
        let peak = left[mid].map(abs).max()!
        #expect(peak > 0.45 && peak < 0.56)
    }

    @Test func concealsALostPacket() throws {
        let packets = opusTone(packets: 20)
        let decoder = try #require(OpusDecoder(.session))
        for p in packets.prefix(10) { decoder.decode(p) { _ in } }
        var concealed: [Float] = []
        #expect(decoder.decode(nil as [UInt8]?) { concealed += $0 })
        #expect(concealed.count == 480 * 2)
        // PLC continues the tone rather than going silent at once.
        #expect(concealed.map(abs).max()! > 0.3)
        var next = 0
        #expect(decoder.decode(packets[11]) { next = $0.count })
        #expect(next == 480 * 2)
    }

    @Test func monoAndOtherRates() throws {
        let format = try #require(OpusFormat(sampleRate: 24000, channels: 1, frameMilliseconds: 20))
        let packets = opusTone(packets: 25, format: format)
        let decoder = try #require(OpusDecoder(format))
        var out: [Float] = []
        for p in packets { decoder.decode(p) { out += $0 } }
        #expect(out.count > 24000 / 2 - 480)
        #expect(abs(frequency(out[out.count / 4..<out.count * 3 / 4], sampleRate: 24000) - 440) < 3)
    }

    @Test func garbageDoesNotCrash() throws {
        let decoder = try #require(OpusDecoder(.session))
        decoder.decode([UInt8](repeating: 0xFF, count: 100)) { _ in }
        decoder.decode([UInt8](repeating: 0, count: OpusDecoder.maxPacketBytes + 1)) { _ in }
        // Still decodes real packets afterwards.
        decoder.reset()
        var got = 0
        for p in opusTone(packets: 3) { decoder.decode(p) { got += $0.count } }
        #expect(got > 0)
    }
}

@Suite("Audio ring")
struct AudioRingTests {
    private func readAll(_ ring: AudioRing, frames: Int, outputChannels: Int = 2) -> ([[Float]], Int) {
        let abl = AudioBufferList.allocate(maximumBuffers: outputChannels)
        defer {
            for b in abl { b.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
        }
        for c in 0..<outputChannels {
            abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                 mData: UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 4))
            abl[c].mData!.initializeMemory(as: Float.self, repeating: -9, count: frames)
        }
        let n = ring.read(into: abl, frames: frames)
        let out = (0..<outputChannels).map { c in
            Array(UnsafeBufferPointer(start: abl[c].mData!.assumingMemoryBound(to: Float.self), count: frames))
        }
        return (out, n)
    }

    @Test func wrapsAndDeinterleaves() {
        let ring = AudioRing(channels: 2, minimumCapacity: 5)
        #expect(ring.capacity == 8)
        var next: Float = 0
        var expected: Float = 0
        for _ in 0..<10 {
            let frames = (0..<3).flatMap { _ -> [Float] in
                defer { next += 1 }
                return [next, -next]
            }
            #expect(frames.withUnsafeBufferPointer { ring.write($0) } == 3)
            let (out, n) = readAll(ring, frames: 3)
            #expect(n == 3)
            for i in 0..<3 {
                #expect(out[0][i] == expected && out[1][i] == -expected)
                expected += 1
            }
        }
    }

    @Test func fullAndEmpty() {
        let ring = AudioRing(channels: 2, minimumCapacity: 4)
        let six = [Float](repeating: 1, count: 12)
        #expect(six.withUnsafeBufferPointer { ring.write($0) } == 4)
        #expect(ring.available == 4)
        let (out, n) = readAll(ring, frames: 6)
        #expect(n == 4)
        #expect(out[0][3] == 1 && out[0][4] == -9) // the rest is left to the caller
        #expect(ring.available == 0)
        _ = six.withUnsafeBufferPointer { ring.write($0) }
        ring.drain()
        #expect(ring.available == 0)
    }

    @Test func monoGoesToBothOutputs() {
        let ring = AudioRing(channels: 1, minimumCapacity: 4)
        _ = [Float](arrayLiteral: 0.25, 0.5).withUnsafeBufferPointer { ring.write($0) }
        let (out, n) = readAll(ring, frames: 2)
        #expect(n == 2)
        #expect(out[0] == [0.25, 0.5] && out[1] == [0.25, 0.5])
    }
}
