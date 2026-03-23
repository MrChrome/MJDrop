//
//  MeshGrid.swift
//  MJDrop
//
//  Generates and manages the warp mesh grid.
//  In Milkdrop, this is the mesh where per-vertex expressions modify
//  texture coordinates each frame to create the feedback distortion.
//

import Metal
import simd

final class MeshGrid {
    let gridWidth: Int
    let gridHeight: Int
    let vertexCount: Int
    let indexCount: Int

    private(set) var vertexBuffer: MTLBuffer!
    private(set) var indexBuffer: MTLBuffer!

    init(device: MTLDevice, width: Int = 48, height: Int = 36) {
        self.gridWidth = width
        self.gridHeight = height
        self.vertexCount = (width + 1) * (height + 1)
        self.indexCount = width * height * 6

        // Static index buffer (two triangles per grid cell)
        var indices: [UInt32] = []
        indices.reserveCapacity(indexCount)
        for row in 0..<height {
            for col in 0..<width {
                let tl = UInt32(row * (width + 1) + col)
                let tr = tl + 1
                let bl = UInt32((row + 1) * (width + 1) + col)
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }
        indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )

        vertexBuffer = device.makeBuffer(
            length: vertexCount * MemoryLayout<MilkdropVertex>.stride,
            options: .storageModeShared
        )
    }

    /// Rebuild a new mesh grid if the preset mesh size changed.
    func rebuildIfNeeded(device: MTLDevice, preset: PresetParameters) -> MeshGrid {
        if preset.meshSizeX != gridWidth || preset.meshSizeY != gridHeight {
            return MeshGrid(device: device, width: preset.meshSizeX, height: preset.meshSizeY)
        }
        return self
    }

    /// Update all vertex UVs for the current frame.
    /// Runs per-pixel expressions if available, otherwise uses hardcoded warp math.
    func updateVertices(params: PresetParameters, audio: AudioAnalyzer, time: Float, fps: Float = 60,
                        perPixelExpressions: [CompiledAssignment] = [],
                        expressionContext: ExpressionContext? = nil,
                        contextBridge: ContextBridge? = nil) {
        let ptr = vertexBuffer.contents().bindMemory(
            to: MilkdropVertex.self, capacity: vertexCount
        )

        let cols = gridWidth + 1
        let rows = gridHeight + 1

        // Milkdrop specifies per-frame values at 30fps — scale to actual fps
        let fpsScale = 30.0 / max(fps, 1.0)

        let hasPerPixel = !perPixelExpressions.isEmpty && expressionContext != nil && contextBridge != nil

        for row in 0..<rows {
            for col in 0..<cols {
                let idx = row * cols + col

                let u = Float(col) / Float(gridWidth)
                let v = Float(row) / Float(gridHeight)

                // Polar coordinates from center
                let relX = u - params.cx
                let relY = v - params.cy
                var radius = sqrt(relX * relX + relY * relY)
                var angle = atan2(relY, relX)

                // Per-pixel expression variables for this vertex
                var vertexZoom = params.zoom
                var vertexZoomExp = params.zoomExponent
                var vertexRot = params.rot
                var vertexWarp = params.warp
                var vertexCx = params.cx
                var vertexCy = params.cy
                var vertexDx = params.dx
                var vertexDy = params.dy
                var vertexSx = params.sx
                var vertexSy = params.sy

                if hasPerPixel, let ctx = expressionContext, let bridge = contextBridge {
                    // Set per-pixel inputs: x, y, rad, ang
                    if let s = bridge.x { ctx[s] = u }
                    if let s = bridge.y { ctx[s] = v }
                    if let s = bridge.rad { ctx[s] = radius }
                    if let s = bridge.ang { ctx[s] = angle }

                    // Run per-pixel expressions
                    executeExpressions(perPixelExpressions, ctx: ctx)

                    // Read back per-pixel outputs
                    if let s = bridge.zoom { vertexZoom = ctx[s] }
                    if let s = bridge.zoomExponent { vertexZoomExp = ctx[s] }
                    if let s = bridge.rot { vertexRot = ctx[s] }
                    if let s = bridge.warp { vertexWarp = ctx[s] }
                    if let s = bridge.cx { vertexCx = ctx[s] }
                    if let s = bridge.cy { vertexCy = ctx[s] }
                    if let s = bridge.dx { vertexDx = ctx[s] }
                    if let s = bridge.dy { vertexDy = ctx[s] }
                    if let s = bridge.sx { vertexSx = ctx[s] }
                    if let s = bridge.sy { vertexSy = ctx[s] }
                }

                // Zoom with exponent
                let zoomExp = pow(max(vertexZoom, 0.001), pow(vertexZoomExp, radius * 2.0))
                radius /= pow(zoomExp, fpsScale)

                // Rotation: radians per frame at 30fps, scaled to actual fps
                let rotAmount = vertexRot * fpsScale
                angle += rotAmount

                // Warp: sinusoidal mesh distortion (the signature Milkdrop look)
                let wt = time * params.warpSpeed
                let warpX = sin(wt * 0.133 + u * params.warpScale * 6.2832) * vertexWarp * 0.035
                let warpY = cos(wt * 0.375 + v * params.warpScale * 6.2832) * vertexWarp * 0.035

                // Convert back to cartesian UV
                var wu = vertexCx + radius * cos(angle) + warpX
                var wv = vertexCy + radius * sin(angle) + warpY

                // Stretch
                wu = (wu - 0.5) / vertexSx + 0.5
                wv = (wv - 0.5) / vertexSy + 0.5

                // Translation (scaled to fps)
                wu += vertexDx * fpsScale
                wv += vertexDy * fpsScale

                ptr[idx] = MilkdropVertex(
                    position: SIMD3<Float>(u, v, 0),
                    color: SIMD4<Float>(1, 1, 1, 1),
                    uv: SIMD2<Float>(wu, wv),
                    uvStatic: SIMD2<Float>(u, v),
                    radAng: SIMD2<Float>(radius, angle)
                )
            }
        }
    }
}
