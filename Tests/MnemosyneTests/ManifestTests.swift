import XCTest
@testable import Mnemosyne

@MainActor
final class ManifestTests: XCTestCase {

    private func vm() throws -> LibraryViewModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Manifest-\(UUID().uuidString)")
        let store = try KnowledgeStore(directory: dir)
        let vm = LibraryViewModel(store: store)
        vm.items = [
            KnowledgeItem(id: "a", path: "/tmp/a.pdf", title: "a.pdf", kind: .pdf,
                          contentHash: "a", byteSize: 123, createdAt: Date(), modifiedAt: Date()),
            KnowledgeItem(id: "b", path: "/tmp/b.md", title: "b.md", kind: .markdown,
                          contentHash: "b", byteSize: 45, createdAt: Date(), modifiedAt: Date())
        ]
        return vm
    }

    func testManifestRoundTripsAllItems() throws {
        let vm = try vm()
        let json = try vm.exportManifestJSON()
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([LibraryViewModel.ManifestEntry].self, from: data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.path)), ["/tmp/a.pdf", "/tmp/b.md"])
        XCTAssertEqual(entries.first(where: { $0.title == "a.pdf" })?.kind, "pdf")
        XCTAssertEqual(entries.first(where: { $0.title == "a.pdf" })?.bytes, 123)
    }

    func testManifestRespectsActiveFilter() throws {
        let vm = try vm()
        vm.toggleKind(.markdown)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([LibraryViewModel.ManifestEntry].self,
                                         from: vm.exportManifestJSON().data(using: .utf8)!)
        XCTAssertEqual(entries.map(\.title), ["b.md"], "export should respect the active kind filter")
    }
}
