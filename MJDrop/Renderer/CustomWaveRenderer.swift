//
//  CustomWaveRenderer.swift
//  MJDrop
//
//  Renders up to 4 Milkdrop custom waves. Each wave has its own expression
//  context with per-frame and per-point expressions that generate vertices
//  with per-vertex colors.
//

import Metal
import simd

// MARK: - CustomWaveConfig

nonisolated struct CustomWaveConfig: Sendable {
    var enabled: Bool = false
    var samples: Int = 512
    var sep: Int = 0
    var bSpectrum: Bool = false
    var bUseDots: Bool = false
    var bDrawThick: Bool = false
    var bAdditive: Bool = false
    var scaling: Float = 1.0
    var smoothing: Float = 0.5
    var r: Float = 1.0
    var g: Float = 1.0
    var b: Float = 1.0
    var a: Float = 1.0
}

// MARK: - CustomWavePreset

nonisolated struct CustomWavePreset: Sendable {
    var config: CustomWaveConfig = CustomWaveConfig()
    var initExpressions: [CompiledAssignment] = []
    var perFrameExpressions: [CompiledAssignment] = []
    var perPointExpressions: [CompiledAssignment] = []
    var variableTable: VariableTable?
    var bridge: CustomWaveBridge?
}

// MARK: - CustomWaveBridge

nonisolated struct CustomWaveBridge: Sendable {
    let time: Int?
    let fps: Int?
    let frame: Int?
    let bass: Int?
    let mid: Int?
    let treb: Int?
    let bassAtt: Int?
    let midAtt: Int?
    let trebAtt: Int?
    let q: [Int?]
    let t: [Int?]
    let sample: Int?
    let value1: Int?
    let value2: Int?
    let x: Int?
    let y: Int?
    let r: Int?
    let g: Int?
    let b: Int?
    let a: Int?

    init(table: VariableTable) {
        time = table.slot(for: "time")
        fps = table.slot(for: "fps")
        frame = table.slot(for: "frame")
        bass = table.slot(for: "bass")
        mid = table.slot(for: "mid")
        treb = table.slot(for: "treb")
        bassAtt = table.slot(for: "bass_att")
        midAtt = table.slot(for: "mid_att")
        trebAtt = table.slot(for: "treb_att")
        q = (1...32).map { table.slot(for: "q\($0)") }
        t = (1...8).map { table.slot(for: "t\($0)") }
        sample = table.slot(for: "sample")
        value1 = table.slot(for: "value1")
        value2 = table.slot(for: "value2")
        x = table.slot(for: "x")
        y = table.slot(for: "y")
        r = table.slot(for: "r")
        g = table.slot(for: "g")
        b = table.slot(for: "b")
        a = table.slot(for: "a")
    }

    func writeGlobals(to ctx: ExpressionContext, audio: AudioSnapshot,
                      time: Float, fps: Float, frame: Int,
                      mainContext: ExpressionContext?, mainBridge: ContextBridge?) {
        if let s = self.time { ctx[s] = time }
        if let s = self.fps { ctx[s] = fps }
        if let s = self.frame { ctx[s] = Float(frame) }
        if let s = bass { ctx[s] = audio.bass }
        if let s = mid { ctx[s] = audio.mid }
        if let s = treb { ctx[s] = audio.treb }
        if let s = bassAtt { ctx[s] = audio.bassAtt }
        if let s = midAtt { ctx[s] = audio.midAtt }
        if let s = trebAtt { ctx[s] = audio.trebAtt }
        if let mainCtx = mainContext, let mainBr = mainBridge {
            for i in 0..<32 {
                if let srcSlot = mainBr.q[i], let dstSlot = q[i] {
                    ctx[dstSlot] = mainCtx[srcSlot]
                }
            }
        }
    }

    func writePerPointInputs(to ctx: ExpressionContext,
                             sample: Float, value1: Float, value2: Float,
                             config: CustomWaveConfig) {
        if let s = self.sample { ctx[s] = sample }
        if let s = self.value1 { ctx[s] = value1 }
        if let s = self.value2 { ctx[s] = value2 }
        if let s = x { ctx[s] = 0.5 }
        if let s = y { ctx[s] = 0.5 }
        if let s = r { ctx[s] = config.r }
        if let s = g { ctx[s] = config.g }
        if let s = b { ctx[s] = config.b }
        if let s = a { ctx[s] = config.a }
    }
}

// MARK: - CustomWaveRenderer

final class CustomWaveRenderer {

    private let vertexBuffer: MTLBuffer
    private var expressionContexts: [ExpressionContext?] = [nil, nil, nil, nil]

    static let maxSamples = 512

    init(device: MTLDevice) {
        vertexBuffer = device.makeBuffer(
            length: Self.maxSamples * MemoryLayout<ColoredVertex>.stride,
            options: .storageModeShared
        )!
    }

    func loadPreset(_ presets: [CustomWavePreset], audio: AudioSnapshot,
                    mainContext: ExpressionContext?, mainBridge: ContextBridge?) {
        for i in 0..<4 {
            guard i < presets.count, presets[i].config.enabled,
                  let table = presets[i].variableTable else {
                expressionContexts[i] = nil
                continue
            }
            let ctx = ExpressionContext(slotCount: table.slotCount)
            expressionContexts[i] = ctx
            if let bridge = presets[i].bridge {
                bridge.writeGlobals(to: ctx, audio: audio, time: 0, fps: 60, frame: 0,
                                    mainContext: mainContext, mainBridge: mainBridge)
                executeExpressions(presets[i].initExpressions, ctx: ctx)
            }
        }
    }

    func encode(encoder: MTLRenderCommandEncoder,
                pipeline: RenderPipeline,
                presets: [CustomWavePreset],
                waveformSamples: [Float],
                fftMagnitudes: [Float],
                audio: AudioSnapshot,
                time: Float, fps: Float, frame: Int,
                mainContext: ExpressionContext?, mainBridge: ContextBridge?) {

        for i in 0..<min(4, presets.count) {
            let wave = presets[i]
            guard wave.config.enabled,
                  let ctx = expressionContexts[i],
                  let bridge = wave.bridge else { continue }

            let vertexCount = generateVertices(
                wave: wave, ctx: ctx, bridge: bridge,
                waveformSamples: waveformSamples,
                fftMagnitudes: fftMagnitudes,
                audio: audio, time: time, fps: fps, frame: frame,
                mainContext: mainContext, mainBridge: mainBridge
            )
            guard vertexCount > 0 else { continue }

            let pso = wave.config.bAdditive
                ? pipeline.customAdditivePipeline
                : pipeline.customAlphaPipeline

            encoder.setRenderPipelineState(pso)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            let primitiveType: MTLPrimitiveType = wave.config.bUseDots ? .point : .lineStrip
            encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertexCount)

            if wave.config.bDrawThick && !wave.config.bUseDots {
                encoder.drawPrimitives(type: primitiveType, vertexStart: 0, vertexCount: vertexCount)
            }
        }
    }

    private func generateVertices(
        wave: CustomWavePreset, ctx: ExpressionContext, bridge: CustomWaveBridge,
        waveformSamples: [Float], fftMagnitudes: [Float],
        audio: AudioSnapshot, time: Float, fps: Float, frame: Int,
        mainContext: ExpressionContext?, mainBridge: ContextBridge?
    ) -> Int {
        let config = wave.config
        let sampleCount = min(config.samples, Self.maxSamples)
        guard sampleCount > 0 else { return 0 }

        // Run per-frame expressions
        bridge.writeGlobals(to: ctx, audio: audio, time: time, fps: fps, frame: frame,
                            mainContext: mainContext, mainBridge: mainBridge)
        executeExpressions(wave.perFrameExpressions, ctx: ctx)

        let ptr = vertexBuffer.contents().bindMemory(to: ColoredVertex.self, capacity: sampleCount)

        // Run per-point expression for each sample
        for si in 0..<sampleCount {
            let t = Float(si) / Float(max(sampleCount - 1, 1))

            let val1: Float
            let val2: Float
            if config.bSpectrum {
                let idx = min(Int(t * Float(fftMagnitudes.count - 1)), fftMagnitudes.count - 1)
                val1 = fftMagnitudes[max(idx, 0)] * config.scaling
                val2 = val1
            } else {
                let idx = min(Int(t * Float(waveformSamples.count - 1)), waveformSamples.count - 1)
                val1 = waveformSamples[max(idx, 0)] * config.scaling
                let idx2 = min(idx + config.sep, waveformSamples.count - 1)
                val2 = waveformSamples[max(idx2, 0)] * config.scaling
            }

            bridge.writePerPointInputs(to: ctx, sample: t, value1: val1, value2: val2,
                                       config: config)
            executeExpressions(wave.perPointExpressions, ctx: ctx)

            // Read outputs
            let px = bridge.x.map { ctx[$0] } ?? 0.5
            let py = bridge.y.map { ctx[$0] } ?? 0.5
            let pr = bridge.r.map { ctx[$0] } ?? 1.0
            let pg = bridge.g.map { ctx[$0] } ?? 1.0
            let pb = bridge.b.map { ctx[$0] } ?? 1.0
            let pa = bridge.a.map { ctx[$0] } ?? 1.0

            // Convert 0..1 to NDC -1..1
            let ndcX = px * 2.0 - 1.0
            let ndcY = -(py * 2.0 - 1.0)

            ptr[si] = ColoredVertex(
                position: SIMD2<Float>(ndcX, ndcY),
                color: SIMD4<Float>(pr, pg, pb, pa),
                uv: SIMD2<Float>(t, 0)
            )
        }

        // Apply smoothing
        if config.smoothing > 0.001 && sampleCount > 2 && !config.bUseDots {
            let sm = config.smoothing
            var tempPositions = [SIMD2<Float>](repeating: .zero, count: sampleCount)
            for si in 0..<sampleCount { tempPositions[si] = ptr[si].position }
            for si in 1..<(sampleCount - 1) {
                let prev = tempPositions[si - 1]
                let curr = tempPositions[si]
                let next = tempPositions[si + 1]
                ptr[si].position = curr * (1.0 - sm) + (prev + next) * (sm * 0.5)
            }
        }

        return sampleCount
    }
}
