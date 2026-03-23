//
//  TextureManager.swift
//  MJDrop
//
//  Manages double-buffered render targets and blur cascade textures.
//  Milkdrop's m_lpVS[0]/m_lpVS[1] map to frontTexture/backTexture.
//

import Metal

final class TextureManager {
    private(set) var frontTexture: MTLTexture!
    private(set) var backTexture: MTLTexture!

    // Blur cascade: 3 levels, each half resolution of previous.
    // Each level has a source (final result) and temp (intermediate H-blur).
    private(set) var blurTextures: [(source: MTLTexture, temp: MTLTexture)] = []

    private let device: MTLDevice
    private(set) var width: Int = 0
    private(set) var height: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height

        frontTexture = makeRenderTarget(width: width, height: height)
        backTexture = makeRenderTarget(width: width, height: height)

        blurTextures.removeAll()
        var bw = width / 2
        var bh = height / 2
        for _ in 0..<3 {
            let w = max(bw, 1)
            let h = max(bh, 1)
            let src = makeRenderTarget(width: w, height: h)
            let tmp = makeRenderTarget(width: w, height: h)
            blurTextures.append((src, tmp))
            bw /= 2
            bh /= 2
        }
    }

    func swap() {
        let temp = frontTexture
        frontTexture = backTexture
        backTexture = temp
    }

    /// Clear both textures to black (used when switching presets).
    func clear(commandBuffer: MTLCommandBuffer) {
        for texture in [frontTexture, backTexture] {
            guard let tex = texture else { continue }
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = tex
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            passDesc.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
                encoder.endEncoding()
            }
        }
    }

    private func makeRenderTarget(width: Int, height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)!
    }
}
