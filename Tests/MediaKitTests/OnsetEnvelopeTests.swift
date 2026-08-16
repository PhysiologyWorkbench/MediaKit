import Foundation
import Testing
@testable import MediaKit

struct OnsetEnvelopeTests {
    /// The envelope's peaks must sit on the click grid: strictly periodic,
    /// with at most a small constant bias from the window convention.
    @Test func peaksAreStrictlyPeriodicOnAClickTrack() {
        let envelope = OnsetEnvelope(sampleRate: 48_000)
        let frames = envelope.process(clickTrack(bpm: 120, seconds: 8))
        let peaks = peakTimes(of: frames, frameRate: envelope.frameRate,
                              offset: envelope.timeOffset)

        #expect(peaks.count >= 14)
        for pair in zip(peaks, peaks.dropFirst()) {
            #expect(abs((pair.1 - pair.0) - 0.5) < 0.03)
        }
        let offsets = peaks.map { $0.truncatingRemainder(dividingBy: 0.5) }
            .map { $0 > 0.25 ? $0 - 0.5 : $0 }
        #expect(offsets.max()! - offsets.min()! < 0.03)
    }

    /// Streaming in capture-sized chunks and processing in one call must
    /// produce the same envelope — the reducer replays.
    @Test func chunkedAndWholesaleProcessingAgree() {
        let samples = clickTrack(bpm: 100, seconds: 4)
        let whole = OnsetEnvelope(sampleRate: 48_000).process(samples)

        let chunked = OnsetEnvelope(sampleRate: 48_000)
        var streamed: [Float] = []
        var cursor = 0
        while cursor < samples.count {
            let end = min(cursor + 4800, samples.count)
            streamed += chunked.process(Array(samples[cursor..<end]))
            cursor = end
        }
        #expect(streamed == whole)
    }

    @Test func silenceProducesAnAllZeroEnvelope() {
        let envelope = OnsetEnvelope(sampleRate: 48_000)
        let frames = envelope.process([Float](repeating: 0, count: 96_000))
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0 == 0 })
    }
}
