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

// Per-vertex colored vertex for custom waves and shapes
struct ColoredVertex {
    simd_float2 position;   // NDC xy
    simd_float4 color;      // per-vertex RGBA
    simd_float2 uv;         // texture coordinates (textured shapes)
};

// V2 shader uniforms — passed to custom warp/comp fragment shaders
struct V2PsUniforms {
    float time;
    float fps;
    float frame;

    float bass;
    float mid;
    float treb;
    float bass_att;
    float mid_att;
    float treb_att;

    float _pad0;  // align to 16 bytes
    float _pad0b;
    float _pad0c;

    simd_float4 aspect;       // .xy = (aspectX, aspectY), .zw = (1/aspectX, 1/aspectY)
    simd_float4 texsize;      // .xy = (width, height), .zw = (1/width, 1/height)

    simd_float4 rand_frame;   // 4 random values regenerated each frame
    simd_float4 rand_preset;  // 4 random values set once per preset load

    simd_float4 roam_cos;     // slowly varying cos values
    simd_float4 roam_sin;     // slowly varying sin values

    // Q variables q1..q32 packed as 8 float4s
    simd_float4 _qa;          // q1, q2, q3, q4
    simd_float4 _qb;          // q5, q6, q7, q8
    simd_float4 _qc;          // q9, q10, q11, q12
    simd_float4 _qd;          // q13, q14, q15, q16
    simd_float4 _qe;          // q17, q18, q19, q20
    simd_float4 _qf;          // q21, q22, q23, q24
    simd_float4 _qg;          // q25, q26, q27, q28
    simd_float4 _qh;          // q29, q30, q31, q32

    float decay;
    float _pad1;
    float _pad2;
    float _pad3;
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
