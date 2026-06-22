import XCTest
@testable import Mnemosyne

final class PromptCachePrefixTests: XCTestCase {

    func testFactsBlockIsSortedAndDeduped() {
        let a = PromptCachePrefix.stableFactsBlock(["banana", "apple", "banana"])
        let b = PromptCachePrefix.stableFactsBlock(["apple", "banana"])
        XCTAssertEqual(a, "- apple\n- banana")
        XCTAssertEqual(a, b)   // same set → identical bytes regardless of input order
    }

    func testFactsBlockTrimsAndDropsBlanks() {
        XCTAssertEqual(PromptCachePrefix.stableFactsBlock(["  x  ", "", "   "]), "- x")
        XCTAssertEqual(PromptCachePrefix.stableFactsBlock([]), "")
    }

    func testCaseInsensitiveDedupeKeepsFirst() {
        // "Apple" and "apple" collapse to one (the first seen).
        XCTAssertEqual(PromptCachePrefix.stableFactsBlock(["Apple", "apple"]), "- Apple")
    }

    func testCacheablePrefixCountsLeadingSystemOnly() {
        let msgs: [[String: Any]] = [
            ["role": "system", "content": "abc"],     // 3
            ["role": "system", "content": "de"],      // 2
            ["role": "user", "content": "ignored"],   // stops here
            ["role": "system", "content": "later"],
        ]
        XCTAssertEqual(PromptCachePrefix.cacheablePrefixChars(msgs), 5)
        XCTAssertEqual(PromptCachePrefix.cacheablePrefixChars([]), 0)
    }
}
