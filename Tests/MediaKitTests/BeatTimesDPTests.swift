import Foundation
import Testing
@testable import MediaKit

struct BeatTimesDPTests {
    let frameRate = 93.75

    @Test func recoversTheGridFromACleanEnvelope() {
        let envelope = pulseEnvelope(bpm: 120, seconds: 20, frameRate: frameRate)
        let beats = beatTimesDP(envelope: envelope, frameRate: frameRate, bpm: 120)

        #expect(beats.count >= 37 && beats.count <= 41)
        for pair in zip(beats, beats.dropFirst()) {
            #expect(abs((pair.1 - pair.0) - 0.5) < 0.025)
        }
        for beat in beats {
            let nearest = (beat / 0.5).rounded() * 0.5
            #expect(abs(beat - nearest) < 0.025)
        }
    }

    /// The penalty is a spring, not a cage: a seed tempo a few BPM off must
    /// still land the grid on the actual pulses.
    @Test func toleratesAnImperfectTempoSeed() {
        let envelope = pulseEnvelope(bpm: 120, seconds: 20, frameRate: frameRate)
        let beats = beatTimesDP(envelope: envelope, frameRate: frameRate, bpm: 114)

        #expect(beats.count >= 35)
        for pair in zip(beats, beats.dropFirst()) {
            #expect(abs((pair.1 - pair.0) - 0.5) < 0.03)
        }
    }

    @Test func aFlatEnvelopeYieldsNoBeats() {
        let envelope = [Float](repeating: 0.2, count: 2_000)
        #expect(beatTimesDP(envelope: envelope, frameRate: frameRate, bpm: 120).isEmpty)
    }

    @Test func tooShortAnEnvelopeYieldsNoBeats() {
        let envelope = pulseEnvelope(bpm: 120, seconds: 0.8, frameRate: frameRate)
        #expect(beatTimesDP(envelope: envelope, frameRate: frameRate, bpm: 120).isEmpty)
    }
}
