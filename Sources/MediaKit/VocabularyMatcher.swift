import Foundation

/// Matches transcribed tokens against a small configured vocabulary,
/// case- and diacritic-insensitively, returning the canonical spelling.
public struct VocabularyMatcher: Sendable, Equatable {
    private let canonical: [String: String]

    public init(words: [String]) {
        var map: [String: String] = [:]
        for word in words {
            let key = Self.normalise(word)
            if !key.isEmpty, map[key] == nil { map[key] = word }
        }
        canonical = map
    }

    /// The canonical vocabulary word the token matches, or nil.
    public func match(_ token: String) -> String? {
        canonical[Self.normalise(token)]
    }

    public static func normalise(_ string: String) -> String {
        string
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The spotter's pure core: transcribed tokens with stream-relative offsets
/// become onset-timestamped events — thresholded, matched, ordered by onset.
public func labelEvents(
    tokens: [(token: String, offset: TimeInterval, confidence: Double)],
    matcher: VocabularyMatcher,
    anchor: AudioClockAnchor,
    confidenceThreshold: Double
) -> [LabelEvent] {
    tokens
        .compactMap { entry -> LabelEvent? in
            guard entry.confidence >= confidenceThreshold,
                  let word = matcher.match(entry.token) else { return nil }
            return LabelEvent(time: anchor.date(atOffset: entry.offset),
                              label: word,
                              confidence: entry.confidence)
        }
        .sorted { $0.time < $1.time }
}
