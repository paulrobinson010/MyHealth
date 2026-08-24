import XCTest
@testable import HealthCore

final class DayKeyTests: XCTestCase {

    func testEpochAnchor() {
        let epoch = DayKey(year: 1970, month: 1, day: 1)
        XCTAssertEqual(epoch.ordinal, 0)
        // 1970-01-01 was a Thursday; weekday is Sunday-based.
        XCTAssertEqual(epoch.weekday, 4)
    }

    func testRoundTripsAcrossLeapYears() {
        for (year, month, day) in [(2000, 2, 29), (2024, 2, 29), (1900, 3, 1), (2023, 12, 31), (1969, 7, 20)] {
            let key = DayKey(year: year, month: month, day: day)
            let parts = key.components
            XCTAssertEqual(parts.year, year)
            XCTAssertEqual(parts.month, month)
            XCTAssertEqual(parts.day, day)
        }
    }

    func testDifferenceInDays() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let end = DayKey(year: 2024, month: 3, day: 1)
        XCTAssertEqual(end - start, 60) // 2024 is a leap year
    }

    func testStartOfWeekIsMonday() {
        // 2024-03-17 is a Sunday.
        let sunday = DayKey(year: 2024, month: 3, day: 17)
        XCTAssertEqual(sunday.weekday, 0)
        XCTAssertEqual(sunday.startOfWeek.description, "2024-03-11")

        let monday = DayKey(year: 2024, month: 3, day: 11)
        XCTAssertEqual(monday.startOfWeek, monday)
    }

    func testStartOfMonthAndDescription() {
        let day = DayKey(year: 2019, month: 11, day: 6)
        XCTAssertEqual(day.startOfMonth.description, "2019-11-01")
        XCTAssertEqual(day.description, "2019-11-06")
    }

    func testParsingExportPrefix() {
        XCTAssertEqual(DayKey(exportPrefix: "2023-06-04 07:12:00 +0100")?.description, "2023-06-04")
        XCTAssertEqual(DayKey(exportPrefix: "2023-06-04")?.description, "2023-06-04")
        XCTAssertNil(DayKey(exportPrefix: "not a date"))
        XCTAssertNil(DayKey(exportPrefix: "2023/06/04 07:12:00 +0100"))
        XCTAssertNil(DayKey(exportPrefix: "2023-13-04 07:12:00 +0000"))
    }

    func testTimestampParsingHandlesOffsets() {
        let utc = ExportTimestamp.epochSeconds("2024-03-17 12:00:00 +0000")
        XCTAssertEqual(utc, 1_710_676_800, accuracy: 0.5)

        // The same wall clock an hour east is an hour earlier in absolute terms.
        let plusOne = ExportTimestamp.epochSeconds("2024-03-17 12:00:00 +0100")
        XCTAssertEqual(plusOne! - utc!, -3600, accuracy: 0.5)

        let minusFive = ExportTimestamp.epochSeconds("2024-03-17 12:00:00 -0500")
        XCTAssertEqual(minusFive! - utc!, 18_000, accuracy: 0.5)

        XCTAssertNil(ExportTimestamp.epochSeconds("garbage"))
    }

    func testTimestampWithoutOffsetStillParses() {
        XCTAssertNotNil(ExportTimestamp.epochSeconds("2024-03-17 12:00:00"))
    }
}
