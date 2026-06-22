import XCTest
@testable import Mnemosyne

final class SamplingPresetTests: XCTestCase {

    func testTemperatureTableMatchesDeepSeekDocs() {
        XCTAssertEqual(SamplingPreset.temperature(for: .codingMath), 0.0)
        XCTAssertEqual(SamplingPreset.temperature(for: .dataAnalysis), 1.0)
        XCTAssertEqual(SamplingPreset.temperature(for: .conversation), 1.3)
        XCTAssertEqual(SamplingPreset.temperature(for: .translation), 1.3)
        XCTAssertEqual(SamplingPreset.temperature(for: .creative), 1.5)
    }

    func testClassifyRoutesByIntent() {
        XCTAssertEqual(SamplingPreset.classify("Translate this to French"), .translation)
        XCTAssertEqual(SamplingPreset.classify("Write a poem about the sea"), .creative)
        XCTAssertEqual(SamplingPreset.classify("Fix this bug in my swift function"), .codingMath)
        XCTAssertEqual(SamplingPreset.classify("Calculate the probability of two sixes"), .codingMath)
        XCTAssertEqual(SamplingPreset.classify("Analyze this csv dataset"), .dataAnalysis)
        XCTAssertEqual(SamplingPreset.classify("What's your favorite color?"), .conversation)
    }

    func testTemperatureForQueryComposes() {
        XCTAssertEqual(SamplingPreset.temperature(forQuery: "translate to German"), 1.3)
        XCTAssertEqual(SamplingPreset.temperature(forQuery: "debug this regex"), 0.0)
    }
}
