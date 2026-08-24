import Foundation

/// One day of the calorie ledger.
public struct EnergyDay: Sendable, Identifiable, Hashable {
    public var id: Int { day.ordinal }
    public let day: DayKey
    /// Calories eaten, when anything was logged at all.
    public let intake: Double?
    public let activeEnergy: Double?
    public let basalEnergy: Double?
    /// Grams of ethanol.
    public let alcoholGrams: Double

    /// Total energy out. Falls back to an estimated BMR when the device did not
    /// record resting energy.
    public let expenditure: Double?

    /// Positive means a deficit — energy out exceeded energy in.
    public var deficit: Double? {
        guard let intake, let expenditure else { return nil }
        return expenditure - intake
    }

    public var isLogged: Bool { intake != nil }
}

/// The result of reconciling what you ate against what you weigh.
public struct EnergyBalanceReport: Sendable {
    public let days: [EnergyDay]
    /// Days in the window that actually had food logged.
    public let loggedDays: Int
    public let totalDays: Int

    public let averageIntake: Double?
    public let averageExpenditure: Double?
    /// Positive is a deficit.
    public let averageDailyDeficit: Double?
    public let cumulativeDeficit: Double?

    /// Weight change the deficit alone predicts, in kilograms (negative = loss).
    public let predictedWeightChangeKg: Double?
    /// Weight change actually observed, from the smoothed weight trend.
    public let actualWeightChangeKg: Double?

    /// Maintenance calories implied by what you ate and what your weight did —
    /// the number that matters, and the one no calculator can tell you.
    public let calibratedMaintenanceCalories: Double?
    /// How far the device's own expenditure estimate is from that calibration.
    public let expenditureBias: Double?

    public let alcoholCaloriesPerWeek: Double?
    public let alcoholShareOfIntake: Double?

    /// Fraction of the window with food logged. Everything above rests on this.
    public var loggingCoverage: Double {
        totalDays > 0 ? Double(loggedDays) / Double(totalDays) : 0
    }

    /// Below this, gaps in logging dominate and the calibration is guesswork.
    public var isCalibrationTrustworthy: Bool {
        loggingCoverage >= 0.6 && loggedDays >= 14 && calibratedMaintenanceCalories != nil
    }
}

/// Reconciles logged intake against measured expenditure and measured weight.
///
/// The headline is not the deficit — anyone can subtract two numbers — but the
/// *calibration*: given what you actually ate and what your weight actually
/// did, what is your real maintenance intake. Apple's active-plus-resting
/// energy is an estimate, and this is the only way to find out how wrong it is
/// for you specifically.
public enum EnergyBalance {

    /// Energy density of body mass change. 1 kg of fat is about 7,700 kcal;
    /// real weight change is a mix of tissue, so this is the standard
    /// approximation rather than a physical constant.
    public static let kilocaloriesPerKilogram: Double = 7_700

    /// Mifflin-St Jeor, used only when the device recorded no resting energy.
    public static func estimatedBasalRate(massKg: Double,
                                          heightCm: Double,
                                          age: Int,
                                          sex: BiologicalSex) -> Double {
        let base = 10 * massKg + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        case .other, .unknown: return base - 78
        }
    }

    public static func ledger(for database: HealthDatabase,
                              range: ClosedRange<DayKey>? = nil) -> [EnergyDay] {
        let profile = database.profile
        // A fallback resting rate, from the most recent known weight.
        let lastMass = database.series(.bodyMass).last?.value
        let height = profile.heightCm

        return database.days.compactMap { summary -> EnergyDay? in
            if let range, !range.contains(summary.day) { return nil }

            let intake = summary[.dietaryEnergy]
            let active = summary[.activeEnergy]
            var basal = summary[.basalEnergy]

            if basal == nil, let mass = summary[.bodyMass] ?? lastMass,
               let height, let age = profile.age(on: summary.day) {
                basal = estimatedBasalRate(massKg: mass, heightCm: height,
                                           age: age, sex: profile.biologicalSex)
            }

            let expenditure: Double?
            if let basal {
                expenditure = basal + (active ?? 0)
            } else {
                // Active energy on its own is not a day's expenditure, and
                // pretending otherwise would invent an enormous deficit.
                expenditure = nil
            }

            let alcohol = summary[.alcoholGrams]
                ?? summary[.alcoholicDrinks].map { $0 * AlcoholUnits.gramsPerUSStandardDrink }
                ?? 0

            return EnergyDay(day: summary.day,
                             intake: intake,
                             activeEnergy: active,
                             basalEnergy: basal,
                             alcoholGrams: alcohol,
                             expenditure: expenditure)
        }
    }

    public static func report(for database: HealthDatabase,
                              range: ClosedRange<DayKey>? = nil) -> EnergyBalanceReport {
        let days = ledger(for: database, range: range)
        let logged = days.filter(\.isLogged)

        let intakes = logged.compactMap(\.intake)
        let expenditures = days.compactMap(\.expenditure)
        let deficits = days.compactMap(\.deficit)

        let averageIntake = intakes.isEmpty ? nil : intakes.reduce(0, +) / Double(intakes.count)
        let averageExpenditure = expenditures.isEmpty
            ? nil : expenditures.reduce(0, +) / Double(expenditures.count)
        let averageDeficit = deficits.isEmpty ? nil : deficits.reduce(0, +) / Double(deficits.count)
        let cumulative = deficits.isEmpty ? nil : deficits.reduce(0, +)

        // Weight change comes from a fitted trend rather than first-minus-last:
        // day-to-day weight is mostly water, and two noisy endpoints can invent
        // or erase a kilogram that never existed.
        let weightSeries = database.series(.bodyMass, in: range).rollingMean(window: 7)
        let weightFit = weightSeries.regression()
        let spanDays = days.count

        var actualChange: Double?
        if let weightFit, weightFit.count >= 8, spanDays > 1 {
            actualChange = weightFit.slopePerDay * Double(spanDays - 1)
        }

        let predictedChange = cumulative.map { -$0 / kilocaloriesPerKilogram }

        // Maintenance = what you ate, adjusted for what your body did with it.
        var calibrated: Double?
        if let averageIntake, let weightFit, weightFit.count >= 14, logged.count >= 14 {
            let kgPerDay = weightFit.slopePerDay
            calibrated = averageIntake - kgPerDay * kilocaloriesPerKilogram
        }

        let bias = (calibrated != nil && averageExpenditure != nil)
            ? averageExpenditure! - calibrated! : nil

        let alcoholGrams = days.reduce(0) { $0 + $1.alcoholGrams }
        let alcoholCalories = alcoholGrams * 7
        let weeks = max(1.0, Double(max(1, spanDays)) / 7)
        let alcoholPerWeek = spanDays > 0 ? alcoholCalories / weeks : nil
        let totalIntake = intakes.reduce(0, +)
        let alcoholShare = totalIntake > 0 ? alcoholCalories / totalIntake : nil

        return EnergyBalanceReport(
            days: days,
            loggedDays: logged.count,
            totalDays: days.count,
            averageIntake: averageIntake,
            averageExpenditure: averageExpenditure,
            averageDailyDeficit: averageDeficit,
            cumulativeDeficit: cumulative,
            predictedWeightChangeKg: predictedChange,
            actualWeightChangeKg: actualChange,
            calibratedMaintenanceCalories: calibrated,
            expenditureBias: bias,
            alcoholCaloriesPerWeek: alcoholPerWeek,
            alcoholShareOfIntake: alcoholShare)
    }

    /// Intake needed to hit a target rate of weight change, given the
    /// calibrated maintenance figure.
    public static func targetIntake(forWeightChangeKgPerWeek target: Double,
                                    maintenance: Double) -> Double {
        maintenance + (target * kilocaloriesPerKilogram) / 7
    }

    /// Waist and weight should move together. When they do not, the composition
    /// of the change is worth a second look — which is exactly what makes waist
    /// worth logging alongside the scale.
    public struct BodyCompositionSignal: Sendable {
        public let weightChangeKg: Double?
        public let waistChangeCm: Double?
        public let correlation: Correlation?

        /// True when weight is holding but the waist is shrinking — the
        /// classic signature of losing fat and gaining muscle at once.
        public var isRecomposition: Bool {
            guard let weightChangeKg, let waistChangeCm else { return false }
            return abs(weightChangeKg) < 1.0 && waistChangeCm <= -1.0
        }
    }

    public static func bodyComposition(for database: HealthDatabase,
                                       range: ClosedRange<DayKey>? = nil) -> BodyCompositionSignal {
        func trendChange(_ metric: Metric) -> Double? {
            let series = database.series(metric, in: range).rollingMean(window: 7)
            guard let fit = series.regression(), fit.count >= 8,
                  let first = series.first?.day, let last = series.last?.day,
                  last > first else { return nil }
            return fit.slopePerDay * Double(last - first)
        }

        return BodyCompositionSignal(
            weightChangeKg: trendChange(.bodyMass),
            waistChangeCm: trendChange(.waistCircumference),
            correlation: CorrelationAnalysis.correlate(.bodyMass, with: .waistCircumference,
                                                       in: database, range: range))
    }
}
