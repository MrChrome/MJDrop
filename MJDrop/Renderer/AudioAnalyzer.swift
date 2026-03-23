//
//  AudioAnalyzer.swift
//  MJDrop
//
//  Converts AudioPlayerManager's 64-band FFT into Milkdrop's audio model:
//  bass/mid/treb (instant + attenuated/smoothed).
//

import Foundation

final class AudioAnalyzer {
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var treb: Float = 0
    private(set) var bassAtt: Float = 0
    private(set) var midAtt: Float = 0
    private(set) var trebAtt: Float = 0
    private(set) var volume: Float = 0

    private let attenuationFactor: Float = 0.92

    func update(fftMagnitudes: [Float]) {
        guard fftMagnitudes.count >= 64 else { return }

        // Split 64 bands into Milkdrop's 3 frequency groups
        bass = average(fftMagnitudes, from: 0, to: 20)
        mid  = average(fftMagnitudes, from: 21, to: 42)
        treb = average(fftMagnitudes, from: 43, to: 63)

        // Attenuated values smooth toward instant values
        bassAtt = bassAtt * attenuationFactor + bass * (1 - attenuationFactor)
        midAtt  = midAtt  * attenuationFactor + mid  * (1 - attenuationFactor)
        trebAtt = trebAtt * attenuationFactor + treb * (1 - attenuationFactor)

        volume = (bass + mid + treb) / 3.0
    }

    private func average(_ data: [Float], from: Int, to: Int) -> Float {
        var sum: Float = 0
        for i in from...to { sum += data[i] }
        return sum / Float(to - from + 1)
    }
}
