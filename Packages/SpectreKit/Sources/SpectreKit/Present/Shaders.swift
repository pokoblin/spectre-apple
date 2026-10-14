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
    """
}
