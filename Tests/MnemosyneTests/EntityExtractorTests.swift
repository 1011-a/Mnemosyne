import XCTest
@testable import Mnemosyne

/// NLTagger NER is OS-model-driven, so these assert MEMBERSHIP (robust) rather than
/// exact full lists, and use unambiguous well-known names.
final class EntityExtractorTests: XCTestCase {

    func testFindsPeopleOrgsPlaces() {
        let text = "Tim Cook met with Angela Merkel in Berlin while representing Apple."
        let ents = EntityExtractor.extract(text)
        let people = ents.filter { $0.kind == .person }.map(\.name)
        let places = ents.filter { $0.kind == .place }.map(\.name)
        XCTAssertTrue(people.contains { $0.contains("Tim Cook") }, "got people: \(people)")
        XCTAssertTrue(people.contains { $0.contains("Angela Merkel") }, "got people: \(people)")
        XCTAssertTrue(places.contains { $0.contains("Berlin") }, "got places: \(places)")
        // (Organization tagging like "Apple" is model-dependent across OS versions, so it
        // isn't asserted here — people/place recognition is stable.)
    }

    func testSummaryGroupsByKind() {
        let text = "Barack Obama visited Paris and London last spring."
        let summary = EntityExtractor.summary(text)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("People:"), "summary: \(summary ?? "")")
    }

    func testDedupesRepeatedNames() {
        let text = "Tim Cook spoke. Later, Tim Cook spoke again, and again Tim Cook."
        let cooks = EntityExtractor.extract(text).filter { $0.name.contains("Tim Cook") }
        XCTAssertEqual(cooks.count, 1, "repeated name collapsed to one entry")
    }

    func testNoEntities() {
        XCTAssertTrue(EntityExtractor.extract("the small round table sat quietly").isEmpty)
        XCTAssertNil(EntityExtractor.summary(""))
    }
}
