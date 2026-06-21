import XCTest
@testable import Mnemosyne

final class ConfirmationHintsTests: XCTestCase {

    func testDetectsToolPreviewPrompts() {
        XCTAssertTrue(ConfirmationHints.isPendingConfirmation(
            "CONFIRM NEEDED — this will add label 'x' to 3 files. Call again with confirm=true."))
        XCTAssertTrue(ConfirmationHints.isPendingConfirmation(
            "Proposed labels … Call again with apply=true to apply them."))
        // The model's rephrased prompt (from the reported screenshot).
        XCTAssertTrue(ConfirmationHints.isPendingConfirmation(
            "**Shall I apply these labels?** (Reply \"是\" or \"apply\" to confirm, or \"no\" to skip.)"))
        XCTAssertTrue(ConfirmationHints.isPendingConfirmation("Proceed? Reply yes or no."))
    }

    func testIgnoresNormalAnswers() {
        XCTAssertFalse(ConfirmationHints.isPendingConfirmation(
            "Your library holds 88 items across images, PDFs and notes."))
        XCTAssertFalse(ConfirmationHints.isPendingConfirmation(
            "I confirmed the budget figures look correct."), "a stray 'confirm' isn't a prompt")
        XCTAssertFalse(ConfirmationHints.isPendingConfirmation(""))
    }

    func testApproveMessageSignalsBothParams() {
        XCTAssertTrue(ConfirmationHints.approveMessage.contains("apply=true"))
        XCTAssertTrue(ConfirmationHints.approveMessage.contains("confirm=true"))
        XCTAssertFalse(ConfirmationHints.skipMessage.isEmpty)
    }
}
