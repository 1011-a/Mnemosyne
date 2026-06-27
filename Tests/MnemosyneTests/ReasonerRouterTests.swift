import XCTest
@testable import Mnemosyne

final class ReasonerRouterTests: XCTestCase {

    func testRoutesAnalyticalQuestionsToReasoner() {
        XCTAssertTrue(ReasonerRouter.shouldUseReasoner("Why does the sky appear blue?"))
        XCTAssertTrue(ReasonerRouter.shouldUseReasoner("Prove that sqrt(2) is irrational."))
        XCTAssertTrue(ReasonerRouter.shouldUseReasoner("Compare Postgres and MySQL for our use case."))
        XCTAssertTrue(ReasonerRouter.shouldUseReasoner("Walk me through the trade-offs step by step."))
    }

    func testKeepsQuickLookupsOnChat() {
        XCTAssertFalse(ReasonerRouter.shouldUseReasoner("What's the capital of France?"))
        XCTAssertFalse(ReasonerRouter.shouldUseReasoner("Define photosynthesis."))
        XCTAssertFalse(ReasonerRouter.shouldUseReasoner(""))
    }

    func testLongPromptsRouteToReasoner() {
        let long = Array(repeating: "word", count: 45).joined(separator: " ")
        XCTAssertTrue(ReasonerRouter.shouldUseReasoner(long))
    }

    func testWholeWordMatchingAvoidsFalsePositives() {
        // "anywhere" contains "why" as a substring but not as a word → should NOT route.
        XCTAssertFalse(ReasonerRouter.shouldUseReasoner("Can I put this anywhere?"))
    }

    func testRationaleReflectsDecision() {
        XCTAssertTrue(ReasonerRouter.rationale("why is this so?").contains("deepseek-v4-pro"))
        XCTAssertTrue(ReasonerRouter.rationale("hi there").contains("deepseek-v4-flash"))
    }
}
