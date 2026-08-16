import Foundation

/// Mono click track: decaying 60 Hz thumps on a strict beat grid — a kick
/// drum reduced to what the 40–150 Hz band cares about.
func clickTrack(bpm: Double, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
    let count = Int(seconds * sampleRate)
    var samples = [Float](repeating: 0, count: count)
    let period = 60 / bpm
    let thumpLength = Int(0.1 * sampleRate)
    var beat = 0.0
    while beat < seconds {
        let start = Int(beat * sampleRate)
        for offset in 0..<thumpLength {
            let index = start + offset
            guard index < count else { break }
            let time = Double(offset) / sampleRate
            samples[index] += Float(sin(2 * .pi * 60 * time) * exp(-time / 0.03))
        }
        beat += period
    }
    return samples
}

/// Envelope-level pulse train: triangular three-frame pulses on the beat
/// grid, wide enough that frame rounding cannot hide one from a lag search.
func pulseEnvelope(bpm: Double, seconds: Double, frameRate: Double) -> [Float] {
    let count = Int(seconds * frameRate)
    var frames = [Float](repeating: 0, count: count)
    let period = frameRate * 60 / bpm
    var position = 0.0
    while position < Double(count) {
        let centre = Int(position.rounded())
        for (offset, value) in [(-1, Float(0.6)), (0, 1), (1, 0.6)] {
            let index = centre + offset
            if index >= 0, index < count {
                frames[index] = max(frames[index], value)
            }
        }
        position += period
    }
    return frames
}

/// Deterministic uniform noise in 0..<1 — tests never draw real randomness.
func deterministicNoise(count: Int, seed: UInt64 = 1) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}

/// Times of local maxima above half the global maximum.
func peakTimes(of frames: [Float], frameRate: Double, offset: TimeInterval) -> [TimeInterval] {
    guard let top = frames.max(), top > 0 else { return [] }
    let threshold = top / 2
    var times: [TimeInterval] = []
    for index in 1..<(frames.count - 1)
        where frames[index] > threshold
        && frames[index] >= frames[index - 1]
        && frames[index] > frames[index + 1]
    {
        times.append(offset + Double(index) / frameRate)
    }
    return times
}
