import XCTest
@testable import Mnemosyne

// NOTE: every "secret" below is a synthetic, well-known-fake placeholder — not a real credential.
final class SecretScannerTests: XCTestCase {

    func testDetectsAwsKeyAndMasksIt() {
        let findings = SecretScanner.scan("key = AKIAIOSFODNN7EXAMPLE here")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].type, "AWS access key")
        XCTAssertEqual(findings[0].masked, "AKIA****")     // value not revealed
        XCTAssertFalse(findings[0].masked.contains("IOSFODNN"))
    }

    func testDetectsGithubTokenAndGenericAssignment() {
        let gh = SecretScanner.scan("token: ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertTrue(gh.contains { $0.type == "GitHub token" }, "\(gh)")

        let generic = SecretScanner.scan(#"password = "hunter2hunter2hunter2""#)
        XCTAssertTrue(generic.contains { $0.type == "generic secret" }, "\(generic)")
    }

    func testDetectsPrivateKeyHeaderWithLabel() {
        let f = SecretScanner.scan("-----BEGIN RSA PRIVATE KEY-----")
        XCTAssertEqual(f.first?.type, "private key")
        XCTAssertEqual(f.first?.masked, "<PEM private key header>")
    }

    func testCleanTextYieldsNothingAndReportNil() {
        XCTAssertTrue(SecretScanner.scan("just a normal note about lunch plans").isEmpty)
        XCTAssertNil(SecretScanner.report("nothing secret here"))
        let report = SecretScanner.report("aws=AKIAIOSFODNN7EXAMPLE")
        XCTAssertNotNil(report)
        XCTAssertTrue(report!.contains("1 potential secret"), report ?? "")
    }
}
