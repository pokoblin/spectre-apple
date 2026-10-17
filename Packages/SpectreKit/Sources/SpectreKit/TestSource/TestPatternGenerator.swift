import CoreVideo
import Metal

/// Draws a synthetic desktop-like picture straight into NV12 pixel buffers
/// on the GPU: 75 % colour bars (for checking the colour pipeline), a
/// scrolling ramp and a moving box (for judging smoothness), per-frame
/// noise over the right third (to load the encoder and decoder like real
/// video), and the frame number in binary. Y'CbCr follows a
/// ``ColorDescription``: by default BT.601 limited range, the protocol's
/// default for block codecs (gdp-spec.md §7.3), with chroma taken at the
/// cosited (even) luma sample; for PyroWave, BT.709 full range with chroma
/// at the midpoint (the average of four luma samples).
public final class TestPatternGenerator: @unchecked Sendable {
    /// The colour bars' R'G'B' values, left to right: 75 % white, yellow, cyan, green, magenta, red, blue, black.
    public static let bars: [SIMD3<UInt8>] = [
        SIMD3(191, 191, 191), SIMD3(191, 191, 0), SIMD3(0, 191, 191), SIMD3(0, 191, 0),
        SIMD3(191, 0, 191), SIMD3(191, 0, 0), SIMD3(0, 0, 191), SIMD3(0, 0, 0),
    ]
    /// The bars occupy the top quarter of the picture.
    public static let barsHeightFraction = 0.25

    public let width: Int
    public let height: Int
    public let color: ColorDescription
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lumaPipeline: MTLComputePipelineState
    private let chromaPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let pool: CVPixelBufferPool

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 bars[8] = {
        float3(191, 191, 191), float3(191, 191, 0), float3(0, 191, 191), float3(0, 191, 0),
        float3(191, 0, 191), float3(191, 0, 0), float3(0, 0, 191), float3(0, 0, 0) };

    float3 pattern(uint2 p, uint2 size, uint frame) {
        float fx = float(p.x), fy = float(p.y);
        float w = float(size.x), h = float(size.y);
        if (fy < h * 0.25) {
            uint bar = min(7u, uint(fx * 8.0 / w));
            return bars[bar] / 255.0;
        }
        if (fy >= h - 64.0) {
            // Frame counter: 24 bits, most significant first.
            uint bit = uint(fx * 24.0 / w);
            return ((frame >> (23u - bit)) & 1u) ? float3(0.9) : float3(0.1);
        }
        // Scrolling diagonal ramp, 4 px per frame.
        float ramp = fract((fx + fy * 0.5 + float(frame) * 4.0) / 512.0);
        float3 c = float3(0.2 + 0.5 * ramp, 0.25 + 0.3 * ramp, 0.5 - 0.3 * ramp);
        // Film grain over the right third: new noise every frame, which no
        // encoder can predict, so the bitrate reaches the target the way
        // video playing on the remote desktop does.
        if (fx >= w * 0.66 && fy < h - 64.0) {
            uint hsh = p.x * 73856093u ^ p.y * 19349663u ^ frame * 83492791u;
            hsh = (hsh ^ (hsh >> 13)) * 1274126177u;
            float n = float(hsh & 255u) / 255.0;
            c = mix(c, float3(n), 0.35);
        }
        // A box bouncing horizontally at 12 px per frame.
        float span = w - 240.0;
        float t = fmod(float(frame) * 12.0, 2.0 * span);
        float bx = t < span ? t : 2.0 * span - t;
        float by = h * 0.25 + (h * 0.75 - 64.0 - 240.0) * 0.5;
        if (fx >= bx && fx < bx + 240.0 && fy >= by && fy < by + 240.0) c = float3(0.95, 0.95, 0.95);
        return c;
    }

    // Keep in sync with PatternColor in TestPatternGenerator.swift.
    struct PatternColor {
        float kr, kb;            // luma coefficients
        float yOffset, yScale;   // Y code value = yOffset + yScale * Y', over 255
        float cScale;            // Cb code value = 128/255 + cScale * Cb', likewise Cr
        uint midpoint;           // chroma at the centre of its four luma samples, else cosited
    };

    // R'G'B' to Y'CbCr, normalized to 8-bit code values / 255.
    float3 to_ycbcr(float3 rgb, constant PatternColor &c) {
        float y = c.kr * rgb.r + (1.0 - c.kr - c.kb) * rgb.g + c.kb * rgb.b;
        float cb = (rgb.b - y) / (2.0 * (1.0 - c.kb));
        float cr = (rgb.r - y) / (2.0 * (1.0 - c.kr));
        return float3(c.yOffset + c.yScale * y, 128.0 / 255.0 + c.cScale * cb, 128.0 / 255.0 + c.cScale * cr);
    }

    kernel void pattern_luma(texture2d<float, access::write> luma [[texture(0)]],
                             constant uint &frame [[buffer(0)]],
                             constant PatternColor &c [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 size = uint2(luma.get_width(), luma.get_height());
        if (gid.x >= size.x || gid.y >= size.y) return;
        luma.write(float4(to_ycbcr(pattern(gid, size, frame), c).x), gid);
    }

    kernel void pattern_chroma(texture2d<float, access::write> chroma [[texture(0)]],
                               constant uint &frame [[buffer(0)]],
                               constant PatternColor &c [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint2 csize = uint2(chroma.get_width(), chroma.get_height());
        if (gid.x >= csize.x || gid.y >= csize.y) return;
        // Cosited: chroma sample (i, j) is the luma sample (2i, 2j).
        // Midpoint: the average of the four it sits between.
        float3 ycc = to_ycbcr(pattern(gid * 2, csize * 2, frame), c);
        if (c.midpoint) {
            ycc += to_ycbcr(pattern(gid * 2 + uint2(1, 0), csize * 2, frame), c);
            ycc += to_ycbcr(pattern(gid * 2 + uint2(0, 1), csize * 2, frame), c);
            ycc += to_ycbcr(pattern(gid * 2 + uint2(1, 1), csize * 2, frame), c);
            ycc *= 0.25;
        }
        chroma.write(float4(ycc.y, ycc.z, 0, 0), gid);
    }
    """

    public init(width: Int, height: Int, color: ColorDescription = .blockCodecDefault,
                device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw VideoRendererError.noDevice }
        self.width = width
        self.height = height
        self.color = color
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source, options: nil)
        lumaPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "pattern_luma")!)
        chromaPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "pattern_chroma")!)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw VideoRendererError.textureCache(kCVReturnError) }
        textureCache = cache

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: color.range == .full
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        guard let pool else { throw VideoRendererError.textureCache(kCVReturnError) }
        self.pool = pool
    }

    /// Renders frame number `frame` into a new pixel buffer and waits for the GPU.
    public func makeFrame(_ frame: UInt32) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let pb else { throw VideoRendererError.textureCache(kCVReturnError) }
        let matrix = switch color.matrix {
        case .bt601: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case .bt709: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .bt2020: kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
        let location = color.chromaLocation == .midpoint
            ? kCVImageBufferChromaLocation_Center : kCVImageBufferChromaLocation_TopLeft
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)

        guard let cb = queue.makeCommandBuffer(), let encoder = cb.makeComputeCommandEncoder() else {
            throw VideoRendererError.noDevice
        }
        var n = frame
        var c = patternColor
        var refs: [CVMetalTexture] = []
        for (plane, pipeline, format) in [(0, lumaPipeline, MTLPixelFormat.r8Unorm), (1, chromaPipeline, .rg8Unorm)] {
            let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
            var ref: CVMetalTexture?
            let attrs = [kCVMetalTextureUsage: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue] as CFDictionary
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, attrs, format, w, h, plane, &ref)
            guard let ref, let texture = CVMetalTextureGetTexture(ref) else { throw VideoRendererError.texture(plane: plane, kCVReturnError) }
            refs.append(ref)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&n, length: 4, index: 0)
            encoder.setBytes(&c, length: MemoryLayout<PatternColor>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(refs) {}
        return pb
    }

    private var patternColor: PatternColor {
        let (kr, kb) = color.coefficients
        let full = color.range == .full
        return PatternColor(kr: kr, kb: kb, yOffset: full ? 0 : 16 / 255, yScale: full ? 1 : 219 / 255,
                            cScale: full ? 1 : 224 / 255, midpoint: color.chromaLocation == .midpoint ? 1 : 0)
    }
}

/// Matches `PatternColor` in the generator's shader.
private struct PatternColor {
    var kr: Float
    var kb: Float
    var yOffset: Float
    var yScale: Float
    var cScale: Float
    var midpoint: UInt32
}
