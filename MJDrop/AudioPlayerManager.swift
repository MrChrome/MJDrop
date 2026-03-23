//
//  AudioPlayerManager.swift
//  MJDrop
//
//  Created by MARC SANTA on 3/22/26.
//

import AVFoundation
import Accelerate
import Observation

private let kAudioFileBookmark = "audioFileBookmark"

/// Manages audio playback and real-time FFT analysis for visualization.
@MainActor
@Observable
final class AudioPlayerManager {
    var isPlaying = false
    var fftMagnitudes: [Float] = Array(repeating: 0, count: 64)
    var waveformSamples: [Float] = Array(repeating: 0, count: 512)
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var fileName: String?

    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var securityScopedURL: URL?

    private let bandCount = 64
    private let fftSize = 1024

    // MARK: - File Loading

    func loadFile(url: URL, autoPlay: Bool = true) {
        stop()
        releaseSecurityScope()

        // Keep security-scoped access alive for the lifetime of playback
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing {
            securityScopedURL = url
        }

        // Save bookmark for next launch
        saveAudioBookmark(url: url)

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            fileName = url.lastPathComponent

            setupAudioEngine(format: file.processingFormat)

            if autoPlay {
                play()
            }
        } catch {
            print("Failed to load audio file: \(error)")
            releaseSecurityScope()
        }
    }

    private func releaseSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    // MARK: - Persistence

    /// Restore last audio file from saved bookmark.
    func restoreSavedFile() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: kAudioFileBookmark) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if isStale {
            saveAudioBookmark(url: url)
        }

        loadFile(url: url, autoPlay: false)
    }

    private func saveAudioBookmark(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmarkData, forKey: kAudioFileBookmark)
    }

    // MARK: - Playback

    func play() {
        guard let file = audioFile else { return }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("Failed to start audio engine: \(error)")
                return
            }
        }

        playerNode.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.stopTimer()
            }
        }
        playerNode.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        playerNode.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        playerNode.stop()
        audioEngine.stop()
        isPlaying = false
        currentTime = 0
        fftMagnitudes = Array(repeating: 0, count: bandCount)
        stopTimer()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    // MARK: - Audio Engine Setup

    private func setupAudioEngine(format: AVAudioFormat) {
        audioEngine.stop()
        audioEngine.reset()

        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

        // Install a tap on the main mixer for FFT analysis
        let mixerFormat = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: mixerFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
    }

    // MARK: - FFT Processing

    private nonisolated func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleCount = min(frameCount, 1024)

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: sampleCount)
        var window = [Float](repeating: 0, count: sampleCount)
        vDSP_hann_window(&window, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(sampleCount))

        // Prepare FFT input
        var realIn = [Float](repeating: 0, count: sampleCount)
        let imagIn = [Float](repeating: 0, count: sampleCount)
        var realOut = [Float](repeating: 0, count: sampleCount)
        var imagOut = [Float](repeating: 0, count: sampleCount)

        realIn[0..<sampleCount] = windowed[0..<sampleCount]

        // Perform FFT
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(sampleCount), .FORWARD) else { return }
        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)
        vDSP_DFT_DestroySetup(setup)

        // Compute magnitudes
        var magnitudes = [Float](repeating: 0, count: sampleCount / 2)
        realOut.withUnsafeMutableBufferPointer { realPtr in
            imagOut.withUnsafeMutableBufferPointer { imagPtr in
                var complex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvabs(&complex, 1, &magnitudes, 1, vDSP_Length(sampleCount / 2))
            }
        }

        // Convert to log scale
        var logMagnitudes = [Float](repeating: 0, count: magnitudes.count)
        var one: Float = 1.0
        vDSP_vdbcon(magnitudes, 1, &one, &logMagnitudes, 1, vDSP_Length(magnitudes.count), 0)

        // Group into bands with logarithmic frequency distribution
        let bands = 64
        let halfCount = sampleCount / 2
        var bandValues = [Float](repeating: 0, count: bands)

        for i in 0..<bands {
            let lowFrac = Float(i) / Float(bands)
            let highFrac = Float(i + 1) / Float(bands)
            // Logarithmic mapping for more musical frequency distribution
            let lowBin = Int(pow(lowFrac, 2.0) * Float(halfCount))
            let highBin = max(lowBin + 1, Int(pow(highFrac, 2.0) * Float(halfCount)))
            let clampedHigh = min(highBin, halfCount)

            if lowBin < clampedHigh {
                var sum: Float = 0
                for j in lowBin..<clampedHigh {
                    sum += logMagnitudes[j]
                }
                bandValues[i] = sum / Float(clampedHigh - lowBin)
            }
        }

        // Normalize to 0...1 range
        let minDb: Float = -60
        let maxDb: Float = 0
        var result = [Float](repeating: 0, count: bands)
        for i in 0..<bands {
            let clamped = max(minDb, min(maxDb, bandValues[i]))
            result[i] = (clamped - minDb) / (maxDb - minDb)
        }

        // Capture raw waveform samples for wave overlay
        let waveCount = min(frameCount, 512)
        var rawSamples = [Float](repeating: 0, count: 512)
        for i in 0..<waveCount {
            rawSamples[i] = channelData[i]
        }

        Task { @MainActor [result, rawSamples] in
            // Smooth the FFT values for a nicer visual
            for i in 0..<result.count {
                self.fftMagnitudes[i] = self.fftMagnitudes[i] * 0.6 + result[i] * 0.4
            }
            self.waveformSamples = rawSamples
        }
    }

    // MARK: - Timer for Time Updates

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateCurrentTime() {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
