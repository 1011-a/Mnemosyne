import XCTest
@testable import Mnemosyne

final class ICalTests: XCTestCase {

    func testParsesEventFields() {
        let text = ICalExtractor.parse("""
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        SUMMARY:Dentist appointment
        DTSTART:20260615T140000Z
        DTEND:20260615T150000Z
        LOCATION:123 Main St
        ORGANIZER:MAILTO:office@dental.com
        DESCRIPTION:Routine cleaning
        END:VEVENT
        END:VCALENDAR
        """)
        XCTAssertTrue(text.contains("Dentist appointment"))
        XCTAssertTrue(text.contains("Jun 15, 2026, 14:00"))
        XCTAssertTrue(text.contains("Jun 15, 2026, 15:00"))
        XCTAssertTrue(text.contains("at 123 Main St"))
        XCTAssertTrue(text.contains("office@dental.com"))
        XCTAssertTrue(text.contains("Routine cleaning"))
    }

    func testAllDayDateHasNoTime() {
        XCTAssertEqual(ICalExtractor.formatDate("20260704"), "Jul 4, 2026")
        XCTAssertEqual(ICalExtractor.formatDate("20260704T090000Z"), "Jul 4, 2026, 09:00")
    }

    func testDateWithTZIDParam() {
        // DTSTART can carry params before the colon — name parsing must drop them.
        let text = ICalExtractor.parse("""
        BEGIN:VEVENT
        SUMMARY:Standup
        DTSTART;TZID=America/New_York:20260301T093000
        END:VEVENT
        """)
        XCTAssertTrue(text.contains("Standup"))
        XCTAssertTrue(text.contains("Mar 1, 2026, 09:30"), "got: \(text)")
    }

    func testMultipleEventsSeparated() {
        let text = ICalExtractor.parse("""
        BEGIN:VEVENT
        SUMMARY:Event One
        END:VEVENT
        BEGIN:VEVENT
        SUMMARY:Event Two
        END:VEVENT
        """)
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(text.contains("Event One") && text.contains("Event Two"))
    }

    func testFoldingAndEscaping() {
        // RFC 5545 unfolding rejoins with no inserted space, so fold mid-word.
        let text = ICalExtractor.parse("""
        BEGIN:VEVENT
        SUMMARY:Quarterly plan
        DESCRIPTION:Discuss roadmap\\, budget and hir
         ing
        END:VEVENT
        """)
        XCTAssertTrue(text.contains("Discuss roadmap, budget and hiring"), "got: \(text)")
    }

    func testNonICalYieldsEmpty() {
        XCTAssertTrue(ICalExtractor.parse("not a calendar").isEmpty)
    }

    func testTypeDetectorMapsICalToEvent() {
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/meeting.ics")), .event)
        XCTAssertEqual(TypeDetector.kind(for: URL(fileURLWithPath: "/tmp/cal.ical")), .event)
    }
}
