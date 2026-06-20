import XCTest
@testable import Mnemosyne

final class CsvTests: XCTestCase {

    func testHeaderValueRows() {
        let text = CsvExtractor.parse("""
        name,email,role
        Alice,alice@x.com,Engineer
        Bob,bob@y.com,Designer
        """)
        XCTAssertEqual(text, """
        name: Alice · email: alice@x.com · role: Engineer
        name: Bob · email: bob@y.com · role: Designer
        """)
    }

    func testQuotedFieldsWithCommas() {
        let text = CsvExtractor.parse("""
        name,age
        "Smith, John",30
        """)
        XCTAssertEqual(text, "name: Smith, John · age: 30")
    }

    func testEscapedDoubleQuotes() {
        let text = CsvExtractor.parse("quote\n\"say \"\"hi\"\"\"")
        XCTAssertEqual(text, "quote: say \"hi\"")
    }

    func testEmptyCellsAreSkipped() {
        let text = CsvExtractor.parse("a,b,c\n1,,3")
        XCTAssertEqual(text, "a: 1 · c: 3")
    }

    func testTabDelimited() {
        let text = CsvExtractor.parse("name\tcity\nAda\tLondon", delimiter: "\t")
        XCTAssertEqual(text, "name: Ada · city: London")
    }

    func testHeaderOnlyJoinsHeaders() {
        XCTAssertEqual(CsvExtractor.parse("a,b,c"), "a · b · c")
    }

    func testIsCsvAndKindMapping() {
        XCTAssertTrue(CsvExtractor.isCsv(URL(fileURLWithPath: "/tmp/data.csv")))
        XCTAssertTrue(CsvExtractor.isCsv(URL(fileURLWithPath: "/tmp/data.tsv")))
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/data.csv")), .data)
    }
}
