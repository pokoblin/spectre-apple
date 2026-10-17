import CoreVideo
import PyroWave

extension TestStreamEncoder {
    /// A PyroWave stream is large (every frame is intra), so a looped test
    /// stream is kept short: two seconds at 60 fps.
    static let pyroWaveFrameLimit = 120

    /// Encodes the test pattern with PyroWave's Metal port, the way a host
    /// would for gdp-spec.md §9.4: each frame one payload, its sequence
    /// header first. Y'CbCr is PyroWave's: BT.709, full range, centre-sited
    /// chroma (§7.3). `bitrate` caps each frame at its share.
    static func encodePyroWave(width: Int, height: Int, framesPerSecond: Int, frameCount: Int, bitrate: Int,
                               progress: (@Sendable (Double) -> Void)?) throws -> TestStream {
        guard let shared = PyroWaveDevice.shared else { throw TestStreamEncoderError.output("PyroWave needs an Apple7 GPU") }
        let generator = try TestPatternGenerator(width: width, height: height, color: .pyrowaveDefault,
                                                 device: shared.metal)
        var info = pyrowave_encoder_create_info(device: shared.device, width: Int32(width), height: Int32(height),
                                                chroma: PYROWAVE_CHROMA_SUBSAMPLING_420)
        var encoder: pyrowave_encoder?
        let created = pyrowave_encoder_create(&info, &encoder)
        guard created == PYROWAVE_SUCCESS, let encoder else {
            throw TestStreamEncoderError.output("pyrowave_encoder_create: \(created.rawValue)")
        }
        defer { pyrowave_encoder_destroy(encoder) }

        let frameBytes = max(bitrate / framesPerSecond / 8, 4096)
        var rate = pyrowave_rate_control(maximum_bitstream_size: frameBytes)
        var bitstream = [UInt8](repeating: 0, count: frameBytes * 2 + 65536)
        var units: [AccessUnit] = []
        for i in 0..<frameCount {
            let pb = try generator.makeFrame(UInt32(i))
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            var input = pyrowave_cpu_buffer()
            input.format = PYROWAVE_CPU_BUFFER_FORMAT_NV12
            input.width = Int32(width)
            input.height = Int32(height)
            input.data = (CVPixelBufferGetBaseAddressOfPlane(pb, 0), CVPixelBufferGetBaseAddressOfPlane(pb, 1), nil)
            input.row_stride_in_bytes = (CVPixelBufferGetBytesPerRowOfPlane(pb, 0),
                                         CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 0)
            input.plane_size_in_bytes = (CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * CVPixelBufferGetHeightOfPlane(pb, 0),
                                         CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1), 0)
            let encoded = pyrowave_encoder_encode_cpu_synchronous(encoder, &input, &rate)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            guard encoded == PYROWAVE_SUCCESS else { throw TestStreamEncoderError.output("PyroWave encode: \(encoded.rawValue)") }

            // One packet as large as the frame: the payload GDP slices itself (§9.2).
            var count = 0
            var packet = pyrowave_packet()
            let packed = pyrowave_encoder_packetize(encoder, &packet, bitstream.count, &count, &bitstream, bitstream.count)
            guard packed == PYROWAVE_SUCCESS, count == 1 else {
                throw TestStreamEncoderError.output("PyroWave packetize: \(packed.rawValue), \(count) packets")
            }
            units.append(AccessUnit(bytes: Array(bitstream[packet.offset..<packet.offset + packet.size]), keyframe: true))
            if i % 30 == 0 { progress?(Double(i) / Double(frameCount)) }
        }
        progress?(1)
        return TestStream(codec: .pyrowave, width: width, height: height, framesPerSecond: framesPerSecond,
                          accessUnits: units)
    }
}
