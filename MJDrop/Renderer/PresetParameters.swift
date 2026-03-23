//
//  PresetParameters.swift
//  MJDrop
//
//  All tunable parameters for a Milkdrop-style visualization preset.
//  Mirrors parameters from .milk preset files.
//

import Foundation

nonisolated struct PresetParameters: Sendable {
    var name: String = "Default"

    // Motion
    var zoom: Float = 1.01
    var zoomExponent: Float = 1.0
    var rot: Float = 0.0
    var warp: Float = 1.0
    var warpSpeed: Float = 1.0
    var warpScale: Float = 1.0
    var cx: Float = 0.5
    var cy: Float = 0.5
    var dx: Float = 0.0
    var dy: Float = 0.0
    var sx: Float = 1.0
    var sy: Float = 1.0

    // Decay / color
    var decay: Float = 0.98
    var gammaAdj: Float = 1.0

    // Video echo
    var videoEchoAlpha: Float = 0.0
    var videoEchoZoom: Float = 1.0
    var videoEchoOrientation: Int = 0

    // Wave
    var waveMode: Int = 0
    var waveAlpha: Float = 0.8
    var waveScale: Float = 1.0
    var waveSmoothing: Float = 0.75
    var waveParam: Float = 0.0
    var waveR: Float = 0.5
    var waveG: Float = 0.5
    var waveB: Float = 1.0
    var waveX: Float = 0.5
    var waveY: Float = 0.5
    var additiveWave: Bool = false
    var waveDots: Bool = false
    var waveThick: Bool = true
    var maximizeWaveColor: Bool = false
    var modWaveAlphaByVolume: Bool = false
    var modWaveAlphaStart: Float = 0.75
    var modWaveAlphaEnd: Float = 0.95

    // Post-processing
    var brighten: Bool = false
    var darken: Bool = false
    var solarize: Bool = false
    var invert: Bool = false
    var darkenCenter: Bool = false

    // Texture
    var texWrap: Bool = true
    var shader: Float = 0.0

    // Mesh
    var meshSizeX: Int = 48
    var meshSizeY: Int = 36

    // Rating
    var rating: Float = 3.0

    // Compiled expressions (populated by MilkFileParser)
    var perFrameInitExpressions: [CompiledAssignment] = []
    var perFrameExpressions: [CompiledAssignment] = []
    var perPixelExpressions: [CompiledAssignment] = []
    var variableTable: VariableTable?
    var contextBridge: ContextBridge?
}
