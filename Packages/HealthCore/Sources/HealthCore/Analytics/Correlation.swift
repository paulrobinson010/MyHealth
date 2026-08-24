import Foundation

/// Pairwise relationship between two metrics measured over the same days.
public struct Correlation: Sendable, Identifiable {
    public var id: String { "\(x.rawValue)-\(y.rawValue)-\(lagDays)" }

    public let x: Metric
    public let y: Metric
    /// Days `y` is shifted forward relative to `x`. A lag of 1 asks "what does
    /// today's drinking do to tomorrow's recovery".
    public let lagDays: Int
    /// Pearson correlation coefficient, −1...1.
    public let r: Double
    /// Number of day pairs behind it.
    public let count: Int
    /// Slope of y on x, in y's units per one unit of x.
    public let slope: Double
    public let intercept: Double
    /// Two-tailed p-value from the Fisher z transform.
    public let pValue: Double

    public var rSquared: Double { r * r }

    /// A correlation this weak, or resting on this few days, is not worth
    /// showing anyone.
    public var isNoteworthy: Bool { count >= 20 && abs(r) >= 0.2 && pValue < 0.05 }

    public var strength: String {
        switch abs(r) {
        case ..<0.2: return "negligible"
        case 0.2..<0.4: return "weak"
        case 0.4..<0.6: return "moderate"
        case 0.6..<0.8: return "strong"
        default: return "very strong"
        }
    }

    public var direction: String { r >= 0 ? "rises with" : "falls as" }

    /// Predicted change in `y` for a given change in `x`.
    public func effect(ofChangeIn deltaX: Double) -> Double { slope * deltaX }
}

public enum CorrelationAnalysis {

    /// Correlates two metrics day-by-day, optionally shifting `y` later by
    /// `lagDays`. Only days where both are present contribute.
    public static func correlate(_ x: Metric,
                                 with y: Metric,
                                 in database: HealthDatabase,
                                 lagDays: Int = 0,
                                 range: ClosedRange<DayKey>? = nil,
                                 minimumPairs: Int = 10) -> Correlation? {
        var yByOrdinal: [Int: Double] = [:]
        for summary in database.days {
            if let value = summary.values[y] { yByOrdinal[summary.day.ordinal] = value }
        }

        var xs: [Double] = []
        var ys: [Double] = []
        for summary in database.days {
            if let range, !range.contains(summary.day) { continue }
            guard let xValue = summary.values[x] else { continue }
            guard let yValue = yByOrdinal[summary.day.ordinal + lagDays] else { continue }
            xs.append(xValue)
            ys.append(yValue)
        }

        guard xs.count >= minimumPairs else { return nil }
        guard let stats = pearson(xs, ys) else { return nil }

        return Correlation(x: x, y: y, lagDays: lagDays,
                           r: stats.r, count: xs.count,
                           slope: stats.slope, intercept: stats.intercept,
                           pValue: stats.p)
    }

    /// Runs one metric against many and returns whatever survives the
    /// noteworthiness bar, strongest first.
    public static func strongestRelationships(for metric: Metric,
                                              in database: HealthDatabase,
                                              candidates: [Metric]? = nil,
                                              lags: [Int] = [0],
                                              limit: Int = 8) -> [Correlation] {
        let pool = (candidates ?? database.availableMetrics(minimumDays: 20))
            .filter { $0 != metric }
        var results: [Correlation] = []
        for candidate in pool {
            for lag in lags {
                if let correlation = correlate(metric, with: candidate, in: database, lagDays: lag),
                   correlation.isNoteworthy {
                    results.append(correlation)
                }
            }
        }
        return results
            .sorted { abs($0.r) > abs($1.r) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Maths

    struct PearsonResult {
        let r: Double
        let slope: Double
        let intercept: Double
        let p: Double
    }

    static func pearson(_ xs: [Double], _ ys: [Double]) -> PearsonResult? {
        let n = Double(xs.count)
        guard xs.count == ys.count, xs.count >= 3 else { return nil }

        var sumX = 0.0, sumY = 0.0, sumXY = 0.0, sumXX = 0.0, sumYY = 0.0
        for index in 0..<xs.count {
            let x = xs[index], y = ys[index]
            sumX += x; sumY += y; sumXY += x * y; sumXX += x * x; sumYY += y * y
        }

        let covariance = n * sumXY - sumX * sumY
        let varianceX = n * sumXX - sumX * sumX
        let varianceY = n * sumYY - sumY * sumY
        guard varianceX > 1e-9, varianceY > 1e-9 else { return nil }

        let r = (covariance / (varianceX * varianceY).squareRoot()).clamped(to: -1...1)
        let slope = covariance / varianceX
        let intercept = (sumY - slope * sumX) / n
        return PearsonResult(r: r, slope: slope, intercept: intercept, p: pValue(r: r, n: xs.count))
    }

    /// Two-tailed significance via Fisher's z transform, which is accurate
    /// enough here and avoids needing a t-distribution.
    static func pValue(r: Double, n: Int) -> Double {
        guard n > 3 else { return 1 }
        let bounded = r.clamped(to: -0.999_999...0.999_999)
        let z = atanh(bounded) * (Double(n - 3)).squareRoot()
        return (2 * (1 - normalCDF(abs(z)))).clamped(to: 0...1)
    }

    static func normalCDF(_ z: Double) -> Double {
        0.5 * (1 + erf(z / 2.0.squareRoot()))
    }
}
