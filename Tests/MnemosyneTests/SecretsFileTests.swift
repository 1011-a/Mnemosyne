import XCTest
@testable import Mnemosyne

final class SecretsFileTests: XCTestCase {

    private func temp() -> (SecretsFile, String) {
        let path = NSTemporaryDirectory() + "sec-\(UUID().uuidString)/secrets.json"
        return (SecretsFile(path: path), path)
    }

    func testWriteReadRoundTrip() {
        let (s, path) = temp()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        XCTAssertNil(s.read("k"), "absent ⇒ nil")
        XCTAssertTrue(s.write("k", "  value  "))
        XCTAssertEqual(s.read("k"), "value", "trimmed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testMultipleKeysAndRemoval() {
        let (s, path) = temp()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        s.write("a", "1"); s.write("b", "2")
        XCTAssertEqual(s.read("a"), "1")
        XCTAssertEqual(s.read("b"), "2")
        s.write("a", "")                      // empty clears the key
        XCTAssertNil(s.read("a"))
        XCTAssertEqual(s.read("b"), "2", "other keys untouched")
    }

    func testFileIsUserOnlyReadable() {
        let (s, path) = temp()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        s.write("k", "secret")
        let perms = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        XCTAssertEqual(perms, 0o600, "secrets file is chmod 600")
    }
}
