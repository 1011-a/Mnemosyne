import XCTest
@testable import Mnemosyne

final class QuestionExtractorTests: XCTestCase {

    func testPullsQuestionsAndSkipsStatements() {
        let text = "The system is fast. How does it scale? It uses caching. What about cost? Done."
        let qs = QuestionExtractor.extract(text)
        XCTAssertEqual(qs, ["How does it scale?", "What about cost?"], "only the interrogative sentences")
    }

    func testDocumentOrderAndDedupe() {
        let text = "Why? Because. Why? Again."
        let qs = QuestionExtractor.extract(text)
        XCTAssertEqual(qs.filter { $0 == "Why?" }.count, 1, "repeated question collapsed")
    }

    func testFullWidthQuestionMark() {
        let qs = QuestionExtractor.extract("这是一个陈述。这个怎么用？谢谢。")
        XCTAssertTrue(qs.contains { $0.contains("怎么用") }, "full-width ？ recognized: \(qs)")
    }

    func testNoQuestions() {
        XCTAssertTrue(QuestionExtractor.extract("A plain statement. Another one.").isEmpty)
        XCTAssertTrue(QuestionExtractor.extract("").isEmpty)
    }
}
