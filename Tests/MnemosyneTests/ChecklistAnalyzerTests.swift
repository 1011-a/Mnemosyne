import XCTest
@testable import Mnemosyne

final class ChecklistAnalyzerTests: XCTestCase {

    private let list = """
    # My plan
    - [x] book flights
    - [ ] pack bags
    * [X] charge camera
    + [ ] confirm hotel
    regular bullet, not a task
    - [ ] buy snacks
    """

    func testParsesDoneAndPendingAcrossBulletStyles() {
        let items = ChecklistAnalyzer.items(list)
        XCTAssertEqual(items.count, 5)               // the plain bullet is excluded
        XCTAssertEqual(items.filter { $0.done }.count, 2)   // [x] and [X]
        XCTAssertEqual(items.filter { !$0.done }.count, 3)
        XCTAssertEqual(items.first, .init(done: true, text: "book flights"))
    }

    func testReportComputesPercentAndListsBoth() {
        let report = ChecklistAnalyzer.report(list)
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.contains("2/5 done (40%)"), report ?? "")
        XCTAssertTrue(report!.contains("☐ pack bags"), report ?? "")   // pending box
        XCTAssertTrue(report!.contains("☑ book flights"), report ?? "")  // done box
    }

    func testNoChecklistReturnsNil() {
        XCTAssertNil(ChecklistAnalyzer.report("Just prose with a - dash and [brackets] but no boxes."))
        XCTAssertTrue(ChecklistAnalyzer.items("").isEmpty)
    }

    func testAllDoneIsHundredPercent() {
        let r = ChecklistAnalyzer.report("- [x] a\n- [x] b")
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("2/2 done (100%)"), r ?? "")
    }
}
