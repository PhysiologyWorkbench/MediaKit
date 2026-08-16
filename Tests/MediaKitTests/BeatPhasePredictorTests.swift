import Foundation
import Testing
@testable import MediaKit

struct BeatPhasePredictorTests {
    let frameRate = 93.75

    /// Runs the predictor over an envelope, retuning once a second the way
    /// `BeatTracker` does: `retunes[second]` absent means no retune that
    /// second, present-but-`nil` means `retune(nil)` — the silence signal.
    private func run(
        _ predictor: inout BeatPhasePredictor,
        over envelope: [Float],
        retunes: [Int: (bpm: Double, confidence: Double)?]
    ) -> [(firedAt: TimeInterval, beat: TimeInterval, period: TimeInterval, confidence: Double)] {
        var emissions: [(TimeInterval, TimeInterval, TimeInterval, Double)] = []
        for (index, value) in envelope.enumerated() {
            if index % Int(frameRate) == 0, let estimate = retunes[index / Int(frameRate)] {
                predictor.retune(estimate)
            }
            let time = Double(index) / frameRate
            if let beat = predictor.step(value: value, time: time) {
                emissions.append((time, beat.time, beat.period, beat.confidence))
            }
        }
        return emissions.map { (firedAt: $0.0, beat: $0.1, period: $0.2, confidence: $0.3) }
    }

    @Test func locksOntoAPulseTrainWithinAFewBeats() {
        var predictor = BeatPhasePredictor()
        let envelope = pulseEnvelope(bpm: 120, seconds: 12, frameRate: frameRate)
        let emissions = run(&predictor, over: envelope, retunes: [0: (bpm: 120, confidence: 0.8)])

        #expect(emissions.count >= 15)
        let settled = emissions.dropFirst(3)
        let offsets = settled.map { emission -> Double in
            let nearest = (emission.beat / 0.5).rounded() * 0.5
            return emission.beat - nearest
        }
        #expect(offsets.allSatisfy { abs($0) < 0.05 })
        #expect(offsets.max()! - offsets.min()! < 0.035)
        #expect(settled.allSatisfy { abs($0.period - 0.5) < 0.01 })
    }

    /// Every beat is announced about `horizon` ahead of when it lands —
    /// predict, never react.
    @Test func emitsAheadOfTheBeat() {
        var predictor = BeatPhasePredictor()
        let envelope = pulseEnvelope(bpm: 120, seconds: 10, frameRate: frameRate)
        let emissions = run(&predictor, over: envelope, retunes: [0: (bpm: 120, confidence: 0.8)])

        #expect(!emissions.isEmpty)
        for emission in emissions {
            let lead = emission.beat - emission.firedAt
            #expect(lead > 0.28 && lead <= 0.3 + 1e-9)
        }
    }

    /// When the music stops the beats stop: no onsets, decaying tempo
    /// evidence, and within a few seconds the predictor refuses to emit.
    @Test func goesSilentRatherThanInventingBeats() {
        var predictor = BeatPhasePredictor()
        let sound = pulseEnvelope(bpm: 120, seconds: 6, frameRate: frameRate)
        let silence = [Float](repeating: 0, count: Int(6 * frameRate))
        var retunes = [Int: (bpm: Double, confidence: Double)?]()
        for second in 0..<6 { retunes[second] = (bpm: 120, confidence: 0.8) }
        for second in 6..<12 { retunes[second] = .some(nil) }
        let emissions = run(&predictor, over: sound + silence, retunes: retunes)

        #expect(!emissions.isEmpty)
        #expect(emissions.allSatisfy { $0.beat < 9 })
    }

    /// A tempo prior — a cached grid's BPM — lets phase lock on the first
    /// strong onset instead of waiting out a fresh estimate.
    @Test func aPriorLocksOnTheFirstOnsets() {
        var predictor = BeatPhasePredictor(bpm: 120)
        let envelope = pulseEnvelope(bpm: 120, seconds: 4, frameRate: frameRate)
        let emissions = run(&predictor, over: envelope, retunes: [:])

        #expect(!emissions.isEmpty)
        #expect(emissions.first!.beat < 1.2)
    }

    @Test func staysSilentWithNoTempoEvidenceAtAll() {
        var predictor = BeatPhasePredictor()
        let envelope = pulseEnvelope(bpm: 120, seconds: 6, frameRate: frameRate)
        let emissions = run(&predictor, over: envelope, retunes: [:])
        #expect(emissions.isEmpty)
    }
}
