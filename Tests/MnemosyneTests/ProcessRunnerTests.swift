import XCTest
@testable import Mnemosyne

/// Exercises the shared subprocess runner with real system binaries — fast and
/// deterministic on macOS. The key guarantee: a hung process is force-killed and the
/// call returns, so ingest can never block forever on one wedged CLI.
final class ProcessRunnerTests: XCTestCase {

    func testCapturesStdoutOnSuccess() async {
        let r = await ProcessRunner.run(bin: "/bin/echo", args: ["hello world"], timeout: 5)
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                       "hello world")
    }

    func testNonZeroExitStatusReported() async {
        let r = await ProcessRunner.run(bin: "/bin/sh", args: ["-c", "exit 7"], timeout: 5)
        XCTAssertEqual(r.status, 7)
        XCTAssertFalse(r.timedOut)
    }

    func testHungProcessIsKilledAndReturnsWithinTimeout() async {
        // `sleep 30` would block ingest forever under the old SIGTERM-only watchdog.
        let start = Date()
        let r = await ProcessRunner.run(bin: "/bin/sleep", args: ["30"],
                                        timeout: 0.4, graceSeconds: 0.4)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.timedOut, "the watchdog had to kill it")
        XCTAssertNotEqual(r.status, 0, "a killed process is not a clean exit")
        XCTAssertLessThan(elapsed, 10, "returned promptly after the timeout, not after sleep finished (took \(elapsed)s)")
    }

    func testSpawnFailureReturnsSentinel() async {
        let r = await ProcessRunner.run(bin: "/nope/not/a/real/binary", args: [], timeout: 2)
        XCTAssertEqual(r.status, -1, "a binary that can't launch reports the sentinel status")
        XCTAssertTrue(r.output.isEmpty)
    }

    func testMergeStderrCapturesErrorOutput() async {
        let r = await ProcessRunner.run(bin: "/bin/sh", args: ["-c", "echo oops 1>&2"],
                                        timeout: 5, mergeStderr: true)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(String(decoding: r.output, as: UTF8.self).contains("oops"),
                      "stderr is captured when merged")
    }
}
