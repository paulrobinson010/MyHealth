import Foundation

/// A weigh-in, taken from the smoothed weight trend rather than the raw
/// reading. Day-to-day weight is mostly water, and anchoring an interval on two
/// noisy endpoints can invent or erase a kilogram that never existed.
public struct WeighIn: Sendable, Hashable {
    public let day: DayKey
    /// Smoothed kilograms.
    public let kilograms: Double
    /// Raw reading, kept so the UI can show what was actually on the scale.
    public let rawKilograms: Double

    public init(day: DayKey, kilograms: Double, rawKilograms: Double) {
        self.day = day
        self.kilograms = kilograms
        self.rawKilograms = rawKilograms
    }
}

/// What happened between two weigh-ins.
///
/// This is the core idea: over an interval bracketed by weigh-ins, the energy
/// balance is not estimated from a food diary at all — it is **measured** from
/// the weight change. Logging then stops being the source of the answer and
/// becomes a way of attributing it, which is a much smaller job and a far more
/// reliable one.
public struct ReconciledInterval: Sendable, Identifiable {
    public var id: Int { start.day.ordinal }

    public let start: WeighIn
    public let end: WeighIn
    /// Days in the interval, counting the end and not the start.
    public let days: Int

    public let loggedDays: Int
    public let loggedIntake: Double
    public let totalExpenditure: Double

    public var unloggedDays: Int { days - loggedDays }
    public var weightChangeKg: Double { end.kilograms - start.kilograms }

    /// Energy balance the scale says happened. Negative is a deficit.
    public var measuredEnergyBalance: Double {
        weightChangeKg * EnergyBalance.kilocaloriesPerKilogram
    }

    /// The honest daily deficit for this interval, from the scale alone.
    /// Positive is a deficit.
    public var measuredDailyDeficit: Double {
        guard days > 0 else { return 0 }
        return -measuredEnergyBalance / Double(days)
    }

    /// What you must have eaten in total for the scale to do what it did.
    public var impliedTotalIntake: Double {
        totalExpenditure + measuredEnergyBalance
    }

    /// What the unlogged days must have averaged. This is measured, not
    /// assumed — and it is usually the most interesting number on the screen.
    public var impliedUnloggedDailyIntake: Double? {
        guard unloggedDays > 0 else { return nil }
        return (impliedTotalIntake - loggedIntake) / Double(unloggedDays)
    }

    public var loggedDailyIntake: Double? {
        guard loggedDays > 0 else { return nil }
        return loggedIntake / Double(loggedDays)
    }

    /// How much the unlogged days differ from the logged ones. A large positive
    /// number is the signature of only logging the good days.
    public var unloggedDayExcess: Double? {
        guard let implied = impliedUnloggedDailyIntake, let logged = loggedDailyIntake else {
            return nil
        }
        return implied - logged
    }

    /// The deficit the food diary alone would have claimed, for comparison
    /// with what the scale actually measured.
    public var loggedDailyDeficit: Double? {
        guard loggedDays > 0 else { return nil }
        let expenditurePerDay = totalExpenditure / Double(days)
        return expenditurePerDay - (loggedIntake / Double(loggedDays))
    }

    /// Gap between what the diary claimed and what the scale measured.
    public var underLoggingPerDay: Double? {
        guard let claimed = loggedDailyDeficit else { return nil }
        return claimed - measuredDailyDeficit
    }

    public enum Plausibility: String, Sendable {
        case sound
        /// The arithmetic works but implies something odd — a huge or negative
        /// intake on the unlogged days.
        case questionable
        /// Too short, or the weight moved too fast to be tissue.
        case unusable

        public var title: String {
            switch self {
            case .sound: return "Sound"
            case .questionable: return "Questionable"
            case .unusable: return "Unusable"
            }
        }
    }

    public var plausibility: Plausibility {
        // Under a week, normal water swings swamp any real change.
        if days < 5 { return .unusable }
        // More than about 1.5 kg a week is water, illness or a mis-keyed entry,
        // not tissue.
        let kgPerWeek = abs(weightChangeKg) / (Double(days) / 7)
        if kgPerWeek > 1.5 { return .unusable }

        if let implied = impliedUnloggedDailyIntake, implied < 400 || implied > 6_000 {
            return .questionable
        }
        if totalExpenditure <= 0 { return .unusable }
        return .sound
    }
}

/// How to treat days with no food logged.
public enum UnloggedDayPolicy: String, Sendable, CaseIterable {
    /// Leave them out of the average entirely. Optimistic: it quietly assumes
    /// the unlogged days looked like the logged ones, which is rarely true.
    case exclude
    /// Assume intake matched expenditure, so the day contributes nothing either
    /// way. Conservative, and the right default when nothing else is known.
    case neutral
    /// Work out what they must have been from the surrounding weigh-ins, and
    /// fall back to neutral where no weigh-in brackets them.
    case reconcile

    public var title: String {
        switch self {
        case .exclude: return "Ignore unlogged days"
        case .neutral: return "Assume unlogged days were calorie-neutral"
        case .reconcile: return "Work them out from your weigh-ins"
        }
    }

    public var explanation: String {
        switch self {
        case .exclude:
            return "Averages only the days you logged. Flattering, because the days you forget are rarely the quiet ones."
        case .neutral:
            return "An unlogged day is counted as breaking even — no deficit, no surplus. It cannot invent progress that did not happen."
        case .reconcile:
            return "Between two weigh-ins your energy balance is measured, not estimated. The unlogged days are whatever they must have been for the scale to read what it did."
        }
    }
}

/// Reconciles a food diary against the scale.
public enum IntervalReconciler {

    /// Minimum days between weigh-ins before a change is treated as real.
    public static let minimumIntervalDays = 5

    /// Pulls weigh-ins out of the database, smoothed.
    public static func weighIns(in database: HealthDatabase,
                                range: ClosedRange<DayKey>? = nil,
                                smoothingWindow: Int = 7) -> [WeighIn] {
        let raw = database.series(.bodyMass, in: range)
        guard !raw.isEmpty else { return [] }
        let smoothed = raw.rollingMean(window: smoothingWindow)
        var smoothedByOrdinal: [Int: Double] = [:]
        for point in smoothed.points { smoothedByOrdinal[point.day.ordinal] = point.value }

        return raw.points.compactMap { point in
            guard let value = smoothedByOrdinal[point.day.ordinal] else { return nil }
            return WeighIn(day: point.day, kilograms: value, rawKilograms: point.value)
        }
    }

    /// Splits the period into intervals bracketed by weigh-ins and reconciles
    /// each one.
    ///
    /// Consecutive weigh-ins closer together than `minimumIntervalDays` are
    /// merged rather than producing intervals too short to mean anything —
    /// weighing daily should sharpen the picture, not fill it with noise.
    public static func intervals(database: HealthDatabase,
                                 range: ClosedRange<DayKey>? = nil) -> [ReconciledInterval] {
        let all = weighIns(in: database, range: range)
        guard all.count >= 2 else { return [] }

        var anchors: [WeighIn] = [all[0]]
        for weighIn in all.dropFirst() {
            guard let last = anchors.last else { continue }
            if weighIn.day - last.day >= minimumIntervalDays {
                anchors.append(weighIn)
            }
        }
        // Always keep the final reading, so the most recent interval runs right
        // up to today rather than stopping at the last convenient anchor.
        if let last = all.last, anchors.last?.day != last.day,
           let previous = anchors.last, last.day - previous.day >= minimumIntervalDays {
            anchors.append(last)
        }
        guard anchors.count >= 2 else { return [] }

        let ledger = EnergyBalance.ledger(for: database, range: range)
        var ledgerByOrdinal: [Int: EnergyDay] = [:]
        for day in ledger { ledgerByOrdinal[day.day.ordinal] = day }

        var results: [ReconciledInterval] = []
        for index in 1..<anchors.count {
            let start = anchors[index - 1]
            let end = anchors[index]
            let days = end.day - start.day
            guard days > 0 else { continue }

            var loggedDays = 0
            var loggedIntake = 0.0
            var expenditure = 0.0
            var expenditureDays = 0

            // The interval covers the days after the first weigh-in up to and
            // including the second.
            for ordinal in (start.day.ordinal + 1)...end.day.ordinal {
                guard let day = ledgerByOrdinal[ordinal] else { continue }
                if let intake = day.intake {
                    loggedDays += 1
                    loggedIntake += intake
                }
                if let out = day.expenditure {
                    expenditure += out
                    expenditureDays += 1
                }
            }

            // Days where the device recorded nothing get the interval's own
            // average rather than zero, which would understate the total.
            if expenditureDays > 0, expenditureDays < days {
                expenditure += (expenditure / Double(expenditureDays))
                    * Double(days - expenditureDays)
            }

            results.append(ReconciledInterval(start: start,
                                              end: end,
                                              days: days,
                                              loggedDays: loggedDays,
                                              loggedIntake: loggedIntake,
                                              totalExpenditure: expenditure))
        }
        return results
    }

    /// The whole-period summary, built from the intervals that stood up.
    public struct Summary: Sendable {
        public let intervals: [ReconciledInterval]
        public let policy: UnloggedDayPolicy

        /// Deficit per day, computed under the chosen policy.
        public let dailyDeficit: Double?
        /// Deficit per day measured purely from weight change, ignoring the
        /// diary entirely. The most trustworthy figure available.
        public let measuredDailyDeficit: Double?
        /// How much a day is under-logged on average.
        public let underLoggingPerDay: Double?
        /// What the unlogged days appear to have been.
        public let impliedUnloggedDailyIntake: Double?
        public let coveredDays: Int
        public let loggedDays: Int

        public var usableIntervals: [ReconciledInterval] {
            intervals.filter { $0.plausibility != .unusable }
        }

        public var hasMeasuredAnswer: Bool { measuredDailyDeficit != nil }
    }

    public static func summarise(for database: HealthDatabase,
                                 range: ClosedRange<DayKey>? = nil,
                                 policy: UnloggedDayPolicy = .reconcile) -> Summary {
        let all = intervals(database: database, range: range)
        let usable = all.filter { $0.plausibility != .unusable }

        let totalDays = usable.reduce(0) { $0 + $1.days }
        let loggedDays = usable.reduce(0) { $0 + $1.loggedDays }

        var measured: Double?
        if totalDays > 0 {
            let balance = usable.reduce(0.0) { $0 + $1.measuredEnergyBalance }
            measured = -balance / Double(totalDays)
        }

        var underLogging: Double?
        let gaps = usable.compactMap(\.underLoggingPerDay)
        if !gaps.isEmpty { underLogging = gaps.reduce(0, +) / Double(gaps.count) }

        var impliedUnlogged: Double?
        let unloggedTotals = usable.compactMap { interval -> (Double, Int)? in
            guard let implied = interval.impliedUnloggedDailyIntake,
                  interval.plausibility == .sound,
                  interval.unloggedDays > 0 else { return nil }
            return (implied * Double(interval.unloggedDays), interval.unloggedDays)
        }
        if !unloggedTotals.isEmpty {
            let calories = unloggedTotals.reduce(0.0) { $0 + $1.0 }
            let days = unloggedTotals.reduce(0) { $0 + $1.1 }
            if days > 0 { impliedUnlogged = calories / Double(days) }
        }

        let deficit: Double?
        switch policy {
        case .reconcile:
            // The scale already answered this; the diary only attributes it.
            deficit = measured
        case .neutral:
            deficit = neutralDeficit(for: database, range: range)
        case .exclude:
            deficit = EnergyBalance.report(for: database, range: range).averageDailyDeficit
        }

        return Summary(intervals: all,
                       policy: policy,
                       dailyDeficit: deficit,
                       measuredDailyDeficit: measured,
                       underLoggingPerDay: underLogging,
                       impliedUnloggedDailyIntake: impliedUnlogged,
                       coveredDays: totalDays,
                       loggedDays: loggedDays)
    }

    /// Deficit with unlogged days counted as breaking even.
    ///
    /// The conservative fallback for stretches no weigh-in brackets. It cannot
    /// invent progress that did not happen, which is exactly what excluding
    /// unlogged days does.
    public static func neutralDeficit(for database: HealthDatabase,
                                      range: ClosedRange<DayKey>? = nil) -> Double? {
        let ledger = EnergyBalance.ledger(for: database, range: range)
        guard !ledger.isEmpty else { return nil }
        var total = 0.0
        var days = 0
        for day in ledger {
            days += 1
            // No log means no contribution — not a day of eating nothing.
            total += day.deficit ?? 0
        }
        return days > 0 ? total / Double(days) : nil
    }
}
