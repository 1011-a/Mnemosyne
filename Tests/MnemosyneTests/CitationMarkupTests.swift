import XCTest
import SwiftUI
@testable import Mnemosyne

final class CitationMarkupTests: XCTestCase {

    func testPlainTextIsPreservedExactly() {
        let attr = CitationMarkup.attributed("See [1] and also [2, 3].", accent: .red)
        XCTAssertEqual(String(attr.characters), "See [1] and also [2, 3].")
    }

    func testMarkersAreColouredAccentAndOthersAreNot() {
        let attr = CitationMarkup.attributed("A [1] B [2] C.", accent: .red)
        var coloured: [String] = []
        for run in attr.runs where run.foregroundColor == .red {
            coloured.append(String(attr[run.range].characters))
        }
        XCTAssertEqual(coloured, ["[1]", "[2]"])
    }

    func testMarkerCount() {
        XCTAssertEqual(CitationMarkup.markerCount("no markers here"), 0)
        XCTAssertEqual(CitationMarkup.markerCount("[1] x [2] y [3]"), 3)
        XCTAssertEqual(CitationMarkup.markerCount("ranges [2, 4] count once"), 1)
    }

    func testNoMarkersStillRoundTrips() {
        XCTAssertEqual(String(CitationMarkup.attributed("plain prose", accent: .red).characters),
                       "plain prose")
    }
}
