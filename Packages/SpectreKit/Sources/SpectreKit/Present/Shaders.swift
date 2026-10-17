/// Metal shader source, compiled at runtime (`MTLDevice.makeLibrary(source:)`)
/// so the same code works from `swift test`, Xcode and every platform
/// without a prebuilt metallib in a resource bundle.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Keep in sync with VideoUniforms in VideoRenderer.swift.
    struct VideoUniforms {
        float4x4 yuvToRGB;    // range expansion + matrix, ColorDescription.yuvToRGB
        float2 uvScale;       // display size / texture size: crop codec padding (gdp-spec.md §9.4)
        float2 chromaOffset;  // ColorDescription.chromaOffset
    };

    struct VideoVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle from the vertex index, no vertex buffer: the
    // viewport places it (letterboxing is the viewport's job).
    vertex VideoVertexOut video_vertex(uint vid [[vertex_id]], constant VideoUniforms &u [[buffer(0)]]) {
        const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        // Metal's texture origin is top-left, clip space's y points up.
        const float2 uvs[3] = { float2(0, 1), float2(2, 1), float2(0, -1) };
        VideoVertexOut out;
        out.position = float4(positions[vid], 0, 1);
        out.uv = uvs[vid] * u.uvScale;
        return out;
    }

    // NV12 -> R'G'B'. Luma and chroma are the two planes of the decoded
    // CVPixelBuffer's IOSurface, wrapped as textures without a copy.
    fragment float4 video_fragment(VideoVertexOut in [[stage_in]],
                                   texture2d<float> luma [[texture(0)]],
                                   texture2d<float> chroma [[texture(1)]],
                                   constant VideoUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = luma.sample(s, in.uv).r;
        float2 cbcr = chroma.sample(s, in.uv + u.chromaOffset).rg;
        float3 rgb = (u.yuvToRGB * float4(y, cbcr, 1)).rgb;
        return float4(saturate(rgb), 1);
    }

    // Lossless refinement's overlay plane (gdp-spec.md §9.6): opaque where
    // the host wrote tiles, transparent elsewhere, premultiplied (a cleared
    // pixel is all zeros). Drawn over the picture with video_vertex at a
    // uvScale of 1 (the plane is the picture's size), blended
    // (one, one - source alpha). Its pixels are R'G'B' in the output's
    // primaries and transfer, as the video's become: written as they are.
    fragment float4 overlay_fragment(VideoVertexOut in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return plane.sample(s, in.uv);
    }

    // Keep in sync with CursorUniforms in CursorRenderer.swift.
    struct CursorUniforms {
        float4 rect;  // left, top, right, bottom in the video viewport's clip space
    };

    struct CursorVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // A quad (triangle strip) from the vertex index. Whatever falls outside
    // the viewport is clipped, so the cursor never covers a letterbox bar.
    vertex CursorVertexOut cursor_vertex(uint vid [[vertex_id]], constant CursorUniforms &u [[buffer(0)]]) {
        float2 corner = float2(float(vid & 1), float(vid >> 1));
        CursorVertexOut out;
        out.position = float4(mix(u.rect.x, u.rect.z, corner.x), mix(u.rect.y, u.rect.w, corner.y), 0, 1);
        out.uv = corner;
        return out;
    }

    // The host's premultiplied, non-linear sRGB cursor pixels, as they are:
    // blended (one, one - source alpha) over the picture's non-linear R'G'B'.
    fragment float4 cursor_fragment(CursorVertexOut in [[stage_in]],
                                    texture2d<float> image [[texture(0)]],
                                    sampler s [[sampler(0)]]) {
        return image.sample(s, in.uv);
    }
    """
}
