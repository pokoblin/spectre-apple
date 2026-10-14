import CoreGraphics
import CoreVideo
import Metal
import Testing
@testable import SpectreKit
#if os(macOS)
import AppKit
#endif

/// Premultiplied BGRA pixels, B G R A in memory.
private let red: [UInt8] = [0, 0, 255, 255]
private let green: [UInt8] = [0, 255, 0, 255]
private let halfBlue: [UInt8] = [128, 0, 0, 128]

/// 4×4: (0, 0) opaque red, the hotspot (1, 1) opaque green, the rest half-transparent blue.
private func testCursor() throws -> CursorImage {
    var bytes: [UInt8] = []
    for y in 0..<4 {
        for x in 0..<4 { bytes += (x, y) == (0, 0) ? red : (x, y) == (1, 1) ? green : halfBlue }
    }
    return try #require(CursorImage(width: 4, height: 4, hotspotX: 1, hotspotY: 1, bgra: bytes))
}

@Suite("Cursor image (gdp-spec.md §7.4)")
struct CursorImageTests {
    @Test func rejectsWhatTheClientMustIgnore() {
        let side = CursorImage.maxSide
        #expect(CursorImage(width: side + 1, height: 1, hotspotX: 0, hotspotY: 0,
                            bgra: .init(repeating: 0, count: (side + 1) * 4)) == nil)
        #expect(CursorImage(width: 1, height: side + 1, hotspotX: 0, hotspotY: 0,
                            bgra: .init(repeating: 0, count: (side + 1) * 4)) == nil)
        #expect(CursorImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, bgra: .init(repeating: 0, count: 15)) == nil)
        #expect(CursorImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, bgra: .init(repeating: 0, count: 17)) == nil)
        #expect(CursorImage(width: 1, height: 0, hotspotX: 0, hotspotY: 0, bgra: []) == nil)
        #expect(CursorImage(width: 0, height: 1, hotspotX: 0, hotspotY: 0, bgra: []) == nil)
        #expect(CursorImage(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: [0, 0, 0, 0]) == nil)
        #expect(CursorImage(width: side, height: side, hotspotX: 0, hotspotY: 0,
                            bgra: .init(repeating: 0, count: side * side * 4)) != nil)
    }

    @Test func zeroByZeroIsHidden() throws {
        let image = try #require(CursorImage(width: 0, height: 0, hotspotX: 5, hotspotY: 5, bgra: []))
        #expect(image.isHidden)
        #expect(image.cgImage == nil)
        #expect(image.hotspot == .zero)
        #expect(image == CursorImage.hidden)
        #expect(CursorImage.hidden.isHidden)
    }

    @Test func hotspotIsClampedIntoTheImage() throws {
        let bytes = [UInt8](repeating: 0, count: 10 * 6 * 4)
        #expect(try #require(CursorImage(width: 10, height: 6, hotspotX: 3, hotspotY: 4, bgra: bytes)).hotspot
            == CGPoint(x: 3, y: 4))
        #expect(try #require(CursorImage(width: 10, height: 6, hotspotX: 10, hotspotY: 99, bgra: bytes)).hotspot
            == CGPoint(x: 9, y: 5))
    }

    @Test func cgImageHoldsTheSamePremultipliedPixels() throws {
        let image = try testCursor()
        let cg = try #require(image.cgImage)
        #expect(cg.width == 4 && cg.height == 4)
        var out = [UInt8](repeating: 0xEE, count: 4 * 4 * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        try out.withUnsafeMutableBytes { buf in
            let ctx = try #require(CGContext(data: buf.baseAddress, width: 4, height: 4, bitsPerComponent: 8,
                                             bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: info))
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        #expect(out == image.bgra)
    }

    @Test func systemCursorScaleFollowsThePictureWithinBounds() throws {
        let image = try testCursor() // 4 px
        #expect(image.systemCursorScale(pointsPerPixel: 2.5) == 2.5)  // 10 pt
        #expect(image.systemCursorScale(pointsPerPixel: 1) == 2)      // 4 pt → 8 pt
        #expect(image.systemCursorScale(pointsPerPixel: 100) == 64)   // 400 pt → 256 pt
        #expect(image.systemCursorScale(pointsPerPixel: .nan) == 2)   // treated as 1, then the lower bound
    }

    #if os(macOS)
    @MainActor
    @Test func nsCursorIsScaledWithThePicture() throws {
        let bytes = [UInt8](repeating: 0, count: 32 * 16 * 4)
        let image = try #require(CursorImage(width: 32, height: 16, hotspotX: 4, hotspotY: 6, bgra: bytes))
        let cursor = image.nsCursor(pointsPerPixel: 0.5)
        #expect(cursor.image.size == NSSize(width: 16, height: 8))
        #expect(cursor.hotSpot == NSPoint(x: 2, y: 3))
        let rep = try #require(cursor.image.representations.first)
        #expect(rep.pixelsWide == 32 && rep.pixelsHigh == 16)

        // 32 px at 10 pt each would be 320 pt: clamped to 256.
        let big = image.nsCursor(pointsPerPixel: 10)
        #expect(big.image.size == NSSize(width: 256, height: 128))
        #expect(big.hotSpot == NSPoint(x: 32, y: 48))

        let hidden = CursorImage.hidden.nsCursor(pointsPerPixel: 2)
        #expect(hidden.image.size == NSSize(width: 1, height: 1))
    }
    #endif
}

@Suite("Cursor overlay", .serialized)
struct CursorOverlayTests {
    @Test func rectScalesWithThePictureAroundTheHotspot() throws {
        let image = try testCursor()
        // 100×50 output in a 300×300 drawable: 3 drawable pixels per output pixel, bars above and below.
        let viewport = VideoRenderer.fitViewport(video: CGSize(width: 100, height: 50),
                                                 drawable: CGSize(width: 300, height: 300))
        #expect(viewport.originX == 0 && viewport.originY == 75 && viewport.width == 300 && viewport.height == 150)
        let rect = VideoRenderer.cursorRect(image: image, at: CGPoint(x: 0.5, y: 0.5),
                                            videoSize: CGSize(width: 100, height: 50), viewport: viewport)
        #expect(rect == CGRect(x: 147, y: 147, width: 12, height: 12))
        // Positions outside 0...1 are clamped.
        let clamped = VideoRenderer.cursorRect(image: image, at: CGPoint(x: -1, y: 2),
                                               videoSize: CGSize(width: 100, height: 50), viewport: viewport)
        #expect(clamped.origin == CGPoint(x: -3, y: 222))
    }

    /// A uniform grey NV12 frame (limited-range Y' 126: R'G'B' 128) in an
    /// IOSurface-backed pixel buffer, as the decoder would hand over.
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

    private func render(position: CGPoint, renderer: VideoRenderer, frame: DecodedFrame,
                        cursor: CursorTexture?) throws -> (Int, Int) -> [UInt8] {
        let size = 300
        let target = try #require(renderer.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VideoRenderer.colorPixelFormat, width: size,
                                                             height: size, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return d
        }()))
        let videoSize = CGSize(width: 100, height: 50)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let cb = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(try renderer.textures(for: frame), color: .blockCodecDefault, displaySize: videoSize,
                        viewport: VideoRenderer.fitViewport(video: videoSize, drawable: CGSize(width: size, height: size)),
                        cursor: cursor.map { CursorOverlay(texture: $0, position: position) }, pass: pass, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return { x, y in
            var bgra = [UInt8](repeating: 0, count: 4)
            target.getBytes(&bgra, bytesPerRow: 4 * size, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return bgra
        }
    }

    private func expectPixel(_ got: [UInt8], _ expected: [UInt8], _ what: String) {
        for c in 0..<4 { #expect(abs(Int(got[c]) - Int(expected[c])) <= 2, "\(what): got \(got), expected \(expected)") }
    }

    @Test func cursorIsDrawnOverThePictureAtItsHotspot() throws {
        let renderer = try VideoRenderer()
        let frame = try greyFrame(width: 112, height: 64) // coded larger than the 100×50 picture, like real streams
        let texture = try #require(renderer.makeCursorTexture(try testCursor()))
        let pixel = try render(position: CGPoint(x: 0.5, y: 0.5), renderer: renderer, frame: frame, cursor: texture)

        let grey: [UInt8] = [128, 128, 128, 255]
        // 128 + 128 × (1 − 128/255) in blue, 128 × (1 − 128/255) in green and red.
        let blended: [UInt8] = [192, 64, 64, 255]
        // The hotspot pixel's top-left corner is the position, (150, 150); each cursor pixel is 3×3.
        for (x, y) in [(147, 147), (149, 149)] { expectPixel(pixel(x, y), red, "pixel (0, 0) at \(x), \(y)") }
        for (x, y) in [(150, 150), (152, 152)] { expectPixel(pixel(x, y), green, "hotspot at \(x), \(y)") }
        for (x, y) in [(153, 150), (158, 158), (147, 158)] { expectPixel(pixel(x, y), blended, "blend at \(x), \(y)") }
        for (x, y) in [(146, 146), (159, 159), (146, 150), (150, 159)] {
            expectPixel(pixel(x, y), grey, "picture at \(x), \(y)")
        }

        // Without a cursor the same frame is plain picture.
        let plain = try render(position: CGPoint(x: 0.5, y: 0.5), renderer: renderer, frame: frame, cursor: nil)
        expectPixel(plain(150, 150), grey, "no cursor")
    }

    @Test func cursorIsClippedToThePicture() throws {
        let renderer = try VideoRenderer()
        let frame = try greyFrame(width: 100, height: 50)
        let texture = try #require(renderer.makeCursorTexture(try testCursor()))
        // At the top edge the hotspot is at y 75, so cursor row 0 (y 72..<75) lies on the black bar.
        let pixel = try render(position: CGPoint(x: 0.5, y: 0), renderer: renderer, frame: frame, cursor: texture)
        let black: [UInt8] = [0, 0, 0, 255]
        expectPixel(pixel(148, 73), black, "clipped cursor row on the bar")
        expectPixel(pixel(151, 74), black, "clipped cursor row on the bar")
        expectPixel(pixel(151, 76), green, "hotspot row inside the picture")
        expectPixel(pixel(148, 76), [192, 64, 64, 255], "blend inside the picture")
    }
}
