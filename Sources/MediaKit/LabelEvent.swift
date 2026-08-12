import Foundation

/// A recognised label on the host wall clock: a spotted word, a sound class,
/// a recognised asana. Structurally a machine annotation — the plain-data
/// shape this library emits alongside runs of `Double`s.
public struct LabelEvent: Sendable, Equatable {
    /// Onset of the labelled event — when it began, not when it was recognised.
    public let time: Date
    /// The canonical label, as configured by the consumer.
    public let label: String
    /// Recognition confidence in 0…1; 1 when the engine reports none.
    public let confidence: Double

    public init(time: Date, label: String, confidence: Double) {
        self.time = time
        self.label = label
        self.confidence = confidence
    }
}
