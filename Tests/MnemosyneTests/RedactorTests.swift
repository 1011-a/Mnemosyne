import XCTest
@testable import Mnemosyne

final class RedactorTests: XCTestCase {

    func testMasksEmailAndPhoneWithCounts() {
        let r = Redactor.redact("Email me at ada@example.com or call (415) 555-1234.")
        XCTAssertTrue(r.text.contains("[email]"), r.text)
        XCTAssertTrue(r.text.contains("[phone]"), r.text)
        XCTAssertFalse(r.text.contains("ada@example.com"))
        XCTAssertFalse(r.text.contains("555-1234"))
        XCTAssertEqual(r.counts["email"], 1)
        XCTAssertEqual(r.counts["phone"], 1)
    }

    func testSsnMaskedAndNotTreatedAsPhone() {
        let r = Redactor.redact("SSN 123-45-6789 on file.")
        XCTAssertTrue(r.text.contains("[ssn]"), r.text)
        XCTAssertNil(r.counts["phone"], "an SSN must not be counted as a phone")
        XCTAssertEqual(r.counts["ssn"], 1)
    }

    func testCountsMultipleAndLeavesCleanTextUnchanged() {
        let r = Redactor.redact("a@b.com and c@d.org are both here.")
        XCTAssertEqual(r.counts["email"], 2)

        let clean = Redactor.redact("No personal data in this sentence at all.")
        XCTAssertTrue(clean.counts.isEmpty)
        XCTAssertEqual(clean.text, "No personal data in this sentence at all.")
    }

    func testReportNilWhenNothingToRedact() {
        XCTAssertNil(Redactor.report("just ordinary prose"))
        let report = Redactor.report("reach me: x@y.com")
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.contains("1 email"), report ?? "")
    }
}
