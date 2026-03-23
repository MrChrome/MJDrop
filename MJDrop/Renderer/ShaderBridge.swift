//
//  ShaderBridge.swift
//  MJDrop
//
//  Swift-side definitions matching the Metal shader structs in ShaderTypes.h.
//  These must have identical memory layout to their C counterparts.
//

import simd

// MARK: - Vertex Types

/// Matches MilkdropVertex in ShaderTypes.h
struct MilkdropVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
    var uv: SIMD2<Float>
    var uvStatic: SIMD2<Float>
    var radAng: SIMD2<Float>
}

/// Matches SimpleVertex in ShaderTypes.h
struct SimpleVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

// MARK: - Uniform Types

/// Matches FrameUniforms in ShaderTypes.h
struct FrameUniforms {
    var time: Float
    var fps: Float
    var aspectRatio: Float
    var decay: Float

    var bass: Float
    var mid: Float
    var treb: Float
    var bassAtt: Float
    var midAtt: Float
    var trebAtt: Float
    var volume: Float

    var zoom: Float
    var rot: Float
    var warpAmount: Float
    var warpSpeed: Float
    var warpScale: Float
    var center: SIMD2<Float>
    var stretchX: Float
    var stretchY: Float
    var translate: SIMD2<Float>

    var gammaAdj: Float
    var videoEchoAlpha: Float
    var videoEchoZoom: Float
    var videoEchoOrientation: Int32

    var waveMode: Int32
    var waveAlpha: Float
    var waveScale: Float
    var waveColor: SIMD4<Float>
    var additiveWave: Int32

    var brighten: Int32
    var darken: Int32
    var solarize: Int32
    var invert: Int32
}

/// Matches BlurUniforms in ShaderTypes.h
struct BlurUniforms {
    var texelSize: SIMD2<Float>
    var horizontal: Int32
    var padding: Int32
}

// MARK: - Buffer / Texture Indices

/// Matches BufferIndex enum in ShaderTypes.h
enum BufferIndex: Int {
    case vertices  = 0
    case uniforms  = 1
    case audioData = 2
}

/// Matches TextureIndex enum in ShaderTypes.h
enum TextureIndex: Int {
    case previousFrame = 0
    case blur1         = 1
    case blur2         = 2
    case blur3         = 3
    case current       = 4
}
