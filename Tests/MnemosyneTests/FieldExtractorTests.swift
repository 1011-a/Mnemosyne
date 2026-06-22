import XCTest
@testable import Mnemosyne

final class FieldExtractorTests: XCTestCase {

    func testMessagesIncludeFieldsAndText() {
        let msgs = FieldExtractor.messages(text: "Invoice #5 for $42", fields: ["number", "amount"])
        XCTAssertEqual(msgs.count, 2)
        let system = msgs[0]["content"] as? String ?? ""
        XCTAssertTrue(system.contains("number, amount"))
        XCTAssertTrue(system.uppercased().contains("JSON"))
        let user = msgs[1]["content"] as? String ?? ""
        XCTAssertTrue(user.contains("Invoice #5 for $42"))
    }

    func testFormatRendersFieldsInOrderWithMissingDash() {
        let json = #"{"name":"Acme","amount":42,"active":true,"note":null}"#
        let out = FieldExtractor.format(json: json, fields: ["name", "amount", "active", "note", "phone"])
        XCTAssertEqual(out, """
        name    Acme
        amount  42
        active  true
        note    —
        phone   —
        """)
    }

    func testFormatRendersArraysCompactly() {
        let out = FieldExtractor.format(json: #"{"tags":["a","b"]}"#, fields: ["tags"])
        XCTAssertEqual(out, "tags  [\"a\",\"b\"]")
    }

    func testFormatNilOnNonObject() {
        XCTAssertNil(FieldExtractor.format(json: "[1,2,3]", fields: ["x"]))
        XCTAssertNil(FieldExtractor.format(json: "not json", fields: ["x"]))
    }
}
