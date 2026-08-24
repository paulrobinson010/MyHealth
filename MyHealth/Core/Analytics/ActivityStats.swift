import Foundation

/// Derived views over activity data that the Activity and Workouts screens
/// need but that are not simple time series.
public enum ActivityStats {

    /// One cell of the year-in-review calendar heatmap.
    public struct HeatmapCell: Identifiable, Sendable {
        public var id: Int { day.ordinal }
        public let day: DayKey
        public let value: Double?
        /// 0...1 against the chosen upper bound, nil when there is no data.
        public let intensity: Double?
    }

    /// Builds a day-by-day grid for `metric`, capped at the 95th percentile so
    /// one enormous outlier day does not flatten the rest of the year.
    public static func heatmap(for metric: Metric,
                               in database: HealthDatabase,
                               range: ClosedRange<DayKey>) -> [HeatmapCell] {
        let series = database.series(metric, in: range)
        let upperBound = series.quantile(0.95) ?? series.maximum?.value ?? 1
        var byOrdinal: [Int: Double] = [:]
        for point in series.points { byOrdinal[point.day.ordinal] = point.value }

        return (range.lowerBound.ordinal...range.upperBound.ordinal).map { ordinal in
            let day = DayKey(ordinal: ordinal)
            guard let value = byOrdinal[ordinal] else {
                return HeatmapCell(day: day, value: nil, intensity: nil)
            }
            let intensity = upperBound > 0 ? (value / upperBound).clamped(to: 0...1) : 0
            return HeatmapCell(day: day, value: value, intensity: intensity)
        }
    }

    /// Average value per day of the week — the "you never train on Fridays" view.
    public struct WeekdayProfile: Identifiable, Sendable {
        public var id: Int { weekday }
        /// 0 = Monday ... 6 = Sunday, which is how the chart reads left to right.
        public let weekday: Int
        public let average: Double
        public let sampleDays: Int

        public var name: String {
            ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][weekday]
        }
    }

    public static func weekdayProfile(for metric: Metric,
                                      in database: HealthDatabase,
                                      range: ClosedRange<DayKey>? = nil) -> [WeekdayProfile] {
        var totals = [Double](repeating: 0, count: 7)
        var counts = [Int](repeating: 0, count: 7)
        for point in database.series(metric, in: range).points {
            let index = (point.day.weekday + 6) % 7 // Sunday-first -> Monday-first
            totals[index] += point.value
            counts[index] += 1
        }
        return (0..<7).map { index in
            WeekdayProfile(weekday: index,
                           average: counts[index] > 0 ? totals[index] / Double(counts[index]) : 0,
                           sampleDays: counts[index])
        }
    }

    /// Share of days in a range that met a goal.
    public static func goalAttainment(for metric: Metric,
                                      in database: HealthDatabase,
                                      goal: Double,
                                      range: ClosedRange<DayKey>? = nil) -> (met: Int, total: Int) {
        let points = database.series(metric, in: range).points
        let met = points.reduce(0) { $0 + ($1.value >= goal ? 1 : 0) }
        return (met, points.count)
    }

    /// Everything the Workouts screen groups by activity type.
    public struct WorkoutGroup: Identifiable, Sendable {
        public var id: String { activity.rawValue }
        public let activity: WorkoutActivity
        public let count: Int
        public let totalMinutes: Double
        public let totalEnergy: Double
        public let totalDistance: Double
        public let averageHeartRate: Double?
        public let lastDate: Date?

        public var averageMinutes: Double { count > 0 ? totalMinutes / Double(count) : 0 }
    }

    public static func groupWorkouts(_ workouts: [WorkoutSummary]) -> [WorkoutGroup] {
        var buckets: [String: [WorkoutSummary]] = [:]
        for workout in workouts {
            buckets[workout.activity.rawValue, default: []].append(workout)
        }
        return buckets.values.map { group in
            let heartRates = group.compactMap(\.averageHeartRate)
            return WorkoutGroup(
                activity: group[0].activity,
                count: group.count,
                totalMinutes: group.reduce(0) { $0 + $1.durationMinutes },
                totalEnergy: group.reduce(0) { $0 + ($1.energyKcal ?? 0) },
                totalDistance: group.reduce(0) { $0 + ($1.distanceKm ?? 0) },
                averageHeartRate: heartRates.isEmpty
                    ? nil
                    : heartRates.reduce(0, +) / Double(heartRates.count),
                lastDate: group.map(\.startDate).max()
            )
        }
        .sorted { $0.totalMinutes > $1.totalMinutes }
    }

    /// Monthly workout minutes split by activity, for the stacked area chart.
    public struct MonthlyActivityVolume: Identifiable, Sendable {
        public var id: String { "\(month.ordinal)-\(activity.rawValue)" }
        public let month: DayKey
        public let activity: WorkoutActivity
        public let minutes: Double
    }

    public static func monthlyVolume(_ workouts: [WorkoutSummary],
                                     topActivities: Int = 6) -> [MonthlyActivityVolume] {
        let ranked = groupWorkouts(workouts).prefix(topActivities).map(\.activity.rawValue)
        let keep = Set(ranked)

        var totals: [String: (month: DayKey, activity: WorkoutActivity, minutes: Double)] = [:]
        for workout in workouts {
            let month = workout.day.startOfMonth
            let activity = keep.contains(workout.activity.rawValue)
                ? workout.activity
                : WorkoutActivity(rawValue: "Other")
            let key = "\(month.ordinal)-\(activity.rawValue)"
            var entry = totals[key] ?? (month, activity, 0)
            entry.minutes += workout.durationMinutes
            totals[key] = entry
        }
        return totals.values
            .map { MonthlyActivityVolume(month: $0.month, activity: $0.activity, minutes: $0.minutes) }
            .sorted { ($0.month.ordinal, $0.activity.rawValue) < ($1.month.ordinal, $1.activity.rawValue) }
    }
}
