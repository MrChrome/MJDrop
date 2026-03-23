//
//  HardcodedPresets.swift
//  MJDrop
//
//  Built-in preset configurations that demonstrate Milkdrop-style visuals
//  without needing the EEL2 expression engine.
//

import Foundation

enum HardcodedPresets {

    static let cosmicDrift: PresetParameters = {
        var p = PresetParameters()
        p.name = "Cosmic Drift"
        p.zoom = 1.02; p.rot = 0.01; p.warp = 0.8; p.warpSpeed = 0.5
        p.decay = 0.97; p.gammaAdj = 1.2
        p.videoEchoAlpha = 0.4; p.videoEchoZoom = 1.05
        p.waveMode = 0; p.waveAlpha = 0.8; p.waveScale = 0.5
        p.waveR = 0.6; p.waveG = 0.8; p.waveB = 1.0
        p.additiveWave = true
        return p
    }()

    static let vortex: PresetParameters = {
        var p = PresetParameters()
        p.name = "Vortex"
        p.zoom = 1.06; p.rot = 0.03; p.warp = 2.0; p.warpSpeed = 1.5; p.warpScale = 1.5
        p.decay = 0.95; p.gammaAdj = 1.5
        p.waveMode = 2; p.waveAlpha = 1.0; p.waveScale = 0.8
        p.waveR = 1.0; p.waveG = 0.3; p.waveB = 0.1
        p.additiveWave = true; p.brighten = true
        p.meshSizeX = 64; p.meshSizeY = 48
        return p
    }()

    static let mirrorPool: PresetParameters = {
        var p = PresetParameters()
        p.name = "Mirror Pool"
        p.zoom = 0.98; p.rot = -0.005; p.warp = 0.5; p.warpSpeed = 0.3; p.warpScale = 2.0
        p.dx = 0.001; p.decay = 0.985; p.gammaAdj = 1.1
        p.videoEchoAlpha = 0.6; p.videoEchoZoom = 1.02; p.videoEchoOrientation = 3
        p.waveMode = 1; p.waveAlpha = 0.6; p.waveScale = 0.4
        p.waveR = 0.3; p.waveG = 1.0; p.waveB = 0.5
        return p
    }()

    static let tunnelVision: PresetParameters = {
        var p = PresetParameters()
        p.name = "Tunnel Vision"
        p.zoom = 1.04; p.rot = 0.0; p.warp = 1.5; p.warpSpeed = 0.8; p.warpScale = 0.8
        p.cx = 0.5; p.cy = 0.5; p.decay = 0.96; p.gammaAdj = 1.3
        p.videoEchoAlpha = 0.3; p.videoEchoZoom = 1.01; p.videoEchoOrientation = 1
        p.waveMode = 3; p.waveAlpha = 0.9; p.waveScale = 0.6
        p.waveR = 0.9; p.waveG = 0.2; p.waveB = 0.8
        p.additiveWave = true
        return p
    }()

    static let slowDream: PresetParameters = {
        var p = PresetParameters()
        p.name = "Slow Dream"
        p.zoom = 1.005; p.rot = 0.002; p.warp = 0.3; p.warpSpeed = 0.2; p.warpScale = 3.0
        p.decay = 0.992; p.gammaAdj = 1.0
        p.videoEchoAlpha = 0.8; p.videoEchoZoom = 1.0; p.videoEchoOrientation = 2
        p.waveMode = 0; p.waveAlpha = 0.5; p.waveScale = 0.3
        p.waveR = 0.4; p.waveG = 0.6; p.waveB = 0.9
        return p
    }()

    static let all: [PresetParameters] = [cosmicDrift, vortex, mirrorPool, tunnelVision, slowDream]
    static let names: [String] = ["Cosmic Drift", "Vortex", "Mirror Pool", "Tunnel Vision", "Slow Dream"]
}
