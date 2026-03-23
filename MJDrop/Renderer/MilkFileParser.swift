//
//  MilkFileParser.swift
//  MJDrop
//
//  Parses Milkdrop .milk preset files (INI-style format) into PresetParameters.
//  Handles all numeric parameters; expression code and shaders are stored as
//  raw strings for future use.
//

import Foundation

nonisolated struct MilkFileParser {

    /// Parse a .milk file at the given URL into a PresetParameters struct.
    static func parse(url: URL) -> PresetParameters? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            // Try other encodings common in Windows files
            guard let content = try? String(contentsOf: url, encoding: .windowsCP1252) else {
                return nil
            }
            return parseContent(content, name: url.deletingPathExtension().lastPathComponent)
        }
        return parseContent(content, name: url.deletingPathExtension().lastPathComponent)
    }

    private static func parseContent(_ content: String, name: String) -> PresetParameters {
        var p = PresetParameters()
        p.name = name

        // Build a dictionary of all key=value pairs from the [preset00] section
        let values = parseINI(content)

        // Motion / transform
        p.zoom = values.float("zoom") ?? p.zoom
        p.zoomExponent = values.float("fZoomExponent") ?? p.zoomExponent
        p.rot = values.float("rot") ?? p.rot
        p.warp = values.float("warp") ?? p.warp
        p.warpSpeed = values.float("fWarpAnimSpeed") ?? p.warpSpeed
        p.warpScale = values.float("fWarpScale") ?? p.warpScale
        p.cx = values.float("cx") ?? p.cx
        p.cy = values.float("cy") ?? p.cy
        p.dx = values.float("dx") ?? p.dx
        p.dy = values.float("dy") ?? p.dy
        p.sx = values.float("sx") ?? p.sx
        p.sy = values.float("sy") ?? p.sy

        // Decay / gamma
        p.decay = values.float("fDecay") ?? p.decay
        p.gammaAdj = values.float("fGammaAdj") ?? p.gammaAdj

        // Video echo
        p.videoEchoAlpha = values.float("fVideoEchoAlpha") ?? p.videoEchoAlpha
        p.videoEchoZoom = values.float("fVideoEchoZoom") ?? p.videoEchoZoom
        p.videoEchoOrientation = values.int("nVideoEchoOrientation") ?? p.videoEchoOrientation

        // Wave
        p.waveMode = values.int("nWaveMode") ?? p.waveMode
        p.waveAlpha = values.float("fWaveAlpha") ?? p.waveAlpha
        p.waveScale = values.float("fWaveScale") ?? p.waveScale
        p.waveSmoothing = values.float("fWaveSmoothing") ?? p.waveSmoothing
        p.waveParam = values.float("fWaveParam") ?? p.waveParam
        p.waveR = values.float("wave_r") ?? p.waveR
        p.waveG = values.float("wave_g") ?? p.waveG
        p.waveB = values.float("wave_b") ?? p.waveB
        p.waveX = values.float("wave_x") ?? p.waveX
        p.waveY = values.float("wave_y") ?? p.waveY
        p.additiveWave = values.bool("bAdditiveWaves") ?? p.additiveWave
        p.waveDots = values.bool("bWaveDots") ?? p.waveDots
        p.waveThick = values.bool("bWaveThick") ?? p.waveThick
        p.maximizeWaveColor = values.bool("bMaximizeWaveColor") ?? p.maximizeWaveColor
        p.modWaveAlphaByVolume = values.bool("bModWaveAlphaByVolume") ?? p.modWaveAlphaByVolume
        p.modWaveAlphaStart = values.float("fModWaveAlphaStart") ?? p.modWaveAlphaStart
        p.modWaveAlphaEnd = values.float("fModWaveAlphaEnd") ?? p.modWaveAlphaEnd

        // Post-processing
        p.brighten = values.bool("bBrighten") ?? p.brighten
        p.darken = values.bool("bDarken") ?? p.darken
        p.solarize = values.bool("bSolarize") ?? p.solarize
        p.invert = values.bool("bInvert") ?? p.invert
        p.darkenCenter = values.bool("bDarkenCenter") ?? p.darkenCenter

        // Texture
        p.texWrap = values.bool("bTexWrap") ?? p.texWrap
        p.shader = values.float("fShader") ?? p.shader

        // Rating
        p.rating = values.float("fRating") ?? p.rating

        // Compile expressions
        compileExpressions(from: values, into: &p)

        return p
    }

    /// Extract per_frame_N=, per_pixel_N=, and per_frame_init_N= lines,
    /// sort by N, parse and compile them into ASTs.
    private static func compileExpressions(from values: [String: String], into p: inout PresetParameters) {
        let builder = VariableTableBuilder()

        // Pre-register all well-known Milkdrop variables so they get consistent slots
        let knownVars = [
            "bass", "mid", "treb", "bass_att", "mid_att", "treb_att",
            "time", "fps", "frame",
            "zoom", "zoomexp", "rot", "warp", "fwarpanimspeed", "fwarpscale",
            "cx", "cy", "dx", "dy", "sx", "sy", "decay", "gammaadj",
            "wave_mode", "wave_a", "wave_scale", "wave_smoothing", "wave_mystery",
            "wave_r", "wave_g", "wave_b", "wave_x", "wave_y",
            "badditivewaves", "bwavedots", "bwavethick", "bmaximizewavecolor",
            "bmodwavealphabyvolume", "fmodwavealphastart", "fmodwavealphaend",
            "bbrighten", "bdarken", "bsolarize", "binvert", "bdarkencenter",
            "x", "y", "rad", "ang",
            "fvideoechoalpha", "fvideoechozoom", "nvideoechoorientation",
            "wrap", "mesh_width", "mesh_height",
            "ob_size", "ob_r", "ob_g", "ob_b", "ob_a",
            "ib_size", "ib_r", "ib_g", "ib_b", "ib_a",
            "mv_x", "mv_y", "mv_dx", "mv_dy", "mv_l", "mv_r", "mv_g", "mv_b", "mv_a",
            "b1n", "b2n", "b3n", "b1x", "b2x", "b3x", "b1ed"
        ]
        // Also register q1..q32
        for name in knownVars { builder.register(name) }
        for i in 1...32 { builder.register("q\(i)") }

        // Collect and sort expression lines by their numeric suffix
        var perFrameInit: [(Int, String)] = []
        var perFrame: [(Int, String)] = []
        var perPixel: [(Int, String)] = []

        for (key, value) in values {
            let lk = key.lowercased()
            if lk.hasPrefix("per_frame_init_") {
                if let n = Int(lk.dropFirst("per_frame_init_".count)) {
                    perFrameInit.append((n, value))
                }
            } else if lk.hasPrefix("per_frame_") {
                if let n = Int(lk.dropFirst("per_frame_".count)) {
                    perFrame.append((n, value))
                }
            } else if lk.hasPrefix("per_pixel_") {
                if let n = Int(lk.dropFirst("per_pixel_".count)) {
                    perPixel.append((n, value))
                }
            }
        }

        // Sort by line number to maintain correct execution order
        perFrameInit.sort { $0.0 < $1.0 }
        perFrame.sort { $0.0 < $1.0 }
        perPixel.sort { $0.0 < $1.0 }

        // Parse each expression line
        p.perFrameInitExpressions = perFrameInit.flatMap { ExpressionParser.parseLine($0.1, builder: builder) }
        p.perFrameExpressions = perFrame.flatMap { ExpressionParser.parseLine($0.1, builder: builder) }
        p.perPixelExpressions = perPixel.flatMap { ExpressionParser.parseLine($0.1, builder: builder) }

        // Build the immutable table and bridge
        let table = builder.build()
        p.variableTable = table
        p.contextBridge = ContextBridge(table: table)
    }

    /// Parse the INI content into a flat key-value dictionary.
    /// Handles the [preset00] section and ignores other sections.
    private static func parseINI(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        var inPresetSection = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
                continue
            }

            // Section headers
            if trimmed.hasPrefix("[") {
                inPresetSection = trimmed.lowercased().hasPrefix("[preset")
                continue
            }

            // For lines before any section header, treat as preset section
            // (some .milk files don't have [preset00] header for the main params)
            // Key=value parsing
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<equalsIndex])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Only store values from the preset section (or before any section)
            if inPresetSection || !trimmed.hasPrefix("[") {
                result[key] = value
            }
        }

        return result
    }
}

// MARK: - Dictionary Helpers

private extension Dictionary where Key == String, Value == String {
    nonisolated func float(_ key: String) -> Float? {
        guard let str = self[key] else { return nil }
        return Float(str)
    }

    nonisolated func int(_ key: String) -> Int? {
        guard let str = self[key] else { return nil }
        // Handle both "1" and "1.000000" formats
        if let i = Int(str) { return i }
        if let f = Float(str) { return Int(f) }
        return nil
    }

    nonisolated func bool(_ key: String) -> Bool? {
        guard let i = int(key) else { return nil }
        return i != 0
    }
}
