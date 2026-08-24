import Foundation
import HealthCore
import HealthCore

public enum Format {

    public static func metric(_ value: Double?, _ metric: Metric, includeUnit: Bool = true) -> String {
        guard let value, value.isFinite else { return "—" }
        let number = decimal(value, fractionDigits: metric.fractionDigits)
        guard includeUnit else { return number }
        switch metric.unit {
        case "count": return number
        case "%": return number + "%"
        default: return "\(number) \(metric.unit)"
        }
    }

    public static func decimal(_ value: Double, fractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }

    /// "+12%" / "−4%", with the typographic minus so columns line up.
    public static func percentChange(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        let percent = fraction * 100
        let magnitude = abs(percent) >= 10 ? decimal(abs(percent), fractionDigits: 0)
                                           : decimal(abs(percent), fractionDigits: 1)
        if abs(percent) < 0.05 { return "0%" }
        return (percent > 0 ? "+" : "−") + magnitude + "%"
    }

    public static func signed(_ value: Double?, fractionDigits: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        if abs(value) < 0.05 { return "0" }
        return (value > 0 ? "+" : "−") + decimal(abs(value), fractionDigits: fractionDigits)
    }

    /// "2", "1.5", "¼" — servings read badly as raw decimals.
    public static func servings(_ value: Double) -> String {
        if abs(value - value.rounded()) < 0.01 { return decimal(value.rounded(), fractionDigits: 0) }
        return decimal(value, fractionDigits: 1)
    }

    public static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let hours = total / 60
        let remainder = total % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    public static func day(_ day: DayKey, style: DateFormatter.Style = .medium) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter.string(from: day.localDate())
    }

    public static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func percentile(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))th percentile"
    }
}
