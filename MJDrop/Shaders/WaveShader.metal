//
//  WaveShader.metal
//  MJDrop
//
//  Audio-reactive waveform overlay rendering.
//

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

struct WaveVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex WaveVertexOut waveVertex(
    const device SimpleVertex* vertices [[buffer(0)]],
    const device FrameUniforms& uniforms [[buffer(BufferIndexUniforms)]],
    uint vid [[vertex_id]])
{
    WaveVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.color = float4(uniforms.waveColor.rgb, uniforms.waveColor.a * uniforms.waveAlpha);
    return out;
}

fragment float4 waveFragment(WaveVertexOut in [[stage_in]])
{
    return in.color;
}
