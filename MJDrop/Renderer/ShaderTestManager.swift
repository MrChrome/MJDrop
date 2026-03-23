//
//  ShaderTestManager.swift
//  MJDrop
//
//  Batch-tests V2 shader compilation for all loaded presets.
//  Reports per-preset pass/fail results with progress tracking.
//

import Foundation
import Metal
import Observation

struct ShaderTestResult: Identifiable {
    let id = UUID()
    let presetName: String
    let warpResult: ShaderTestOutcome
    let compResult: ShaderTestOutcome

    var passed: Bool {
        warpResult != .failed && compResult != .failed
    }

    enum ShaderTestOutcome {
        case passed
        case failed
        case skipped // No V2 shader source (psVersion < 2 or no source)
    }
}

@MainActor
@Observable
final class ShaderTestManager {
    private(set) var isRunning = false
    private(set) var progress: Double = 0 // 0.0 to 1.0
    private(set) var currentPresetName: String = ""
    private(set) var results: [ShaderTestResult] = []
    private(set) var completed: Int = 0
    private(set) var total: Int = 0

    var passedCount: Int { results.filter(\.passed).count }
    var failedCount: Int { results.filter { !$0.passed }.count }
    var failedResults: [ShaderTestResult] { results.filter { !$0.passed } }

    func runTests(presets: [PresetParameters]) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        results = []
        completed = 0
        total = presets.count
        currentPresetName = ""

        let presetsCopy = presets
        let totalCount = presets.count

        Task.detached { [weak self] in
            guard let device = MTLCreateSystemDefaultDevice(),
                  let library = device.makeDefaultLibrary()
            else {
                await MainActor.run {
                    self?.isRunning = false
                }
                return
            }

            // Create a fresh pipeline for testing (no shared cache)
            guard let pipeline = try? RenderPipeline(device: device, library: library, drawableFormat: .bgra8Unorm) else {
                await MainActor.run {
                    self?.isRunning = false
                }
                return
            }

            // Process in batches to reduce main-actor round-trips
            let batchSize = 20
            var batch: [ShaderTestResult] = []
            batch.reserveCapacity(batchSize)

            for (index, preset) in presetsCopy.enumerated() {
                let result = Self.testPreset(preset, index: index, pipeline: pipeline)
                batch.append(result)

                // Flush batch to main actor periodically or at the end
                if batch.count >= batchSize || index == totalCount - 1 {
                    let batchToSend = batch
                    let currentIndex = index
                    let name = preset.name
                    batch.removeAll(keepingCapacity: true)

                    await MainActor.run {
                        guard let self else { return }
                        self.results.append(contentsOf: batchToSend)
                        self.completed = currentIndex + 1
                        self.progress = Double(currentIndex + 1) / Double(totalCount)
                        self.currentPresetName = name
                    }
                }
            }

            await MainActor.run {
                self?.isRunning = false
            }
        }
    }

    private nonisolated static func testPreset(_ preset: PresetParameters, index: Int, pipeline: RenderPipeline) -> ShaderTestResult {
        var warpOutcome: ShaderTestResult.ShaderTestOutcome = .skipped
        var compOutcome: ShaderTestResult.ShaderTestOutcome = .skipped

        if preset.psVersion >= 2 {
            // Use unique name per preset to avoid function name collisions
            let name = "test_\(index)"

            // Test warp shader
            if let hlsl = preset.warpShaderSource,
               let transpiled = ShaderTranspiler.transpile(hlsl: hlsl, type: .warp, presetName: name) {
                let compResult = pipeline.compileV2WarpPipeline(
                    metalSource: transpiled.metalSource, functionName: transpiled.functionName
                )
                warpOutcome = compResult.pipeline != nil ? .passed : .failed
            }

            // Test composite shader
            if let hlsl = preset.compShaderSource,
               let transpiled = ShaderTranspiler.transpile(hlsl: hlsl, type: .composite, presetName: name) {
                let compResult = pipeline.compileV2CompPipeline(
                    metalSource: transpiled.metalSource, functionName: transpiled.functionName
                )
                compOutcome = compResult.pipeline != nil ? .passed : .failed
            }
        }

        return ShaderTestResult(
            presetName: preset.name,
            warpResult: warpOutcome,
            compResult: compOutcome
        )
    }
}
