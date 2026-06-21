import XCTest
@testable import Mnemosyne

final class KeywordExtractorTests: XCTestCase {

    func testRanksByFrequencyAndDropsStopwords() {
        let text = """
        Vector search with embeddings. The embeddings power vector retrieval.
        Vector vector embeddings retrieval retrieval retrieval.
        """
        let terms = KeywordExtractor.topTerms(text, limit: 5)
        let map = Dictionary(uniqueKeysWithValues: terms.map { ($0.term, $0.count) })
        XCTAssertEqual(map["retrieval"], 4)
        XCTAssertEqual(map["vector"], 4)
        XCTAssertEqual(map["embeddings"], 3)
        // Stopwords and short tokens are excluded.
        XCTAssertNil(map["the"]); XCTAssertNil(map["with"])
        // Ties (vector & retrieval at 4) order alphabetically: retrieval before vector.
        XCTAssertEqual(terms.first?.term, "retrieval")
    }

    func testSkipsShortTokensAndPureNumbers() {
        let terms = KeywordExtractor.topTerms("a ab abc 1234 abc abc 42 42 42")
        let map = Dictionary(uniqueKeysWithValues: terms.map { ($0.term, $0.count) })
        XCTAssertEqual(map["abc"], 3, "3+ letter tokens count")
        XCTAssertNil(map["ab"], "2-char tokens skipped")
        XCTAssertNil(map["1234"], "pure-number tokens skipped (no letter)")
        XCTAssertNil(map["42"], "short pure-number skipped")
    }

    func testLimitAndSummary() {
        let text = "alpha beta gamma delta epsilon zeta alpha beta gamma"
        XCTAssertEqual(KeywordExtractor.topTerms(text, limit: 3).count, 3)
        let s = KeywordExtractor.summary(text, limit: 3)
        XCTAssertTrue(s.hasPrefix("alpha (2)"), "most frequent first: \(s)")
        XCTAssertEqual(KeywordExtractor.summary("the and for"), "No salient terms found.",
                       "all-stopword text ⇒ friendly note")
        XCTAssertEqual(KeywordExtractor.summary(""), "No salient terms found.")
    }

    func testLibraryThemesByDocumentFrequency() {
        let docs = [
            "vector search with embeddings",
            "embeddings power retrieval and vector search",
            "retrieval augmented generation uses vector stores",
            "cooking pasta recipe tomato",          // off-topic, unique terms
        ]
        let themes = KeywordExtractor.libraryThemes(docs: docs)
        let map = Dictionary(uniqueKeysWithValues: themes.map { ($0.term, $0.count) })
        XCTAssertEqual(map["vector"], 3, "in 3 docs")
        XCTAssertEqual(map["embeddings"], 2)
        XCTAssertEqual(map["retrieval"], 2)
        XCTAssertNil(map["pasta"], "one-off terms (df<2) excluded")
        XCTAssertEqual(themes.first?.term, "vector", "highest document frequency first")
    }

    func testLibraryThemesEmptyWhenNoOverlap() {
        XCTAssertTrue(KeywordExtractor.libraryThemes(docs: ["alpha beta", "gamma delta"]).isEmpty,
                      "no term shared across ≥2 docs")
    }

    func testAlphanumericTokenKept() {
        // Mixed letter+digit tokens (e.g. "gpt4") are kept since they contain a letter.
        let map = Dictionary(uniqueKeysWithValues:
            KeywordExtractor.topTerms("gpt4 gpt4 model").map { ($0.term, $0.count) })
        XCTAssertEqual(map["gpt4"], 2)
    }
}
