import XCTest
@testable import Mnemosyne

@MainActor
final class IngestProgressTests: XCTestCase {

    /// The bug behind "Up to date · 4%": a small FSEvents batch finishing WHILE the
    /// big folder scan is still running must not flip the whole run to .done.
    func testOverlappingBatchDoesNotEndRunEarly() {
        let p = IngestProgress()
        p.beginJob(total: 100)             // the big scan starts
        for _ in 0..<10 { p.tickSkipped("x") }
        XCTAssertEqual(p.phase, .ingesting)

        // A watcher batch arrives mid-scan, runs, and ends.
        p.beginJob(total: 3)
        p.tickAdded("new.txt")
        p.endJob()

        // The big scan is STILL going — must not read "Up to date".
        XCTAssertEqual(p.phase, .ingesting, "run must stay active until the last job ends")
        XCTAssertEqual(p.total, 103, "overlapping jobs accumulate into one total")

        p.endJob()                          // big scan finishes
        XCTAssertEqual(p.phase, .done, "only now is the run complete")
    }

    /// Fraction is monotonic and never exceeds 1 even if extra ticks slip in.
    func testFractionStaysBounded() {
        let p = IngestProgress()
        p.beginJob(total: 2)
        p.tickAdded("a"); p.tickAdded("b"); p.tickSkipped("c")   // 3 processed of 2
        XCTAssertEqual(p.fraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(p.remaining, 0)
    }

    /// A fresh run after one completes zeroes the counters.
    func testNewRunResetsCounters() {
        let p = IngestProgress()
        p.beginJob(total: 5); p.tickAdded("a"); p.endJob()
        XCTAssertEqual(p.phase, .done)

        p.beginJob(total: 2)
        XCTAssertEqual(p.processed, 0)
        XCTAssertEqual(p.added, 0)
        XCTAssertEqual(p.total, 2)
        XCTAssertEqual(p.phase, .ingesting)
    }
}
