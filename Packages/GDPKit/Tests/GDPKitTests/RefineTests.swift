import Foundation
import Testing
@testable import GDPKit

/// Opaque BGRA for a `width` × `height` tile, every pixel different.
private func tilePixels(_ width: Int, _ height: Int, seed: UInt8) -> [UInt8] {
    (0..<width * height).flatMap { i -> [UInt8] in
        [UInt8(truncatingIfNeeded: i &* 7 &+ Int(seed)), UInt8(truncatingIfNeeded: i &* 13), seed, 0xff]
    }
}

private func refineHost() throws -> GDPTestHost {
    var hc = GDPTestHost.Configuration()
    hc.capabilities = [GDPSession.Capability.refine]
    return try GDPTestHost(hc)
}

@Suite("Lossless refinement (§7.8, §9.5)", .serialized)
struct RefineTests {
    @Test func layersArriveWithTheirFrames() async throws {
        let host = try refineHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.refine] }
        defer { withExtendedLifetime(session) {} }
        #expect(rec.snapshot.accept?.capabilities == [GDPSession.Capability.refine])

        let base = randomFrame(20_000)
        let a = GDPSession.RefineRect(x: 16, y: 32, width: 16, height: 16)
        let b = GDPSession.RefineRect(x: 100, y: 0, width: 5, height: 3) // odd widths too
        let pixels = tilePixels(16, 16, seed: 1) + tilePixels(5, 3, seed: 2)
        let clear = GDPSession.RefineRect(x: 0, y: 0, width: 64, height: 64)
        host.sendRefinedFrame(base, keyframe: true, reset: true, clears: [clear], tiles: [a, b], bgra: pixels)
        // Plain frames go as containers with an empty layer.
        let plain = randomFrame(3000)
        host.sendVideoFrame(plain, keyframe: false)
        // A layer-only frame: no video, just tiles.
        let c = GDPSession.RefineRect(x: 200, y: 100, width: 8, height: 8)
        host.sendRefinedFrame([], keyframe: false, tiles: [c], bgra: tilePixels(8, 8, seed: 3))

        #expect(await eventually { rec.snapshot.frames.count == 3 })
        let f = rec.snapshot.frames
        #expect(f[0].data == base && f[0].keyframe)
        #expect(f[0].layer == Recorder.Layer(reset: true, clears: [clear], tiles: [a, b], bgra: pixels))
        #expect(f[1].data == plain)
        #expect(f[1].layer == Recorder.Layer(reset: false, clears: [], tiles: [], bgra: []))
        #expect(f[2].data.isEmpty && !f[2].keyframe)
        #expect(f[2].layer?.tiles == [c] && f[2].layer?.bgra == tilePixels(8, 8, seed: 3))
        #expect(await eventually { host.observed.lastHighestFrameID == 2 })
        #expect(host.observed.lostFrameIDs.isEmpty)
    }

    @Test func withoutTheCapabilityFramesAreBare() async throws {
        let host = try refineHost()
        let rec = Recorder()
        let session = try await connected(host, rec) // refine not offered
        defer { withExtendedLifetime(session) {} }
        let frame = randomFrame(5000)
        host.sendVideoFrame(frame, keyframe: true)
        #expect(await eventually { rec.snapshot.frames.count == 1 })
        #expect(rec.snapshot.frames[0].data == frame && rec.snapshot.frames[0].layer == nil)
        session.setRefinePaused(true) // nothing to send it to
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.observed.refinePauses == 0)
    }

    @Test func aMalformedContainerIsDroppedAndReportedLost() async throws {
        let host = try refineHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.refine] }
        defer { withExtendedLifetime(session) {} }
        host.sendVideoFrame(randomFrame(3000), keyframe: true)          // 0
        host.sendRawVideo(randomFrame(3000), keyframe: false)           // 1: not a container
        var header = [UInt8](repeating: 0, count: 16)                   // 2: claims tiles past the 64 MiB bound
        header[0] = 0x52
        header[1] = 1
        header[6] = 1 // tile_count 1
        let huge: [UInt8] = [0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]        // a 65535 × 65535 tile
        host.sendRawVideo(header + huge, keyframe: false)
        host.sendVideoFrame(randomFrame(3000), keyframe: true)          // 3
        #expect(await eventually { rec.snapshot.frames.map(\.id) == [0, 3] })
        #expect(await eventually { Set(host.observed.lostFrameIDs).isSuperset(of: [1, 2]) })
    }

    @Test func aPauseIsSentAndSentAgainOnTheNextConnection() async throws {
        let host = try refineHost()
        let rec = Recorder()
        let session = try await connected(host, rec) { $0.capabilities = [GDPSession.Capability.refine] }
        defer { withExtendedLifetime(session) {} }
        session.setRefinePaused(true)
        #expect(await eventually { host.observed.refinePauses == 1 && host.observed.refinePaused })
        session.setRefinePaused(true) // no change: nothing sent
        session.setRefinePaused(false)
        #expect(await eventually { host.observed.refinePauses == 2 && !host.observed.refinePaused })

        // Paused before connecting: said right after SessionAccept.
        let host2 = try refineHost()
        let rec2 = Recorder()
        let session2 = GDPSession(handlers: rec2.handlers())
        defer { withExtendedLifetime(session2) {} }
        session2.setRefinePaused(true)
        var config = host2.sessionConfiguration(codecs: ["h264"])
        config.capabilities = [GDPSession.Capability.refine]
        try session2.connect(config)
        #expect(await eventually { host2.observed.refinePauses == 1 && host2.observed.refinePaused })
    }
}
