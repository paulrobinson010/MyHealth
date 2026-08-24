import Foundation

/// One weighted ingredient of the fitness index.
public struct FitnessComponent: Sendable, Identifiable, Hashable {
    public enum Kind: String, CaseIterable, Sendable {
        case cardio          // VO₂ max
        case restingHeart    // resting heart rate
        case recovery        // HRV
        case volume          // exercise minutes + active energy
        case consistency     // how many days you showed up
        case movement        // baseline daily steps

        public var title: String {
            switch self {
            case .cardio: return "Cardio Capacity"
            case .restingHeart: return "Resting Heart Rate"
            case .recovery: return "Recovery"
            case .volume: return "Training Volume"
            case .consistency: return "Consistency"
            case .movement: return "Daily Movement"
            }
        }

        public var explanation: String {
            switch self {
            case .cardio: return "VO₂ max against reference ranges for your age and sex."
            case .restingHeart: return "Your average resting heart rate over the window — lower scores higher."
            case .recovery: return "Heart rate variability (SDNN) against what is typical for your age."
            case .volume: return "Exercise minutes per week and active energy per day."
            case .consistency: return "The share of days in the window you actually moved."
            case .movement: return "Average daily step count outside of workouts."
            }
        }

        public var symbolName: String {
            switch self {
            case .cardio: return "lungs.fill"
            case .restingHeart: return "heart.fill"
            case .recovery: return "waveform.path.ecg"
            case .volume: return "flame.fill"
            case .consistency: return "calendar"
            case .movement: return "figure.walk"
            }
        }

        /// Base weight before renormalising over whatever data exists.
        public var baseWeight: Double {
            switch self {
            case .cardio: return 0.28
            case .restingHeart: return 0.14
            case .recovery: return 0.13
            case .volume: return 0.22
            case .consistency: return 0.11
            case .movement: return 0.12
            }
        }
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    /// 0...100.
    public let score: Double
    /// Share of the final index this component actually contributed.
    public let weight: Double
    /// The underlying measurement, for display ("52.3 mL/kg·min").
    public let detail: String?

    public init(kind: Kind, score: Double, weight: Double, detail: String?) {
        self.kind = kind
        self.score = score
        self.weight = weight
        self.detail = detail
    }
}

public enum FitnessBand: String, Sendable, CaseIterable {
    case needsWork, fair, good, strong, elite

    public init(score: Double) {
        switch score {
        case ..<35: self = .needsWork
        case 35..<52: self = .fair
        case 52..<70: self = .good
        case 70..<85: self = .strong
        default: self = .elite
        }
    }

    public var title: String {
        switch self {
        case .needsWork: return "Building"
        case .fair: return "Fair"
        case .good: return "Good"
        case .strong: return "Strong"
        case .elite: return "Elite"
        }
    }
}

/// The fitness index on one day: a 0...100 rollup of the trailing window.
public struct FitnessScore: Sendable, Identifiable, Hashable {
    public var id: Int { day.ordinal }
    public let day: DayKey
    public let value: Double
    public let components: [FitnessComponent]
    /// Total base weight of the components that had data, 0...1. Low coverage
    /// means the score rests on thin evidence and the UI flags it.
    public let coverage: Double

    public var band: FitnessBand { FitnessBand(score: value) }

    public init(day: DayKey, value: Double, components: [FitnessComponent], coverage: Double) {
        self.day = day
        self.value = value
        self.components = components
        self.coverage = coverage
    }

    public func component(_ kind: FitnessComponent.Kind) -> FitnessComponent? {
        components.first { $0.kind == kind }
    }
}

/// Computes the composite fitness index over time.
///
/// Each day's score summarises a trailing window (28 days by default) so the
/// series reflects sustained fitness rather than whether yesterday happened to
/// include a long run.
public struct FitnessIndex: Sendable {
    public struct Configuration: Sendable {
        public var window: Int = 28
        /// How far back a VO₂ max reading stays usable. Apple only estimates it
        /// during outdoor walks and runs, so it can be weeks between readings.
        public var vo2MaxLookback: Int = 180
        /// A day counts as "active" for the consistency component if it clears
        /// either of these.
        public var activeDayExerciseMinutes: Double = 20
        public var activeDaySteps: Double = 7_500
        /// Minimum days of data in the window before a score is emitted.
        public var minimumWindowDays: Int = 7
        public init() {}
    }

    public let configuration: Configuration
    private let profile: UserProfile
    private let byOrdinal: [Int: DailySummary]
    private let orderedDays: [DayKey]

    public init(database: HealthDatabase, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.profile = database.profile
        self.byOrdinal = database.indexed()
        self.orderedDays = database.days.map(\.day)
    }

    /// The index on a single day, or nil if the trailing window is too sparse.
    public func score(on day: DayKey) -> FitnessScore? {
        let window = configuration.window
        let start = day.adding(days: -(window - 1))

        var exerciseTotal = 0.0
        var energyValues: [Double] = []
        var stepValues: [Double] = []
        var restingValues: [Double] = []
        var hrvValues: [Double] = []
        var activeDays = 0
        var daysWithData = 0

        for ordinal in start.ordinal...day.ordinal {
            guard let summary = byOrdinal[ordinal] else { continue }
            daysWithData += 1

            let exercise = summary[.exerciseMinutes] ?? summary[.workoutMinutes] ?? 0
            exerciseTotal += exercise
            if let energy = summary[.activeEnergy] { energyValues.append(energy) }
            if let steps = summary[.steps] { stepValues.append(steps) }
            if let resting = summary[.restingHeartRate] { restingValues.append(resting) }
            if let hrv = summary[.hrv] { hrvValues.append(hrv) }

            let steps = summary[.steps] ?? 0
            if exercise >= configuration.activeDayExerciseMinutes
                || steps >= configuration.activeDaySteps {
                activeDays += 1
            }
        }

        guard daysWithData >= configuration.minimumWindowDays else { return nil }

        var components: [FitnessComponent] = []
        var weightedTotal = 0.0
        var weightUsed = 0.0

        func add(_ kind: FitnessComponent.Kind, score: Double, detail: String) {
            let weight = kind.baseWeight
            let clamped = score.clamped(to: 0...100)
            components.append(FitnessComponent(kind: kind, score: clamped, weight: weight, detail: detail))
            weightedTotal += clamped * weight
            weightUsed += weight
        }

        let age = profile.age(on: day)

        if let vo2 = latestVO2Max(asOf: day) {
            let category = ReferenceRanges.vo2MaxCategory(vo2, age: age, sex: profile.biologicalSex)
            add(.cardio,
                score: ReferenceRanges.vo2MaxScore(vo2, age: age, sex: profile.biologicalSex),
                detail: String(format: "%.1f mL/kg·min · %@", vo2, category))
        }

        if !restingValues.isEmpty {
            let mean = restingValues.reduce(0, +) / Double(restingValues.count)
            add(.restingHeart,
                score: ReferenceRanges.restingHeartRateScore(mean, age: age),
                detail: String(format: "%.0f bpm average", mean))
        }

        if !hrvValues.isEmpty {
            let mean = hrvValues.reduce(0, +) / Double(hrvValues.count)
            add(.recovery,
                score: ReferenceRanges.hrvScore(mean, age: age),
                detail: String(format: "%.0f ms SDNN", mean))
        }

        if exerciseTotal > 0 || !energyValues.isEmpty {
            let minutesPerWeek = exerciseTotal / Double(window) * 7
            let exerciseScore = ReferenceRanges.exerciseVolumeScore(minutesPerWeek: minutesPerWeek)
            var detail = String(format: "%.0f min/week", minutesPerWeek)
            var combined = exerciseScore
            if !energyValues.isEmpty {
                let perDay = energyValues.reduce(0, +) / Double(energyValues.count)
                combined = 0.65 * exerciseScore + 0.35 * ReferenceRanges.activeEnergyScore(kcalPerDay: perDay)
                detail += String(format: " · %.0f kcal/day", perDay)
            }
            add(.volume, score: combined, detail: detail)
        }

        if daysWithData >= configuration.minimumWindowDays {
            let fraction = Double(activeDays) / Double(daysWithData)
            add(.consistency,
                score: ReferenceRanges.consistencyScore(activeDayFraction: fraction),
                detail: "\(activeDays) of \(daysWithData) days active")
        }

        if !stepValues.isEmpty {
            let perDay = stepValues.reduce(0, +) / Double(stepValues.count)
            add(.movement,
                score: ReferenceRanges.stepsScore(perDay: perDay),
                detail: String(format: "%.0f steps/day", perDay))
        }

        guard weightUsed > 0 else { return nil }
        let value = weightedTotal / weightUsed
        // Rescale each component's weight to the share it really contributed.
        let normalised = components.map {
            FitnessComponent(kind: $0.kind, score: $0.score, weight: $0.weight / weightUsed, detail: $0.detail)
        }
        return FitnessScore(day: day, value: value, components: normalised, coverage: weightUsed)
    }

    /// The index for every day in the database that can produce one.
    /// `stride` samples the series — 1 for daily, 7 for weekly.
    public func history(stride step: Int = 1, in range: ClosedRange<DayKey>? = nil) -> [FitnessScore] {
        guard let firstDay = orderedDays.first, let lastDay = orderedDays.last else { return [] }
        let start = max(firstDay.adding(days: configuration.window - 1), range?.lowerBound ?? firstDay)
        let end = min(lastDay, range?.upperBound ?? lastDay)
        guard start <= end else { return [] }

        var scores: [FitnessScore] = []
        var ordinal = start.ordinal
        while ordinal <= end.ordinal {
            if let score = score(on: DayKey(ordinal: ordinal)) { scores.append(score) }
            ordinal += max(1, step)
        }
        // Always include the final day even when the stride would skip it.
        if let last = scores.last, last.day < end, let final = score(on: end) {
            scores.append(final)
        }
        return scores
    }

    private func latestVO2Max(asOf day: DayKey) -> Double? {
        let lowest = day.ordinal - configuration.vo2MaxLookback
        var ordinal = day.ordinal
        while ordinal >= lowest {
            if let value = byOrdinal[ordinal]?[.vo2Max] { return value }
            ordinal -= 1
        }
        return nil
    }
}
