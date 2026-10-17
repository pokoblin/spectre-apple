import Metal
import PyroWave
import Testing

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
