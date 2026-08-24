import Foundation

/// A calendar day, stored as a day ordinal relative to 1970-01-01.
///
/// Health export timestamps carry the wall-clock time (and UTC offset) that was
/// in effect on the device when the sample was recorded, so the leading
/// `yyyy-MM-dd` of a timestamp is already the day the Health app files it
/// under. Bucketing on that string means importing never drifts a day because
/// the Mac happens to sit in a different time zone than the phone did.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let ordinal: Int

    public init(ordinal: Int) { self.ordinal = ordinal }

    public init(year: Int, month: Int, day: Int) {
        self.ordinal = DayKey.daysFromCivil(year: year, month: month, day: day)
    }

    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Parses the `yyyy-MM-dd` prefix of a Health export timestamp.
    /// Returns nil for anything that is not 10+ ASCII characters in that shape.
    public init?(exportPrefix s: String) {
        var year = 0, month = 0, day = 0, index = 0
        for byte in s.utf8 {
            switch index {
            case 0...3:
                guard byte >= 48, byte <= 57 else { return nil }
                year = year * 10 + Int(byte - 48)
            case 4, 7:
                guard byte == 45 else { return nil } // "-"
            case 5, 6:
                guard byte >= 48, byte <= 57 else { return nil }
                month = month * 10 + Int(byte - 48)
            case 8, 9:
                guard byte >= 48, byte <= 57 else { return nil }
                day = day * 10 + Int(byte - 48)
            default:
                break
            }
            index += 1
            if index == 10 { break }
        }
        guard index == 10, month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var components: (year: Int, month: Int, day: Int) {
        DayKey.civilFromDays(ordinal)
    }

    public var year: Int { components.year }
    public var month: Int { components.month }
    public var day: Int { components.day }

    /// 0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday.
    public var weekday: Int { ((ordinal % 7) + 11) % 7 }

    /// The Monday on or before this day, used as the canonical week bucket.
    public var startOfWeek: DayKey {
        let offset = (weekday + 6) % 7 // Monday == 0
        return DayKey(ordinal: ordinal - offset)
    }

    public var startOfMonth: DayKey {
        let c = components
        return DayKey(year: c.year, month: c.month, day: 1)
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ordinal) * 86_400)
    }

    /// Midnight local time on this day, for chart axes that expect real dates.
    public func localDate(calendar: Calendar = .current) -> Date {
        let c = components
        var dc = DateComponents()
        dc.year = c.year; dc.month = c.month; dc.day = c.day
        return calendar.date(from: dc) ?? date
    }

    public func adding(days: Int) -> DayKey { DayKey(ordinal: ordinal + days) }

    public static func - (lhs: DayKey, rhs: DayKey) -> Int { lhs.ordinal - rhs.ordinal }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool { lhs.ordinal < rhs.ordinal }

    public static var today: DayKey { DayKey(date: Date()) }

    public var description: String {
        let c = components
        let m = c.month < 10 ? "0\(c.month)" : "\(c.month)"
        let d = c.day < 10 ? "0\(c.day)" : "\(c.day)"
        return "\(c.year)-\(m)-\(d)"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ordinal)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.ordinal = try container.decode(Int.self)
    }

    // MARK: - Civil calendar arithmetic (Howard Hinnant's algorithms)

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                        // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ ordinal: Int) -> (year: Int, month: Int, day: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}

/// Parses Health export timestamps (`2024-03-17 07:41:22 +0000`) into epoch
/// seconds without touching DateFormatter, which is far too slow to run over
/// the millions of samples in a multi-year export.
public enum ExportTimestamp {
    public static func epochSeconds(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }

        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2)
        else { return nil }

        let days = DayKey.daysFromCivil(year: year, month: month, day: day)
        var seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)

        // Optional " +HHMM" / " -HHMM" trailer.
        if b.count >= 25, b[19] == 32, b[20] == 43 || b[20] == 45 {
            if let oh = digits(21, 2), let om = digits(23, 2) {
                let offset = Double(oh * 3600 + om * 60)
                seconds += b[20] == 43 ? -offset : offset
            }
        }
        return seconds
    }
}
