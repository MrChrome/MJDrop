//
//  CompositeShader.metal
//  MJDrop
//
//  Final color processing: video echo, blur glow, gamma correction.
//  Outputs to the screen drawable.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct CompositeVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeVertexOut compositeVertex(
    const device SimpleVertex* vertices [[buffer(0)]],
    uint vid [[vertex_id]])
{
    CompositeVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

fragment float4 compositeFragment(
    CompositeVertexOut in [[stage_in]],
    texture2d<float> currentFrame [[texture(TextureIndexCurrent)]],
    texture2d<float> blur1 [[texture(TextureIndexBlur1)]],
    texture2d<float> blur2 [[texture(TextureIndexBlur2)]],
    texture2d<float> blur3 [[texture(TextureIndexBlur3)]],
    const device FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]])
{
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear,
                                 address::clamp_to_edge);

    float4 color = currentFrame.sample(texSampler, in.uv);

    // Video echo: overlay a zoomed/flipped copy of the frame
    if (uniforms.videoEchoAlpha > 0.001) {
        float2 echoUV = (in.uv - 0.5) / uniforms.videoEchoZoom + 0.5;
        if (uniforms.videoEchoOrientation == 1 || uniforms.videoEchoOrientation == 3)
            echoUV.x = 1.0 - echoUV.x;
        if (uniforms.videoEchoOrientation >= 2)
            echoUV.y = 1.0 - echoUV.y;

        float4 echoColor = currentFrame.sample(texSampler, echoUV);
        color = mix(color, echoColor, uniforms.videoEchoAlpha);
    }

    // Blur glow: add soft bloom from cascade, weighted by audio energy
    float glowAmount = saturate(uniforms.volume * 0.5 + 0.05);
    float4 b1 = blur1.sample(texSampler, in.uv);
    float4 b2 = blur2.sample(texSampler, in.uv);
    float4 b3 = blur3.sample(texSampler, in.uv);
    color.rgb += b1.rgb * glowAmount * 0.4;
    color.rgb += b2.rgb * glowAmount * 0.25;
    color.rgb += b3.rgb * glowAmount * 0.15;

    // Post-processing: Milkdrop brighten/darken/solarize/invert
    if (uniforms.brighten) {
        float mx = max(color.r, max(color.g, color.b));
        if (mx > 0.001) {
            color.rgb /= mx;
        }
    }
    if (uniforms.darken) {
        float mn = min(color.r, min(color.g, color.b));
        color.rgb -= mn;
    }
    if (uniforms.solarize) {
        color.r = color.r < 0.5 ? color.r * 2.0 : (1.0 - color.r) * 2.0;
        color.g = color.g < 0.5 ? color.g * 2.0 : (1.0 - color.g) * 2.0;
        color.b = color.b < 0.5 ? color.b * 2.0 : (1.0 - color.b) * 2.0;
    }
    if (uniforms.invert) {
        color.rgb = 1.0 - color.rgb;
    }

    // Gamma correction
    color.rgb = pow(max(color.rgb, 0.0), float3(1.0 / max(uniforms.gammaAdj, 0.1)));

    color.rgb = saturate(color.rgb);
    color.a = 1.0;

    return color;
}
