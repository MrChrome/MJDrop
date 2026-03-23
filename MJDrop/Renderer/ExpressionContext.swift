//
//  ExpressionContext.swift
//  MJDrop
//
//  Variable table and execution context for Milkdrop expression evaluation.
//  Variables are mapped to integer slot indices at parse time for O(1) access
//  during per-frame and per-pixel evaluation.
//

import Foundation

// MARK: - VariableTableBuilder

/// Mutable builder for creating a VariableTable during parsing.
/// Once all variables are registered, call `build()` to get an immutable table.
nonisolated final class VariableTableBuilder: @unchecked Sendable {
    private var nameToSlot: [String: Int] = [:]
    private var slotCount: Int = 0

    /// Register a variable name and return its slot index.
    /// If the variable already exists, returns the existing slot.
    @discardableResult
    func register(_ name: String) -> Int {
        let lower = name.lowercased()
        if let existing = nameToSlot[lower] {
            return existing
        }
        let slot = slotCount
        nameToSlot[lower] = slot
        slotCount += 1
        return slot
    }

    /// Look up a variable's slot without registering it.
    func slot(for name: String) -> Int? {
        nameToSlot[name.lowercased()]
    }

    /// Build an immutable VariableTable from this builder.
    func build() -> VariableTable {
        VariableTable(nameToSlot: nameToSlot, slotCount: slotCount)
    }
}

// MARK: - VariableTable

/// Immutable mapping from variable names to slot indices.
/// Created once after parsing, then shared across all frames.
nonisolated struct VariableTable: Sendable {
    let nameToSlot: [String: Int]
    let slotCount: Int

    func slot(for name: String) -> Int? {
        nameToSlot[name.lowercased()]
    }
}

// MARK: - ExpressionContext

/// Flat array of Float values indexed by slot.
/// Reused across frames and vertices to avoid allocation.
nonisolated final class ExpressionContext: @unchecked Sendable {
    var values: [Float]

    init(slotCount: Int) {
        values = Array(repeating: 0, count: slotCount)
    }

    subscript(slot: Int) -> Float {
        get { values[slot] }
        set { values[slot] = newValue }
    }

    /// Reset all values to zero.
    func reset() {
        for i in values.indices {
            values[i] = 0
        }
    }
}

// MARK: - AudioSnapshot

/// Lightweight value-type snapshot of audio data for use in expression evaluation.
struct AudioSnapshot: Sendable {
    let bass: Float
    let mid: Float
    let treb: Float
    let bassAtt: Float
    let midAtt: Float
    let trebAtt: Float

    init(from analyzer: AudioAnalyzer) {
        bass = analyzer.bass
        mid = analyzer.mid
        treb = analyzer.treb
        bassAtt = analyzer.bassAtt
        midAtt = analyzer.midAtt
        trebAtt = analyzer.trebAtt
    }

    nonisolated init() {
        bass = 0; mid = 0; treb = 0
        bassAtt = 0; midAtt = 0; trebAtt = 0
    }
}

// MARK: - ContextBridge

/// Maps well-known Milkdrop variable names to slot indices.
/// Provides fast read/write between PresetParameters/audio and the context.
nonisolated struct ContextBridge: Sendable {
    // Audio
    let bass: Int?
    let mid: Int?
    let treb: Int?
    let bassAtt: Int?
    let midAtt: Int?
    let trebAtt: Int?

    // Time
    let time: Int?
    let fps: Int?
    let frame: Int?

    // Q variables (q1..q32)
    let q: [Int?]  // 32 entries

    // Motion params
    let zoom: Int?
    let zoomExponent: Int?
    let rot: Int?
    let warp: Int?
    let warpSpeed: Int?
    let warpScale: Int?
    let cx: Int?
    let cy: Int?
    let dx: Int?
    let dy: Int?
    let sx: Int?
    let sy: Int?
    let decay: Int?
    let gammaAdj: Int?

    // Wave params
    let waveMode: Int?
    let waveAlpha: Int?
    let waveScale: Int?
    let waveSmoothing: Int?
    let waveParam: Int?
    let waveR: Int?
    let waveG: Int?
    let waveB: Int?
    let waveX: Int?
    let waveY: Int?
    let additiveWave: Int?
    let waveDots: Int?
    let waveThick: Int?
    let maximizeWaveColor: Int?
    let modWaveAlphaByVolume: Int?
    let modWaveAlphaStart: Int?
    let modWaveAlphaEnd: Int?

    // Post-processing
    let brighten: Int?
    let darken: Int?
    let solarize: Int?
    let invert: Int?
    let darkenCenter: Int?

    // Per-pixel specific
    let x: Int?
    let y: Int?
    let rad: Int?
    let ang: Int?

    // Video echo
    let videoEchoAlpha: Int?
    let videoEchoZoom: Int?
    let videoEchoOrientation: Int?

    // Texture
    let texWrap: Int?

    // Monitor/ob_size
    let meshX: Int?
    let meshY: Int?

    init(table: VariableTable) {
        bass = table.slot(for: "bass")
        mid = table.slot(for: "mid")
        treb = table.slot(for: "treb")
        bassAtt = table.slot(for: "bass_att")
        midAtt = table.slot(for: "mid_att")
        trebAtt = table.slot(for: "treb_att")

        time = table.slot(for: "time")
        fps = table.slot(for: "fps")
        frame = table.slot(for: "frame")

        q = (1...32).map { table.slot(for: "q\($0)") }

        zoom = table.slot(for: "zoom")
        zoomExponent = table.slot(for: "zoomexp")
        rot = table.slot(for: "rot")
        warp = table.slot(for: "warp")
        warpSpeed = table.slot(for: "fwarpanimspeed")
        warpScale = table.slot(for: "fwarpscale")
        cx = table.slot(for: "cx")
        cy = table.slot(for: "cy")
        dx = table.slot(for: "dx")
        dy = table.slot(for: "dy")
        sx = table.slot(for: "sx")
        sy = table.slot(for: "sy")
        decay = table.slot(for: "decay")
        gammaAdj = table.slot(for: "gammaadj")

        waveMode = table.slot(for: "wave_mode")
        waveAlpha = table.slot(for: "wave_a")
        waveScale = table.slot(for: "wave_scale")
        waveSmoothing = table.slot(for: "wave_smoothing")
        waveParam = table.slot(for: "wave_mystery")
        waveR = table.slot(for: "wave_r")
        waveG = table.slot(for: "wave_g")
        waveB = table.slot(for: "wave_b")
        waveX = table.slot(for: "wave_x")
        waveY = table.slot(for: "wave_y")
        additiveWave = table.slot(for: "badditivewaves") // also try "additive"
        waveDots = table.slot(for: "bwavedots")
        waveThick = table.slot(for: "bwavethick")
        maximizeWaveColor = table.slot(for: "bmaximizewavecolor")
        modWaveAlphaByVolume = table.slot(for: "bmodwavealphabyvolume")
        modWaveAlphaStart = table.slot(for: "fmodwavealphastart")
        modWaveAlphaEnd = table.slot(for: "fmodwavealphaend")

        brighten = table.slot(for: "bbrighten")
        darken = table.slot(for: "bdarken")
        solarize = table.slot(for: "bsolarize")
        invert = table.slot(for: "binvert")
        darkenCenter = table.slot(for: "bdarkencenter")

        x = table.slot(for: "x")
        y = table.slot(for: "y")
        rad = table.slot(for: "rad")
        ang = table.slot(for: "ang")

        videoEchoAlpha = table.slot(for: "fvideoechoalpha")
        videoEchoZoom = table.slot(for: "fvideoechozoom")
        videoEchoOrientation = table.slot(for: "nvideoechoorientation")

        texWrap = table.slot(for: "wrap")

        meshX = table.slot(for: "mesh_width")
        meshY = table.slot(for: "mesh_height")
    }

    /// Write preset parameters and audio data into the context before per-frame evaluation.
    func writeInputs(to ctx: ExpressionContext, params: PresetParameters,
                     audio: AudioSnapshot, time: Float, fps fpsVal: Float, frame frameVal: Int) {
        // Audio
        if let s = bass { ctx[s] = audio.bass }
        if let s = mid { ctx[s] = audio.mid }
        if let s = treb { ctx[s] = audio.treb }
        if let s = bassAtt { ctx[s] = audio.bassAtt }
        if let s = midAtt { ctx[s] = audio.midAtt }
        if let s = trebAtt { ctx[s] = audio.trebAtt }

        // Time
        if let s = self.time { ctx[s] = time }
        if let s = self.fps { ctx[s] = fpsVal }
        if let s = frame { ctx[s] = Float(frameVal) }

        // Motion
        if let s = zoom { ctx[s] = params.zoom }
        if let s = zoomExponent { ctx[s] = params.zoomExponent }
        if let s = rot { ctx[s] = params.rot }
        if let s = warp { ctx[s] = params.warp }
        if let s = warpSpeed { ctx[s] = params.warpSpeed }
        if let s = warpScale { ctx[s] = params.warpScale }
        if let s = cx { ctx[s] = params.cx }
        if let s = cy { ctx[s] = params.cy }
        if let s = dx { ctx[s] = params.dx }
        if let s = dy { ctx[s] = params.dy }
        if let s = sx { ctx[s] = params.sx }
        if let s = sy { ctx[s] = params.sy }
        if let s = decay { ctx[s] = params.decay }
        if let s = gammaAdj { ctx[s] = params.gammaAdj }

        // Wave
        if let s = waveMode { ctx[s] = Float(params.waveMode) }
        if let s = waveAlpha { ctx[s] = params.waveAlpha }
        if let s = waveScale { ctx[s] = params.waveScale }
        if let s = waveSmoothing { ctx[s] = params.waveSmoothing }
        if let s = waveParam { ctx[s] = params.waveParam }
        if let s = waveR { ctx[s] = params.waveR }
        if let s = waveG { ctx[s] = params.waveG }
        if let s = waveB { ctx[s] = params.waveB }
        if let s = waveX { ctx[s] = params.waveX }
        if let s = waveY { ctx[s] = params.waveY }
        if let s = additiveWave { ctx[s] = params.additiveWave ? 1 : 0 }
        if let s = waveDots { ctx[s] = params.waveDots ? 1 : 0 }
        if let s = waveThick { ctx[s] = params.waveThick ? 1 : 0 }
        if let s = maximizeWaveColor { ctx[s] = params.maximizeWaveColor ? 1 : 0 }
        if let s = modWaveAlphaByVolume { ctx[s] = params.modWaveAlphaByVolume ? 1 : 0 }
        if let s = modWaveAlphaStart { ctx[s] = params.modWaveAlphaStart }
        if let s = modWaveAlphaEnd { ctx[s] = params.modWaveAlphaEnd }

        // Post-processing
        if let s = brighten { ctx[s] = params.brighten ? 1 : 0 }
        if let s = darken { ctx[s] = params.darken ? 1 : 0 }
        if let s = solarize { ctx[s] = params.solarize ? 1 : 0 }
        if let s = invert { ctx[s] = params.invert ? 1 : 0 }
        if let s = darkenCenter { ctx[s] = params.darkenCenter ? 1 : 0 }

        // Video echo
        if let s = videoEchoAlpha { ctx[s] = params.videoEchoAlpha }
        if let s = videoEchoZoom { ctx[s] = params.videoEchoZoom }
        if let s = videoEchoOrientation { ctx[s] = Float(params.videoEchoOrientation) }

        // Texture
        if let s = texWrap { ctx[s] = params.texWrap ? 1 : 0 }

        // Mesh
        if let s = meshX { ctx[s] = Float(params.meshSizeX) }
        if let s = meshY { ctx[s] = Float(params.meshSizeY) }
    }

    /// Read back per-frame expression results into PresetParameters.
    func readOutputs(from ctx: ExpressionContext, into params: inout PresetParameters) {
        if let s = zoom { params.zoom = ctx[s] }
        if let s = zoomExponent { params.zoomExponent = ctx[s] }
        if let s = rot { params.rot = ctx[s] }
        if let s = warp { params.warp = ctx[s] }
        if let s = warpSpeed { params.warpSpeed = ctx[s] }
        if let s = warpScale { params.warpScale = ctx[s] }
        if let s = cx { params.cx = ctx[s] }
        if let s = cy { params.cy = ctx[s] }
        if let s = dx { params.dx = ctx[s] }
        if let s = dy { params.dy = ctx[s] }
        if let s = sx { params.sx = ctx[s] }
        if let s = sy { params.sy = ctx[s] }
        if let s = decay { params.decay = ctx[s] }
        if let s = gammaAdj { params.gammaAdj = ctx[s] }

        if let s = waveMode { params.waveMode = Int(ctx[s]) }
        if let s = waveAlpha { params.waveAlpha = ctx[s] }
        if let s = waveScale { params.waveScale = ctx[s] }
        if let s = waveSmoothing { params.waveSmoothing = ctx[s] }
        if let s = waveParam { params.waveParam = ctx[s] }
        if let s = waveR { params.waveR = ctx[s] }
        if let s = waveG { params.waveG = ctx[s] }
        if let s = waveB { params.waveB = ctx[s] }
        if let s = waveX { params.waveX = ctx[s] }
        if let s = waveY { params.waveY = ctx[s] }
        if let s = additiveWave { params.additiveWave = ctx[s] > 0.5 }
        if let s = waveDots { params.waveDots = ctx[s] > 0.5 }
        if let s = waveThick { params.waveThick = ctx[s] > 0.5 }
        if let s = maximizeWaveColor { params.maximizeWaveColor = ctx[s] > 0.5 }
        if let s = modWaveAlphaByVolume { params.modWaveAlphaByVolume = ctx[s] > 0.5 }
        if let s = modWaveAlphaStart { params.modWaveAlphaStart = ctx[s] }
        if let s = modWaveAlphaEnd { params.modWaveAlphaEnd = ctx[s] }

        if let s = brighten { params.brighten = ctx[s] > 0.5 }
        if let s = darken { params.darken = ctx[s] > 0.5 }
        if let s = solarize { params.solarize = ctx[s] > 0.5 }
        if let s = invert { params.invert = ctx[s] > 0.5 }
        if let s = darkenCenter { params.darkenCenter = ctx[s] > 0.5 }

        if let s = videoEchoAlpha { params.videoEchoAlpha = ctx[s] }
        if let s = videoEchoZoom { params.videoEchoZoom = ctx[s] }
        if let s = videoEchoOrientation { params.videoEchoOrientation = Int(ctx[s]) }

        if let s = texWrap { params.texWrap = ctx[s] > 0.5 }
    }
}
