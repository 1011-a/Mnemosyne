import XCTest
@testable import Mnemosyne

final class OllamaClientTests: XCTestCase {

    func testDecodesTagNamesFromNameAndModelFields() throws {
        let json = """
        {
          "models": [
            { "name": "gemma3:12b", "model": "gemma3:12b" },
            { "name": "llava:latest", "model": "llava:latest" }
          ]
        }
        """
        let names = try OllamaClient.modelNames(fromTagsData: Data(json.utf8))
        XCTAssertEqual(names, ["gemma3:12b", "llava:latest"])
    }

    func testModelMatchingRequiresConfiguredTag() {
        XCTAssertTrue(OllamaClient.hasModel("gemma3:12b", in: ["gemma3:12b"]))
        XCTAssertTrue(OllamaClient.hasModel("gemma3", in: ["gemma3:latest"]))
        XCTAssertFalse(OllamaClient.hasModel("gemma3:12b", in: ["gemma3:4b", "llava:latest"]))
    }

    func testOllamaStatusMessagesExplainSetup() {
        let status = OllamaStatus.modelMissing(installed: ["llava:latest"])
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.isReachable)
        XCTAssertTrue(status.label(model: "gemma3:12b").contains("missing"))
        XCTAssertTrue(status.detail(model: "gemma3:12b",
                                    baseURL: URL(string: "http://127.0.0.1:11434")!)
            .contains("ollama pull gemma3:12b"))
    }
}
