import CoreVideo
import Metal
import Synchronization
import Testing
@testable import SpectreKit

@Suite("Annex B")
struct AnnexBTests {
    @Test func splitsThreeAndFourByteStartCodes() {
        let bytes: [UInt8] = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 6]
        let units = AnnexB.nalUnits(in: bytes)
        #expect(units.map { Array(bytes[$0]) } == [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 6]])
    }

    @Test func ignoresLeadingGarbageAndTrailingZeros() {
        let bytes: [UInt8] = [9, 9, 0, 0, 1, 0x41, 7, 0, 0]
        #expect(AnnexB.nalUnits(in: bytes).map { Array(bytes[$0]) } == [[0x41, 7]])
    }

    @Test func nalKinds() {
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x67) == .parameterSet(index: 0))
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x68) == .parameterSet(index: 1))
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x65) == .keyframeSlice)
        #expect(VideoCodec.h264.kind(ofNALHeader: 0x41) == .other)
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x40) == .parameterSet(index: 0)) // VPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x42) == .parameterSet(index: 1)) // SPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x44) == .parameterSet(index: 2)) // PPS
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x26) == .keyframeSlice)          // IDR_W_RADL
        #expect(VideoCodec.h265.kind(ofNALHeader: 0x02) == .other)                  // TRAIL_R
    }
}

@Suite("Colour (gdp-spec.md §7.3)")
struct ColorTests {
    let bt601 = ColorDescription.blockCodecDefault

    @Test func limitedRangeEndpoints() {
        #expect(bt601.rgb(y: 16, cb: 128, cr: 128) == SIMD3(0, 0, 0))
        #expect(bt601.rgb(y: 235, cb: 128, cr: 128) == SIMD3(255, 255, 255))
        #expect(bt601.rgb(y: 126, cb: 128, cr: 128) == SIMD3(128, 128, 128))
    }

    /// The test pattern's RGB -> Y'CbCr (BT.601 limited) followed by the
    /// presenter's matrix lands back on the same RGB, within rounding.
    @Test(arguments: TestPatternGenerator.bars)
    func barsRoundTrip(rgb: SIMD3<UInt8>) {
        let r = Double(rgb.x) / 255, g = Double(rgb.y) / 255, b = Double(rgb.z) / 255
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let code = { (v: Double) in UInt8((v).rounded()) }
        let out = bt601.rgb(y: code(16 + 219 * y), cb: code(128 + 224 * (b - y) / 1.772),
                            cr: code(128 + 224 * (r - y) / 1.402))
        for i in 0..<3 { #expect(abs(Int(out[i]) - Int(rgb[i])) <= 2) }
    }

    @Test func chromaSiting() {
        #expect(bt601.chromaOffset(lumaWidth: 1920, lumaHeight: 1080) == SIMD2(0.5 / 1920, 0.5 / 1080))
        #expect(ColorDescription.pyrowaveDefault.chromaOffset(lumaWidth: 1920, lumaHeight: 1080) == .zero)
    }

    @Test func fitViewportLetterboxes() {
        let v = VideoRenderer.fitViewport(video: CGSize(width: 1920, height: 1080), drawable: CGSize(width: 1000, height: 1000))
        #expect(v.width == 1000 && v.height == 563 && v.originX == 0 && v.originY == 219)
    }
}

/// Everything at once: synthetic picture -> VideoToolbox encode -> Annex B
/// -> VideoDecoder -> zero-copy textures -> video shader -> read back.
@Suite("Decode and present", .serialized)
struct PipelineTests {
    @Test(arguments: VideoCodec.allCases)
    func decodedBarsRenderTheirColours(codec: VideoCodec) throws {
        let width = 1920, height = 1080
        let stream = try TestStreamEncoder.encode(codec: codec, width: width, height: height, frameCount: 10,
                                                  bitrate: 20_000_000)
        #expect(stream.accessUnits.count == 10)
        #expect(stream.accessUnits[0].keyframe)
        #expect(stream.accessUnits.dropFirst().allSatisfy { !$0.keyframe })

        // The Annex B byte stream splits back into the same access units.
        let reparsed = TestStream(annexB: stream.annexB, codec: codec, width: width, height: height, framesPerSecond: 60)
        #expect(reparsed.accessUnits.map(\.bytes) == stream.accessUnits.map(\.bytes))
        #expect(reparsed.accessUnits.map(\.keyframe) == stream.accessUnits.map(\.keyframe))

        let frames = Mutex<[DecodedFrame]>([])
        let decoder = VideoDecoder(codec: codec, onFrame: { f in frames.withLock { $0.append(f) } })
        for (i, au) in stream.accessUnits.enumerated() {
            try au.bytes.withUnsafeBytes { try decoder.decode($0, pts: UInt32(i * 16_667)) }
        }
        decoder.flush()
        let decoded = frames.withLock { $0 }
        #expect(decoded.count == 10)
        let first = try #require(decoded.first)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == width)
        #expect(CVPixelBufferGetHeight(first.pixelBuffer) == height)
        print("\(codec.displayName): hardware decoder \(decoder.isHardwareAccelerated), "
            + String(format: "first frame decode %.2f ms", first.decodeDuration * 1000))

        let renderer = try VideoRenderer()
        let textures = try renderer.textures(for: first)
        #expect(textures.isZeroCopy, "textures must be views of the decoder's IOSurface")

        let target = try #require(renderer.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VideoRenderer.colorPixelFormat, width: width,
                                                             height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return d
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let cb = try #require(renderer.commandQueue.makeCommandBuffer())
        renderer.encode(textures, color: .blockCodecDefault, viewport: VideoRenderer.fitViewport(
            video: CGSize(width: width, height: height), drawable: CGSize(width: width, height: height)),
            pass: pass, into: cb)
        cb.commit()
        cb.waitUntilCompleted()

        // Sample the middle of each bar, away from its edges.
        for (i, expected) in TestPatternGenerator.bars.enumerated() {
            let x = (2 * i + 1) * width / 16
            let y = Int(Double(height) * TestPatternGenerator.barsHeightFraction / 2)
            var bgra = [UInt8](repeating: 0, count: 4)
            target.getBytes(&bgra, bytesPerRow: 4 * width, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let got = SIMD3(bgra[2], bgra[1], bgra[0])
            for c in 0..<3 {
                #expect(abs(Int(got[c]) - Int(expected[c])) <= 6, "bar \(i): got \(got), expected \(expected)")
            }
        }
    }
}
