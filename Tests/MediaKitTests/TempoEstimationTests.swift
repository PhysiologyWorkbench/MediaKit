import Foundation
import Testing
@testable import MediaKit

struct TempoEstimationTests {
    let frameRate = 93.75

    @Test func findsASteadyOneTwenty() {
        let envelope = pulseEnvelope(bpm: 120, seconds: 12, frameRate: frameRate)
        let estimate = estimateTempo(envelope: envelope, frameRate: frameRate)
        #expect(estimate != nil)
        #expect(abs(estimate!.bpm - 120) < 1)
    }

    @Test func ninetyStaysNinety() {
        let envelope = pulseEnvelope(bpm: 90, seconds: 12, frameRate: frameRate)
        let estimate = estimateTempo(envelope: envelope, frameRate: frameRate)
        #expect(estimate != nil)
        #expect(abs(estimate!.bpm - 90) < 1.5)
    }

    /// A 240 BPM pattern is felt at 120: the octave fold must bring it into
    /// the 60–180 band rather than report the literal periodicity.
    @Test func foldsDoubleTimeIntoTheBand() {
        let envelope = pulseEnvelope(bpm: 240, seconds: 12, frameRate: frameRate)
        let estimate = estimateTempo(envelope: envelope, frameRate: frameRate)
        #expect(estimate != nil)
        #expect(abs(estimate!.bpm - 120) < 3)
    }

    @Test func aFlatEnvelopeRefuses() {
        let envelope = [Float](repeating: 0.3, count: 1_200)
        #expect(estimateTempo(envelope: envelope, frameRate: frameRate) == nil)
    }

    @Test func noiseRefusesRatherThanInvents() {
        let envelope = deterministicNoise(count: 1_200)
        #expect(estimateTempo(envelope: envelope, frameRate: frameRate) == nil)
    }

    @Test func tooShortAWindowRefuses() {
        let envelope = pulseEnvelope(bpm: 120, seconds: 1, frameRate: frameRate)
        #expect(estimateTempo(envelope: envelope, frameRate: frameRate) == nil)
    }
}
