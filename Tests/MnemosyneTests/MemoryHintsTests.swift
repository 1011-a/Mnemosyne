import XCTest
@testable import Mnemosyne

final class MemoryHintsTests: XCTestCase {

    func testDetectsDurableStatements() {
        XCTAssertEqual(MemoryHints.durableFactCandidate("My name is Sam"), "My name is Sam")
        XCTAssertNotNil(MemoryHints.durableFactCandidate("I always use metric units"))
        XCTAssertNotNil(MemoryHints.durableFactCandidate("Please remember that I prefer dark mode"))
        XCTAssertNotNil(MemoryHints.durableFactCandidate("I work at a hospital"))
        XCTAssertNotNil(MemoryHints.durableFactCandidate("我喜欢喝茶"))   // Chinese cue
    }

    func testIgnoresQuestionsAndNonFacts() {
        XCTAssertNil(MemoryHints.durableFactCandidate("What is my name?"), "questions excluded")
        XCTAssertNil(MemoryHints.durableFactCandidate("How do I prefer to work?"))
        XCTAssertNil(MemoryHints.durableFactCandidate("Can you remember this"), "polite request, not a fact")
        XCTAssertNil(MemoryHints.durableFactCandidate("Summarize my budget"), "no durable cue")
        XCTAssertNil(MemoryHints.durableFactCandidate("hi"), "too short")
    }

    func testLengthBounds() {
        XCTAssertNil(MemoryHints.durableFactCandidate("I am"), "too short even with a cue")
        XCTAssertNil(MemoryHints.durableFactCandidate("I always " + String(repeating: "x", count: 300)),
                     "too long to pin")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(MemoryHints.durableFactCandidate("   My favourite colour is teal  "),
                       "My favourite colour is teal")
    }
}
