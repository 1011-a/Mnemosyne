import XCTest
@testable import Mnemosyne

final class HashtagExtractorTests: XCTestCase {

    func testCountsHashtagsCaseInsensitivelyAndMentions() {
        let r = HashtagExtractor.extract("Loving #SwiftUI and #swiftui with @alice today!")
        XCTAssertEqual(r.hashtags.first?.name, "swiftui")
        XCTAssertEqual(r.hashtags.first?.count, 2)         // #SwiftUI + #swiftui
        XCTAssertEqual(r.mentions.first?.name, "alice")
        XCTAssertEqual(r.mentions.first?.count, 1)
    }

    func testIgnoresEmailsAndHeadings() {
        // @ inside an email follows a letter; # in a heading is followed by a space.
        let r = HashtagExtractor.extract("# Heading here\nContact a@b.com for info")
        XCTAssertTrue(r.hashtags.isEmpty, "\(r.hashtags)")
        XCTAssertTrue(r.mentions.isEmpty, "\(r.mentions)")
    }

    func testSummaryListsBothSectionsAndEmptyIsNil() {
        let s = HashtagExtractor.summary("Plan #q3 #q3 review with @sam and @sam")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("Hashtags: #q3 (2)"), s ?? "")
        XCTAssertTrue(s!.contains("Mentions: @sam (2)"), s ?? "")
        XCTAssertNil(HashtagExtractor.summary("no tags or mentions here"))
        XCTAssertNil(HashtagExtractor.summary(""))
    }

    func testHashtagAtStartOfLineIsCounted() {
        let r = HashtagExtractor.extract("#todo finish the report")
        XCTAssertEqual(r.hashtags.first?.name, "todo")
    }
}
