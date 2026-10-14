import CoreGraphics
import Metal
import simd

/// Matches `CursorUniforms` in Shaders.swift.
struct CursorUniforms {
    var rect: SIMD4<Float>
}

/// A cursor image uploaded as a texture. Make a new one per image change
/// rather than rewriting the old one in place: a frame still on the GPU may
/// be reading it (command buffers retain the textures they use).
public struct CursorTexture: @unchecked Sendable {
    public let texture: MTLTexture
    public let image: CursorImage
}

/// A cursor to draw over the picture: its texture and the pointer's
/// position, 0...1 over the output, (0, 0) at the top left (gdp-spec.md §7.4).
public struct CursorOverlay: @unchecked Sendable {
    public var texture: CursorTexture
    public var position: CGPoint

    public init(texture: CursorTexture, position: CGPoint) {
        self.texture = texture
        self.position = position
    }
}

/// The cursor pass: a textured quad blended premultiplied over the video.
final class CursorRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private let linear: MTLSamplerState

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "cursor"
        desc.vertexFunction = library.makeFunction(name: "cursor_vertex")
        desc.fragmentFunction = library.makeFunction(name: "cursor_fragment")
        let color = desc.colorAttachments[0]!
        color.pixelFormat = VideoRenderer.colorPixelFormat
        // Premultiplied source over: out = src + dst × (1 − src.a).
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.alphaBlendOperation = .add
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)

        func sampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            guard let s = device.makeSamplerState(descriptor: d) else { throw VideoRendererError.noDevice }
            return s
        }
        nearest = try sampler(.nearest)
        linear = try sampler(.linear)
    }

    /// Plain `.bgra8Unorm`, not `_srgb`: the bytes are non-linear sRGB like
    /// the video shader's output, and are drawn as they are.
    func makeTexture(_ image: CursorImage) -> CursorTexture? {
        guard !image.isHidden else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: image.width,
                                                            height: image.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "cursor"
        image.bgra.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: image.width * 4)
        }
        return CursorTexture(texture: texture, image: image)
    }

    func encode(_ cursor: CursorOverlay, videoSize: CGSize, viewport: MTLViewport, targetSize: CGSize,
                encoder: MTLRenderCommandEncoder) {
        let image = cursor.texture.image
        let p = cursor.position
        guard p.x.isFinite, p.y.isFinite, viewport.width > 0, viewport.height > 0 else { return }
        let rect = VideoRenderer.cursorRect(image: image, at: p, videoSize: videoSize, viewport: viewport)

        // Clip to the picture: the viewport's clip space already does, the
        // scissor makes it exact in whole pixels.
        let x0 = max(Int(viewport.originX.rounded(.down)), 0)
        let y0 = max(Int(viewport.originY.rounded(.down)), 0)
        let x1 = min(Int((viewport.originX + viewport.width).rounded(.up)), Int(targetSize.width))
        let y1 = min(Int((viewport.originY + viewport.height).rounded(.up)), Int(targetSize.height))
        guard x1 > x0, y1 > y0, rect.maxX > CGFloat(x0), rect.minX < CGFloat(x1),
              rect.maxY > CGFloat(y0), rect.minY < CGFloat(y1) else { return }

        // Drawable pixels (y down) → the viewport's clip space (y up).
        func clipX(_ x: CGFloat) -> Float { Float((x - viewport.originX) / viewport.width * 2 - 1) }
        func clipY(_ y: CGFloat) -> Float { Float(1 - (y - viewport.originY) / viewport.height * 2) }
        var uniforms = CursorUniforms(rect: SIMD4(clipX(rect.minX), clipY(rect.minY), clipX(rect.maxX),
                                                  clipY(rect.maxY)))

        // Whole-number scales stay pixel-exact; others are filtered.
        let scale = rect.width / CGFloat(image.width)
        let integral = abs(scale - scale.rounded()) < 1e-3

        encoder.pushDebugGroup("cursor")
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(viewport)
        encoder.setScissorRect(MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CursorUniforms>.stride, index: 0)
        encoder.setFragmentTexture(cursor.texture.texture, index: 0)
        encoder.setFragmentSamplerState(integral ? nearest : linear, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.popDebugGroup()
    }
}

extension VideoRenderer {
    /// Uploads `image` as a texture; nil when it is hidden (nothing to draw).
    public func makeCursorTexture(_ image: CursorImage) -> CursorTexture? {
        cursorRenderer.makeTexture(image)
    }

    /// Draws `cursor` over what `encoder` already drew: scaled with the
    /// picture, its hotspot at the position inside `viewport` (the
    /// picture's letterboxed rectangle), clipped to it. `videoSize` is the
    /// output's size in pixels (§7.2), `targetSize` the render target's.
    /// Leaves the encoder's viewport, scissor and pipeline changed.
    public func encodeCursor(_ cursor: CursorOverlay, videoSize: CGSize, viewport: MTLViewport, targetSize: CGSize,
                             encoder: MTLRenderCommandEncoder) {
        cursorRenderer.encode(cursor, videoSize: videoSize, viewport: viewport, targetSize: targetSize,
                              encoder: encoder)
    }

    /// Where the cursor lands, in drawable pixels (top-left origin): one
    /// cursor pixel is as large as one output pixel in the viewport
    /// (`viewport.width / videoSize.width`), and the hotspot pixel's top-left
    /// corner is at `position` (clamped to 0...1) over the viewport. The
    /// origin is rounded to a whole pixel so a 1:1 or 2:1 cursor stays sharp.
    public static func cursorRect(image: CursorImage, at position: CGPoint, videoSize: CGSize,
                                  viewport: MTLViewport) -> CGRect {
        let scale = videoSize.width > 0 ? viewport.width / videoSize.width : 1
        let px = min(max(position.x, 0), 1), py = min(max(position.y, 0), 1)
        let x = viewport.originX + px * viewport.width - image.hotspot.x * scale
        let y = viewport.originY + py * viewport.height - image.hotspot.y * scale
        return CGRect(x: x.rounded(), y: y.rounded(), width: CGFloat(image.width) * scale,
                      height: CGFloat(image.height) * scale)
    }
}
