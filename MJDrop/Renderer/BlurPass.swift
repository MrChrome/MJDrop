//
//  BlurPass.swift
//  MJDrop
//
//  Encodes the cascading blur passes. For each blur level:
//  H-blur from source into temp, then V-blur from temp into final.
//

import Metal

final class BlurPass {
    private let quadBuffer: MTLBuffer

    init(device: MTLDevice) {
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
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        sourceTexture: MTLTexture,
        textureManager: TextureManager
    ) {
        for level in 0..<textureManager.blurTextures.count {
            let input = level == 0 ? sourceTexture : textureManager.blurTextures[level - 1].source
            let target = textureManager.blurTextures[level]

            // Horizontal: input -> temp
            encodePass(commandBuffer: commandBuffer, pipeline: pipeline,
                       source: input, destination: target.temp, horizontal: true)

            // Vertical: temp -> source (final result for this level)
            encodePass(commandBuffer: commandBuffer, pipeline: pipeline,
                       source: target.temp, destination: target.source, horizontal: false)
        }
    }

    private func encodePass(
        commandBuffer: MTLCommandBuffer,
        pipeline: MTLRenderPipelineState,
        source: MTLTexture,
        destination: MTLTexture,
        horizontal: Bool
    ) {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(pipeline)

        var uniforms = BlurUniforms(
            texelSize: SIMD2(1.0 / Float(source.width), 1.0 / Float(source.height)),
            horizontal: horizontal ? 1 : 0,
            padding: 0
        )

        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
