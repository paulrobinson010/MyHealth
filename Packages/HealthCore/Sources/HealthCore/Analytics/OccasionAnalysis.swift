import Foundation

/// What a given kind of occasion actually costs, in calories and in what it
/// does to you the following morning.
public struct OccasionImpact: Sendable, Identifiable {
    public var id: String { context.rawValue }
    public let context: MealContext
    public let dayCount: Int

    public let averageCalories: Double
    public let averageAlcoholGrams: Double
    /// Calories above your own average day.
    public let caloriesVsTypicalDay: Double?

    /// Change in the next morning's numbers, against the average morning after
    /// a day with no occasion of this kind.
    public let nextDayRestingHeartRateDelta: Double?
    public let nextDayHRVDelta: Double?
    public let nextDaySleepDelta: Double?
    public let nextDayStepsDelta: Double?

    public var averageUKUnits: Double { AlcoholUnits.ukUnits(grams: averageAlcoholGrams) }

    /// True when the morning after measurably suffers.
    public var hasNextDayCost: Bool {
        (nextDayRestingHeartRateDelta ?? 0) > 1.5 || (nextDayHRVDelta ?? 0) < -3
    }
}

public enum OccasionAnalysis {

    /// Groups days by the occasion that characterised them and measures both
    /// the day itself and the morning after.
    ///
    /// The comparison baseline is every *other* day in the same window, so the
    /// numbers read as "versus your normal", not versus a population.
    public static func impacts(log: FoodLog,
                               database: HealthDatabase,
                               range: ClosedRange<DayKey>? = nil,
                               minimumDays: Int = 3) -> [OccasionImpact] {
        var contextByOrdinal: [Int: MealContext] = [:]
        for occasion in log.occasions {
            if let range, !range.contains(occasion.day) { continue }
            // A pub day beats a home day when both happened.
            let existing = contextByOrdinal[occasion.day.ordinal]
            if existing == nil || (!existing!.isEatingOut && occasion.context.isEatingOut) {
                contextByOrdinal[occasion.day.ordinal] = occasion.context
            }
        }
        guard !contextByOrdinal.isEmpty else { return [] }

        let byOrdinal = database.indexed()

        func value(_ metric: Metric, on ordinal: Int) -> Double? {
            byOrdinal[ordinal]?.values[metric]
        }

        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        let allOrdinals = database.days
            .filter { range.map { r in r.contains($0.day) } ?? true }
            .map(\.day.ordinal)

        let typicalIntake = mean(allOrdinals.compactMap { value(.dietaryEnergy, on: $0) })

        var results: [OccasionImpact] = []
        for context in MealContext.allCases {
            let ordinals = contextByOrdinal.filter { $0.value == context }.map(\.key)
            guard ordinals.count >= minimumDays else { continue }
            let others = Set(allOrdinals).subtracting(ordinals)

            // Same-day intake comes from the log rather than HealthKit, so the
            // figure holds up even before a sync has happened.
            let calories = ordinals.map { ordinal in
                log.total(on: DayKey(ordinal: ordinal)).kilocalories
            }
            let alcohol = ordinals.map { ordinal in
                log.total(on: DayKey(ordinal: ordinal)).alcoholGrams
            }

            func nextDayDelta(_ metric: Metric) -> Double? {
                let after = ordinals.compactMap { value(metric, on: $0 + 1) }
                let baseline = others.compactMap { value(metric, on: $0 + 1) }
                guard after.count >= minimumDays, baseline.count >= minimumDays,
                      let a = mean(after), let b = mean(baseline) else { return nil }
                return a - b
            }

            results.append(OccasionImpact(
                context: context,
                dayCount: ordinals.count,
                averageCalories: mean(calories) ?? 0,
                averageAlcoholGrams: mean(alcohol) ?? 0,
                caloriesVsTypicalDay: typicalIntake.map { (mean(calories) ?? 0) - $0 },
                nextDayRestingHeartRateDelta: nextDayDelta(.restingHeartRate),
                nextDayHRVDelta: nextDayDelta(.hrv),
                nextDaySleepDelta: nextDayDelta(.sleepHours),
                nextDayStepsDelta: nextDayDelta(.steps)))
        }

        return results.sorted { $0.averageCalories > $1.averageCalories }
    }

    /// The morning-after effect of drinking, measured straight from the health
    /// data without needing any occasion tagging at all.
    public struct HangoverProfile: Sendable {
        public let drinkingDays: Int
        public let dryDays: Int
        public let restingHeartRateDelta: Double?
        public let hrvDelta: Double?
        public let sleepDelta: Double?
        public let stepsDelta: Double?
        /// Correlation between grams of alcohol and the next day's HRV.
        public let alcoholToNextDayHRV: Correlation?

        public var isMeaningful: Bool { drinkingDays >= 8 && dryDays >= 8 }
    }

    public static func hangoverProfile(for database: HealthDatabase,
                                       range: ClosedRange<DayKey>? = nil,
                                       threshold: Double = 16) -> HangoverProfile {
        let byOrdinal = database.indexed()
        var drinking: [Int] = []
        var dry: [Int] = []

        for summary in database.days {
            if let range, !range.contains(summary.day) { continue }
            let grams = summary[.alcoholGrams]
                ?? summary[.alcoholicDrinks].map { $0 * AlcoholUnits.gramsPerUSStandardDrink }
            guard let grams else { continue }
            if grams >= threshold { drinking.append(summary.day.ordinal) }
            else if grams == 0 { dry.append(summary.day.ordinal) }
        }

        func delta(_ metric: Metric) -> Double? {
            func mean(_ ordinals: [Int]) -> Double? {
                let values = ordinals.compactMap { byOrdinal[$0 + 1]?.values[metric] }
                return values.count >= 5 ? values.reduce(0, +) / Double(values.count) : nil
            }
            guard let a = mean(drinking), let b = mean(dry) else { return nil }
            return a - b
        }

        return HangoverProfile(
            drinkingDays: drinking.count,
            dryDays: dry.count,
            restingHeartRateDelta: delta(.restingHeartRate),
            hrvDelta: delta(.hrv),
            sleepDelta: delta(.sleepHours),
            stepsDelta: delta(.steps),
            alcoholToNextDayHRV: CorrelationAnalysis.correlate(.alcoholGrams, with: .hrv,
                                                               in: database, lagDays: 1,
                                                               range: range))
    }
}
