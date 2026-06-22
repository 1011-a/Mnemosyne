import XCTest
@testable import Mnemosyne

final class TextReplaceTests: XCTestCase {

    func testReplacesAllAndCounts() {
        let r = TextReplace.replace("a b a b a", find: "a", with: "X")
        XCTAssertEqual(r.result, "X b X b X")
        XCTAssertEqual(r.count, 3)
    }

    func testCaseInsensitiveMatching() {
        let sensitive = TextReplace.replace("Cat cat CAT", find: "cat", with: "dog")
        XCTAssertEqual(sensitive.count, 1)            // only the exact-case match
        let insensitive = TextReplace.replace("Cat cat CAT", find: "cat", with: "dog", caseInsensitive: true)
        XCTAssertEqual(insensitive.count, 3)
        XCTAssertEqual(insensitive.result, "dog dog dog")
    }

    func testEmptyReplacementDeletes() {
        let r = TextReplace.replace("hello world", find: "o", with: "")
        XCTAssertEqual(r.result, "hell wrld")
        XCTAssertEqual(r.count, 2)
    }

    func testNoMatchAndEmptyFind() {
        let none = TextReplace.replace("abc", find: "z", with: "Y")
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(none.result, "abc")
        let emptyFind = TextReplace.replace("abc", find: "", with: "Y")
        XCTAssertEqual(emptyFind.count, 0)
        XCTAssertEqual(emptyFind.result, "abc")       // empty find never matches
    }
}
