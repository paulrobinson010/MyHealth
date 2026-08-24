import Foundation

/// A sparse, day-indexed series of one metric, ascending by day.
public struct TimeSeries: Sendable {
    public struct Point: Hashable, Sendable, Identifiable {
        public var id: Int { day.ordinal }
        public let day: DayKey
        public let value: Double
        public init(day: DayKey, value: Double) {
            self.day = day
            self.value = value
        }
    }

    public let metric: Metric
    public let points: [Point]

    public init(metric: Metric, points: [Point]) {
        self.metric = metric
        self.points = points
    }

    public var isEmpty: Bool { points.isEmpty }
    public var count: Int { points.count }
    public var values: [Double] { points.map(\.value) }
    public var first: Point? { points.first }
    public var last: Point? { points.last }

    public func clipped(to range: ClosedRange<DayKey>) -> TimeSeries {
        TimeSeries(metric: metric, points: points.filter { range.contains($0.day) })
    }

    /// The last `days` days of the series, measured from its final point.
    public func trailing(_ days: Int, endingAt end: DayKey? = nil) -> TimeSeries {
        guard let end = end ?? points.last?.day else { return self }
        let start = end.adding(days: -(days - 1))
        return clipped(to: start...end)
    }

    public var total: Double { points.reduce(0) { $0 + $1.value } }

    public var mean: Double? {
        points.isEmpty ? nil : total / Double(points.count)
    }

    public var minimum: Point? { points.min { $0.value < $1.value } }
    public var maximum: Point? { points.max { $0.value < $1.value } }

    /// Aggregates the way the metric wants to be aggregated: totals for
    /// additive metrics, averages for measurements.
    public var naturalAggregate: Double? {
        guard !points.isEmpty else { return nil }
        switch metric.aggregation {
        case .sum: return total
        case .mean: return mean
        case .minimum: return minimum?.value
        case .maximum: return maximum?.value
        case .latest: return points.last?.value
        }
    }

    /// Centre-anchored trailing rolling mean. Each output point averages the
    /// values present in the preceding `window` days, so gaps in wear do not
    /// punch holes in the smoothed line.
    public func rollingMean(window: Int) -> TimeSeries {
        guard window > 1, !points.isEmpty else { return self }
        var out: [Point] = []
        out.reserveCapacity(points.count)
        var head = 0
        var runningSum = 0.0
        var runningCount = 0
        for (index, point) in points.enumerated() {
            runningSum += point.value
            runningCount += 1
            let cutoff = point.day.ordinal - window + 1
            while head <= index, points[head].day.ordinal < cutoff {
                runningSum -= points[head].value
                runningCount -= 1
                head += 1
            }
            if runningCount > 0 {
                out.append(Point(day: point.day, value: runningSum / Double(runningCount)))
            }
        }
        return TimeSeries(metric: metric, points: out)
    }

    /// Trailing rolling sum, used for "exercise minutes in the last 7 days".
    public func rollingSum(window: Int) -> TimeSeries {
        guard window > 1, !points.isEmpty else { return self }
        var out: [Point] = []
        out.reserveCapacity(points.count)
        var head = 0
        var runningSum = 0.0
        for (index, point) in points.enumerated() {
            runningSum += point.value
            let cutoff = point.day.ordinal - window + 1
            while head <= index, points[head].day.ordinal < cutoff {
                runningSum -= points[head].value
                head += 1
            }
            out.append(Point(day: point.day, value: runningSum))
        }
        return TimeSeries(metric: metric, points: out)
    }

    // MARK: - Bucketing

    public enum Bucket: String, CaseIterable, Sendable {
        case day, week, month, quarter, year

        public var title: String { rawValue.capitalized }

        func key(for day: DayKey) -> DayKey {
            switch self {
            case .day: return day
            case .week: return day.startOfWeek
            case .month: return day.startOfMonth
            case .quarter:
                let c = day.components
                let firstMonth = ((c.month - 1) / 3) * 3 + 1
                return DayKey(year: c.year, month: firstMonth, day: 1)
            case .year:
                return DayKey(year: day.components.year, month: 1, day: 1)
            }
        }

        public func label(for day: DayKey) -> String {
            let c = day.components
            let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            switch self {
            case .day: return "\(monthNames[c.month - 1]) \(c.day), \(c.year)"
            case .week: return "Week of \(monthNames[c.month - 1]) \(c.day), \(c.year)"
            case .month: return "\(monthNames[c.month - 1]) \(c.year)"
            case .quarter: return "Q\((c.month - 1) / 3 + 1) \(c.year)"
            case .year: return "\(c.year)"
            }
        }
    }

    public struct BucketedValue: Identifiable, Sendable {
        public var id: Int { start.ordinal }
        public let start: DayKey
        public let value: Double
        /// Number of days in the bucket that carried a sample.
        public let sampleDays: Int
        public let label: String
    }

    /// Groups the series into calendar buckets. `forceAverage` reports a daily
    /// average even for additive metrics, which is what makes a partial current
    /// month comparable with completed ones.
    public func bucketed(by bucket: Bucket, forceAverage: Bool = false) -> [BucketedValue] {
        guard !points.isEmpty else { return [] }
        var order: [Int] = []
        var groups: [Int: (start: DayKey, values: [Double])] = [:]
        for point in points {
            let key = bucket.key(for: point.day)
            if groups[key.ordinal] == nil {
                groups[key.ordinal] = (key, [])
                order.append(key.ordinal)
            }
            groups[key.ordinal]?.values.append(point.value)
        }
        return order.compactMap { ordinal in
            guard let group = groups[ordinal], !group.values.isEmpty else { return nil }
            let value: Double
            if metric.aggregation == .sum && !forceAverage {
                value = group.values.reduce(0, +)
            } else if metric.aggregation == .minimum {
                value = group.values.min() ?? 0
            } else if metric.aggregation == .maximum {
                value = group.values.max() ?? 0
            } else if metric.aggregation == .latest {
                value = group.values.last ?? 0
            } else {
                value = group.values.reduce(0, +) / Double(group.values.count)
            }
            return BucketedValue(start: group.start,
                                 value: value,
                                 sampleDays: group.values.count,
                                 label: bucket.label(for: group.start))
        }
    }

    // MARK: - Statistics

    /// Ordinary least squares fit of value against day ordinal.
    public struct Regression: Sendable {
        /// Change in the metric's unit per day.
        public let slopePerDay: Double
        public let intercept: Double
        /// Coefficient of determination, 0...1.
        public let rSquared: Double
        public let count: Int

        public var slopePerWeek: Double { slopePerDay * 7 }
        public var slopePerMonth: Double { slopePerDay * 30.436_875 }
        public var slopePerYear: Double { slopePerDay * 365.2425 }

        public func value(at day: DayKey) -> Double {
            intercept + slopePerDay * Double(day.ordinal)
        }

        /// A fit this loose is noise, not a trend, and the UI says so.
        public var isMeaningful: Bool { count >= 8 && rSquared >= 0.06 }
    }

    public func regression() -> Regression? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        // Re-base x on the first ordinal to keep the sums well conditioned.
        let base = Double(points[0].day.ordinal)
        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0, sumYY = 0.0
        for point in points {
            let x = Double(point.day.ordinal) - base
            let y = point.value
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x; sumYY += y * y
        }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n

        let residualDenominator = (n * sumYY - sumY * sumY) * denominator
        let rSquared: Double
        if residualDenominator > 1e-9 {
            let r = (n * sumXY - sumX * sumY) / residualDenominator.squareRoot()
            rSquared = min(1, max(0, r * r))
        } else {
            rSquared = 0
        }
        // Shift the intercept back into absolute ordinal space.
        return Regression(slopePerDay: slope,
                          intercept: intercept - slope * base,
                          rSquared: rSquared,
                          count: points.count)
    }

    /// Percentile of `value` within the series, 0...1.
    public func percentile(of value: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        let below = points.reduce(0) { $0 + ($1.value < value ? 1 : 0) }
        let equal = points.reduce(0) { $0 + ($1.value == value ? 1 : 0) }
        return (Double(below) + Double(equal) / 2) / Double(points.count)
    }

    public func quantile(_ q: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let position = q.clamped(to: 0...1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
