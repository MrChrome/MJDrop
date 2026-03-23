//
//  CustomShapeRenderer.swift
//  MJDrop
//
//  Renders up to 4 Milkdrop custom shapes. Each shape is a filled polygon
//  (triangle fan) with optional border, optional texture, and per-instance
//  expression evaluation.
//

import Metal
import simd

// MARK: - CustomShapeConfig

nonisolated struct CustomShapeConfig: Sendable {
    var enabled: Bool = false
    var sides: Int = 4
    var additive: Bool = false
    var thickOutline: Bool = false
    var textured: Bool = false
    var numInst: Int = 1
    var x: Float = 0.5
    var y: Float = 0.5
    var rad: Float = 0.1
    var ang: Float = 0.0
    var texZoom: Float = 1.0
    var texAng: Float = 0.0
    var r: Float = 1.0
    var g: Float = 0.0
    var b: Float = 0.0
    var a: Float = 1.0
    var r2: Float = 0.0
    var g2: Float = 1.0
    var b2: Float = 0.0
    var a2: Float = 0.0
    var borderR: Float = 1.0
    var borderG: Float = 1.0
    var borderB: Float = 1.0
    var borderA: Float = 0.1
}

// MARK: - CustomShapePreset

nonisolated struct CustomShapePreset: Sendable {
    var config: CustomShapeConfig = CustomShapeConfig()
    var initExpressions: [CompiledAssignment] = []
    var perFrameExpressions: [CompiledAssignment] = []
    var variableTable: VariableTable?
    var bridge: CustomShapeBridge?
}

// MARK: - CustomShapeBridge

nonisolated struct CustomShapeBridge: Sendable {
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
    let instance: Int?
    let numInst: Int?
    let x: Int?
    let y: Int?
    let rad: Int?
    let ang: Int?
    let sides: Int?
    let r: Int?
    let g: Int?
    let b: Int?
    let a: Int?
    let r2: Int?
    let g2: Int?
    let b2: Int?
    let a2: Int?
    let borderR: Int?
    let borderG: Int?
    let borderB: Int?
    let borderA: Int?
    let texAng: Int?
    let texZoom: Int?
    let additive: Int?
    let thickOutline: Int?
    let textured: Int?

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
        instance = table.slot(for: "instance")
        numInst = table.slot(for: "num_inst")
        x = table.slot(for: "x")
        y = table.slot(for: "y")
        rad = table.slot(for: "rad")
        ang = table.slot(for: "ang")
        sides = table.slot(for: "sides")
        r = table.slot(for: "r")
        g = table.slot(for: "g")
        b = table.slot(for: "b")
        a = table.slot(for: "a")
        r2 = table.slot(for: "r2")
        g2 = table.slot(for: "g2")
        b2 = table.slot(for: "b2")
        a2 = table.slot(for: "a2")
        borderR = table.slot(for: "border_r")
        borderG = table.slot(for: "border_g")
        borderB = table.slot(for: "border_b")
        borderA = table.slot(for: "border_a")
        texAng = table.slot(for: "tex_ang")
        texZoom = table.slot(for: "tex_zoom")
        additive = table.slot(for: "additive")
        thickOutline = table.slot(for: "thickoutline")
        textured = table.slot(for: "textured")
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

    func writeInstanceInputs(to ctx: ExpressionContext, config: CustomShapeConfig,
                             instanceIndex: Int) {
        if let s = instance { ctx[s] = Float(instanceIndex) }
        if let s = numInst { ctx[s] = Float(config.numInst) }
        if let s = x { ctx[s] = config.x }
        if let s = y { ctx[s] = config.y }
        if let s = rad { ctx[s] = config.rad }
        if let s = ang { ctx[s] = config.ang }
        if let s = sides { ctx[s] = Float(config.sides) }
        if let s = r { ctx[s] = config.r }
        if let s = g { ctx[s] = config.g }
        if let s = b { ctx[s] = config.b }
        if let s = a { ctx[s] = config.a }
        if let s = r2 { ctx[s] = config.r2 }
        if let s = g2 { ctx[s] = config.g2 }
        if let s = b2 { ctx[s] = config.b2 }
        if let s = a2 { ctx[s] = config.a2 }
        if let s = borderR { ctx[s] = config.borderR }
        if let s = borderG { ctx[s] = config.borderG }
        if let s = borderB { ctx[s] = config.borderB }
        if let s = borderA { ctx[s] = config.borderA }
        if let s = texAng { ctx[s] = config.texAng }
        if let s = texZoom { ctx[s] = config.texZoom }
        if let s = additive { ctx[s] = config.additive ? 1 : 0 }
        if let s = thickOutline { ctx[s] = config.thickOutline ? 1 : 0 }
        if let s = textured { ctx[s] = config.textured ? 1 : 0 }
    }

    struct ShapeOutputs {
        var x: Float; var y: Float; var rad: Float; var ang: Float
        var sides: Int
        var r: Float; var g: Float; var b: Float; var a: Float
        var r2: Float; var g2: Float; var b2: Float; var a2: Float
        var borderR: Float; var borderG: Float; var borderB: Float; var borderA: Float
        var texAng: Float; var texZoom: Float
        var additive: Bool; var thickOutline: Bool; var textured: Bool
    }

    func readOutputs(from ctx: ExpressionContext, config: CustomShapeConfig) -> ShapeOutputs {
        ShapeOutputs(
            x: x.map { ctx[$0] } ?? config.x,
            y: y.map { ctx[$0] } ?? config.y,
            rad: rad.map { ctx[$0] } ?? config.rad,
            ang: ang.map { ctx[$0] } ?? config.ang,
            sides: sides.map { max(3, Int(ctx[$0])) } ?? config.sides,
            r: r.map { ctx[$0] } ?? config.r,
            g: g.map { ctx[$0] } ?? config.g,
            b: b.map { ctx[$0] } ?? config.b,
            a: a.map { ctx[$0] } ?? config.a,
            r2: r2.map { ctx[$0] } ?? config.r2,
            g2: g2.map { ctx[$0] } ?? config.g2,
            b2: b2.map { ctx[$0] } ?? config.b2,
            a2: a2.map { ctx[$0] } ?? config.a2,
            borderR: borderR.map { ctx[$0] } ?? config.borderR,
            borderG: borderG.map { ctx[$0] } ?? config.borderG,
            borderB: borderB.map { ctx[$0] } ?? config.borderB,
            borderA: borderA.map { ctx[$0] } ?? config.borderA,
            texAng: texAng.map { ctx[$0] } ?? config.texAng,
            texZoom: texZoom.map { ctx[$0] } ?? config.texZoom,
            additive: additive.map { ctx[$0] > 0.5 } ?? config.additive,
            thickOutline: thickOutline.map { ctx[$0] > 0.5 } ?? config.thickOutline,
            textured: textured.map { ctx[$0] > 0.5 } ?? config.textured
        )
    }
}

// MARK: - CustomShapeRenderer

final class CustomShapeRenderer {

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let borderVertexBuffer: MTLBuffer
    private var expressionContexts: [ExpressionContext?] = [nil, nil, nil, nil]

    static let maxShapeVertices = 102
    static let maxSides = 100

    init(device: MTLDevice) {
        vertexBuffer = device.makeBuffer(
            length: Self.maxShapeVertices * MemoryLayout<ColoredVertex>.stride,
            options: .storageModeShared
        )!

        // Pre-build fan indices for triangle fan emulation
        var indices: [UInt32] = []
        for i in 0..<Self.maxSides {
            indices.append(0)
            indices.append(UInt32(i + 1))
            indices.append(UInt32(i + 2))
        }
        indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )!

        borderVertexBuffer = device.makeBuffer(
            length: (Self.maxSides + 1) * MemoryLayout<ColoredVertex>.stride,
            options: .storageModeShared
        )!
    }

    func loadPreset(_ presets: [CustomShapePreset], audio: AudioSnapshot,
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
                presets: [CustomShapePreset],
                audio: AudioSnapshot,
                time: Float, fps: Float, frame: Int,
                aspectRatio: Float,
                mainTexture: MTLTexture?,
                mainContext: ExpressionContext?, mainBridge: ContextBridge?) {

        for i in 0..<min(4, presets.count) {
            let shape = presets[i]
            guard shape.config.enabled,
                  let ctx = expressionContexts[i],
                  let bridge = shape.bridge else { continue }

            let numInst = max(1, shape.config.numInst)
            for inst in 0..<numInst {
                renderInstance(
                    encoder: encoder, pipeline: pipeline,
                    shape: shape, ctx: ctx, bridge: bridge,
                    instanceIndex: inst,
                    audio: audio, time: time, fps: fps, frame: frame,
                    aspectRatio: aspectRatio,
                    mainTexture: mainTexture,
                    mainContext: mainContext, mainBridge: mainBridge
                )
            }
        }
    }

    private func renderInstance(
        encoder: MTLRenderCommandEncoder, pipeline: RenderPipeline,
        shape: CustomShapePreset, ctx: ExpressionContext, bridge: CustomShapeBridge,
        instanceIndex: Int,
        audio: AudioSnapshot, time: Float, fps: Float, frame: Int,
        aspectRatio: Float, mainTexture: MTLTexture?,
        mainContext: ExpressionContext?, mainBridge: ContextBridge?
    ) {
        // Write globals and instance inputs, run per-frame expressions
        bridge.writeGlobals(to: ctx, audio: audio, time: time, fps: fps, frame: frame,
                            mainContext: mainContext, mainBridge: mainBridge)
        bridge.writeInstanceInputs(to: ctx, config: shape.config, instanceIndex: instanceIndex)
        executeExpressions(shape.perFrameExpressions, ctx: ctx)

        let out = bridge.readOutputs(from: ctx, config: shape.config)
        let sides = max(3, min(out.sides, Self.maxSides))
        let vertCount = sides + 2

        let ptr = vertexBuffer.contents().bindMemory(to: ColoredVertex.self, capacity: vertCount)

        // Center vertex
        let cx = out.x * 2.0 - 1.0
        let cy = -(out.y * 2.0 - 1.0)
        ptr[0] = ColoredVertex(
            position: SIMD2<Float>(cx, cy),
            color: SIMD4<Float>(out.r, out.g, out.b, out.a),
            uv: SIMD2<Float>(0.5, 0.5)
        )

        // Edge vertices
        for si in 0...sides {
            let t = Float(si) / Float(sides)
            let angle = t * Float.pi * 2.0 + out.ang

            let edgeX = cx + cosf(angle) * out.rad * 2.0 / max(aspectRatio, 0.001)
            let edgeY = cy + sinf(angle) * out.rad * 2.0

            let texU: Float
            let texV: Float
            if out.textured {
                let texAngle = angle - out.texAng
                let texR = 0.5 / max(out.texZoom, 0.001)
                texU = 0.5 + cosf(texAngle) * texR
                texV = 0.5 + sinf(texAngle) * texR
            } else {
                texU = 0.5 + cosf(angle) * 0.5
                texV = 0.5 + sinf(angle) * 0.5
            }

            ptr[si + 1] = ColoredVertex(
                position: SIMD2<Float>(edgeX, edgeY),
                color: SIMD4<Float>(out.r2, out.g2, out.b2, out.a2),
                uv: SIMD2<Float>(texU, texV)
            )
        }

        // Draw filled polygon
        let pso: MTLRenderPipelineState
        if out.textured, let tex = mainTexture {
            pso = out.additive
                ? pipeline.customTexturedAdditivePipeline
                : pipeline.customTexturedAlphaPipeline
            encoder.setFragmentTexture(tex, index: 0)
        } else {
            pso = out.additive
                ? pipeline.customAdditivePipeline
                : pipeline.customAlphaPipeline
        }

        encoder.setRenderPipelineState(pso)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: sides * 3,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        // Draw border
        if out.borderA > 0.001 {
            let borderPtr = borderVertexBuffer.contents()
                .bindMemory(to: ColoredVertex.self, capacity: sides + 1)

            for si in 0...sides {
                let edgeVert = ptr[si + 1]
                borderPtr[si] = ColoredVertex(
                    position: edgeVert.position,
                    color: SIMD4<Float>(out.borderR, out.borderG, out.borderB, out.borderA),
                    uv: SIMD2<Float>(0, 0)
                )
            }

            let borderPso = out.additive
                ? pipeline.customAdditivePipeline
                : pipeline.customAlphaPipeline
            encoder.setRenderPipelineState(borderPso)
            encoder.setVertexBuffer(borderVertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: sides + 1)

            if out.thickOutline {
                encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: sides + 1)
            }
        }
    }
}
