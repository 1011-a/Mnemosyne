import XCTest
@testable import Mnemosyne

final class SimilarityTests: XCTestCase {

    func testIdenticalAndDisjoint() {
        XCTAssertEqual(Similarity.jaccard("the quick fox", "the quick fox"), 1.0)
        XCTAssertEqual(Similarity.jaccard("alpha beta", "gamma delta"), 0.0)
    }

    func testPartialOverlap() {
        // {a,b,c} vs {b,c,d}: intersection 2, union 4 → 0.5
        XCTAssertEqual(Similarity.jaccard("a b c", "b c d"), 0.5)
    }

    func testCaseInsensitiveAndPunctuation() {
        XCTAssertEqual(Similarity.jaccard("Hello, World!", "hello world"), 1.0)
    }

    func testEmptyCases() {
        XCTAssertEqual(Similarity.jaccard("", ""), 1.0)      // both empty → identical
        XCTAssertEqual(Similarity.jaccard("", "x"), 0.0)
    }
}
