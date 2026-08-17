import Foundation
import Testing
@testable import MediaKit

/// The full tracking loop as `BeatTracker.run` wires it: audio → envelope →
/// retune once a second over an eight-second suffix → phase predictor. The
/// Spotify bench exposed a slow phase drift this composition can produce
/// even while every component's own test passes.
struct BeatTrackerLoopTests {
    @Test("emitted beats stay phase-locked over five minutes of a steady click track")
    func longRunPhaseLock() {
        let bpm = 120.0
        let audio = clickTrack(bpm: bpm, seconds: 300)
        let envelope = OnsetEnvelope(sampleRate: 48_000)
        var predictor = BeatPhasePredictor()
        var frames: [Float] = []
        var lastRetune = 0
        var emitted: [TimeInterval] = []

        let block = 24_000
        var index = 0
        while index < audio.count {
            let slice = Array(audio[index..<min(index + block, audio.count)])
            index += block
            for value in envelope.process(slice) {
                let time = envelope.timeOffset + Double(frames.count) / envelope.frameRate
                frames.append(value)
                if let beat = predictor.step(value: value, time: time) {
                    emitted.append(beat.time)
                }
            }
            if frames.count - lastRetune >= Int(envelope.frameRate),
               frames.count >= Int(envelope.frameRate * 4) {
                lastRetune = frames.count
                let window = Array(frames.suffix(Int(envelope.frameRate * 8)))
                predictor.retune(estimateTempo(envelope: window, frameRate: envelope.frameRate))
            }
        }

        // Phase error of each emitted beat against the true grid; a constant
        // offset (detection latency) is fine, growth is not.
        let period = 60 / bpm
        let settled = emitted.filter { $0 > 30 }
        let errors = settled.map { ($0 / period - ($0 / period).rounded()) * period }
        let spread = (errors.max() ?? 1) - (errors.min() ?? 0)
        #expect(spread < 0.04, """
        phase drifted: spread \(Int(spread * 1000)) ms over \(settled.count) beats, \
        first error \(Int((errors.first ?? 0) * 1000)) ms, \
        last error \(Int((errors.last ?? 0) * 1000)) ms
        """)
    }

    /// The Spotify bench (2026-08-17) showed a warm start dying: retunes fired
    /// before the window held enough audio, and their nil or octave-folded
    /// results displaced the prior that was carrying the beats.
    @Test("a tempo prior carries beats gaplessly until real estimates arrive")
    func warmStartSustains() {
        let bpm = 120.0
        let audio = clickTrack(bpm: bpm, seconds: 20)
        let envelope = OnsetEnvelope(sampleRate: 48_000)
        var predictor = BeatPhasePredictor(bpm: bpm)
        var frames: [Float] = []
        var lastRetune = 0
        var emitted: [(time: TimeInterval, period: TimeInterval)] = []

        let block = 24_000
        var index = 0
        while index < audio.count {
            let slice = Array(audio[index..<min(index + block, audio.count)])
            index += block
            for value in envelope.process(slice) {
                let time = envelope.timeOffset + Double(frames.count) / envelope.frameRate
                frames.append(value)
                if let beat = predictor.step(value: value, time: time) {
                    emitted.append((beat.time, beat.period))
                }
            }
            if frames.count - lastRetune >= Int(envelope.frameRate),
               frames.count >= Int(envelope.frameRate * 4) {
                lastRetune = frames.count
                let window = Array(frames.suffix(Int(envelope.frameRate * 8)))
                predictor.retune(estimateTempo(envelope: window, frameRate: envelope.frameRate))
            }
        }

        let period = 60 / bpm
        #expect((emitted.first?.time ?? .infinity) < 2 * period, "warm start locked late")
        let intervals = zip(emitted.dropFirst(), emitted).map { $0.time - $1.time }
        #expect((intervals.max() ?? .infinity) < 1.5 * period, "beats dropped out mid-track")
        #expect(emitted.allSatisfy { abs($0.period - period) < 0.1 * period },
                "an octave-folded estimate displaced the prior")
    }
}
