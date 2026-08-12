import Foundation
import Testing
@testable import MediaKit

struct LabelEventMappingTests {
    let matcher = VocabularyMatcher(words: ["apple", "banana"])
    let anchor = AudioClockAnchor(sampleTime: 0, sampleRate: 1,
                                  hostDate: Date(timeIntervalSince1970: 5_000_000))

    @Test func dropsBelowThreshold() {
        let events = labelEvents(tokens: [("apple", 1.0, 0.2)],
                                 matcher: matcher, anchor: anchor,
                                 confidenceThreshold: 0.3)
        #expect(events.isEmpty)
    }

    @Test func onsetIsAnchorPlusOffset() {
        let events = labelEvents(tokens: [("apple", 2.25, 1.0)],
                                 matcher: matcher, anchor: anchor,
                                 confidenceThreshold: 0.3)
        #expect(events == [LabelEvent(time: anchor.hostDate.addingTimeInterval(2.25),
                                      label: "apple", confidence: 1.0)])
    }

    @Test func ordersByOnsetEvenIfTokensArriveUnordered() {
        let events = labelEvents(tokens: [("banana", 4.0, 1.0), ("apple", 1.0, 1.0)],
                                 matcher: matcher, anchor: anchor,
                                 confidenceThreshold: 0.3)
        #expect(events.map(\.label) == ["apple", "banana"])
    }

    @Test func emitsOneEventPerVocabularyWordInBatch() {
        let events = labelEvents(
            tokens: [("the", 0.5, 1.0), ("Apple.", 1.0, 1.0), ("fell", 1.5, 1.0), ("banana", 2.0, 0.9)],
            matcher: matcher, anchor: anchor, confidenceThreshold: 0.3)
        #expect(events.map(\.label) == ["apple", "banana"])
        #expect(events[1].confidence == 0.9)
    }
}
