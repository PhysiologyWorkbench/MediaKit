import AVFAudio
import Foundation
import Testing
@testable import MediaKit

/// Gap detection is the library's, not each host's: `BeatTracker` assumes a
/// gapless stream, so it is the thing that must notice when it does not get one.
@MainActor
struct BeatTrackerGapTests {
    @Test func aContinuousStreamReportsNoGaps() async {
        let tracker = BeatTracker()
        await feed(starts: [0, 0.1, 0.2, 0.3], to: tracker)
        #expect(tracker.gapCount == 0)
        #expect(tracker.lastGap == nil)
    }

    @Test func aShedBufferIsReported() async {
        let tracker = BeatTracker()
        await feed(starts: [0, 0.1, 0.2, 0.6], to: tracker)
        #expect(tracker.gapCount == 1)
        #expect(abs((tracker.lastGap?.seconds ?? 0) - 0.3) < 1e-6)
        #expect(tracker.lastGap?.at == origin.addingTimeInterval(0.6))
    }

    /// Timestamp jitter is not a gap; only a discrepancy past the tolerance is.
    @Test func jitterUnderToleranceIsIgnored() async {
        let tracker = BeatTracker()
        await feed(starts: [0, 0.1005, 0.2, 0.2995], to: tracker)
        #expect(tracker.gapCount == 0)
    }

    private let origin = Date(timeIntervalSince1970: 1_000_000)

    /// 100 ms chunks starting at the given offsets, fed to completion.
    private func feed(starts: [TimeInterval], to tracker: BeatTracker) async {
        let (chunks, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        let events = tracker.events(from: chunks)
        for offset in starts {
            continuation.yield(silence(start: origin.addingTimeInterval(offset)))
        }
        continuation.finish()
        for await _ in events {}
    }

    private func silence(start: Date) -> AudioChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        return AudioChunk(buffer: buffer, start: start)
    }
}
