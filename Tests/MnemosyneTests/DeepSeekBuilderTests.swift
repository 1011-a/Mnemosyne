import XCTest
@testable import Mnemosyne

final class DeepSeekBuilderTests: XCTestCase {

    func testParsesMultiFileManifest() {
        let json = #"""
        {"files":[
          {"path":"index.html","content":"<!doctype html><html></html>"},
          {"path":"style.css","content":"body{margin:0}"}
        ]}
        """#
        let files = DeepSeekBuilder.parseFiles(json)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "index.html")
        XCTAssertTrue(files[0].content.contains("<!doctype"))
        XCTAssertEqual(files[1].path, "style.css")
    }

    func testParseStripsCodeFencesAndSkipsBadEntries() {
        let fenced = "```json\n{\"files\":[{\"path\":\"a.js\",\"content\":\"x\"},{\"path\":\"\",\"content\":\"y\"},{\"path\":\"b.js\"}]}\n```"
        let files = DeepSeekBuilder.parseFiles(fenced)
        XCTAssertEqual(files.map(\.path), ["a.js"], "blank path and missing content dropped")
    }

    func testParseMalformedReturnsEmpty() {
        XCTAssertTrue(DeepSeekBuilder.parseFiles("not json").isEmpty)
        XCTAssertTrue(DeepSeekBuilder.parseFiles(#"{"nope":1}"#).isEmpty)
    }

    func testSafeRelativePathRejectsTraversalAndAbsolute() {
        XCTAssertEqual(DeepSeekBuilder.safeRelativePath("index.html"), "index.html")
        XCTAssertEqual(DeepSeekBuilder.safeRelativePath("./assets/app.js"), "assets/app.js")
        XCTAssertEqual(DeepSeekBuilder.safeRelativePath("  sub/dir/file.css "), "sub/dir/file.css")
        XCTAssertNil(DeepSeekBuilder.safeRelativePath("/etc/passwd"), "absolute rejected")
        XCTAssertNil(DeepSeekBuilder.safeRelativePath("../outside.txt"), "parent traversal rejected")
        XCTAssertNil(DeepSeekBuilder.safeRelativePath("a/../../b"), "embedded traversal rejected")
        XCTAssertNil(DeepSeekBuilder.safeRelativePath("~/secret"), "home expansion rejected")
        XCTAssertNil(DeepSeekBuilder.safeRelativePath("   "))
    }

    func testSystemPromptRequestsJsonManifestAndRefineMode() {
        let fresh = DeepSeekBuilder.systemPrompt(refining: false)
        XCTAssertTrue(fresh.contains("\"files\""), "asks for the files manifest")
        XCTAssertTrue(fresh.lowercased().contains("relative"))
        XCTAssertFalse(fresh.contains("REVISING"))
        XCTAssertTrue(DeepSeekBuilder.systemPrompt(refining: true).contains("REVISING"))
    }

    func testUserPromptIncludesPriorWhenRefining() {
        let prior = [DeepSeekBuilder.BuiltFile(path: "index.html", content: "<old/>")]
        let p = DeepSeekBuilder.userPrompt(task: "a dashboard", context: "ctx", prior: prior)
        XCTAssertTrue(p.contains("a dashboard"))
        XCTAssertTrue(p.contains("=== index.html ==="))
        XCTAssertFalse(DeepSeekBuilder.userPrompt(task: "t", context: "c", prior: nil).contains("previous attempt"))
    }
}
