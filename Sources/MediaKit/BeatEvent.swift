import Foundation

/// One predicted beat: the instant it is expected to land, the current beat
/// period, and how much the tracker trusts itself. Emitted ahead of the beat,
/// never after it — consumers schedule, they do not react. In silence no
/// events are emitted at all; a derived value that can be refused goes silent.
public struct BeatEvent: Sendable, Equatable {
    /// Predicted beat instant on the host clock.
    public let time: Date

    /// Beat period at prediction time; `60 / period` is the tempo in BPM.
    public let period: TimeInterval

    /// 0…1. Tempo evidence times recent onset support.
    public let confidence: Double

    public init(time: Date, period: TimeInterval, confidence: Double) {
        self.time = time
        self.period = period
        self.confidence = confidence
    }
}
