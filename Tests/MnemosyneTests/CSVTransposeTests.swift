import XCTest
@testable import Mnemosyne

final class CSVTransposeTests: XCTestCase {

    func testSwapsRowsAndColumns() {
        let rows = [["a", "b"], ["1", "2"], ["3", "4"]]
        XCTAssertEqual(CSVTranspose.transpose(rows), [["a", "1", "3"], ["b", "2", "4"]])
    }

    func testRaggedRowsPaddedWithBlanks() {
        let rows = [["a", "b", "c"], ["1"]]
        XCTAssertEqual(CSVTranspose.transpose(rows), [["a", "1"], ["b", ""], ["c", ""]])
    }

    func testTransposeTwiceIsIdentityForRectangular() {
        let rows = [["a", "b"], ["1", "2"]]
        XCTAssertEqual(CSVTranspose.transpose(CSVTranspose.transpose(rows)), rows)
    }

    func testEmpty() {
        XCTAssertTrue(CSVTranspose.transpose([]).isEmpty)
        XCTAssertTrue(CSVTranspose.transpose([[]]).isEmpty)
    }
}
