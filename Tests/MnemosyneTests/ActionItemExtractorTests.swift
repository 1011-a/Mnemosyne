import XCTest
@testable import Mnemosyne

final class ActionItemExtractorTests: XCTestCase {

    func testCheckboxesOnlyUnchecked() {
        let text = """
        Sprint notes
        - [ ] Ship the report
        - [x] Already done thing
        * [ ] Email the client
        """
        XCTAssertEqual(ActionItemExtractor.extract(text), ["Ship the report", "Email the client"])
    }

    func testMarkers() {
        let text = "TODO: call Sam\nFIXME - retry the upload\nACTION ITEM: sign the form"
        XCTAssertEqual(ActionItemExtractor.extract(text),
                       ["call Sam", "retry the upload", "sign the form"])
    }

    func testCommitmentPhrasing() {
        let text = """
        We need to finalize the budget.
        I should review the draft tonight.
        Remember to water the plants.
        Follow up on the invoice.
        This sentence is just narrative with no task.
        """
        let items = ActionItemExtractor.extract(text)
        XCTAssertTrue(items.contains("We need to finalize the budget."))
        XCTAssertTrue(items.contains("Remember to water the plants."))
        XCTAssertTrue(items.contains("Follow up on the invoice."))
        XCTAssertFalse(items.contains { $0.contains("just narrative") }, "non-task prose is excluded")
    }

    func testDedupeAndOrder() {
        let text = "TODO: ship it\n- [ ] ship it\nLater we must ship it again differently"
        let items = ActionItemExtractor.extract(text)
        XCTAssertEqual(items.first, "ship it", "first occurrence wins, document order")
        XCTAssertEqual(items.filter { $0 == "ship it" }.count, 1, "duplicate collapsed case-insensitively")
    }

    func testNoActionItems() {
        XCTAssertTrue(ActionItemExtractor.extract("Just a calm paragraph about the weather.").isEmpty)
        XCTAssertTrue(ActionItemExtractor.extract("").isEmpty)
    }
}
