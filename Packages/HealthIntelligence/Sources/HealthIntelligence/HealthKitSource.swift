import Foundation
import HealthCore
#if canImport(HealthKit)
import HealthKit
#endif

/// Reads health data straight out of the local HealthKit store.
///
/// macOS 26 (Tahoe) was the first release to make HealthKit available to Mac
/// apps. The Mac never talks to the Watch directly — samples travel
/// Watch → iPhone → iCloud Health sync → this Mac's HealthKit store — so the
/// phone still has to be syncing for anything to show up here.
///
/// Everything below is compiled out when building against an SDK without
/// HealthKit, and gated at runtime besides, so the app still builds and runs on
/// older systems using `Import from export.zip` instead.
public enum HealthKitAvailability {
    case available
    case requiresNewerMacOS
    case unavailableOnThisDevice
    case notBuiltWithHealthKit

    public var message: String {
        switch self {
        case .available:
            return "HealthKit is available on this Mac."
        case .requiresNewerMacOS:
            return "Native HealthKit access on the Mac needs macOS 26 (Tahoe) or later. You can still import an export.zip from your iPhone."
        case .unavailableOnThisDevice:
            return "HealthKit reports no health data store on this Mac. The diagnostics below say which requirement is not met."
        case .notBuiltWithHealthKit:
            return "This build was compiled without HealthKit. Rebuild with the macOS 26 SDK or later, or import an export.zip instead."
        }
    }

    public var isUsable: Bool { self == .available }
}

public enum HealthKitError: LocalizedError {
    case unavailable(HealthKitAvailability)
    case authorizationDenied
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let availability): return availability.message
        case .authorizationDenied:
            return "MyHealth was not granted permission to read your health data. Open System Settings › Privacy & Security › Health to change it."
        case .queryFailed(let detail):
            return "HealthKit query failed: \(detail)"
        }
    }
}

/// Availability check that is safe to call from anywhere, including builds and
/// systems where HealthKit does not exist. Everything in the UI routes through
/// this rather than touching `HealthKitSource` directly, so the app degrades to
/// the export importer instead of failing to launch.
public enum HealthKitBridge {
    public static var availability: HealthKitAvailability {
        #if canImport(HealthKit)
        // Every platform but the Mac has had HealthKit for years; only macOS
        // needs a version gate, and it needs 26.
        #if os(macOS)
        if #available(macOS 26.0, *) {
            return HKHealthStore.isHealthDataAvailable() ? .available : .unavailableOnThisDevice
        }
        return .requiresNewerMacOS
        #else
        return HKHealthStore.isHealthDataAvailable() ? .available : .unavailableOnThisDevice
        #endif
        #else
        return .notBuiltWithHealthKit
        #endif
    }
}

#if canImport(HealthKit)

@available(macOS 26.0, iOS 17.0, watchOS 10.0, *)
public actor HealthKitSource {

    /// The quantity types MyHealth reads, with the unit each is requested in
    /// and how it collapses to one value per day.
    private struct QuantitySpec {
        let metric: Metric
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let options: HKStatisticsOptions
        /// Applied after reading, e.g. HKUnit.percent() reports 0...1.
        var scale: Double = 1
    }

    private let healthStore = HKHealthStore()

    public init() {}

    // MARK: - Availability & authorisation

    public static var availability: HealthKitAvailability { HealthKitBridge.availability }

    private static var quantitySpecs: [QuantitySpec] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return [
            .init(metric: .steps, identifier: .stepCount, unit: .count(), options: .cumulativeSum),
            .init(metric: .walkingRunningDistance, identifier: .distanceWalkingRunning,
                  unit: .meterUnit(with: .kilo), options: .cumulativeSum),
            .init(metric: .cyclingDistance, identifier: .distanceCycling,
                  unit: .meterUnit(with: .kilo), options: .cumulativeSum),
            .init(metric: .swimmingDistance, identifier: .distanceSwimming,
                  unit: .meterUnit(with: .kilo), options: .cumulativeSum),
            .init(metric: .flightsClimbed, identifier: .flightsClimbed, unit: .count(), options: .cumulativeSum),
            .init(metric: .activeEnergy, identifier: .activeEnergyBurned,
                  unit: .kilocalorie(), options: .cumulativeSum),
            .init(metric: .basalEnergy, identifier: .basalEnergyBurned,
                  unit: .kilocalorie(), options: .cumulativeSum),
            .init(metric: .exerciseMinutes, identifier: .appleExerciseTime, unit: .minute(), options: .cumulativeSum),
            .init(metric: .moveMinutes, identifier: .appleMoveTime, unit: .minute(), options: .cumulativeSum),
            .init(metric: .timeInDaylight, identifier: .timeInDaylight, unit: .minute(), options: .cumulativeSum),

            .init(metric: .restingHeartRate, identifier: .restingHeartRate, unit: bpm, options: .discreteAverage),
            .init(metric: .walkingHeartRate, identifier: .walkingHeartRateAverage, unit: bpm, options: .discreteAverage),
            .init(metric: .heartRateAverage, identifier: .heartRate, unit: bpm, options: .discreteAverage),
            .init(metric: .heartRateMin, identifier: .heartRate, unit: bpm, options: .discreteMin),
            .init(metric: .heartRateMax, identifier: .heartRate, unit: bpm, options: .discreteMax),
            .init(metric: .hrv, identifier: .heartRateVariabilitySDNN,
                  unit: .secondUnit(with: .milli), options: .discreteAverage),
            .init(metric: .respiratoryRate, identifier: .respiratoryRate, unit: bpm, options: .discreteAverage),
            .init(metric: .oxygenSaturation, identifier: .oxygenSaturation,
                  unit: .percent(), options: .discreteAverage, scale: 100),
            .init(metric: .bloodPressureSystolic, identifier: .bloodPressureSystolic,
                  unit: .millimeterOfMercury(), options: .discreteAverage),
            .init(metric: .bloodPressureDiastolic, identifier: .bloodPressureDiastolic,
                  unit: .millimeterOfMercury(), options: .discreteAverage),

            .init(metric: .vo2Max, identifier: .vo2Max,
                  unit: HKUnit(from: "ml/kg*min"), options: .discreteAverage),
            .init(metric: .sixMinuteWalk, identifier: .sixMinuteWalkTestDistance,
                  unit: .meter(), options: .discreteAverage),

            .init(metric: .bodyMass, identifier: .bodyMass, unit: .gramUnit(with: .kilo), options: .discreteAverage),
            .init(metric: .leanBodyMass, identifier: .leanBodyMass,
                  unit: .gramUnit(with: .kilo), options: .discreteAverage),
            .init(metric: .bodyFatPercentage, identifier: .bodyFatPercentage,
                  unit: .percent(), options: .discreteAverage, scale: 100),
            .init(metric: .bodyMassIndex, identifier: .bodyMassIndex, unit: .count(), options: .discreteAverage),
            .init(metric: .waistCircumference, identifier: .waistCircumference,
                  unit: .meterUnit(with: .centi), options: .discreteAverage),

            .init(metric: .walkingSpeed, identifier: .walkingSpeed,
                  unit: .meter().unitDivided(by: .second()), options: .discreteAverage),
            .init(metric: .walkingStepLength, identifier: .walkingStepLength,
                  unit: .meterUnit(with: .centi), options: .discreteAverage),
            .init(metric: .walkingAsymmetry, identifier: .walkingAsymmetryPercentage,
                  unit: .percent(), options: .discreteAverage, scale: 100),
            .init(metric: .walkingDoubleSupport, identifier: .walkingDoubleSupportPercentage,
                  unit: .percent(), options: .discreteAverage, scale: 100),
            .init(metric: .walkingSteadiness, identifier: .appleWalkingSteadiness,
                  unit: .percent(), options: .discreteAverage, scale: 100),
            .init(metric: .stairAscentSpeed, identifier: .stairAscentSpeed,
                  unit: .meter().unitDivided(by: .second()), options: .discreteAverage),
            .init(metric: .stairDescentSpeed, identifier: .stairDescentSpeed,
                  unit: .meter().unitDivided(by: .second()), options: .discreteAverage),
            .init(metric: .runningPower, identifier: .runningPower, unit: .watt(), options: .discreteAverage),
            .init(metric: .runningSpeed, identifier: .runningSpeed,
                  unit: .meter().unitDivided(by: .second()), options: .discreteAverage),
            .init(metric: .runningStrideLength, identifier: .runningStrideLength,
                  unit: .meterUnit(with: .centi), options: .discreteAverage),
            .init(metric: .runningVerticalOscillation, identifier: .runningVerticalOscillation,
                  unit: .meterUnit(with: .centi), options: .discreteAverage),
            .init(metric: .runningGroundContactTime, identifier: .runningGroundContactTime,
                  unit: .secondUnit(with: .milli), options: .discreteAverage),

            .init(metric: .dietaryEnergy, identifier: .dietaryEnergyConsumed,
                  unit: .kilocalorie(), options: .cumulativeSum),
            .init(metric: .dietaryProtein, identifier: .dietaryProtein,
                  unit: .gram(), options: .cumulativeSum),
            .init(metric: .dietaryCarbohydrates, identifier: .dietaryCarbohydrates,
                  unit: .gram(), options: .cumulativeSum),
            .init(metric: .dietaryFat, identifier: .dietaryFatTotal,
                  unit: .gram(), options: .cumulativeSum),
            .init(metric: .dietaryFibre, identifier: .dietaryFiber,
                  unit: .gram(), options: .cumulativeSum),
            .init(metric: .dietarySugar, identifier: .dietarySugar,
                  unit: .gram(), options: .cumulativeSum),
            .init(metric: .dietaryWater, identifier: .dietaryWater,
                  unit: .liter(), options: .cumulativeSum),
            .init(metric: .alcoholicDrinks, identifier: .numberOfAlcoholicBeverages,
                  unit: .count(), options: .cumulativeSum)
        ]
    }

    /// The sample types MyHealth writes. Logging on the Watch writes these, and
    /// they then reach the Mac through the ordinary iCloud Health sync rather
    /// than any private channel of our own.
    static var writeTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for identifier: HKQuantityTypeIdentifier in [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
            .dietaryFiber, .dietarySugar, .dietaryWater, .numberOfAlcoholicBeverages,
            .bodyMass, .waistCircumference
        ] {
            types.insert(HKQuantityType(identifier))
        }
        return types
    }

    private static var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for spec in quantitySpecs {
            types.insert(HKQuantityType(spec.identifier))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKCategoryType(.mindfulSession))
        types.insert(HKCategoryType(.appleStandHour))
        types.insert(HKWorkoutType.workoutType())
        types.insert(HKActivitySummaryType.activitySummaryType())
        types.insert(HKCharacteristicType(.dateOfBirth))
        types.insert(HKCharacteristicType(.biologicalSex))
        return types
    }

    /// Prompts for read access. HealthKit deliberately never tells an app which
    /// types were denied, so a run that comes back with no samples for a metric
    /// is indistinguishable from a metric you have no data for.
    public func requestAuthorization() async throws {
        guard HealthKitSource.availability.isUsable else {
            throw HealthKitError.unavailable(HealthKitSource.availability)
        }
        try await healthStore.requestAuthorization(toShare: HealthKitSource.writeTypes,
                                                  read: HealthKitSource.readTypes)
    }

    // MARK: - Building the database

    /// Reads everything from `start` up to today into a `HealthDatabase`.
    public func buildDatabase(from start: DayKey,
                              to end: DayKey = .today,
                              progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> HealthDatabase {
        guard HealthKitSource.availability.isUsable else {
            throw HealthKitError.unavailable(HealthKitSource.availability)
        }

        let calendar = Calendar.current
        let startDate = start.localDate(calendar: calendar)
        let endDate = calendar.date(byAdding: .day, value: 1, to: end.localDate(calendar: calendar)) ?? Date()

        var values: [Int: [Metric: Double]] = [:]
        func store(_ value: Double, _ metric: Metric, _ day: DayKey) {
            guard value.isFinite else { return }
            values[day.ordinal, default: [:]][metric] = value
        }

        let specs = HealthKitSource.quantitySpecs
        for (index, spec) in specs.enumerated() {
            progress?(ImportProgress(fraction: Double(index) / Double(specs.count + 3) * 0.8,
                                     message: "Reading \(spec.metric.title)…"))
            let daily = try await dailyStatistics(spec: spec, start: startDate, end: endDate, calendar: calendar)
            for (day, value) in daily { store(value, spec.metric, day) }
        }

        progress?(ImportProgress(fraction: 0.82, message: "Reading activity rings…"))
        for (day, ring) in try await activitySummaries(start: start, end: end, calendar: calendar) {
            if ring.activeEnergy > 0 { store(ring.activeEnergy, .activeEnergy, day) }
            if ring.exerciseMinutes > 0 { store(ring.exerciseMinutes, .exerciseMinutes, day) }
            if ring.standHours > 0 { store(ring.standHours, .standHours, day) }
        }

        progress?(ImportProgress(fraction: 0.88, message: "Reading sleep…"))
        for (day, hours) in try await sleepHours(start: startDate, end: endDate) {
            store(hours, .sleepHours, day)
        }

        progress?(ImportProgress(fraction: 0.92, message: "Reading workouts…"))
        let workouts = try await self.workouts(start: startDate, end: endDate)
        var workoutTotals: [Int: (count: Double, minutes: Double, energy: Double, distance: Double)] = [:]
        for workout in workouts {
            var entry = workoutTotals[workout.day.ordinal] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.minutes += workout.durationMinutes
            entry.energy += workout.energyKcal ?? 0
            entry.distance += workout.distanceKm ?? 0
            workoutTotals[workout.day.ordinal] = entry
        }
        for (ordinal, totals) in workoutTotals {
            let day = DayKey(ordinal: ordinal)
            store(totals.count, .workoutCount, day)
            store(totals.minutes, .workoutMinutes, day)
            if totals.energy > 0 { store(totals.energy, .workoutEnergy, day) }
            if totals.distance > 0 { store(totals.distance, .workoutDistance, day) }
        }

        let days = values
            .map { DailySummary(day: DayKey(ordinal: $0.key), values: $0.value) }
            .sorted { $0.day < $1.day }

        progress?(ImportProgress(fraction: 1, message: "Done"))
        var database = HealthDatabase(profile: readProfile(),
                                      days: days,
                                      workouts: workouts,
                                      exportedAt: Date(),
                                      sourceFileName: "HealthKit")
        database.importedAt = Date()
        return database
    }

    // MARK: - Queries

    /// Runs a daily statistics collection query.
    ///
    /// Cumulative types are split by source and the largest source is kept for
    /// each day rather than summing them: an iPhone in a pocket and a Watch on
    /// the wrist both log the same walk, and HealthKit's plain sum would count
    /// it twice.
    private func dailyStatistics(spec: QuantitySpec,
                                 start: Date,
                                 end: Date,
                                 calendar: Calendar) async throws -> [(DayKey, Double)] {
        let type = HKQuantityType(spec.identifier)
        let isCumulative = spec.options.contains(.cumulativeSum)
        var options = spec.options
        if isCumulative { options.insert(.separateBySource) }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        var interval = DateComponents()
        interval.day = 1

        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type,
                                                    quantitySamplePredicate: predicate,
                                                    options: options,
                                                    anchorDate: calendar.startOfDay(for: start),
                                                    intervalComponents: interval)
            query.initialResultsHandler = { _, results, error in
                if let results {
                    continuation.resume(returning: results)
                } else {
                    continuation.resume(throwing: HealthKitError.queryFailed(
                        error?.localizedDescription ?? "no results for \(spec.metric.rawValue)"))
                }
            }
            healthStore.execute(query)
        }

        var output: [(DayKey, Double)] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            let day = DayKey(date: statistics.startDate, calendar: calendar)
            let quantity: HKQuantity?
            if isCumulative {
                if let sources = statistics.sources, !sources.isEmpty {
                    var best: Double?
                    for source in sources {
                        guard let value = statistics.sumQuantity(for: source)?.doubleValue(for: spec.unit)
                        else { continue }
                        best = Swift.max(best ?? value, value)
                    }
                    if let best {
                        output.append((day, best * spec.scale))
                        return
                    }
                }
                quantity = statistics.sumQuantity()
            } else if spec.options.contains(.discreteMin) {
                quantity = statistics.minimumQuantity()
            } else if spec.options.contains(.discreteMax) {
                quantity = statistics.maximumQuantity()
            } else {
                quantity = statistics.averageQuantity()
            }
            if let quantity {
                output.append((day, quantity.doubleValue(for: spec.unit) * spec.scale))
            }
        }
        return output
    }

    private struct Ring {
        let activeEnergy: Double
        let exerciseMinutes: Double
        let standHours: Double
    }

    /// Apple's own activity rings, already de-duplicated across devices.
    private func activitySummaries(start: DayKey,
                                   end: DayKey,
                                   calendar: Calendar) async throws -> [(DayKey, Ring)] {
        var units = Set<Calendar.Component>([.year, .month, .day])
        units.insert(.era)
        let startComponents = calendar.dateComponents(units, from: start.localDate(calendar: calendar))
        let endComponents = calendar.dateComponents(units, from: end.localDate(calendar: calendar))
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComponents,
                                          end: endComponents)

        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, results, error in
                if let results {
                    continuation.resume(returning: results)
                } else {
                    continuation.resume(throwing: HealthKitError.queryFailed(
                        error?.localizedDescription ?? "activity summaries unavailable"))
                }
            }
            healthStore.execute(query)
        }

        return summaries.compactMap { summary in
            let components = summary.dateComponents(for: calendar)
            guard let year = components.year, let month = components.month, let day = components.day
            else { return nil }
            let energy = summary.activeEnergyBurned.doubleValue(for: .kilocalorie())
            let exercise = summary.appleExerciseTime.doubleValue(for: .minute())
            let stand = summary.appleStandHours.doubleValue(for: .count())
            return (DayKey(year: year, month: month, day: day),
                    Ring(activeEnergy: energy, exerciseMinutes: exercise, standHours: stand))
        }
    }

    /// Asleep time, filed under the morning you woke up.
    private func sleepHours(start: Date, end: Date) async throws -> [(DayKey, Double)] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, error in
                if let results {
                    continuation.resume(returning: results)
                } else {
                    continuation.resume(throwing: HealthKitError.queryFailed(
                        error?.localizedDescription ?? "sleep unavailable"))
                }
            }
            healthStore.execute(query)
        }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        // Per source, then take the largest source for each night so a Watch and
        // a third-party sleep tracker do not stack.
        var perSource: [Int: [String: Double]] = [:]
        for sample in samples {
            guard let categorySample = sample as? HKCategorySample,
                  asleepValues.contains(categorySample.value) else { continue }
            let hours = categorySample.endDate.timeIntervalSince(categorySample.startDate) / 3600
            guard hours > 0 else { continue }
            let wakeDay = DayKey(date: categorySample.endDate)
            let source = categorySample.sourceRevision.source.bundleIdentifier
            perSource[wakeDay.ordinal, default: [:]][source, default: 0] += hours
        }
        return perSource.compactMap { ordinal, bySource in
            guard let best = bySource.values.max() else { return nil }
            return (DayKey(ordinal: ordinal), best)
        }
    }

    private func workouts(start: Date, end: Date) async throws -> [WorkoutSummary] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKWorkoutType.workoutType(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                         ascending: true)]) { _, results, error in
                if let results {
                    continuation.resume(returning: results)
                } else {
                    continuation.resume(throwing: HealthKitError.queryFailed(
                        error?.localizedDescription ?? "workouts unavailable"))
                }
            }
            healthStore.execute(query)
        }

        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            let distance = HealthKitSource.distanceKilometres(of: workout)
            let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
            let bpm = HKUnit.count().unitDivided(by: .minute())

            return WorkoutSummary(
                day: DayKey(date: workout.startDate),
                start: workout.startDate.timeIntervalSince1970,
                durationMinutes: workout.duration / 60,
                energyKcal: energy,
                distanceKm: distance,
                averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
                maxHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
                activity: WorkoutActivity(rawValue: HealthKitSource.name(for: workout.workoutActivityType)),
                sourceName: workout.sourceRevision.source.name)
        }
    }

    private static func distanceKilometres(of workout: HKWorkout) -> Double? {
        let identifiers: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
            .distanceWheelchair, .distanceDownhillSnowSports, .distanceCrossCountrySkiing,
            .distanceRowing, .distancePaddleSports, .distanceSkatingSports
        ]
        for identifier in identifiers {
            if let sum = workout.statistics(for: HKQuantityType(identifier))?.sumQuantity() {
                let value = sum.doubleValue(for: .meterUnit(with: .kilo))
                if value > 0 { return value }
            }
        }
        return nil
    }

    private func readProfile() -> UserProfile {
        var profile = UserProfile()
        if let components = try? healthStore.dateOfBirthComponents(),
           let year = components.year, let month = components.month, let day = components.day {
            profile.dateOfBirth = DayKey(year: year, month: month, day: day)
        }
        if let sex = try? healthStore.biologicalSex().biologicalSex {
            switch sex {
            case .male: profile.biologicalSex = .male
            case .female: profile.biologicalSex = .female
            case .other: profile.biologicalSex = .other
            default: profile.biologicalSex = .unknown
            }
        }
        return profile
    }

    /// HealthKit's activity types are a C enum; this gives them the same names
    /// the XML export uses so both import paths produce identical data.
    static func name(for activityType: HKWorkoutActivityType) -> String {
        switch activityType {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "StairClimbing"
        case .stairs: return "Stairs"
        case .highIntensityIntervalTraining: return "HighIntensityIntervalTraining"
        case .traditionalStrengthTraining: return "TraditionalStrengthTraining"
        case .functionalStrengthTraining: return "FunctionalStrengthTraining"
        case .coreTraining: return "CoreTraining"
        case .crossTraining: return "CrossTraining"
        case .flexibility: return "Flexibility"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .mindAndBody: return "MindAndBody"
        case .cooldown: return "Cooldown"
        case .preparationAndRecovery: return "PreparationAndRecovery"
        case .dance, .cardioDance, .socialDance: return "Dance"
        case .boxing: return "Boxing"
        case .kickboxing: return "Kickboxing"
        case .martialArts: return "MartialArts"
        case .climbing: return "Climbing"
        case .golf: return "Golf"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .tableTennis: return "TableTennis"
        case .squash: return "Squash"
        case .racquetball: return "Racquetball"
        case .pickleball: return "Pickleball"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .americanFootball: return "AmericanFootball"
        case .rugby: return "Rugby"
        case .hockey: return "Hockey"
        case .baseball: return "Baseball"
        case .cricket: return "Cricket"
        case .volleyball: return "Volleyball"
        case .skatingSports: return "SkatingSports"
        case .snowboarding: return "Snowboarding"
        case .downhillSkiing: return "DownhillSkiing"
        case .crossCountrySkiing: return "CrossCountrySkiing"
        case .surfingSports: return "SurfingSports"
        case .paddleSports: return "PaddleSports"
        case .sailing: return "Sailing"
        case .waterFitness, .waterSports, .waterPolo: return "WaterSports"
        case .fishing: return "Fishing"
        case .hunting: return "Hunting"
        case .equestrianSports: return "EquestrianSports"
        case .fitnessGaming: return "FitnessGaming"
        case .wheelchairWalkPace, .wheelchairRunPace: return "Wheelchair"
        case .barre: return "Barre"
        case .jumpRope: return "JumpRope"
        case .play: return "Play"
        case .taiChi: return "TaiChi"
        case .mixedCardio: return "MixedCardio"
        case .handCycling: return "HandCycling"
        case .discSports: return "DiscSports"
        case .archery: return "Archery"
        case .bowling: return "Bowling"
        case .curling: return "Curling"
        case .gymnastics: return "Gymnastics"
        case .trackAndField: return "TrackAndField"
        case .wrestling: return "Wrestling"
        case .swimBikeRun: return "SwimBikeRun"
        case .transition: return "Transition"
        case .underwaterDiving: return "UnderwaterDiving"
        case .other: return "Other"
        @unknown default: return "Other"
        }
    }
}

#endif
