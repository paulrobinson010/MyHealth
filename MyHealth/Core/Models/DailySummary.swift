import Foundation

/// One calendar day of health data, already de-duplicated and unit-normalised.
///
/// MyHealth deliberately keeps daily rollups rather than raw samples: a decade
/// of Health data is tens of millions of samples but only a few thousand days,
/// which is what every screen in the app actually plots.
public struct DailySummary: Codable, Hashable, Sendable {
    public var day: DayKey
    public var values: [Metric: Double]

    public init(day: DayKey, values: [Metric: Double] = [:]) {
        self.day = day
        self.values = values
    }

    public subscript(metric: Metric) -> Double? {
        get { values[metric] }
        set { values[metric] = newValue }
    }

    /// True if the day carries any evidence the person was wearing a device.
    public var hasActivityData: Bool {
        for metric in [Metric.steps, .activeEnergy, .exerciseMinutes, .walkingRunningDistance] {
            if let v = values[metric], v > 0 { return true }
        }
        return false
    }
}

/// A single completed workout.
public struct WorkoutSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(day.ordinal)-\(Int(start))-\(activity.rawValue)" }

    public var day: DayKey
    /// Epoch seconds.
    public var start: Double
    public var durationMinutes: Double
    public var energyKcal: Double?
    public var distanceKm: Double?
    public var averageHeartRate: Double?
    public var maxHeartRate: Double?
    public var activity: WorkoutActivity
    public var sourceName: String

    public init(day: DayKey, start: Double, durationMinutes: Double, energyKcal: Double? = nil,
                distanceKm: Double? = nil, averageHeartRate: Double? = nil,
                maxHeartRate: Double? = nil, activity: WorkoutActivity, sourceName: String) {
        self.day = day
        self.start = start
        self.durationMinutes = durationMinutes
        self.energyKcal = energyKcal
        self.distanceKm = distanceKm
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.activity = activity
        self.sourceName = sourceName
    }

    public var startDate: Date { Date(timeIntervalSince1970: start) }

    /// Pace in minutes per kilometre, for distance-based activities.
    public var paceMinutesPerKm: Double? {
        guard let distanceKm, distanceKm > 0.05 else { return nil }
        return durationMinutes / distanceKm
    }
}

/// Apple's workout activity types, collapsed to the ones worth naming plus a
/// catch-all that keeps the raw identifier so nothing is silently lost.
public struct WorkoutActivity: Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(identifier: String) {
        let prefix = "HKWorkoutActivityType"
        self.rawValue = identifier.hasPrefix(prefix)
            ? String(identifier.dropFirst(prefix.count))
            : identifier
    }

    public init(rawValue: String) { self.rawValue = rawValue }

    /// "TraditionalStrengthTraining" -> "Traditional Strength Training"
    public var title: String {
        switch rawValue {
        case "HighIntensityIntervalTraining": return "HIIT"
        case "FunctionalStrengthTraining": return "Functional Strength"
        case "TraditionalStrengthTraining": return "Strength Training"
        case "MindAndBody": return "Mind & Body"
        case "PreparationAndRecovery": return "Prep & Recovery"
        case "CrossTraining": return "Cross Training"
        case "": return "Workout"
        default:
            var out = ""
            for (index, ch) in rawValue.enumerated() {
                if index > 0, ch.isUppercase, !out.hasSuffix(" ") { out.append(" ") }
                out.append(ch)
            }
            return out
        }
    }

    public var isDistanceBased: Bool {
        ["Running", "Walking", "Cycling", "Hiking", "Swimming", "Rowing",
         "CrossCountrySkiing", "DownhillSkiing", "Elliptical", "Wheelchair"].contains(rawValue)
    }

    public static func < (lhs: WorkoutActivity, rhs: WorkoutActivity) -> Bool {
        lhs.title < rhs.title
    }
}

/// The `<Me>` element of the export: what Health knows about the person.
public struct UserProfile: Codable, Hashable, Sendable {
    public var dateOfBirth: DayKey?
    public var biologicalSex: BiologicalSex
    public var heightCm: Double?

    public init(dateOfBirth: DayKey? = nil, biologicalSex: BiologicalSex = .unknown, heightCm: Double? = nil) {
        self.dateOfBirth = dateOfBirth
        self.biologicalSex = biologicalSex
        self.heightCm = heightCm
    }

    /// Age on a given day, used by the age-adjusted fitness reference ranges.
    public func age(on day: DayKey) -> Int? {
        guard let dateOfBirth else { return nil }
        let born = dateOfBirth.components
        let now = day.components
        var age = now.year - born.year
        if (now.month, now.day) < (born.month, born.day) { age -= 1 }
        return age >= 0 && age < 130 ? age : nil
    }
}

public enum BiologicalSex: String, Codable, Sendable {
    case male, female, other, unknown

    public init(healthKitValue: String) {
        switch healthKitValue {
        case "HKBiologicalSexMale": self = .male
        case "HKBiologicalSexFemale": self = .female
        case "HKBiologicalSexOther": self = .other
        default: self = .unknown
        }
    }
}
