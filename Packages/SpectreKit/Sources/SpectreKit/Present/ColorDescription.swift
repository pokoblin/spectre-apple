import GDPKit
import simd

/// How to turn decoded pictures back into RGB (gdp-spec.md §7.3,
/// `OutputDescriptor.color`). Matrix and range are applied in the video
/// shader; the bitstream's own VUI is ignored, as the spec requires.
public struct ColorDescription: Equatable, Sendable {
    public enum Matrix: Sendable { case bt601, bt709, bt2020 }
    public enum Range: Sendable { case limited, full }
    /// Where chroma samples sit relative to luma, per axis (Vulkan's
    /// `VkChromaLocation`, which the upstream client configures).
    public enum ChromaLocation: Sendable { case cositedEven, midpoint }

    public var matrix: Matrix
    public var range: Range
    public var chromaLocation: ChromaLocation

    public init(matrix: Matrix, range: Range, chromaLocation: ChromaLocation) {
        self.matrix = matrix
        self.range = range
        self.chromaLocation = chromaLocation
    }

    /// §7.3's default for h264/h265/av1: BT.601, limited range. Cosited-even
    /// chroma on both axes, as the upstream client's ycbcr sampler uses
    /// (client/spectre/src/present/video_image_source.cpp).
    public static let blockCodecDefault = ColorDescription(matrix: .bt601, range: .limited, chromaLocation: .cositedEven)
    /// §7.3's default for pyrowave: BT.709, full range, centre-sited chroma.
    public static let pyrowaveDefault = ColorDescription(matrix: .bt709, range: .full, chromaLocation: .midpoint)

    /// Luma coefficients (Kr, Kb).
    var coefficients: (kr: Float, kb: Float) {
        switch matrix {
        case .bt601: (0.299, 0.114)
        case .bt709: (0.2126, 0.0722)
        case .bt2020: (0.2627, 0.0593)
        }
    }

    /// Maps normalized 8-bit samples (y, cb, cr, 1) to non-linear R'G'B':
    /// range expansion and the matrix folded into one affine transform.
    public var yuvToRGB: simd_float4x4 {
        let (kr, kb) = coefficients
        let kg = 1 - kr - kb
        // Y' = (y - yOffset) * yScale, Cb' = (cb - 128/255) * cScale, likewise Cr'.
        let yOffset: Float, yScale: Float, cScale: Float
        switch range {
        case .limited:
            yOffset = 16 / 255
            yScale = 255 / 219
            cScale = 255 / 224
        case .full:
            yOffset = 0
            yScale = 1
            cScale = 1
        }
        let cOffset: Float = 128 / 255
        // R = Y' + 2(1-Kr) Cr', G = Y' - 2Kb(1-Kb)/Kg Cb' - 2Kr(1-Kr)/Kg Cr', B = Y' + 2(1-Kb) Cb'
        let rCr = 2 * (1 - kr)
        let gCb = -2 * kb * (1 - kb) / kg
        let gCr = -2 * kr * (1 - kr) / kg
        let bCb = 2 * (1 - kb)
        let m = simd_float3x3(rows: [
            SIMD3(yScale, 0, rCr * cScale),
            SIMD3(yScale, gCb * cScale, gCr * cScale),
            SIMD3(yScale, bCb * cScale, 0),
        ])
        let offset = -(m * SIMD3(yOffset, cOffset, cOffset))
        return simd_float4x4(columns: (
            SIMD4(m.columns.0, 0),
            SIMD4(m.columns.1, 0),
            SIMD4(m.columns.2, 0),
            SIMD4(offset, 1)))
    }

    /// The chroma texture coordinate offset from the luma one, in units of
    /// the luma texture size: cosited-even puts chroma sample j on luma
    /// sample 2j, half a luma texel off a plain 2:1 mapping.
    func chromaOffset(lumaWidth: Int, lumaHeight: Int) -> SIMD2<Float> {
        switch chromaLocation {
        case .cositedEven: SIMD2(0.5 / Float(lumaWidth), 0.5 / Float(lumaHeight))
        case .midpoint: .zero
        }
    }

    /// CPU reference of the shader's conversion, for tests: 8-bit Y'CbCr to 8-bit R'G'B'.
    public func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> SIMD3<UInt8> {
        let v = yuvToRGB * SIMD4(Float(y) / 255, Float(cb) / 255, Float(cr) / 255, 1)
        let c = simd_clamp(SIMD3(v.x, v.y, v.z), SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
        return SIMD3(UInt8(c.x.rounded()), UInt8(c.y.rounded()), UInt8(c.z.rounded()))
    }
}

extension ColorDescription {
    /// An output's colour description (gdp-spec.md §7.3, `OutputDescriptor.color`):
    /// unspecified fields take the codec's default.
    public init(output: GDPSession.Output, codec: String) {
        let base: ColorDescription = codec == "pyrowave" ? .pyrowaveDefault : .blockCodecDefault
        self = base
        switch output.matrix {
        case 1: matrix = .bt601
        case 2: matrix = .bt709
        case 3: matrix = .bt2020
        default: break
        }
        switch output.range {
        case 1: range = .limited
        case 2: range = .full
        default: break
        }
    }
}
