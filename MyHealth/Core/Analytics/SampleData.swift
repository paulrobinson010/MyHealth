import Foundation

/// Deterministic synthetic history, used by SwiftUI previews and by the
/// "Explore with sample data" button so the app is explorable before anyone
/// has an export to hand.
public enum SampleData {

    public static func database(years: Int = 3, endingAt end: DayKey = .today) -> HealthDatabase {
        var generator = SeededGenerator(seed: 20_240_317)
        let totalDays = years * 365
        let start = end.adding(days: -totalDays + 1)

        var days: [DailySummary] = []
        var workouts: [WorkoutSummary] = []

        // A slow upward fitness arc with a dip in the middle, so trends and
        // rankings have something real to find.
        for offset in 0..<totalDays {
            let day = start.adding(days: offset)
            let phase = Double(offset) / Double(totalDays)
            let arc = 0.45 + 0.4 * sin(phase * .pi * 1.3) + 0.25 * phase
            let seasonal = 0.08 * sin(Double(offset) / 58.0)
            let form = (arc + seasonal).clamped(to: 0.1...1.15)

            let weekday = day.weekday
            let isWeekend = weekday == 0 || weekday == 6
            let restDay = generator.nextDouble() < (isWeekend ? 0.25 : 0.34)

            var values: [Metric: Double] = [:]

            let baseSteps = 5_200 + form * 7_000 + (isWeekend ? 1_400 : 0)
            values[.steps] = (baseSteps * generator.jitter(0.22)).rounded()
            values[.walkingRunningDistance] = (values[.steps] ?? 0) / 1_380
            values[.flightsClimbed] = (4 + form * 9) * generator.jitter(0.5)

            let exercise = restDay ? Double.random(in: 0...8, using: &generator)
                                   : (18 + form * 52) * generator.jitter(0.3)
            values[.exerciseMinutes] = exercise.rounded()
            values[.activeEnergy] = (230 + form * 520 + exercise * 4.2) * generator.jitter(0.18)
            values[.basalEnergy] = 1_620 * generator.jitter(0.03)
            values[.standHours] = Double(Int((9 + form * 4) * generator.jitter(0.15)))

            values[.restingHeartRate] = (68 - form * 13) * generator.jitter(0.045)
            values[.hrv] = (34 + form * 30) * generator.jitter(0.22)
            values[.heartRateAverage] = (74 - form * 8) * generator.jitter(0.06)
            values[.heartRateMin] = (52 - form * 7) * generator.jitter(0.05)
            values[.heartRateMax] = (138 + form * 32) * generator.jitter(0.09)
            values[.respiratoryRate] = 15.2 * generator.jitter(0.06)
            values[.oxygenSaturation] = 97.4 * generator.jitter(0.008)

            values[.sleepHours] = (7.1 + form * 0.4) * generator.jitter(0.12)
            values[.bodyMass] = 84.5 - form * 6.5 + generator.nextDouble() * 0.8
            values[.bodyFatPercentage] = 24.5 - form * 5.5 + generator.nextDouble() * 0.6

            // VO₂ max only lands on outdoor workout days, as on a real Watch.
            if offset % 9 == 0 {
                values[.vo2Max] = (36 + form * 15) * generator.jitter(0.03)
            }
            if offset % 5 == 0 {
                values[.walkingSpeed] = (1.28 + form * 0.22) * generator.jitter(0.05)
            }

            days.append(DailySummary(day: day, values: values))

            if !restDay, exercise > 15 {
                let kinds = ["Running", "Cycling", "TraditionalStrengthTraining",
                             "HighIntensityIntervalTraining", "Walking", "Yoga"]
                let kind = kinds[Int(generator.nextDouble() * Double(kinds.count)) % kinds.count]
                let activity = WorkoutActivity(rawValue: kind)
                let minutes = exercise * generator.jitter(0.15)
                let distance: Double?
                switch kind {
                case "Running": distance = minutes / (5.4 - form * 0.7)
                case "Cycling": distance = minutes / 2.4
                case "Walking": distance = minutes / 11.5
                default: distance = nil
                }
                workouts.append(WorkoutSummary(
                    day: day,
                    start: Double(day.ordinal) * 86_400 + 18 * 3_600,
                    durationMinutes: minutes,
                    energyKcal: minutes * (6.2 + form * 2.5),
                    distanceKm: distance,
                    averageHeartRate: 128 + form * 18,
                    maxHeartRate: 158 + form * 20,
                    activity: activity,
                    sourceName: "Apple Watch"))
            }
        }

        var database = HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male,
                                 heightCm: 180),
            days: days,
            workouts: workouts,
            exportedAt: end.localDate(),
            sourceFileName: "Sample data")
        database.importedAt = Date()
        return database
    }
}

/// Tiny reproducible PRNG so sample data and tests are identical every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A multiplier in 1±spread.
    mutating func jitter(_ spread: Double) -> Double {
        1 + (nextDouble() * 2 - 1) * spread
    }
}
