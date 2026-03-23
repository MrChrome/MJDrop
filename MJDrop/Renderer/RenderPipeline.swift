//
//  RenderPipeline.swift
//  MJDrop
//
//  Creates and caches all Metal pipeline state objects.
//

import Metal
import MetalKit

final class RenderPipeline {
    let warpPipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let wavePipelineAlpha: MTLRenderPipelineState
    let wavePipelineAdditive: MTLRenderPipelineState

    // Custom wave/shape pipelines (per-vertex color)
    let customAlphaPipeline: MTLRenderPipelineState
    let customAdditivePipeline: MTLRenderPipelineState
    let customTexturedAlphaPipeline: MTLRenderPipelineState
    let customTexturedAdditivePipeline: MTLRenderPipelineState

    // V2 shader support — device and library refs for runtime compilation
    private let device: MTLDevice
    private let defaultLibrary: MTLLibrary
    private let drawableFormat: MTLPixelFormat
    private var v2PipelineCache: [String: MTLRenderPipelineState] = [:]

    static let offscreenFormat: MTLPixelFormat = .rgba16Float

    init(device: MTLDevice, library: MTLLibrary, drawableFormat: MTLPixelFormat) throws {
        self.device = device
        self.defaultLibrary = library
        self.drawableFormat = drawableFormat
        // Warp: mesh grid samples previous frame
        let warpDesc = MTLRenderPipelineDescriptor()
        warpDesc.vertexFunction = library.makeFunction(name: "warpVertex")
        warpDesc.fragmentFunction = library.makeFunction(name: "warpFragment")
        warpDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        warpPipeline = try device.makeRenderPipelineState(descriptor: warpDesc)

        // Blur: separable Gaussian
        let blurDesc = MTLRenderPipelineDescriptor()
        blurDesc.vertexFunction = library.makeFunction(name: "blurVertex")
        blurDesc.fragmentFunction = library.makeFunction(name: "blurFragment")
        blurDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        blurPipeline = try device.makeRenderPipelineState(descriptor: blurDesc)

        // Composite: final output to screen
        let compDesc = MTLRenderPipelineDescriptor()
        compDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        compDesc.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compDesc.colorAttachments[0].pixelFormat = drawableFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: compDesc)

        // Wave with alpha blending
        let waveAlphaDesc = MTLRenderPipelineDescriptor()
        waveAlphaDesc.vertexFunction = library.makeFunction(name: "waveVertex")
        waveAlphaDesc.fragmentFunction = library.makeFunction(name: "waveFragment")
        waveAlphaDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        waveAlphaDesc.colorAttachments[0].isBlendingEnabled = true
        waveAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        waveAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        waveAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        waveAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wavePipelineAlpha = try device.makeRenderPipelineState(descriptor: waveAlphaDesc)

        // Wave with additive blending
        let waveAddDesc = MTLRenderPipelineDescriptor()
        waveAddDesc.vertexFunction = library.makeFunction(name: "waveVertex")
        waveAddDesc.fragmentFunction = library.makeFunction(name: "waveFragment")
        waveAddDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        waveAddDesc.colorAttachments[0].isBlendingEnabled = true
        waveAddDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        waveAddDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        waveAddDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        waveAddDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        wavePipelineAdditive = try device.makeRenderPipelineState(descriptor: waveAddDesc)

        // Custom colored (per-vertex color) — alpha blend
        let customAlphaDesc = MTLRenderPipelineDescriptor()
        customAlphaDesc.vertexFunction = library.makeFunction(name: "customColorVertex")
        customAlphaDesc.fragmentFunction = library.makeFunction(name: "customColorFragment")
        customAlphaDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        customAlphaDesc.colorAttachments[0].isBlendingEnabled = true
        customAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        customAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        customAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        customAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        customAlphaPipeline = try device.makeRenderPipelineState(descriptor: customAlphaDesc)

        // Custom colored — additive blend
        let customAddDesc = MTLRenderPipelineDescriptor()
        customAddDesc.vertexFunction = library.makeFunction(name: "customColorVertex")
        customAddDesc.fragmentFunction = library.makeFunction(name: "customColorFragment")
        customAddDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        customAddDesc.colorAttachments[0].isBlendingEnabled = true
        customAddDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        customAddDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        customAddDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        customAddDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        customAdditivePipeline = try device.makeRenderPipelineState(descriptor: customAddDesc)

        // Textured shape — alpha blend
        let customTexAlphaDesc = MTLRenderPipelineDescriptor()
        customTexAlphaDesc.vertexFunction = library.makeFunction(name: "customColorVertex")
        customTexAlphaDesc.fragmentFunction = library.makeFunction(name: "customTexturedFragment")
        customTexAlphaDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        customTexAlphaDesc.colorAttachments[0].isBlendingEnabled = true
        customTexAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        customTexAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        customTexAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        customTexAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        customTexturedAlphaPipeline = try device.makeRenderPipelineState(descriptor: customTexAlphaDesc)

        // Textured shape — additive blend
        let customTexAddDesc = MTLRenderPipelineDescriptor()
        customTexAddDesc.vertexFunction = library.makeFunction(name: "customColorVertex")
        customTexAddDesc.fragmentFunction = library.makeFunction(name: "customTexturedFragment")
        customTexAddDesc.colorAttachments[0].pixelFormat = Self.offscreenFormat
        customTexAddDesc.colorAttachments[0].isBlendingEnabled = true
        customTexAddDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        customTexAddDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        customTexAddDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        customTexAddDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        customTexturedAdditivePipeline = try device.makeRenderPipelineState(descriptor: customTexAddDesc)
    }

    // MARK: - V2 Dynamic Compilation

    /// Compile a v2 warp fragment shader from transpiled Metal source.
    /// Returns nil on failure (transpilation error, compilation error, etc.).
    func compileV2WarpPipeline(metalSource: String, functionName: String) -> MTLRenderPipelineState? {
        if let cached = v2PipelineCache[metalSource] { return cached }

        guard let runtimeLibrary = compileLibrary(source: metalSource, label: "v2 warp") else { return nil }
        guard let fragFunc = runtimeLibrary.makeFunction(name: functionName) else {
            print("[RenderPipeline] v2 warp function '\(functionName)' not found in compiled library")
            return nil
        }
        guard let vertFunc = defaultLibrary.makeFunction(name: "warpVertexV2") else {
            print("[RenderPipeline] warpVertexV2 not found in default library")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = Self.offscreenFormat

        do {
            let pso = try device.makeRenderPipelineState(descriptor: desc)
            v2PipelineCache[metalSource] = pso
            return pso
        } catch {
            print("[RenderPipeline] v2 warp pipeline creation failed: \(error)")
            return nil
        }
    }

    /// Compile a v2 composite fragment shader from transpiled Metal source.
    func compileV2CompPipeline(metalSource: String, functionName: String) -> MTLRenderPipelineState? {
        if let cached = v2PipelineCache[metalSource] { return cached }

        guard let runtimeLibrary = compileLibrary(source: metalSource, label: "v2 comp") else { return nil }
        guard let fragFunc = runtimeLibrary.makeFunction(name: functionName) else {
            print("[RenderPipeline] v2 comp function '\(functionName)' not found in compiled library")
            return nil
        }
        guard let vertFunc = defaultLibrary.makeFunction(name: "compositeVertex") else {
            print("[RenderPipeline] compositeVertex not found in default library")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = drawableFormat

        do {
            let pso = try device.makeRenderPipelineState(descriptor: desc)
            v2PipelineCache[metalSource] = pso
            return pso
        } catch {
            print("[RenderPipeline] v2 comp pipeline creation failed: \(error)")
            return nil
        }
    }

    private func compileLibrary(source: String, label: String) -> MTLLibrary? {
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            return try device.makeLibrary(source: source, options: options)
        } catch {
            print("[RenderPipeline] \(label) shader compilation failed:\n\(error)")
            // Print first few lines of source for debugging
            let lines = source.components(separatedBy: "\n")
            let preview = lines.prefix(10).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            print("[RenderPipeline] Source preview:\n\(preview)")
            return nil
        }
    }
}
