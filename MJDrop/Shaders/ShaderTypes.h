//
//  ShaderTypes.h
//  MJDrop
//
//  Shared struct definitions between Swift and Metal shaders.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Milkdrop warp mesh vertex (mirrors Milkdrop's MYVERTEX)
struct MilkdropVertex {
    simd_float3 position;       // xyz screen position
    simd_float4 color;          // diffuse RGBA
    simd_float2 uv;             // dynamic (warped) texture coordinates
    simd_float2 uvStatic;       // static (original) texture coordinates
    simd_float2 radAng;         // polar coords (radius, angle) from center
};

// Per-frame uniforms sent to GPU
struct FrameUniforms {
    float time;
    float fps;
    float aspectRatio;
    float decay;

    // Audio
    float bass;
    float mid;
    float treb;
    float bassAtt;
    float midAtt;
    float trebAtt;
    float volume;

    // Warp motion
    float zoom;
    float rot;
    float warpAmount;
    float warpSpeed;
    float warpScale;
    simd_float2 center;
    float stretchX;
    float stretchY;
    simd_float2 translate;

    // Composite
    float gammaAdj;
    float videoEchoAlpha;
    float videoEchoZoom;
    int videoEchoOrientation;

    // Wave
    int waveMode;
    float waveAlpha;
    float waveScale;
    simd_float4 waveColor;
    int additiveWave;

    // Post-processing flags
    int brighten;
    int darken;
    int solarize;
    int invert;
};

// Blur pass uniforms
struct BlurUniforms {
    simd_float2 texelSize;
    int horizontal;
    int padding;
};

// Simple vertex for fullscreen quads and wave lines
struct SimpleVertex {
    simd_float2 position;
    simd_float2 uv;
};

// Buffer indices
enum BufferIndex {
    BufferIndexVertices  = 0,
    BufferIndexUniforms  = 1,
    BufferIndexAudioData = 2
};

// Texture indices
enum TextureIndex {
    TextureIndexPreviousFrame = 0,
    TextureIndexBlur1         = 1,
    TextureIndexBlur2         = 2,
    TextureIndexBlur3         = 3,
    TextureIndexCurrent       = 4
};

#endif
