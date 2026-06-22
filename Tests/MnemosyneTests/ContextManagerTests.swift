import XCTest
@testable import Mnemosyne

final class ContextManagerTests: XCTestCase {

    private func msg(_ role: ChatMessageRole, tokens: Int) -> ChatMessage {
        // ~4 chars per token, so content of 4*tokens chars ≈ `tokens` tokens.
        ChatMessage(role: role, content: String(repeating: "x", count: tokens * 4))
    }

    func testHumanTokensLabel() {
        XCTAssertEqual(ContextManager.humanTokens(850), "850")
        XCTAssertEqual(ContextManager.humanTokens(1200), "1.2k")
        XCTAssertEqual(ContextManager.humanTokens(12_000), "12k")
        XCTAssertEqual(ContextManager.humanTokens(96_000), "96k")
        XCTAssertEqual(ContextManager.humanTokens(0), "0")
    }

    func testEstimateTokens() {
        XCTAssertEqual(ContextManager.estimateTokens(String(repeating: "a", count: 400)), 100)
        XCTAssertEqual(ContextManager.estimateTokens(""), 1, "never zero")
    }

    func testKeepsEverythingUnderBudget() {
        let thread = (0..<10).map { _ in msg(.user, tokens: 10) }   // 100 tokens total
        let plan = ContextManager.plan(thread, budget: 1000)
        XCTAssertEqual(plan, .init(compactUpTo: 0, keepFrom: 0), "whole thread fits ⇒ no compaction")
    }

    func testCompactsOldestWhenOverBudget() {
        // 5 messages × 60 tokens = 300 > budget 100; minRecent 2, keepBudget = 70.
        let thread = (0..<5).map { _ in msg(.assistant, tokens: 60) }
        let plan = ContextManager.plan(thread, budget: 100, minRecent: 2)
        XCTAssertGreaterThan(plan.compactUpTo, 0, "older turns are compacted")
        XCTAssertEqual(plan.keepFrom, plan.compactUpTo, "kept suffix begins where compaction ends")
        XCTAssertGreaterThanOrEqual(thread.count - plan.keepFrom, 2, "at least minRecent kept verbatim")
    }

    func testNeverCompactsBelowMinRecent() {
        let thread = (0..<4).map { _ in msg(.user, tokens: 999) }   // huge but only 4 messages
        let plan = ContextManager.plan(thread, budget: 100, minRecent: 6)
        XCTAssertEqual(plan.compactUpTo, 0, "too few messages to compact")
    }

    func testAssemblePrependsSystemSummary() {
        let recent = [msg(.user, tokens: 5), msg(.assistant, tokens: 5)]
        let out = ContextManager.assemble(recent: recent, summary: "Earlier: discussed X.")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.first?.role, .system)
        XCTAssertTrue(out.first?.content.contains("Summary of earlier conversation") ?? false)
        XCTAssertTrue(out.first?.content.contains("Earlier: discussed X.") ?? false)
        // Empty summary ⇒ just the recent messages, no synthetic system turn.
        XCTAssertEqual(ContextManager.assemble(recent: recent, summary: "   ").count, 2)
    }
}
