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

    private static let offscreenFormat: MTLPixelFormat = .rgba16Float

    init(device: MTLDevice, library: MTLLibrary, drawableFormat: MTLPixelFormat) throws {
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
    }
}
