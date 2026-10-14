import AVFoundation
import Foundation
import Testing
@testable import SpectreKit

/// Renders `frames` from the pipeline as the real-time callback would, into
/// two non-interleaved channels.
private func render(_ pipeline: AudioPipeline, frames: Int, hostTime: UInt64 = 0) -> (left: [Float], right: [Float], silent: Bool) {
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer {
        for b in abl { b.mData?.deallocate() }
        free(abl.unsafeMutablePointer)
    }
    for c in 0..<2 {
        abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                             mData: UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 4))
    }
    let silent = pipeline.render(frames: frames, into: abl, hostTime: hostTime)
    func channel(_ c: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: abl[c].mData!.assumingMemoryBound(to: Float.self), count: frames))
    }
    return (channel(0), channel(1), silent)
}

private func feed(_ pipeline: AudioPipeline, _ packets: [[UInt8]], from first: Int, _ indices: some Sequence<Int>, now: Double = 0) {
    for i in indices {
        packets[i].withUnsafeBytes {
            pipeline.receive(sequence: UInt16(truncatingIfNeeded: first + i), pts: UInt32(truncatingIfNeeded: i * 10_000),
                             opus: $0, now: now)
        }
    }
}

/// A live link: every 10 ms one packet arrives (from `packets`, numbered
/// from `first`, except those in `lost`), then the pipeline pumps and renders
/// 480 frames, like a device with a 10 ms buffer.
private struct Link {
    let pipeline: AudioPipeline
    let packets: [[UInt8]]
    var first = 0
    var next = 0
    var lost: Set<Int> = []
    var left: [Float] = []
    var right: [Float] = []

    mutating func deliver(_ n: Int) {
        let end = min(next + n, packets.count)
        feed(pipeline, packets, from: first, (next..<end).filter { !lost.contains($0) })
        next = end
    }

    mutating func play(ms: Int, sending: Bool = true) {
        for _ in 0..<(ms / 10) {
            if sending { deliver(1) }
            pipeline.pump(now: 0)
            let r = render(pipeline, frames: 480)
            left += r.left
            right += r.right
        }
    }
}

@Suite("Audio playback")
struct AudioPlaybackTests {
    @Test func silentUntilBufferedThenTheTone() throws {
        let pipeline = try #require(AudioPipeline(format: .session))
        var link = Link(pipeline: pipeline, packets: opusTone(packets: 60))
        #expect(render(pipeline, frames: 480).silent)
        link.play(ms: 50)
        // 5 of 6 packets: still buffering, all silence.
        #expect(link.left.allSatisfy { $0 == 0 })
        link.play(ms: 550)
        // Starts as the 6th packet arrives, in the 6th render.
        #expect(link.left[..<2400].allSatisfy { $0 == 0 })
        #expect(link.left[2400..<2880].contains { $0 != 0 })
        #expect(abs(frequency(link.left[4800..<24000], sampleRate: 48000) - 440) < 3)
        #expect(abs(frequency(link.right[4800..<24000], sampleRate: 48000) - 660) < 3)
        let s = pipeline.statistics
        #expect(s.counters.played >= 54)
        #expect(s.counters.concealed == 0 && s.counters.underruns == 0 && s.counters.dropped == 0)
        #expect(s.decodeErrors == 0)
    }

    @Test func aLostPacketIsConcealedWithoutAGap() throws {
        let pipeline = try #require(AudioPipeline(format: .session))
        var link = Link(pipeline: pipeline, packets: opusTone(packets: 60), lost: [20])
        link.play(ms: 500)
        let s = pipeline.statistics
        #expect(s.counters.concealed == 1)
        #expect(s.counters.underruns == 0)
        // No silent stretch once playback has started: the concealed 10 ms
        // carries on the tone.
        let playing = link.left[3000...]
        var quiet = 0, longest = 0
        for x in playing {
            quiet = abs(x) < 0.05 ? quiet + 1 : 0
            longest = max(longest, quiet)
        }
        #expect(longest < 60) // a 440 Hz sine is under 0.05 for ~35 samples around each zero crossing
    }

    /// The host stops sending: the output runs dry, and the pipeline
    /// re-buffers and re-anchors on the next packets whatever their `seq`.
    @Test func underrunThenRebuffer() throws {
        let pipeline = try #require(AudioPipeline(format: .session))
        var link = Link(pipeline: pipeline, packets: opusTone(packets: 60))
        link.play(ms: 200)
        link.play(ms: 150, sending: false)
        var s = pipeline.statistics
        #expect(s.counters.played == 20)
        #expect(s.counters.underruns == 1)
        #expect(!s.isPlaying)
        #expect(s.counters.concealed == 0)
        // Resumes 1000 packets later (the host's seq kept running, say).
        link.first = 1000
        let resumed = link.left.count
        link.play(ms: 300)
        s = pipeline.statistics
        #expect(s.counters.played >= 44)
        #expect(s.counters.concealed == 0)
        #expect(s.counters.underruns == 1)
        #expect(s.counters.resyncs == 0) // not playing when it arrived: no resync needed
        // Silent while re-buffering, then the tone.
        #expect(link.left[resumed..<(resumed + 2400)].allSatisfy { $0 == 0 })
        #expect(link.left[(resumed + 4800)...].map(abs).max()! > 0.4)
    }

    /// A render bigger than the lookahead (iOS with the screen locked) is
    /// the pump's to catch up on, not an underrun.
    @Test func largeRendersAreNotUnderruns() throws {
        let packets = opusTone(packets: 12)
        let pipeline = try #require(AudioPipeline(format: .session))
        feed(pipeline, packets, from: 0, 0..<12)
        pipeline.pump(now: 0)
        _ = render(pipeline, frames: 2048) // ran dry: the ring held two packets
        pipeline.pump(now: 0)
        #expect(pipeline.statistics.counters.underruns == 0)
        #expect(pipeline.ring.available >= 2048)
        #expect(!render(pipeline, frames: 2048).silent)
        #expect(pipeline.statistics.counters.underruns == 0)
    }

    @Test func playoutTimeIsMeasuredAgainstPTS() throws {
        let packets = opusTone(packets: 20)
        let pipeline = try #require(AudioPipeline(format: .session))
        pipeline.setOutputLatency(0.010)
        feed(pipeline, packets, from: 0, 0..<12)
        pipeline.pump(now: 0)
        // Render the first 480 frames "at" host time t; the next pump
        // measures (t + 10 ms output latency) − pts of the first sample.
        let t = AVAudioTime.hostTime(forSeconds: 5)
        _ = render(pipeline, frames: 480, hostTime: t)
        pipeline.pump(now: 0)
        // The first packet starts 2.5 ms late in pts (its pre-skip was trimmed).
        let expected = Int32(5_000_000 + 10_000 - 2_500)
        let got = try #require(pipeline.statistics.playoutMinusPTS)
        #expect(abs(got - expected) <= 1)
        // Ten packets later: pts has advanced by as much as host time.
        for i in 1...8 {
            _ = render(pipeline, frames: 480, hostTime: AVAudioTime.hostTime(forSeconds: 5 + Double(i) * 0.01))
            pipeline.pump(now: 0)
        }
        #expect(abs(try #require(pipeline.statistics.playoutMinusPTS) - expected) <= 2)
    }

    @Test func flushStartsOver() throws {
        let pipeline = try #require(AudioPipeline(format: .session))
        var link = Link(pipeline: pipeline, packets: opusTone(packets: 40))
        link.play(ms: 100)
        pipeline.flush()
        #expect(render(pipeline, frames: 480).silent) // the renderer empties the ring
        #expect(!pipeline.statistics.isPlaying)
        link.first = 100
        link.play(ms: 150)
        #expect(link.left.suffix(2400).map(abs).max()! > 0.4)
    }
}

@Suite("Audio player (offline rendering)")
struct SessionAudioPlayerTests {
    @Test func playsThroughTheEngineAndMutes() throws {
        let packets = opusTone(packets: 100)
        let player = try #require(SessionAudioPlayer(format: .session, output: .manual))
        player.start()
        #expect(player.failure == nil)
        defer { player.stop() }
        var sent = 0
        func render(_ frames: Int) throws -> (left: [Float], right: [Float]) {
            var left: [Float] = [], right: [Float] = []
            for _ in 0..<(frames / 480) {
                if sent < packets.count {
                    packets[sent].withUnsafeBytes { player.receive(sequence: UInt16(sent), pts: UInt32(sent * 10_000), opus: $0) }
                    sent += 1
                }
                let out = try player.renderOffline(frames: 480)
                left += UnsafeBufferPointer(start: out.floatChannelData![0], count: 480)
                right += UnsafeBufferPointer(start: out.floatChannelData![1], count: 480)
            }
            return (left, right)
        }
        let (left, right) = try render(24000)
        #expect(abs(frequency(left[4800..<19200], sampleRate: 48000) - 440) < 3)
        #expect(abs(frequency(right[4800..<19200], sampleRate: 48000) - 660) < 3)
        // The main mixer leaves the level alone.
        let peak = left[4800..<19200].map(abs).max()!
        #expect(peak > 0.45 && peak < 0.56)

        player.isMuted = true
        // The mixer fades its volume out over about 30 ms.
        #expect(try render(9600).left.dropFirst(1920).allSatisfy { $0 == 0 })
        // Still pulled through while muted, so unmuting plays what is current.
        #expect(player.pipeline.statistics.counters.played >= 64)
        player.isMuted = false
        #expect(try render(4800).left.map(abs).max()! > 0.4)
        #expect(player.pipeline.statistics.counters.underruns == 0)
    }

    @Test func monoPlaysOnBothChannels() throws {
        let format = try #require(OpusFormat(sampleRate: 48000, channels: 1, frameMilliseconds: 10))
        let packets = opusTone(packets: 40, format: format)
        let player = try #require(SessionAudioPlayer(format: format, output: .manual))
        player.start()
        defer { player.stop() }
        var left: [Float] = [], right: [Float] = []
        for (i, p) in packets.prefix(20).enumerated() {
            p.withUnsafeBytes { player.receive(sequence: UInt16(i), pts: UInt32(i * 10_000), opus: $0) }
            let out = try player.renderOffline(frames: 480)
            left += UnsafeBufferPointer(start: out.floatChannelData![0], count: 480)
            right += UnsafeBufferPointer(start: out.floatChannelData![1], count: 480)
        }
        #expect(left == right)
        #expect(abs(frequency(left[3360..<9600], sampleRate: 48000) - 440) < 4)
    }
}
