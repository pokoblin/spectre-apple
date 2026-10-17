import CoreVideo
import GDPKit
import Metal
import Synchronization
import Testing
@testable import SpectreKit

/// Opaque BGRA, every pixel different.
private func tile(_ width: Int, _ height: Int, seed: UInt8) -> [UInt8] {
    (0..<width * height).flatMap { i -> [UInt8] in
        [UInt8(truncatingIfNeeded: i &* 7 &+ Int(seed)), UInt8(truncatingIfNeeded: i &* 13 &+ 1), seed, 0xff]
    }
}

private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> GDPSession.RefineRect {
    GDPSession.RefineRect(x: UInt16(x), y: UInt16(y), width: UInt16(w), height: UInt16(h))
}

private func apply(_ plane: RefinementPlane, reset: Bool = false, clears: [GDPSession.RefineRect] = [],
                   tiles: [GDPSession.RefineRect] = [], bgra: [UInt8] = []) {
    bgra.withUnsafeBytes {
        plane.apply(GDPSession.RefineLayer(reset: reset, clears: clears, tiles: tiles, bgra: $0))
    }
}

private let clear: [UInt8] = [0, 0, 0, 0]

@Suite("Lossless refinement's overlay plane (§9.6)")
struct RefinementPlaneTests {
    @Test func layersApplyInOrderClippedToThePlane() {
        let plane = RefinementPlane()
        apply(plane, tiles: [rect(0, 0, 2, 2)], bgra: tile(2, 2, seed: 1)) // before any size: nowhere to go
        plane.resize(width: 64, height: 32)
        #expect(plane.pixel(x: 0, y: 0) == clear)

        let a = tile(8, 4, seed: 9)
        apply(plane, tiles: [rect(10, 5, 8, 4)], bgra: a)
        #expect(plane.pixel(x: 10, y: 5) == Array(a[0..<4]))
        #expect(plane.pixel(x: 17, y: 8) == Array(a[(3 * 8 + 7) * 4..<(3 * 8 + 7) * 4 + 4]))
        #expect(plane.pixel(x: 9, y: 5) == clear && plane.pixel(x: 18, y: 8) == clear)

        // Past the edge: only what is inside lands, from the right offset in the tile.
        let b = tile(8, 8, seed: 3)
        apply(plane, tiles: [rect(60, 28, 8, 8)], bgra: b)
        #expect(plane.pixel(x: 63, y: 31) == Array(b[(3 * 8 + 3) * 4..<(3 * 8 + 3) * 4 + 4]))

        // Clears go before the frame's tiles.
        let c = tile(2, 2, seed: 5)
        apply(plane, clears: [rect(10, 5, 8, 4)], tiles: [rect(12, 6, 2, 2)], bgra: c)
        #expect(plane.pixel(x: 10, y: 5) == clear)
        #expect(plane.pixel(x: 12, y: 6) == Array(c[0..<4]))
        // A reset drops everything before the frame's tiles.
        apply(plane, reset: true, tiles: [rect(0, 0, 2, 2)], bgra: c)
        #expect(plane.pixel(x: 12, y: 6) == clear && plane.pixel(x: 63, y: 31) == clear)
        #expect(plane.pixel(x: 1, y: 1) == Array(c[12..<16]))
        let counters = plane.counters
        // Every layer counts; the first one's tile had no plane to land on.
        #expect(counters.layers == 5 && counters.resets == 1 && counters.tiles == 4)

        // A new size starts transparent.
        plane.resize(width: 32, height: 32)
        #expect(plane.pixel(x: 1, y: 1) == clear)
    }

    @Test func onlyWhatChangedIsUploaded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plane = RefinementPlane()
        #expect(plane.takeUpload(device: device) == nil)
        plane.resize(width: 1920, height: 1080)
        let first = try #require(plane.takeUpload(device: device))
        #expect(first.width == 1920 && first.pieces.count == 1 && first.pieces[0].region.size.width == 1920)
        #expect(plane.takeUpload(device: device) == nil)

        // Two small tiles far apart: two small pieces, not all between them.
        apply(plane, tiles: [rect(0, 0, 4, 4), rect(1900, 1060, 4, 4)], bgra: tile(4, 4, seed: 1) + tile(4, 4, seed: 2))
        let two = try #require(plane.takeUpload(device: device))
        #expect(two.pieces.map(\.region.origin.x) == [0, 1900] && two.buffer.length == 2 * 4 * 4 * 4)
        // The second piece's pixels, as they are in the plane.
        let p = two.buffer.contents().advanced(by: two.pieces[1].offset).assumingMemoryBound(to: UInt8.self)
        #expect(Array(UnsafeBufferPointer(start: p, count: 4)) == Array(tile(4, 4, seed: 2)[0..<4]))

        // Many scattered changes merge into their bounds.
        for i in 0..<(RefinementPlane.maxDirtyRects + 1) {
            apply(plane, clears: [rect(i * 20, i, 2, 2)])
        }
        let merged = try #require(plane.takeUpload(device: device))
        #expect(merged.pieces.count == 1)
        #expect(merged.pieces[0].region.origin.x == 0 && merged.pieces[0].region.size.width == 64 * 20 + 2)
    }
}

@Suite("Lossless refinement on screen (§7.8)")
struct RefinementRenderTests {
    /// A uniform grey NV12 frame (limited-range Y' 126: R'G'B' 128).
    private func greyFrame(width: Int, height: Int) throws -> DecodedFrame {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                      kCVPixelBufferMetalCompatibilityKey: true]
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                    attrs as CFDictionary, &pb) == kCVReturnSuccess)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for (plane, value) in [(0, UInt8(126)), (1, UInt8(128))] {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return DecodedFrame(pixelBuffer: buffer, pts: 0, frameID: 0, sequence: 0, submitTime: 0, decodedTime: 0)
    }

    /// Draws `frame` (100×50, coded 112×64) at 1:1 with the plane over it, uploading what changed in it.
    private func render(_ renderer: VideoRenderer, _ frame: DecodedFrame, _ plane: RefinementPlane,
                        _ overlay: inout MTLTexture?) throws -> [UInt8] {
        let w = 100, h = 50
        let target = try #require(renderer.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VideoRenderer.colorPixelFormat, width: w,
                                                             height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return d
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let cb = try #require(renderer.commandQueue.makeCommandBuffer())
        if let upload = plane.takeUpload(device: renderer.device) {
            if overlay?.width != upload.width { overlay = renderer.makeOverlayTexture(width: upload.width, height: upload.height) }
            renderer.encodeUpload(upload, into: try #require(overlay), commandBuffer: cb)
        }
        let size = CGSize(width: w, height: h)
        renderer.encode(try renderer.textures(for: frame), color: .blockCodecDefault, displaySize: size,
                        viewport: VideoRenderer.fitViewport(video: size, drawable: size), overlay: overlay,
                        pass: pass, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bgra, bytesPerRow: 4 * w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bgra
    }

    @Test func tilesShowExactlyAndClearsShowThePictureAgain() throws {
        let renderer = try VideoRenderer()
        let frame = try greyFrame(width: 112, height: 64)
        let plane = RefinementPlane()
        plane.resize(width: 100, height: 50)
        var overlay: MTLTexture?
        func at(_ image: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(image[(y * 100 + x) * 4..<(y * 100 + x) * 4 + 4]) }
        func isGrey(_ p: [UInt8]) -> Bool { p[0...2].allSatisfy { abs(Int($0) - 128) <= 2 } && p[3] == 255 }

        let pixels = tile(10, 6, seed: 40)
        apply(plane, tiles: [rect(20, 10, 10, 6)], bgra: pixels)
        let shown = try render(renderer, frame, plane, &overlay)
        for y in 0..<6 {
            for x in 0..<10 {
                let i = (y * 10 + x) * 4
                #expect(at(shown, 20 + x, 10 + y) == Array(pixels[i..<i + 4]), "tile pixel (\(x), \(y))")
            }
        }
        #expect(isGrey(at(shown, 19, 10)) && isGrey(at(shown, 30, 15)) && isGrey(at(shown, 0, 0)))

        // Cleared in part: the picture there again, the rest still exact.
        apply(plane, clears: [rect(20, 10, 5, 6)])
        let after = try render(renderer, frame, plane, &overlay)
        #expect(isGrey(at(after, 20, 10)) && isGrey(at(after, 24, 15)))
        #expect(at(after, 25, 10) == Array(pixels[5 * 4..<5 * 4 + 4]))
    }
}

@Suite("Lossless refinement in a session (§7.8)", .serialized)
struct RefinementSessionTests {
    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func layerOnlyFramesChangeThePlaneAndAskForADraw() async throws {
        var hc = GDPTestHost.Configuration()
        hc.capabilities = [GDPSession.Capability.refine]
        hc.width = 64
        hc.height = 32
        let host = try GDPTestHost(hc)
        let remote = RemoteSession(mailbox: FrameMailbox(), stats: PlaybackStats(), audioOutput: .manual) {}
        let draws = Mutex(0)
        remote.onRefinementChanged = { draws.withLock { $0 += 1 } }
        let established = Mutex(false)
        remote.onStateChange = { if case .established = $0 { established.withLock { $0 = true } } }
        try remote.connect(host.sessionConfiguration(codecs: ["h264"]))
        defer { remote.close() }
        #expect(await until { established.withLock { $0 } })
        #expect(host.observed.capabilities.contains(GDPSession.Capability.refine))
        #expect(remote.refinement.size.width == 64 && remote.refinement.size.height == 32)

        // A real keyframe first: until one arrives, GDPKit drops the frames
        // after it, layer-only ones too, and reports them lost (§7.5).
        let stream = try TestStreamEncoder.encode(codec: .h264, width: 128, height: 64, frameCount: 1, bitrate: 500_000)
        let keyframe = try #require(stream.accessUnits.first)
        host.sendRefinedFrame(keyframe.bytes, keyframe: true, reset: true)
        let a = tile(4, 4, seed: 7)
        host.sendRefinedFrame([], keyframe: false, tiles: [rect(8, 8, 4, 4)], bgra: a)
        #expect(await until { remote.refinement.pixel(x: 8, y: 8) == Array(a[0..<4]) })
        #expect(await until { draws.withLock { $0 } == 1 })

        // Suspended (the app in the background): still applied, but no draw.
        remote.suspendVideo()
        host.sendRefinedFrame([], keyframe: false, clears: [rect(8, 8, 4, 4)])
        #expect(await until { remote.refinement.pixel(x: 8, y: 8) == clear })
        try await Task.sleep(for: .milliseconds(100))
        #expect(draws.withLock { $0 } == 1)

        // A pause asked for before connecting goes with SessionAccept.
        let host2 = try GDPTestHost(hc)
        let remote2 = RemoteSession(mailbox: FrameMailbox(), stats: PlaybackStats(), audioOutput: .manual) {}
        remote2.setRefinePaused(true)
        try remote2.connect(host2.sessionConfiguration(codecs: ["h264"]))
        defer { remote2.close() }
        #expect(await until { host2.observed.refinePaused })
    }
}
