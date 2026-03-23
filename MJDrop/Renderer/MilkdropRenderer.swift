//
//  MilkdropRenderer.swift
//  MJDrop
//
//  Main Milkdrop renderer. Implements MTKViewDelegate to drive the
//  Metal rendering loop. Orchestrates the multi-pass pipeline:
//    1. Warp pass — mesh grid samples previous frame with warped UVs
//    2. Wave overlay — audio-reactive waveform drawn on top
//    3. Blur cascade — generate glow textures
//    4. Composite pass — final color processing to screen
//

import Metal
import MetalKit

final class MilkdropRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: RenderPipeline
    private let textureManager: TextureManager
    private var meshGrid: MeshGrid
    private let blurPass: BlurPass
    private let audioAnalyzer: AudioAnalyzer

    private var currentPreset: PresetParameters
    private var basePreset: PresetParameters  // Original params before expression modification
    private let quadBuffer: MTLBuffer
    private let waveVertexBuffer: MTLBuffer

    private let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastFrameTime: CFAbsoluteTime = 0
    private var fps: Float = 60
    private var frameCount: Int = 0

    // Expression evaluation
    private var expressionContext: ExpressionContext?

    // Audio data bridge — set from main thread
    var fftMagnitudes: [Float] = Array(repeating: 0, count: 64)
    var waveformSamples: [Float] = Array(repeating: 0, count: 512)

    // Preset management
    private var presetIndex: Int = 0

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.audioAnalyzer = AudioAnalyzer()
        self.textureManager = TextureManager(device: device)
        self.currentPreset = HardcodedPresets.all[0]
        self.basePreset = self.currentPreset

        let library = device.makeDefaultLibrary()!
        self.pipeline = try RenderPipeline(device: device, library: library, drawableFormat: pixelFormat)
        self.meshGrid = MeshGrid(device: device,
                                  width: currentPreset.meshSizeX,
                                  height: currentPreset.meshSizeY)
        self.blurPass = BlurPass(device: device)

        // Fullscreen quad for composite pass
        let quadVertices: [SimpleVertex] = [
            SimpleVertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
            SimpleVertex(position: SIMD2( 1, -1), uv: SIMD2(1, 1)),
            SimpleVertex(position: SIMD2(-1,  1), uv: SIMD2(0, 0)),
            SimpleVertex(position: SIMD2( 1, -1), uv: SIMD2(1, 1)),
            SimpleVertex(position: SIMD2( 1,  1), uv: SIMD2(1, 0)),
            SimpleVertex(position: SIMD2(-1,  1), uv: SIMD2(0, 0)),
        ]
        quadBuffer = device.makeBuffer(
            bytes: quadVertices,
            length: quadVertices.count * MemoryLayout<SimpleVertex>.stride,
            options: .storageModeShared
        )!

        waveVertexBuffer = device.makeBuffer(
            length: 512 * MemoryLayout<SimpleVertex>.stride,
            options: .storageModeShared
        )!

        super.init()
    }

    func loadPreset(_ preset: PresetParameters) {
        basePreset = preset
        currentPreset = preset
        frameCount = 0
        meshGrid = meshGrid.rebuildIfNeeded(device: device, preset: preset)

        // Set up expression context if preset has expressions
        if let table = preset.variableTable, table.slotCount > 0 {
            let ctx = ExpressionContext(slotCount: table.slotCount)
            expressionContext = ctx

            // Run init expressions once
            if let bridge = preset.contextBridge {
                bridge.writeInputs(to: ctx, params: preset, audio: AudioSnapshot(from: audioAnalyzer),
                                   time: 0, fps: 60, frame: 0)
                executeExpressions(preset.perFrameInitExpressions, ctx: ctx)
                bridge.readOutputs(from: ctx, into: &currentPreset)
            }
        } else {
            expressionContext = nil
        }

        // Clear the feedback textures so the old preset's colors don't bleed through
        if let commandBuffer = commandQueue.makeCommandBuffer() {
            textureManager.clear(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }

    func nextPreset() {
        presetIndex = (presetIndex + 1) % HardcodedPresets.all.count
        loadPreset(HardcodedPresets.all[presetIndex])
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        textureManager.resize(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastFrameTime
        lastFrameTime = now
        fps = dt > 0 ? Float(1.0 / dt) : 60
        let time = Float(now - startTime)

        // Update audio
        audioAnalyzer.update(fftMagnitudes: fftMagnitudes)
        frameCount += 1

        // Per-frame expression evaluation: reset to base params, then run expressions
        if let ctx = expressionContext, let bridge = basePreset.contextBridge {
            // Start from base preset each frame (expressions modify from initial values)
            currentPreset = basePreset
            let audioSnap = AudioSnapshot(from: audioAnalyzer)
            bridge.writeInputs(to: ctx, params: currentPreset, audio: audioSnap,
                               time: time, fps: fps, frame: frameCount)
            executeExpressions(basePreset.perFrameExpressions, ctx: ctx)
            bridge.readOutputs(from: ctx, into: &currentPreset)
        }

        // Update mesh (with per-pixel expressions if available)
        meshGrid.updateVertices(params: currentPreset, audio: audioAnalyzer, time: time, fps: fps,
                                perPixelExpressions: basePreset.perPixelExpressions,
                                expressionContext: expressionContext,
                                contextBridge: basePreset.contextBridge)

        // Build uniforms
        var uniforms = buildFrameUniforms(time: time)

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              textureManager.frontTexture != nil,
              textureManager.backTexture != nil
        else { return }

        // Pass 1: Warp
        encodeWarpPass(commandBuffer: commandBuffer, uniforms: &uniforms)

        // Pass 2: Wave overlay
        encodeWavePass(commandBuffer: commandBuffer, uniforms: &uniforms, time: time)

        // Pass 3: Blur cascade
        blurPass.encode(
            commandBuffer: commandBuffer,
            pipeline: pipeline.blurPipeline,
            sourceTexture: textureManager.frontTexture,
            textureManager: textureManager
        )

        // Pass 4: Composite to screen
        encodeCompositePass(commandBuffer: commandBuffer, uniforms: &uniforms,
                            drawable: drawable, view: view)

        // Swap: front becomes back for next frame
        textureManager.swap()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Pass Encoding

    private func encodeWarpPass(commandBuffer: MTLCommandBuffer, uniforms: inout FrameUniforms) {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = textureManager.frontTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(pipeline.warpPipeline)
        encoder.setVertexBuffer(meshGrid.vertexBuffer, offset: 0, index: BufferIndex.vertices.rawValue)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride,
                               index: BufferIndex.uniforms.rawValue)
        encoder.setFragmentTexture(textureManager.backTexture,
                                    index: TextureIndex.previousFrame.rawValue)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride,
                                  index: BufferIndex.uniforms.rawValue)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: meshGrid.indexCount,
            indexType: .uint32,
            indexBuffer: meshGrid.indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()
    }

    private func encodeWavePass(commandBuffer: MTLCommandBuffer, uniforms: inout FrameUniforms, time: Float) {
        let waveCount = generateWaveVertices(time: time)
        guard waveCount > 1 else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = textureManager.frontTexture
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        let wavePipeline = currentPreset.additiveWave
            ? pipeline.wavePipelineAdditive
            : pipeline.wavePipelineAlpha
        encoder.setRenderPipelineState(wavePipeline)
        encoder.setVertexBuffer(waveVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride,
                               index: BufferIndex.uniforms.rawValue)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: waveCount)
        encoder.endEncoding()
    }

    private func encodeCompositePass(commandBuffer: MTLCommandBuffer,
                                      uniforms: inout FrameUniforms,
                                      drawable: CAMetalDrawable,
                                      view: MTKView) {
        guard let passDesc = view.currentRenderPassDescriptor else { return }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipeline.compositePipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)

        encoder.setFragmentTexture(textureManager.frontTexture,
                                    index: TextureIndex.current.rawValue)
        for i in 0..<min(3, textureManager.blurTextures.count) {
            encoder.setFragmentTexture(textureManager.blurTextures[i].source,
                                        index: TextureIndex.blur1.rawValue + i)
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride,
                                  index: BufferIndex.uniforms.rawValue)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    // MARK: - Helpers

    private func buildFrameUniforms(time: Float) -> FrameUniforms {
        let p = currentPreset
        let a = audioAnalyzer

        // Compute effective wave color
        var wr = p.waveR
        var wg = p.waveG
        var wb = p.waveB
        var effectiveWaveAlpha = p.waveAlpha

        // Only auto-generate colors for presets WITHOUT expressions
        // (expression-based presets set their own colors dynamically)
        let hasExpressions = !basePreset.perFrameExpressions.isEmpty
        if !hasExpressions {
            let colorBrightness = wr + wg + wb
            if colorBrightness < 0.15 {
                wr = 0.5 + 0.5 * sin(time * 0.63)
                wg = 0.5 + 0.5 * sin(time * 0.81 + 1.3)
                wb = 0.5 + 0.5 * sin(time * 1.13 + 2.7)
            }
            effectiveWaveAlpha = max(p.waveAlpha, 0.1)
        }

        return FrameUniforms(
            time: time, fps: fps,
            aspectRatio: textureManager.width > 0
                ? Float(textureManager.width) / Float(max(textureManager.height, 1))
                : 1.0,
            decay: p.decay,
            bass: a.bass, mid: a.mid, treb: a.treb,
            bassAtt: a.bassAtt, midAtt: a.midAtt, trebAtt: a.trebAtt,
            volume: a.volume,
            zoom: p.zoom, rot: p.rot,
            warpAmount: p.warp, warpSpeed: p.warpSpeed, warpScale: p.warpScale,
            center: SIMD2(p.cx, p.cy),
            stretchX: p.sx, stretchY: p.sy,
            translate: SIMD2(p.dx, p.dy),
            gammaAdj: p.gammaAdj,
            videoEchoAlpha: p.videoEchoAlpha,
            videoEchoZoom: p.videoEchoZoom,
            videoEchoOrientation: Int32(p.videoEchoOrientation),
            waveMode: Int32(p.waveMode), waveAlpha: effectiveWaveAlpha, waveScale: p.waveScale,
            waveColor: SIMD4(wr, wg, wb, 1.0),
            additiveWave: p.additiveWave ? 1 : 0,
            brighten: p.brighten ? 1 : 0,
            darken: p.darken ? 1 : 0,
            solarize: p.solarize ? 1 : 0,
            invert: p.invert ? 1 : 0
        )
    }

    /// Generate wave vertices based on audio data and wave mode.
    /// Returns the number of vertices generated.
    /// Milkdrop has 8 wave modes (0-7).
    private func generateWaveVertices(time: Float) -> Int {
        let p = currentPreset
        let a = audioAnalyzer
        let ptr = waveVertexBuffer.contents().bindMemory(to: SimpleVertex.self, capacity: 512)

        let count = 128

        // Helper to get a waveform sample (safe, interpolated)
        func wave(_ t: Float) -> Float {
            let fi = t * Float(waveformSamples.count - 1)
            let i = min(max(Int(fi), 0), waveformSamples.count - 1)
            return waveformSamples[i]
        }

        // Helper to get spectrum value
        func spec(_ t: Float) -> Float {
            let i = min(max(Int(t * 63), 0), 63)
            return fftMagnitudes[i]
        }

        let scale = p.waveScale
        let mode = p.waveMode % 8

        switch mode {
        case 0:
            // Circular waveform — radius modulated by audio
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let angle = t * .pi * 2
                let sample = wave(t) * scale
                let radius: Float = 0.25 + sample * 0.25
                let x = cos(angle) * radius
                let y = sin(angle) * radius
                ptr[i] = SimpleVertex(position: SIMD2(x, y), uv: SIMD2(t, 0))
            }
            return count

        case 1:
            // X-axis oscilloscope waveform
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let x = t * 2.0 - 1.0
                let y = wave(t) * scale * 0.5
                ptr[i] = SimpleVertex(position: SIMD2(x * 0.9, y), uv: SIMD2(t, 0))
            }
            return count

        case 2:
            // Centered spectrum analyzer
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let x = t * 2.0 - 1.0
                let y = spec(t) * scale * 0.7 - 0.3
                ptr[i] = SimpleVertex(position: SIMD2(x * 0.9, y), uv: SIMD2(t, 0))
            }
            return count

        case 3:
            // Two horizontal waves, one above center and one below
            let half = count / 2
            for i in 0..<half {
                let t = Float(i) / Float(half - 1)
                let x = t * 2.0 - 1.0
                let y = wave(t) * scale * 0.3 + 0.25
                ptr[i] = SimpleVertex(position: SIMD2(x * 0.9, y), uv: SIMD2(t, 0))
            }
            for i in 0..<half {
                let t = Float(i) / Float(half - 1)
                let x = t * 2.0 - 1.0
                let y = wave(t) * scale * 0.3 - 0.25
                ptr[half + i] = SimpleVertex(position: SIMD2(x * 0.9, y), uv: SIMD2(t, 0))
            }
            return count

        case 4:
            // X-Y oscilloscope (Lissajous-like)
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let x = wave(t) * scale * 0.6
                let t2 = fmod(t + 0.25, 1.0) // quarter-phase offset for Y
                let y = wave(t2) * scale * 0.6
                ptr[i] = SimpleVertex(position: SIMD2(x, y), uv: SIMD2(t, 0))
            }
            return count

        case 5:
            // Vertical waveform (rotated mode 1)
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let y = t * 2.0 - 1.0
                let x = wave(t) * scale * 0.5
                ptr[i] = SimpleVertex(position: SIMD2(x, y * 0.9), uv: SIMD2(t, 0))
            }
            return count

        case 6:
            // Blob: circular with strong radius modulation from spectrum
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let angle = t * .pi * 2
                let specVal = spec(t)
                let waveVal = wave(t)
                let radius: Float = 0.15 + (specVal * 0.3 + waveVal * 0.15) * scale
                let x = cos(angle) * radius
                let y = sin(angle) * radius
                ptr[i] = SimpleVertex(position: SIMD2(x, y), uv: SIMD2(t, 0))
            }
            return count

        case 7:
            // DerivativeLine — plot difference between consecutive samples
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let x = t * 2.0 - 1.0
                let s0 = wave(t)
                let s1 = wave(min(t + 1.0 / Float(count), 1.0))
                let y = (s1 - s0) * scale * 8.0
                ptr[i] = SimpleVertex(position: SIMD2(x * 0.9, y), uv: SIMD2(t, 0))
            }
            return count

        default:
            // Fallback circle
            for i in 0..<count {
                let t = Float(i) / Float(count - 1)
                let angle = t * .pi * 2
                let radius = a.bass * scale * 0.3
                let x = cos(angle) * radius
                let y = sin(angle) * radius
                ptr[i] = SimpleVertex(position: SIMD2(x, y), uv: SIMD2(t, 0))
            }
            return count
        }
    }
}
