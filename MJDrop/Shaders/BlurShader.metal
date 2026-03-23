//
//  BlurShader.metal
//  MJDrop
//
//  Separable Gaussian blur used for the cascading blur levels.
//  Each level is half the resolution of the previous.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct BlurVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlurVertexOut blurVertex(
    const device SimpleVertex* vertices [[buffer(0)]],
    uint vid [[vertex_id]])
{
    BlurVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.uv = vertices[vid].uv;
    return out;
}

fragment float4 blurFragment(
    BlurVertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    const device BlurUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear,
                                 address::clamp_to_edge);

    // Optimized 7-tap Gaussian using linear filtering to combine taps
    const float weights[4] = { 0.2270270270, 0.1945945946, 0.1216216216, 0.0540540541 };
    const float offsets[4] = { 0.0, 1.3846153846, 3.2307692308, 5.0 };

    float2 direction = uniforms.horizontal
        ? float2(uniforms.texelSize.x, 0.0)
        : float2(0.0, uniforms.texelSize.y);

    float4 result = sourceTexture.sample(texSampler, in.uv) * weights[0];

    for (int i = 1; i < 4; i++) {
        float2 offset = direction * offsets[i];
        result += sourceTexture.sample(texSampler, in.uv + offset) * weights[i];
        result += sourceTexture.sample(texSampler, in.uv - offset) * weights[i];
    }

    return result;
}
