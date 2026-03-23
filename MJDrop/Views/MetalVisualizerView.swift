//
//  MetalVisualizerView.swift
//  MJDrop
//
//  NSViewRepresentable wrapping MTKView for Milkdrop rendering.
//  Bridges audio data and preset changes to the Metal renderer.
//

import SwiftUI
import MetalKit

struct MetalVisualizerView: NSViewRepresentable {
    let audioManager: AudioPlayerManager
    let presetManager: PresetManager
    @Binding var isRendererPaused: Bool
    var onShaderError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        context.coordinator.mtkView = mtkView

        do {
            let renderer = try MilkdropRenderer(device: device, pixelFormat: mtkView.colorPixelFormat)
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer

            // Wire shader error callback
            renderer.onShaderError = { [weak mtkView] message in
                mtkView?.isPaused = true
                self.isRendererPaused = true
                self.onShaderError?(message)
            }
        } catch {
            print("Failed to create MilkdropRenderer: \(error)")
        }

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        // Sync renderer pause state
        nsView.isPaused = isRendererPaused

        // Forward audio data
        renderer.fftMagnitudes = audioManager.fftMagnitudes
        renderer.waveformSamples = audioManager.waveformSamples

        // Update preset if changed
        let currentPreset = presetManager.currentPreset
        if currentPreset.name != context.coordinator.lastPresetName {
            context.coordinator.lastPresetName = currentPreset.name
            renderer.loadPreset(currentPreset)
        }
    }

    class Coordinator {
        var renderer: MilkdropRenderer?
        weak var mtkView: MTKView?
        var lastPresetName: String = ""
    }
}
