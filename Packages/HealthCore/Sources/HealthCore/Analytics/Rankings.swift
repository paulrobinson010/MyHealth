import Foundation

/// A period (month, quarter, year) ranked against every other period in your
/// history by average fitness index — the "how does now compare with then"
/// view of the data.
public struct RankedPeriod: Sendable, Identifiable, Hashable {
    public var id: Int { start.ordinal }
    public let start: DayKey
    public let label: String
    public let averageScore: Double
    public let bestScore: Double
    public let days: Int
    /// 1 = your best period on record.
    public let rank: Int
    public let totalPeriods: Int
    /// Change in average score against the immediately preceding period.
    public let changeFromPrevious: Double?

    public var band: FitnessBand { FitnessBand(score: averageScore) }

    /// 0...1, where 1 is your best period ever.
    public var percentile: Double {
        guard totalPeriods > 1 else { return 1 }
        return Double(totalPeriods - rank) / Double(totalPeriods - 1)
    }
}

/// Where today sits against your own history.
public struct FitnessStanding: Sendable {
    public let current: FitnessScore
    /// Percentile of the current score against every score on record, 0...1.
    public let percentileAllTime: Double
    /// Percentile against the last 365 days only.
    public let percentileLastYear: Double
    public let allTimeBest: FitnessScore?
    public let allTimeWorst: FitnessScore?
    /// Days since the index was last at or above its current level.
    public let daysSinceHigher: Int?
    public let changeVs30Days: Double?
    public let changeVs90Days: Double?
    public let changeVs365Days: Double?
}

public enum Rankings {

    public static func rankedPeriods(from scores: [FitnessScore],
                                     bucket: TimeSeries.Bucket = .month,
                                     minimumDays: Int = 7) -> [RankedPeriod] {
        guard !scores.isEmpty else { return [] }

        var order: [Int] = []
        var groups: [Int: (start: DayKey, values: [Double])] = [:]
        for score in scores {
            let key = bucket.key(for: score.day)
            if groups[key.ordinal] == nil {
                groups[key.ordinal] = (key, [])
                order.append(key.ordinal)
            }
            groups[key.ordinal]?.values.append(score.value)
        }

        struct Draft {
            let start: DayKey
            let average: Double
            let best: Double
            let days: Int
        }

        let drafts: [Draft] = order.compactMap { ordinal in
            guard let group = groups[ordinal], group.values.count >= minimumDays else { return nil }
            let average = group.values.reduce(0, +) / Double(group.values.count)
            return Draft(start: group.start,
                         average: average,
                         best: group.values.max() ?? average,
                         days: group.values.count)
        }
        guard !drafts.isEmpty else { return [] }

        // Rank descending by average; ties share the better rank.
        let sortedAverages = drafts.map(\.average).sorted(by: >)
        let total = drafts.count

        return drafts.enumerated().map { index, draft in
            let rank = (sortedAverages.firstIndex { $0 <= draft.average + 1e-9 } ?? 0) + 1
            let previous = index > 0 ? drafts[index - 1].average : nil
            return RankedPeriod(start: draft.start,
                                label: bucket.label(for: draft.start),
                                averageScore: draft.average,
                                bestScore: draft.best,
                                days: draft.days,
                                rank: rank,
                                totalPeriods: total,
                                changeFromPrevious: previous.map { draft.average - $0 })
        }
    }

    /// The headline "where do I stand" summary for the dashboard.
    public static func standing(from scores: [FitnessScore]) -> FitnessStanding? {
        guard let current = scores.last else { return nil }

        let values = scores.map(\.value)
        func percentile(_ pool: [Double]) -> Double {
            guard !pool.isEmpty else { return 0 }
            let below = pool.reduce(0) { $0 + ($1 < current.value ? 1 : 0) }
            let equal = pool.reduce(0) { $0 + ($1 == current.value ? 1 : 0) }
            return (Double(below) + Double(equal) / 2) / Double(pool.count)
        }

        let yearCutoff = current.day.adding(days: -365)
        let lastYearValues = scores.filter { $0.day >= yearCutoff }.map(\.value)

        // Walk backwards for the last time the index was at least this high,
        // skipping the tail of the current run at or above the level.
        var daysSinceHigher: Int?
        var sawLower = false
        for score in scores.reversed() {
            if score.day == current.day { continue }
            if score.value < current.value { sawLower = true; continue }
            if sawLower {
                daysSinceHigher = current.day.ordinal - score.day.ordinal
                break
            }
        }

        func valueNearest(daysAgo: Int) -> Double? {
            let target = current.day.adding(days: -daysAgo)
            var best: FitnessScore?
            for score in scores where abs(score.day.ordinal - target.ordinal) <= 7 {
                if best == nil || abs(score.day.ordinal - target.ordinal) < abs(best!.day.ordinal - target.ordinal) {
                    best = score
                }
            }
            return best?.value
        }

        return FitnessStanding(
            current: current,
            percentileAllTime: percentile(values),
            percentileLastYear: percentile(lastYearValues),
            allTimeBest: scores.max { $0.value < $1.value },
            allTimeWorst: scores.min { $0.value < $1.value },
            daysSinceHigher: daysSinceHigher,
            changeVs30Days: valueNearest(daysAgo: 30).map { current.value - $0 },
            changeVs90Days: valueNearest(daysAgo: 90).map { current.value - $0 },
            changeVs365Days: valueNearest(daysAgo: 365).map { current.value - $0 }
        )
    }

    /// Average contribution of each component across a set of scores, so the
    /// Fitness screen can show which pillar is carrying you and which is not.
    public static func componentAverages(from scores: [FitnessScore]) -> [FitnessComponent] {
        var totals: [FitnessComponent.Kind: (score: Double, weight: Double, count: Int, detail: String?)] = [:]
        for score in scores {
            for component in score.components {
                var entry = totals[component.kind] ?? (0, 0, 0, nil)
                entry.score += component.score
                entry.weight += component.weight
                entry.count += 1
                entry.detail = component.detail
                totals[component.kind] = entry
            }
        }
        return FitnessComponent.Kind.allCases.compactMap { kind -> FitnessComponent? in
            guard let entry = totals[kind], entry.count > 0 else { return nil }
            return FitnessComponent(kind: kind,
                                    score: entry.score / Double(entry.count),
                                    weight: entry.weight / Double(entry.count),
                                    detail: entry.detail)
        }
    }
}
