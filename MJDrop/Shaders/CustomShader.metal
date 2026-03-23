//
//  CustomShader.metal
//  MJDrop
//
//  Vertex and fragment shaders for custom waves and custom shapes.
//  Uses ColoredVertex with per-vertex RGBA color.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct CustomVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// Vertex shader for custom waves and shapes (per-vertex color)
vertex CustomVertexOut customColorVertex(
    const device ColoredVertex* vertices [[buffer(0)]],
    uint vid [[vertex_id]])
{
    CustomVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.color = vertices[vid].color;
    out.uv = vertices[vid].uv;
    return out;
}

// Fragment shader: pass-through per-vertex color (waves + untextured shapes)
fragment float4 customColorFragment(CustomVertexOut in [[stage_in]])
{
    return in.color;
}

// Fragment shader: multiply per-vertex color with sampled texture (textured shapes)
fragment float4 customTexturedFragment(
    CustomVertexOut in [[stage_in]],
    texture2d<float> mainTexture [[texture(0)]])
{
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear,
                                 address::repeat);
    float4 texColor = mainTexture.sample(texSampler, in.uv);
    return in.color * texColor;
}
