import AVFAudio
import Testing
@testable import MediaKit

struct PeakMagnitudeTests {
    /// Fills every channel from `samples`, one value per frame.
    private func buffer(channels: AVAudioChannelCount, samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) {
            for (frame, sample) in samples.enumerated() {
                buffer.floatChannelData![channel][frame * buffer.stride] = sample
            }
        }
        return buffer
    }

    @Test func silenceReadsZero() {
        #expect(peakMagnitude(of: buffer(channels: 1, samples: [Float](repeating: 0, count: 64))) == 0)
    }

    @Test func takesTheLargestMagnitudeRegardlessOfSign() {
        #expect(peakMagnitude(of: buffer(channels: 1, samples: [0.1, -0.7, 0.3])) == 0.7)
    }

    @Test func spansEveryChannel() {
        let stereo = buffer(channels: 2, samples: [0.2, 0.4])
        stereo.floatChannelData![1][1 * stereo.stride] = -0.9
        #expect(peakMagnitude(of: stereo) == 0.9)
    }

    /// Frames past `frameLength` are stale capacity, not signal.
    @Test func ignoresFramesBeyondTheLength() {
        let buffer = buffer(channels: 1, samples: [0.25, 0.25])
        buffer.floatChannelData![0][2 * buffer.stride] = 1.0
        buffer.frameLength = 2
        #expect(peakMagnitude(of: buffer) == 0.25)
    }
}
