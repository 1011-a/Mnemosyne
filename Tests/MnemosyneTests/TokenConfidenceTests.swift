import XCTest
@testable import Mnemosyne

final class TokenConfidenceTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesLogprobs() {
        let body = data("""
        {"choices":[{"logprobs":{"content":[{"token":"Hello","logprob":0.0},{"token":" world","logprob":-0.6931471805599453}]}}]}
        """)
        let toks = TokenConfidence.parse(from: body)
        XCTAssertEqual(toks?.count, 2)
        XCTAssertEqual(toks?.first?.token, "Hello")
        XCTAssertEqual(toks?.first?.logprob ?? 1, 0, accuracy: 1e-9)
    }

    func testAverageProbability() {
        // logprob 0 → prob 1.0; ln(0.5) → prob 0.5; mean = 0.75.
        let toks = [TokenConfidence.Token(token: "a", logprob: 0),
                    TokenConfidence.Token(token: "b", logprob: log(0.5))]
        XCTAssertEqual(TokenConfidence.averageProbability(toks)!, 0.75, accuracy: 1e-9)
        XCTAssertNil(TokenConfidence.averageProbability([]))
    }

    func testLeastConfidentSortsByProbability() {
        let toks = [TokenConfidence.Token(token: "sure", logprob: -0.1),
                    TokenConfidence.Token(token: "maybe", logprob: -2.3),
                    TokenConfidence.Token(token: "ok", logprob: -0.5)]
        let worst = TokenConfidence.leastConfident(toks, count: 2)
        XCTAssertEqual(worst.map(\.token), ["maybe", "ok"])
        XCTAssertLessThan(worst[0].probability, worst[1].probability)
    }

    func testNoLogprobsReturnsNil() {
        XCTAssertNil(TokenConfidence.parse(from: data(#"{"choices":[{"message":{"content":"hi"}}]}"#)))
        XCTAssertNil(TokenConfidence.parse(from: data("not json")))
    }
}
