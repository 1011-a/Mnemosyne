import XCTest
@testable import Mnemosyne

/// Guards create_artifact's external end-state verification (ToolAgent.artifactShortfall) — the
/// filesystem-grounded check that drives the one grounded retry.
final class ArtifactShortfallTests: XCTestCase {

    func testFreshBuildWithNoFilesIsShort() {
        let gap = ToolAgent.artifactShortfall(files: [], wantsPDF: false, baseline: [], revising: false)
        XCTAssertNotNil(gap)
        XCTAssertTrue(gap!.contains("no new files"))
    }

    func testFilesPresentNoPDFWantedIsComplete() {
        XCTAssertNil(ToolAgent.artifactShortfall(files: ["index.html"], wantsPDF: false, baseline: [], revising: false))
    }

    func testPDFWantedButMissingIsShort() {
        let gap = ToolAgent.artifactShortfall(files: ["book.html"], wantsPDF: true, baseline: [], revising: false)
        XCTAssertNotNil(gap)
        XCTAssertTrue(gap!.lowercased().contains("pdf"))
    }

    func testPDFWantedAndPresentIsComplete() {
        XCTAssertNil(ToolAgent.artifactShortfall(files: ["book.html", "book.pdf"], wantsPDF: true, baseline: [], revising: false))
        // case-insensitive extension
        XCTAssertNil(ToolAgent.artifactShortfall(files: ["BOOK.PDF"], wantsPDF: true, baseline: [], revising: false))
    }

    func testReviseProducesNothingWhenUnchanged() {
        let base: Set<String> = ["index.html"]
        XCTAssertNotNil(ToolAgent.artifactShortfall(files: ["index.html"], wantsPDF: false, baseline: base, revising: true))
        XCTAssertNil(ToolAgent.artifactShortfall(files: ["index.html", "style.css"], wantsPDF: false, baseline: base, revising: true))
    }
}
