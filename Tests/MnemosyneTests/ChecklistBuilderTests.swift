import XCTest
@testable import Mnemosyne

final class ChecklistBuilderTests: XCTestCase {

    func testPlainItemsBecomeUncheckedTasks() {
        XCTAssertEqual(ChecklistBuilder.build("buy milk\ncall Sam"),
                       "- [ ] buy milk\n- [ ] call Sam")
    }

    func testStripsExistingBulletsAndNumbers() {
        let out = ChecklistBuilder.build("- already\n* star\n1. numbered\n2) paren")
        XCTAssertEqual(out, "- [ ] already\n- [ ] star\n- [ ] numbered\n- [ ] paren")
    }

    func testPreservesDoneState() {
        let out = ChecklistBuilder.build("- [x] done thing\n- [ ] open thing\nplain")
        XCTAssertEqual(out, "- [x] done thing\n- [ ] open thing\n- [ ] plain")
    }

    func testSkipsBlankLinesAndEmptyIsNil() {
        XCTAssertEqual(ChecklistBuilder.build("a\n\n   \nb"), "- [ ] a\n- [ ] b")
        XCTAssertNil(ChecklistBuilder.build("   \n  "))
        XCTAssertNil(ChecklistBuilder.build(""))
    }
}
