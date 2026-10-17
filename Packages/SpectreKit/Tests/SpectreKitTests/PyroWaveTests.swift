import CoreVideo
import Foundation
import Metal
import PyroWave
import Synchronization
import Testing
@testable import SpectreKit

/// The port needs an Apple7 GPU (A14, M1) or later.
private let pyroWaveIsSupported: Bool = {
    guard let device = MTLCreateSystemDefaultDevice() else { return false }
    return pyrowave_device_is_supported(Unmanaged.passUnretained(device).toOpaque())
}()

@Suite("PyroWave library", .enabled(if: pyroWaveIsSupported, "no Apple7 GPU here"))
struct PyroWaveLibraryTests {
    @Test func theLinkedPortIsTheOneThePinnedCommitShips() {
        var major: UInt32 = 0, minor: UInt32 = 0, patch: UInt32 = 0
        pyrowave_get_api_version(&major, &minor, &patch)
        #expect((major, minor, patch) == (0, 5, 0))
    }

    /// Encodes a 4:2:0 frame on the CPU path, decodes it into Metal
    /// textures and checks the picture survived.
    @Test func aFrameRoundTrips() throws {
        let mtl = try #require(MTLCreateSystemDefaultDevice())
        var info = pyrowave_device_create_info()
        info.mtl_device = Unmanaged.passUnretained(mtl).toOpaque()
        var device: pyrowave_device?
        try #require(pyrowave_device_create(&info, &device) == PYROWAVE_SUCCESS)
        defer { pyrowave_device_destroy(device) }

        let (w, h) = (256, 128)
        var y = Self.luma(w, h), cb = [UInt8](repeating: 100, count: w * h / 4), cr = [UInt8](repeating: 160, count: w * h / 4)
        let planes = [y, cb, cr]
        let sizes = [(w, h), (w / 2, h / 2), (w / 2, h / 2)]

        var encoderInfo = pyrowave_encoder_create_info(device: device, width: Int32(w), height: Int32(h),
                                                       chroma: PYROWAVE_CHROMA_SUBSAMPLING_420)
        var encoder: pyrowave_encoder?
        try #require(pyrowave_encoder_create(&encoderInfo, &encoder) == PYROWAVE_SUCCESS)
        defer { pyrowave_encoder_destroy(encoder) }
        var rate = pyrowave_rate_control(maximum_bitstream_size: w * h) // 8 bits per pixel: near lossless
        let encoded = y.withUnsafeMutableBytes { y in
            cb.withUnsafeMutableBytes { cb in
                cr.withUnsafeMutableBytes { cr in
                    var buffer = pyrowave_cpu_buffer()
                    buffer.data = (y.baseAddress, cb.baseAddress, cr.baseAddress)
                    buffer.row_stride_in_bytes = (w, w / 2, w / 2)
                    buffer.plane_size_in_bytes = (y.count, cb.count, cr.count)
                    buffer.width = Int32(w)
                    buffer.height = Int32(h)
                    buffer.format = PYROWAVE_CPU_BUFFER_FORMAT_YUV420P
                    return pyrowave_encoder_encode_cpu_synchronous(encoder, &buffer, &rate)
                }
            }
        }
        try #require(encoded == PYROWAVE_SUCCESS)
        let boundary = 1400 // one datagram's worth, as on the wire
        var count = 0
        try #require(pyrowave_encoder_compute_num_packets(encoder, boundary, &count) == PYROWAVE_SUCCESS)
        var packets = [pyrowave_packet](repeating: .init(), count: count)
        var bitstream = [UInt8](repeating: 0, count: w * h * 2)
        try #require(pyrowave_encoder_packetize(encoder, &packets, boundary, &count, &bitstream, bitstream.count)
                     == PYROWAVE_SUCCESS)
        #expect(count > 1)

        var decoderInfo = pyrowave_decoder_create_info(device: device, width: Int32(w), height: Int32(h),
                                                       chroma: PYROWAVE_CHROMA_SUBSAMPLING_420)
        var decoder: pyrowave_decoder?
        try #require(pyrowave_decoder_create(&decoderInfo, &decoder) == PYROWAVE_SUCCESS)
        defer { pyrowave_decoder_destroy(decoder) }
        #expect(!pyrowave_decoder_decode_is_ready(decoder, false))
        for packet in packets.prefix(count) {
            let pushed = bitstream.withUnsafeBytes {
                pyrowave_decoder_push_packet(decoder, $0.baseAddress! + packet.offset, packet.size)
            }
            #expect(pushed == PYROWAVE_SUCCESS)
        }
        #expect(pyrowave_decoder_decode_is_ready(decoder, false))

        let textures = try sizes.map { size in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size.0, height: size.1,
                                                             mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return try #require(mtl.makeTexture(descriptor: d))
        }
        let queue = try #require(mtl.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        var buffers = pyrowave_gpu_buffers()
        buffers.planes = (Unmanaged.passUnretained(textures[0]).toOpaque(),
                          Unmanaged.passUnretained(textures[1]).toOpaque(),
                          Unmanaged.passUnretained(textures[2]).toOpaque())
        try #require(pyrowave_decoder_decode_gpu_buffer(decoder, Unmanaged.passUnretained(commands).toOpaque(), &buffers)
                     == PYROWAVE_SUCCESS)
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)

        for (k, texture) in textures.enumerated() {
            let (pw, ph) = sizes[k]
            var out = [UInt8](repeating: 0, count: pw * ph)
            texture.getBytes(&out, bytesPerRow: pw, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
            let diffs = zip(out, planes[k]).map { abs(Int($0) - Int($1)) }
            let mean = Double(diffs.reduce(0, +)) / Double(diffs.count)
            #expect(mean < 1.5, "plane \(k): mean error \(mean)")
            #expect(diffs.max()! < 24, "plane \(k): max error \(diffs.max()!)")
        }
    }

    /// Gradients with some one-pixel detail, like text.
    static func luma(_ w: Int, _ h: Int) -> [UInt8] {
        (0..<h).flatMap { y in
            (0..<w).map { x in
                let v = (3 * x + 5 * y) & 0xff
                return UInt8((x / 8 + y / 8) % 2 == 0 && x % 3 == 0 ? 255 - v : v)
            }
        }
    }
}

@Suite("PyroWave decoding", .enabled(if: pyroWaveIsSupported, "no Apple7 GPU here"))
struct PyroWaveDecodeTests {
    /// Decodes `units` with a VideoDecoder and returns its pictures in order.
    static func decode(_ units: [[UInt8]], firstFrameID: UInt32 = 0) throws -> [DecodedFrame] {
        let frames = Mutex<[DecodedFrame]>([])
        let decoder = VideoDecoder(codec: .pyrowave) { f in frames.withLock { $0.append(f) } }
        for (i, unit) in units.enumerated() {
            try unit.withUnsafeBytes { try decoder.decode($0, pts: UInt32(i) * 16_667, frameID: firstFrameID + UInt32(i)) }
        }
        decoder.flush()
        #expect(decoder.isHardwareAccelerated)
        return frames.withLock { $0 }.sorted { $0.sequence < $1.sequence }
    }

    @Test func aFrameStartsWithItsSequenceHeader() throws {
        let stream = try TestStreamEncoder.encode(codec: .pyrowave, width: 320, height: 180, frameCount: 1)
        let header = stream.accessUnits[0].bytes.withUnsafeBytes { PyroWaveSequenceHeader($0) }
        #expect(header == PyroWaveSequenceHeader(width: 320, height: 180, is444: false))
        #expect([UInt8](repeating: 0, count: 16).withUnsafeBytes { PyroWaveSequenceHeader($0) } == nil)
        #expect([UInt8](repeating: 0xff, count: 4).withUnsafeBytes { PyroWaveSequenceHeader($0) } == nil)
    }

    /// The test pattern, encoded with the port's encoder: every frame comes
    /// out, in order, full-range NV12 at the coded size, close to the source.
    @Test func theTestStreamDecodesCloseToItsSource() throws {
        let (w, h) = (640, 360)
        let stream = try TestStreamEncoder.encode(codec: .pyrowave, width: w, height: h, frameCount: 8)
        #expect(stream.accessUnits.allSatisfy { $0.keyframe })
        let frames = try Self.decode(stream.accessUnits.map(\.bytes))
        #expect(frames.map(\.frameID) == Array(0..<8))
        let source = try TestPatternGenerator(width: w, height: h, color: .pyrowaveDefault).makeFrame(7)
        let picture = try #require(frames.last).pixelBuffer
        #expect(CVPixelBufferGetPixelFormatType(picture) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVPixelBufferGetWidth(picture) == w && CVPixelBufferGetHeight(picture) == h)
        #expect(CVPixelBufferGetIOSurface(picture) != nil)
        for plane in 0..<2 {
            let error = Self.meanError(picture, source, plane: plane)
            #expect(error < 3, "plane \(plane): mean error \(error)")
        }
    }

    /// One frame from the host's encoder (PyroWave's Vulkan library at the
    /// same revision): what the port decodes matches the host's own decode.
    @Test func aHostFrameDecodesAsTheHostDecodesIt() throws {
        let url = try #require(Bundle.module.url(forResource: "pyrowave-host-720p", withExtension: "bin"))
        let data = [UInt8](try Data(contentsOf: url))
        let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let payload = Array(data[4..<4 + length])
        let reference: [Float] = data[(4 + length)...].withUnsafeBytes { raw in
            (0..<raw.count / 4).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        try #require(reference.count == 3 * 80 * 45)
        let picture = try #require(try Self.decode([payload]).first).pixelBuffer
        #expect(CVPixelBufferGetWidth(picture) == 1280 && CVPixelBufferGetHeight(picture) == 720)
        let means = Self.blockMeans(picture)
        let worst = zip(means, reference).map { abs($0 - $1) }.max() ?? .infinity
        #expect(worst < 0.05, "largest block mean difference \(worst)")
    }

    /// Every frame stands alone: after any gap, the next frame decodes. (The
    /// port takes a sequence number more than half its 3-bit range behind
    /// as an older frame's, unless the decoder starts each frame afresh.)
    @Test func framesDecodeAcrossGaps() throws {
        let stream = try TestStreamEncoder.encode(codec: .pyrowave, width: 320, height: 180, frameCount: 16)
        let kept = [0, 1, 6, 7, 13, 15]
        let frames = try Self.decode(kept.map { stream.accessUnits[$0].bytes })
        #expect(frames.count == kept.count)
    }

    @Test func brokenFramesAreRefusedAndTheNextOneDecodes() throws {
        let stream = try TestStreamEncoder.encode(codec: .pyrowave, width: 320, height: 180, frameCount: 2)
        let frames = Mutex(0)
        let decoder = VideoDecoder(codec: .pyrowave) { _ in frames.withLock { $0 += 1 } }
        let whole = stream.accessUnits[0].bytes
        #expect(throws: VideoDecoderError.self) {
            try [UInt8](repeating: 0x55, count: 64).withUnsafeBytes { try decoder.decode($0, pts: 0) }
        }
        #expect(throws: VideoDecoderError.self) { // cut short: blocks missing
            try Array(whole.prefix(whole.count / 2)).withUnsafeBytes { try decoder.decode($0, pts: 0) }
        }
        try stream.accessUnits[1].bytes.withUnsafeBytes { try decoder.decode($0, pts: 16_667) }
        decoder.flush()
        #expect(frames.withLock { $0 } == 1)
    }

    @Test func aNewSizeReconfigures() throws {
        let small = try TestStreamEncoder.encode(codec: .pyrowave, width: 320, height: 180, frameCount: 1)
        let large = try TestStreamEncoder.encode(codec: .pyrowave, width: 640, height: 360, frameCount: 1)
        let frames = try Self.decode([small.accessUnits[0].bytes, large.accessUnits[0].bytes, small.accessUnits[0].bytes])
        #expect(frames.map { CVPixelBufferGetWidth($0.pixelBuffer) } == [320, 640, 320])
    }

    /// Through the presenter's path, with PyroWave's colour (full-range
    /// BT.709, centre-sited chroma): the bars come out their colours.
    @Test(arguments: PipelineTests.sizes)
    func decodedBarsRenderTheirColours(size: (Int, Int)) throws {
        let (width, height) = size
        let stream = try TestStreamEncoder.encode(codec: .pyrowave, width: width, height: height, frameCount: 1)
        let frame = try #require(try Self.decode([stream.accessUnits[0].bytes]).first)
        let renderer = try VideoRenderer()
        let textures = try renderer.textures(for: frame)
        #expect(textures.isZeroCopy)
        let target = try #require(renderer.device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: VideoRenderer.colorPixelFormat, width: width,
                                                             height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return d
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let commands = try #require(renderer.commandQueue.makeCommandBuffer())
        let video = CGSize(width: width, height: height)
        renderer.encode(textures, color: .pyrowaveDefault, displaySize: video,
                        viewport: VideoRenderer.fitViewport(video: video, drawable: video), pass: pass, into: commands)
        commands.commit()
        commands.waitUntilCompleted()
        let barsBottom = Double(height) * TestPatternGenerator.barsHeightFraction
        for (i, expected) in TestPatternGenerator.bars.enumerated() {
            for y in [Int(barsBottom * 0.1), Int(barsBottom * 0.9)] {
                let x = (2 * i + 1) * width / 16
                var bgra = [UInt8](repeating: 0, count: 4)
                target.getBytes(&bgra, bytesPerRow: 4 * width, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                let got = SIMD3(bgra[2], bgra[1], bgra[0])
                for c in 0..<3 {
                    #expect(abs(Int(got[c]) - Int(expected[c])) <= 6, "bar \(i) row \(y): got \(got), expected \(expected)")
                }
            }
        }
    }

    static func meanError(_ a: CVPixelBuffer, _ b: CVPixelBuffer, plane: Int) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        let bytes = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2)
        let rows = CVPixelBufferGetHeightOfPlane(a, plane)
        let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, plane), rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
        var total = 0
        for y in 0..<rows {
            for x in 0..<bytes { total += abs(Int(pa[y * ra + x]) - Int(pb[y * rb + x])) }
        }
        return Double(total) / Double(bytes * rows)
    }

    /// Luma per 16×16 block, then Cb and Cr per 8×8, as the fixture stores the host's.
    static func blockMeans(_ picture: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(picture, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(picture, .readOnly) }
        func means(plane: Int, block: Int, stride: Int, offset: Int) -> [Float] {
            let p = CVPixelBufferGetBaseAddressOfPlane(picture, plane)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRowOfPlane(picture, plane)
            let w = CVPixelBufferGetWidthOfPlane(picture, plane), h = CVPixelBufferGetHeightOfPlane(picture, plane)
            var out: [Float] = []
            for by in 0..<h / block {
                for bx in 0..<w / block {
                    var t = 0
                    for y in by * block..<(by + 1) * block {
                        for x in bx * block..<(bx + 1) * block { t += Int(p[y * row + x * stride + offset]) }
                    }
                    out.append(Float(t) / Float(block * block))
                }
            }
            return out
        }
        return means(plane: 0, block: 16, stride: 1, offset: 0) + means(plane: 1, block: 8, stride: 2, offset: 0)
            + means(plane: 1, block: 8, stride: 2, offset: 1)
    }
}
