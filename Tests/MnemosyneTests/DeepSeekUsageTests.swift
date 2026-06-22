import XCTest
@testable import Mnemosyne

final class DeepSeekUsageTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParsesCacheCounters() {
        let body = data("""
        {"choices":[],"usage":{"prompt_tokens":2048,"completion_tokens":120,"prompt_cache_hit_tokens":1920,"prompt_cache_miss_tokens":128}}
        """)
        let u = DeepSeekUsage.parse(from: body)
        XCTAssertEqual(u?.promptTokens, 2048)
        XCTAssertEqual(u?.cacheHitTokens, 1920)
        XCTAssertEqual(u?.cacheMissTokens, 128)
        XCTAssertEqual(u?.cacheHitRate ?? 0, 1920.0 / 2048.0, accuracy: 1e-9)
    }

    func testCacheNoteFormatsWithThousands() {
        let u = DeepSeekUsage.Usage(promptTokens: 2048, completionTokens: 0,
                                    cacheHitTokens: 1920, cacheMissTokens: 128)
        XCTAssertEqual(DeepSeekUsage.cacheNote(u), "Cache: 1,920/2,048 prompt tokens hit (94%)")
    }

    func testNoCacheHitsGivesNilNote() {
        let u = DeepSeekUsage.Usage(promptTokens: 500, completionTokens: 10,
                                    cacheHitTokens: 0, cacheMissTokens: 500)
        XCTAssertNil(u.cacheHitRate.flatMap { _ in DeepSeekUsage.cacheNote(u) })
        XCTAssertNil(DeepSeekUsage.cacheNote(u))
    }

    func testMissingUsageOrMalformedIsNil() {
        XCTAssertNil(DeepSeekUsage.parse(from: data(#"{"choices":[]}"#)))
        XCTAssertNil(DeepSeekUsage.parse(from: data("not json")))
        // usage present but no cache fields → parses with zeros, note is nil.
        let u = DeepSeekUsage.parse(from: data(#"{"usage":{"prompt_tokens":10,"completion_tokens":5}}"#))
        XCTAssertEqual(u?.cacheHitTokens, 0)
        XCTAssertNil(u.flatMap(DeepSeekUsage.cacheNote))
    }
}
