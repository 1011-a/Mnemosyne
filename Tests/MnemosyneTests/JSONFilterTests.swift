import XCTest
@testable import Mnemosyne

final class JSONFilterTests: XCTestCase {

    private let json = #"[{"name":"a","score":90},{"name":"b","score":60},{"name":"c","score":85}]"#

    func testNumericFilter() {
        guard case let .ok(rows) = JSONFilter.filter(json, where: "score >= 80") else { return XCTFail("expected ok") }
        XCTAssertEqual(rows.count, 3)   // header + 2 matches (90, 85)
        // header is JSONTable's sorted-key order: name, score.
        let nameIdx = rows[0].firstIndex(of: "name")!
        XCTAssertEqual(Set(rows.dropFirst().map { $0[nameIdx] }), ["a", "c"])
    }

    func testTextEqualsFilter() {
        let nestedJson = #"[{"status":"active"},{"status":"closed"}]"#
        guard case let .ok(rows) = JSONFilter.filter(nestedJson, where: "status = active") else { return XCTFail() }
        XCTAssertEqual(rows.count, 2)   // header + 1 match
    }

    func testBadPredicateAndMissingKeyAndBadJSON() {
        if case .badPredicate = JSONFilter.filter(json, where: "gibberish") {} else { XCTFail("expected badPredicate") }
        if case .noColumn = JSONFilter.filter(json, where: "missing = 1") {} else { XCTFail("expected noColumn") }
        if case .badJSON = JSONFilter.filter("not json", where: "a = 1") {} else { XCTFail("expected badJSON") }
    }
}
