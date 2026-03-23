//
//  WarpShader.metal
//  MJDrop
//
//  The core Milkdrop feedback shader. Samples the previous frame's texture
//  through the warped mesh grid, applying decay to create trails and motion.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct WarpVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float2 uvStatic;
    float2 radAng;
};

vertex WarpVertexOut warpVertex(
    const device MilkdropVertex* vertices [[buffer(BufferIndexVertices)]],
    const device FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]],
    uint vid [[vertex_id]])
{
    MilkdropVertex in = vertices[vid];
    WarpVertexOut out;

    // Map 0..1 grid position to -1..1 NDC
    out.position = float4(in.position.xy * 2.0 - 1.0, 0.0, 1.0);
    out.position.y = -out.position.y; // Metal Y-flip
    out.color = in.color;
    out.uv = in.uv;
    out.uvStatic = in.uvStatic;
    out.radAng = in.radAng;

    return out;
}

// V2 warp vertex output — includes uv_orig for v2 fragment shaders
struct WarpV2VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;         // warped UV
    float2 uv_orig;    // original (static) UV
    float2 rad_ang;    // polar coords
};

vertex WarpV2VertexOut warpVertexV2(
    const device MilkdropVertex* vertices [[buffer(BufferIndexVertices)]],
    const device FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]],
    uint vid [[vertex_id]])
{
    MilkdropVertex in = vertices[vid];
    WarpV2VertexOut out;

    out.position = float4(in.position.xy * 2.0 - 1.0, 0.0, 1.0);
    out.position.y = -out.position.y;
    out.color = in.color;
    out.uv = in.uv;
    out.uv_orig = in.uvStatic;
    out.rad_ang = in.radAng;

    return out;
}

fragment float4 warpFragment(
    WarpVertexOut in [[stage_in]],
    texture2d<float> previousFrame [[texture(TextureIndexPreviousFrame)]],
    const device FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]])
{
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear,
                                 address::repeat);

    // Sample previous frame at warped UV coordinates
    float4 color = previousFrame.sample(texSampler, in.uv);

    // Apply decay: Milkdrop specifies decay at 30fps, scale to actual fps
    float fpsScale = 30.0 / max(uniforms.fps, 1.0);
    float decay = pow(uniforms.decay, fpsScale);
    color.rgb *= decay;

    return color;
}
