import CoreVideo
import Metal
import PyroWave
import QuartzCore

/// The sequence header a PyroWave frame starts with (gdp-spec.md §9.4):
/// two little-endian 32-bit words, laid out as PyroWave's own
/// `BitstreamSequenceHeader` (pyrowave_bitstream.hpp).
struct PyroWaveSequenceHeader: Equatable, Sendable {
    var width: Int
    var height: Int
    /// 4:4:4 chroma; 4:2:0 otherwise.
    var is444: Bool

    init(width: Int, height: Int, is444: Bool) {
        self.width = width
        self.height = height
        self.is444 = is444
    }

    /// Nil unless `bytes` starts with a start-of-frame sequence header.
    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 8 else { return nil }
        let w0 = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        let w1 = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        // extended (bit 31): a sequence header, not a block's; code (bits 24-25 of
        // the second word) 0: start of frame.
        guard w0 >> 31 == 1, (w1 >> 24) & 3 == 0 else { return nil }
        width = Int(w0 & 0x3fff) + 1
        height = Int((w0 >> 14) & 0x3fff) + 1
        is444 = (w1 >> 26) & 1 == 1
    }
}

/// The process's one PyroWave device: Metal's default device with
/// PyroWave's compute pipelines, which take the better part of a second to
/// compile, so they are made once and kept.
final class PyroWaveDevice: @unchecked Sendable {
    let metal: MTLDevice
    let device: pyrowave_device
    let queue: MTLCommandQueue
    /// Cb and Cr, two planes as PyroWave writes them, into one CbCr plane.
    let interleave: MTLComputePipelineState

    /// Whether this Mac or iPad can decode PyroWave: an Apple7 GPU (A14, M1) or later.
    static let isSupported: Bool = {
        guard let metal = MTLCreateSystemDefaultDevice() else { return false }
        return pyrowave_device_is_supported(Unmanaged.passUnretained(metal).toOpaque())
    }()

    /// Made on first use; nil where PyroWave can't run.
    static let shared: PyroWaveDevice? = try? PyroWaveDevice()

    /// Makes the shared device ahead of the first frame, off the caller's
    /// thread, so that frame doesn't wait for the pipelines.
    static func prepare() {
        guard isSupported else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = shared }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void pyrowave_interleave(texture2d<float, access::read> cb [[texture(0)]],
                                    texture2d<float, access::read> cr [[texture(1)]],
                                    texture2d<float, access::write> cbcr [[texture(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= cbcr.get_width() || gid.y >= cbcr.get_height()) return;
        cbcr.write(float4(cb.read(gid).r, cr.read(gid).r, 0, 0), gid);
    }
    """

    private init() throws(VideoDecoderError) {
        guard Self.isSupported, let metal = MTLCreateSystemDefaultDevice(), let queue = metal.makeCommandQueue() else {
            throw .pyrowave("no Apple7 GPU")
        }
        queue.label = "spectre.pyrowave"
        do {
            let library = try metal.makeLibrary(source: Self.source, options: nil)
            interleave = try metal.makeComputePipelineState(function: library.makeFunction(name: "pyrowave_interleave")!)
        } catch {
            throw .pyrowave("shader: \(error)")
        }
        var info = pyrowave_device_create_info()
        info.mtl_device = Unmanaged.passUnretained(metal).toOpaque()
        var device: pyrowave_device?
        let result = pyrowave_device_create(&info, &device)
        guard result == PYROWAVE_SUCCESS, let device else { throw .pyrowave("device: \(result.rawValue)") }
        self.metal = metal
        self.queue = queue
        self.device = device
    }

    deinit { pyrowave_device_destroy(device) }
}

/// Decodes a stream's PyroWave frames (gdp-spec.md §6.6, §9.4) on the GPU,
/// with PyroWave's Metal port, into the same kind of picture VideoToolbox
/// hands out: an IOSurface-backed NV12 `CVPixelBuffer`, full range here
/// (`420f`). Luma is decoded straight into the buffer; Cb and Cr, which
/// PyroWave writes as separate planes, are interleaved into it by one small
/// compute pass. Every frame stands alone, so there is no keyframe to wait
/// for and nothing to repair after a loss.
///
/// Not thread-safe: feed it from one queue. `onFrame` runs on Metal's
/// completion thread, once the GPU is done with the picture.
final class PyroWaveDecoder {
    private let shared: PyroWaveDevice
    private let onFrame: @Sendable (DecodedFrame) -> Void
    private let onError: @Sendable (_ status: OSStatus, _ frameID: UInt32) -> Void
    private let textureCache: CVMetalTextureCache
    private var header: PyroWaveSequenceHeader?
    private var decoder: pyrowave_decoder?
    private var pool: CVPixelBufferPool?
    /// What PyroWave writes Cb and Cr into, for the interleave pass.
    private var chroma: [MTLTexture] = []
    private var sequence: UInt64 = 0
    private var lastCommands: MTLCommandBuffer?

    init(onFrame: @escaping @Sendable (DecodedFrame) -> Void,
         onError: @escaping @Sendable (_ status: OSStatus, _ frameID: UInt32) -> Void) throws(VideoDecoderError) {
        guard let shared = PyroWaveDevice.shared else { throw .pyrowave("no Apple7 GPU") }
        var cache: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, shared.metal, nil, &cache)
        guard r == kCVReturnSuccess, let cache else { throw .pyrowave("texture cache: \(r)") }
        self.shared = shared
        self.onFrame = onFrame
        self.onError = onError
        textureCache = cache
    }

    deinit {
        lastCommands?.waitUntilCompleted()
        if let decoder { pyrowave_decoder_destroy(decoder) }
    }

    /// Decodes one frame: the GPU work is committed before this returns,
    /// and the picture reaches `onFrame` when it completes. The bytes need
    /// only live for the call.
    func decode(_ frame: UnsafeRawBufferPointer, pts: UInt32, frameID: UInt32,
                submitTime: CFTimeInterval) throws(VideoDecoderError) {
        guard let header = PyroWaveSequenceHeader(frame) else { throw .malformedAccessUnit }
        // 4:2:0 is the baseline, and all this client declares (gdp-spec.md §7.3).
        guard !header.is444 else { throw .pyrowave("4:4:4 wasn't declared") }
        if header != self.header { try configure(header) }
        guard let decoder, let pool else { throw .pyrowave("not configured") }

        // One payload is one whole frame: start from nothing, so that a
        // sequence number PyroWave takes for an older frame's after a run
        // of losses doesn't get the frame ignored.
        pyrowave_decoder_clear(decoder)
        guard pyrowave_decoder_push_packet(decoder, frame.baseAddress, frame.count) == PYROWAVE_SUCCESS,
              pyrowave_decoder_decode_is_ready(decoder, false) else { throw .malformedAccessUnit }

        var buffer: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard r == kCVReturnSuccess, let buffer else { throw .pyrowave("pixel buffer: \(r)") }
        Self.tag(buffer)
        CVMetalTextureCacheFlush(textureCache, 0)
        let (lumaRef, luma) = try texture(buffer, plane: 0, format: .r8Unorm)
        let (cbcrRef, cbcr) = try texture(buffer, plane: 1, format: .rg8Unorm)

        guard let commands = shared.queue.makeCommandBuffer() else { throw .pyrowave("no command buffer") }
        commands.label = "pyrowave frame \(frameID)"
        var planes = pyrowave_gpu_buffers()
        planes.planes = (Unmanaged.passUnretained(luma).toOpaque(), Unmanaged.passUnretained(chroma[0]).toOpaque(),
                         Unmanaged.passUnretained(chroma[1]).toOpaque())
        let result = pyrowave_decoder_decode_gpu_buffer(decoder, Unmanaged.passUnretained(commands).toOpaque(), &planes)
        guard result == PYROWAVE_SUCCESS else { throw .pyrowave("decode: \(result.rawValue)") }
        guard let pass = commands.makeComputeCommandEncoder() else { throw .pyrowave("no compute encoder") }
        pass.label = "pyrowave chroma"
        pass.setComputePipelineState(shared.interleave)
        pass.setTexture(chroma[0], index: 0)
        pass.setTexture(chroma[1], index: 1)
        pass.setTexture(cbcr, index: 2)
        pass.dispatchThreads(MTLSize(width: cbcr.width, height: cbcr.height, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        pass.endEncoding()

        sequence += 1
        let seq = sequence
        let onFrame = onFrame, onError = onError
        commands.addCompletedHandler { commands in
            // The textures (and through them the buffer) stay until the GPU is done.
            withExtendedLifetime((lumaRef, cbcrRef)) {}
            guard commands.status == .completed else {
                onError(OSStatus(commands.status.rawValue), frameID)
                return
            }
            onFrame(DecodedFrame(pixelBuffer: buffer, pts: pts, frameID: frameID, sequence: seq,
                                 submitTime: submitTime, decodedTime: CACurrentMediaTime()))
        }
        commands.commit()
        lastCommands = commands
    }

    /// Waits until every frame submitted so far has come out.
    func flush() {
        lastCommands?.waitUntilCompleted()
    }

    /// Drops the decoder; the next frame makes a new one.
    func reset() {
        flush()
        if let decoder { pyrowave_decoder_destroy(decoder) }
        decoder = nil
        header = nil
        pool = nil
        chroma = []
    }

    /// A decoder, a pixel buffer pool and chroma planes for `header`'s size.
    private func configure(_ header: PyroWaveSequenceHeader) throws(VideoDecoderError) {
        reset()
        var info = pyrowave_decoder_create_info(device: shared.device, width: Int32(header.width),
                                                height: Int32(header.height), chroma: PYROWAVE_CHROMA_SUBSAMPLING_420)
        var decoder: pyrowave_decoder?
        let result = pyrowave_decoder_create(&info, &decoder)
        guard result == PYROWAVE_SUCCESS, let decoder else { throw .pyrowave("decoder: \(result.rawValue)") }
        self.decoder = decoder

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: header.width,
            kCVPixelBufferHeightKey: header.height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        let r = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard r == kCVReturnSuccess, let pool else { throw .pyrowave("pixel buffer pool: \(r)") }
        self.pool = pool

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: header.width / 2,
                                                            height: header.height / 2, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        chroma = try (0..<2).map { _ throws(VideoDecoderError) in
            guard let t = shared.metal.makeTexture(descriptor: desc) else { throw .pyrowave("no chroma texture") }
            return t
        }
        self.header = header
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int,
                         format: MTLPixelFormat) throws(VideoDecoderError) -> (CVMetalTexture, MTLTexture) {
        var ref: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, attributes, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &ref)
        guard r == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else {
            throw .pyrowave("plane \(plane) texture: \(r)")
        }
        return (ref, texture)
    }

    /// What the picture is (gdp-spec.md §7.3, pyrowave's default), for
    /// whoever reads the buffer without the session's colour description
    /// (a snapshot through Core Image).
    private static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
                              .shouldPropagate)
    }
}
