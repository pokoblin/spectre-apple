import CoreVideo
import IOSurface
import Metal
import simd

/// Matches `VideoUniforms` in Shaders.swift.
struct VideoUniforms {
    var yuvToRGB: simd_float4x4
    var uvScale: SIMD2<Float>
    var chromaOffset: SIMD2<Float>
}

public enum VideoRendererError: Error, CustomStringConvertible {
    case noDevice
    case shader(String)
    case textureCache(CVReturn)
    case texture(plane: Int, CVReturn)
    case unexpectedPixelFormat(OSType)
    case notIOSurfaceBacked

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case let .shader(s): "shader: \(s)"
        case let .textureCache(r): "CVMetalTextureCacheCreate failed (\(r))"
        case let .texture(plane, r): "CVMetalTextureCacheCreateTextureFromImage(plane \(plane)) failed (\(r))"
        case let .unexpectedPixelFormat(f): "unexpected pixel format \(String(format: "%08x", f))"
        case .notIOSurfaceBacked: "pixel buffer is not IOSurface-backed"
        }
    }
}

/// A decoded frame's two planes as Metal textures over the frame's own
/// IOSurface. Holds the CVMetalTextures (and through them the pixel buffer)
/// until the GPU is done with them: keep it alive until the command buffer
/// completes.
public struct VideoTextures: @unchecked Sendable {
    public let luma: MTLTexture
    public let chroma: MTLTexture
    let lumaRef: CVMetalTexture
    let chromaRef: CVMetalTexture
    public let frame: DecodedFrame
    /// Both textures are views of the pixel buffer's IOSurface (verified, not assumed).
    public let isZeroCopy: Bool
}

/// Draws decoded NV12 frames with Metal. Thread-compatible: one thread
/// encodes at a time (the view's draw callback).
public final class VideoRenderer: @unchecked Sendable {
    public static let colorPixelFormat = MTLPixelFormat.bgra8Unorm

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    let cursorRenderer: CursorRenderer

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws(VideoRendererError) {
        guard let device, let queue = device.makeCommandQueue() else { throw .noDevice }
        self.device = device
        commandQueue = queue
        commandQueue.label = "spectre.video"
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "video"
            desc.vertexFunction = library.makeFunction(name: "video_vertex")
            desc.fragmentFunction = library.makeFunction(name: "video_fragment")
            desc.colorAttachments[0].pixelFormat = Self.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            cursorRenderer = try CursorRenderer(device: device, library: library)
        } catch {
            throw .shader(String(describing: error))
        }
        var cache: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard r == kCVReturnSuccess, let cache else { throw .textureCache(r) }
        textureCache = cache
    }

    /// Wraps the frame's planes as textures. No pixel is copied: the
    /// textures are backed by the pixel buffer's IOSurface, which is checked.
    public func textures(for frame: DecodedFrame) throws(VideoRendererError) -> VideoTextures {
        let pb = frame.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(pb)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else { throw .unexpectedPixelFormat(format) }
        guard let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { throw .notIOSurfaceBacked }

        let (lumaRef, luma) = try planeTexture(pb, plane: 0, format: .r8Unorm)
        let (chromaRef, chroma) = try planeTexture(pb, plane: 1, format: .rg8Unorm)
        // Compare global surface IDs, not wrapper objects: the simulator hands
        // back a different IOSurfaceRef object for the same surface. It also
        // reports plane 0 for the chroma texture (whose contents are plane 1),
        // so the plane is checked only where it is reported faithfully.
        let id = IOSurfaceGetID(surface)
        var zeroCopy = luma.iosurface.map(IOSurfaceGetID) == id && chroma.iosurface.map(IOSurfaceGetID) == id
        #if !targetEnvironment(simulator)
        zeroCopy = zeroCopy && luma.iosurfacePlane == 0 && chroma.iosurfacePlane == 1
        #endif
        return VideoTextures(luma: luma, chroma: chroma, lumaRef: lumaRef, chromaRef: chromaRef, frame: frame,
                             isZeroCopy: zeroCopy)
    }

    private func planeTexture(_ pb: CVPixelBuffer, plane: Int,
                              format: MTLPixelFormat) throws(VideoRendererError) -> (CVMetalTexture, MTLTexture) {
        var ref: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, format,
            CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &ref)
        guard r == kCVReturnSuccess, let ref, let texture = CVMetalTextureGetTexture(ref) else {
            throw .texture(plane: plane, r)
        }
        return (ref, texture)
    }

    /// The largest rectangle of the video's aspect ratio inside `drawableSize`, centred (the "fit" view).
    public static func fitViewport(video: CGSize, drawable: CGSize) -> MTLViewport {
        guard video.width > 0, video.height > 0, drawable.width > 0, drawable.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: drawable.width, height: drawable.height, znear: 0, zfar: 1)
        }
        let scale = min(drawable.width / video.width, drawable.height / video.height)
        let w = (video.width * scale).rounded()
        let h = (video.height * scale).rounded()
        return MTLViewport(originX: ((drawable.width - w) / 2).rounded(), originY: ((drawable.height - h) / 2).rounded(),
                           width: w, height: h, znear: 0, zfar: 1)
    }

    /// Encodes one frame into `pass` (cleared to black outside the viewport).
    /// `displaySize` is the picture's size (gdp-spec.md §7.2); a larger
    /// coded picture's padding is cropped off. `cursor`, if any, is drawn
    /// over the picture in the same pass (``encodeCursor(_:videoSize:viewport:targetSize:encoder:)``).
    public func encode(_ textures: VideoTextures, color: ColorDescription, displaySize: CGSize? = nil,
                       viewport: MTLViewport, cursor: CursorOverlay? = nil, pass: MTLRenderPassDescriptor,
                       into commandBuffer: MTLCommandBuffer) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "video"
        let lw = textures.luma.width, lh = textures.luma.height
        let display = displaySize ?? CGSize(width: lw, height: lh)
        var uniforms = VideoUniforms(
            yuvToRGB: color.yuvToRGB,
            uvScale: SIMD2(Float(min(display.width, CGFloat(lw)) / CGFloat(lw)),
                           Float(min(display.height, CGFloat(lh)) / CGFloat(lh))),
            chromaOffset: color.chromaOffset(lumaWidth: lw, lumaHeight: lh))
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(viewport)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VideoUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.stride, index: 0)
        encoder.setFragmentTexture(textures.luma, index: 0)
        encoder.setFragmentTexture(textures.chroma, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let cursor, let target = pass.colorAttachments[0].texture {
            encodeCursor(cursor, videoSize: display, viewport: viewport,
                         targetSize: CGSize(width: target.width, height: target.height), encoder: encoder)
        }
        encoder.endEncoding()
        // Keep the CVMetalTextures (and the pixel buffer) alive until the GPU is done.
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(textures) {} }
    }
}
