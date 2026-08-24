import Foundation

/// Direction of travel for a metric, already interpreted against whether
/// higher is good for that metric.
public enum TrendDirection: String, Sendable {
    case improving, declining, steady, unknown

    public var symbolName: String {
        switch self {
        case .improving: return "arrow.up.right"
        case .declining: return "arrow.down.right"
        case .steady: return "arrow.right"
        case .unknown: return "questionmark"
        }
    }
}

/// A metric's behaviour over a window, plus how that window compares with the
/// one before it and with the same window a year earlier.
public struct MetricTrend: Sendable, Identifiable {
    public var id: String { metric.rawValue }

    public let metric: Metric
    public let window: Int
    /// Aggregate over the current window (total or average, per the metric).
    public let current: Double?
    /// Same aggregate over the immediately preceding window.
    public let previous: Double?
    /// Same aggregate over the window one year earlier.
    public let yearAgo: Double?
    public let regression: TimeSeries.Regression?
    public let sampleDays: Int
    public let best: TimeSeries.Point?
    public let worst: TimeSeries.Point?

    /// Fractional change against the previous window, e.g. 0.12 for +12%.
    public var changeVsPrevious: Double? {
        guard let current, let previous, abs(previous) > 1e-9 else { return nil }
        return (current - previous) / abs(previous)
    }

    public var changeVsYearAgo: Double? {
        guard let current, let yearAgo, abs(yearAgo) > 1e-9 else { return nil }
        return (current - yearAgo) / abs(yearAgo)
    }

    /// Absolute change per 30 days implied by the regression line.
    public var monthlyDrift: Double? {
        guard let regression, regression.isMeaningful else { return nil }
        return regression.slopePerMonth
    }

    public var direction: TrendDirection {
        guard let change = changeVsPrevious else { return .unknown }
        // Under 2% either way is noise for every metric we track.
        guard abs(change) >= 0.02 else { return .steady }
        let rising = change > 0
        return rising == metric.higherIsBetter ? .improving : .declining
    }

    public init(metric: Metric, window: Int, current: Double?, previous: Double?,
                yearAgo: Double?, regression: TimeSeries.Regression?, sampleDays: Int,
                best: TimeSeries.Point?, worst: TimeSeries.Point?) {
        self.metric = metric
        self.window = window
        self.current = current
        self.previous = previous
        self.yearAgo = yearAgo
        self.regression = regression
        self.sampleDays = sampleDays
        self.best = best
        self.worst = worst
    }
}

public enum TrendAnalysis {

    /// Builds the trend for one metric ending on `end` (defaults to the last
    /// day the metric has data for, so a stale metric still reports its own
    /// last known state rather than an empty window).
    public static func trend(for metric: Metric,
                             in database: HealthDatabase,
                             window: Int = 28,
                             endingAt end: DayKey? = nil) -> MetricTrend {
        let full = database.series(metric)
        guard let anchor = end ?? full.last?.day else {
            return MetricTrend(metric: metric, window: window, current: nil, previous: nil,
                               yearAgo: nil, regression: nil, sampleDays: 0, best: nil, worst: nil)
        }

        func aggregate(endingAt day: DayKey) -> (value: Double?, days: Int) {
            let slice = full.clipped(to: day.adding(days: -(window - 1))...day)
            return (slice.naturalAggregate, slice.count)
        }

        let currentWindow = aggregate(endingAt: anchor)
        let previousWindow = aggregate(endingAt: anchor.adding(days: -window))
        let yearAgoWindow = aggregate(endingAt: anchor.adding(days: -365))

        let recent = full.clipped(to: anchor.adding(days: -(window - 1))...anchor)
        let bestPoint = metric.higherIsBetter ? full.maximum : full.minimum
        let worstPoint = metric.higherIsBetter ? full.minimum : full.maximum

        return MetricTrend(metric: metric,
                           window: window,
                           current: currentWindow.value,
                           previous: previousWindow.value,
                           yearAgo: yearAgoWindow.value,
                           regression: recent.regression(),
                           sampleDays: currentWindow.days,
                           best: bestPoint,
                           worst: worstPoint)
    }

    public static func trends(for metrics: [Metric],
                              in database: HealthDatabase,
                              window: Int = 28,
                              endingAt end: DayKey? = nil) -> [MetricTrend] {
        metrics.map { trend(for: $0, in: database, window: window, endingAt: end) }
    }

    /// The metrics that moved most over the window, largest relative change
    /// first. Metrics with too little data, or changes small enough to be
    /// noise, are left out.
    public static func topMovers(in database: HealthDatabase,
                                 window: Int = 28,
                                 limit: Int = 6,
                                 endingAt end: DayKey? = nil) -> [MetricTrend] {
        let candidates = database.availableMetrics(minimumDays: window)
        return trends(for: candidates, in: database, window: window, endingAt: end)
            .filter { $0.sampleDays >= max(4, window / 4) }
            .filter { trend in
                guard let change = trend.changeVsPrevious else { return false }
                return abs(change) >= 0.03 && change.isFinite
            }
            .sorted { abs($0.changeVsPrevious ?? 0) > abs($1.changeVsPrevious ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    /// Longest and current run of consecutive days meeting a goal.
    public struct Streak: Sendable {
        public let current: Int
        public let longest: Int
        public let longestEnd: DayKey?
    }

    public static func streak(for metric: Metric,
                              in database: HealthDatabase,
                              atLeast goal: Double,
                              endingAt end: DayKey? = nil) -> Streak {
        let points = database.series(metric).points
        guard !points.isEmpty else { return Streak(current: 0, longest: 0, longestEnd: nil) }

        var longest = 0, running = 0
        var longestEnd: DayKey?
        var previousOrdinal: Int?
        for point in points {
            let contiguous = previousOrdinal.map { point.day.ordinal == $0 + 1 } ?? false
            if point.value >= goal {
                running = contiguous ? running + 1 : 1
                if running > longest {
                    longest = running
                    longestEnd = point.day
                }
            } else {
                running = 0
            }
            previousOrdinal = point.day.ordinal
        }

        // The current streak only counts if it runs up to the anchor day.
        let anchor = end ?? DayKey.today
        let lastDay = points[points.count - 1].day
        let current = (anchor.ordinal - lastDay.ordinal) <= 1 ? running : 0
        return Streak(current: current, longest: longest, longestEnd: longestEnd)
    }

    /// Personal best for a metric over a given bucket, e.g. best week of steps.
    public static func personalBest(for metric: Metric,
                                    in database: HealthDatabase,
                                    bucket: TimeSeries.Bucket) -> TimeSeries.BucketedValue? {
        let buckets = database.series(metric).bucketed(by: bucket)
        guard !buckets.isEmpty else { return nil }
        return metric.higherIsBetter
            ? buckets.max { $0.value < $1.value }
            : buckets.min { $0.value < $1.value }
    }
}
