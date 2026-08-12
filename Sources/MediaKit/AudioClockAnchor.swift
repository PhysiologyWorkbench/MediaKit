import AVFAudio
import Foundation

/// Pins an audio clock to the host wall clock: a known sample position paired
/// with the host `Date` it was observed at. Established once, at the first tap
/// callback, and applied to everything after it. Audio-clock versus wall-clock
/// drift is ppm-level over a session — negligible for human-scale events.
public struct AudioClockAnchor: Sendable, Equatable {
    public let sampleTime: AVAudioFramePosition
    public let sampleRate: Double
    public let hostDate: Date

    public init(sampleTime: AVAudioFramePosition, sampleRate: Double, hostDate: Date) {
        self.sampleTime = sampleTime
        self.sampleRate = sampleRate
        self.hostDate = hostDate
    }

    /// Host `Date` of the given position on the same audio clock.
    public func date(forSampleTime time: AVAudioFramePosition) -> Date {
        hostDate.addingTimeInterval(Double(time - sampleTime) / sampleRate)
    }

    /// Host `Date` for an offset in seconds past the anchor — the shape a
    /// transcriber's `audioTimeRange` yields, measured from the first buffer fed.
    public func date(atOffset seconds: TimeInterval) -> Date {
        hostDate.addingTimeInterval(seconds)
    }
}
