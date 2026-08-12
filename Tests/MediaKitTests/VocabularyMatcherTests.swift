import Testing
@testable import MediaKit

struct VocabularyMatcherTests {
    let matcher = VocabularyMatcher(words: ["Mark", "naïve", "banana"])

    @Test func matchesCaseInsensitively() {
        #expect(matcher.match("mark") == "Mark")
        #expect(matcher.match("MARK") == "Mark")
    }

    @Test func matchesDiacriticInsensitively() {
        #expect(matcher.match("naive") == "naïve")
        #expect(matcher.match("NAÏVE") == "naïve")
    }

    @Test func trimsPunctuationAndWhitespace() {
        #expect(matcher.match("mark.") == "Mark")
        #expect(matcher.match(" banana, ") == "banana")
        #expect(matcher.match("“mark”") == "Mark")
    }

    @Test func rejectsNonVocabularyTokens() {
        #expect(matcher.match("apple") == nil)
        #expect(matcher.match("markers") == nil)
        #expect(matcher.match("") == nil)
    }

    @Test func returnsCanonicalSpelling() {
        #expect(matcher.match("Banana") == "banana")
    }

    @Test func ignoresEmptyVocabularyEntries() {
        let sparse = VocabularyMatcher(words: ["", "  ", "word"])
        #expect(sparse.match("word") == "word")
        #expect(sparse.match("") == nil)
    }
}
