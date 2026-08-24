import Foundation

/// Progress reported while chewing through a Health export.
public struct ImportProgress: Sendable {
    public let fraction: Double
    public let message: String
    public let recordsProcessed: Int

    public init(fraction: Double, message: String, recordsProcessed: Int = 0) {
        self.fraction = fraction
        self.message = message
        self.recordsProcessed = recordsProcessed
    }
}

public enum ImportError: LocalizedError {
    case fileNotFound(URL)
    case notAHealthExport
    case parseFailed(String)
    case cancelled
    case noDataFound

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Could not read \(url.lastPathComponent)."
        case .notAHealthExport:
            return "That file does not look like an Apple Health export. Choose the export.zip that Health creates, or the export.xml inside it."
        case .parseFailed(let detail):
            return "The Health export could not be read: \(detail)"
        case .cancelled:
            return "Import cancelled."
        case .noDataFound:
            return "The export parsed, but contained no health records."
        }
    }
}

/// Streams `export.xml` and folds it into daily summaries.
///
/// The export for an active user runs to millions of `<Record>` elements and
/// several gigabytes, so nothing is ever held in memory except the running
/// per-day accumulators — a few thousand entries regardless of history length.
public final class HealthExportParser: NSObject {

    private struct RunningStat {
        var total = 0.0
        var count = 0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var last = 0.0

        mutating func add(_ value: Double) {
            total += value
            count += 1
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
            last = value
        }

        var mean: Double? { count > 0 ? total / Double(count) : nil }
    }

    private final class DayAccumulator {
        /// metric -> source id -> summed value, kept per source so overlapping
        /// devices can be de-duplicated at finalise time.
        var sums: [Metric: [Int32: Double]] = [:]
        var stats: [Metric: RunningStat] = [:]
        var summaryActiveEnergy: Double?
        var summaryExerciseMinutes: Double?
        var summaryStandHours: Double?
        var workoutMinutes = 0.0
        var workoutEnergy = 0.0
        var workoutDistance = 0.0
        var workoutCount = 0.0
    }

    private struct WorkoutDraft {
        var day: DayKey
        var start: Double
        var end: Double
        var durationMinutes: Double
        var activity: WorkoutActivity
        var sourceName: String
        var energyKcal: Double?
        var distanceKm: Double?
        var averageHeartRate: Double?
        var maxHeartRate: Double?
    }

    private let fileURL: URL
    private let progressHandler: (@Sendable (ImportProgress) -> Void)?
    private let isCancelled: (@Sendable () -> Bool)?

    private var days: [Int: DayAccumulator] = [:]
    private var workouts: [WorkoutSummary] = []
    private var currentWorkout: WorkoutDraft?
    private var profile = UserProfile()
    private var exportedAt: Date?

    private var sourceIDs: [String: Int32] = [:]
    private var nextSourceID: Int32 = 0

    private var recordCount = 0
    private var estimatedLines = 1.0
    private var lastReportedRecordCount = 0
    private var parseErrorMessage: String?
    private var sawHealthDataRoot = false
    private var cancelledDuringParse = false

    public init(fileURL: URL,
                progress: (@Sendable (ImportProgress) -> Void)? = nil,
                isCancelled: (@Sendable () -> Bool)? = nil) {
        self.fileURL = fileURL
        self.progressHandler = progress
        self.isCancelled = isCancelled
    }

    public func parse() throws -> HealthDatabase {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ImportError.fileNotFound(fileURL)
        }
        estimatedLines = HealthExportParser.estimateLineCount(of: fileURL)

        guard let parser = XMLParser(contentsOf: fileURL) else {
            throw ImportError.fileNotFound(fileURL)
        }
        parser.delegate = self
        parser.shouldResolveExternalEntities = false

        progressHandler?(ImportProgress(fraction: 0, message: "Reading export…"))
        let succeeded = parser.parse()

        if cancelledDuringParse { throw ImportError.cancelled }
        if !sawHealthDataRoot { throw ImportError.notAHealthExport }

        // A malformed tail is common in large exports. Everything parsed up to
        // that point is still good data, so keep it rather than failing outright.
        if !succeeded, days.isEmpty, workouts.isEmpty {
            throw ImportError.parseFailed(parseErrorMessage ?? "unknown error")
        }

        progressHandler?(ImportProgress(fraction: 0.95,
                                        message: "Summarising \(days.count) days…",
                                        recordsProcessed: recordCount))

        let summaries = finaliseDays()
        guard !summaries.isEmpty || !workouts.isEmpty else { throw ImportError.noDataFound }

        var database = HealthDatabase(profile: profile,
                                      days: summaries,
                                      workouts: workouts,
                                      exportedAt: exportedAt,
                                      sourceFileName: fileURL.lastPathComponent)
        database.importedAt = Date()
        progressHandler?(ImportProgress(fraction: 1, message: "Done", recordsProcessed: recordCount))
        return database
    }

    // MARK: - Finalising

    private func finaliseDays() -> [DailySummary] {
        var result: [DailySummary] = []
        result.reserveCapacity(days.count)

        for (ordinal, accumulator) in days {
            var values: [Metric: Double] = [:]

            // Additive metrics: sum within a source, then take the largest
            // source rather than adding sources together. An iPhone in a pocket
            // and a Watch on the wrist both record steps for the same walk, and
            // adding them would roughly double every number in the app.
            for (metric, bySource) in accumulator.sums {
                guard let best = bySource.values.max() else { continue }
                values[metric] = best
            }

            for (metric, stat) in accumulator.stats {
                switch metric.aggregation {
                case .minimum:
                    if stat.count > 0 { values[metric] = stat.minimum }
                case .maximum:
                    if stat.count > 0 { values[metric] = stat.maximum }
                case .latest:
                    if stat.count > 0 { values[metric] = stat.last }
                default:
                    if let mean = stat.mean { values[metric] = mean }
                }
            }

            // Apple's own daily rings are already de-duplicated across devices,
            // so they win over anything reconstructed from raw records.
            if let energy = accumulator.summaryActiveEnergy, energy > 0 {
                values[.activeEnergy] = energy
            }
            if let exercise = accumulator.summaryExerciseMinutes, exercise > 0 {
                values[.exerciseMinutes] = exercise
            }
            if let stand = accumulator.summaryStandHours, stand > 0 {
                values[.standHours] = stand
            }

            if accumulator.workoutCount > 0 {
                values[.workoutCount] = accumulator.workoutCount
                values[.workoutMinutes] = accumulator.workoutMinutes
                if accumulator.workoutEnergy > 0 { values[.workoutEnergy] = accumulator.workoutEnergy }
                if accumulator.workoutDistance > 0 { values[.workoutDistance] = accumulator.workoutDistance }
            }

            guard !values.isEmpty else { continue }
            result.append(DailySummary(day: DayKey(ordinal: ordinal), values: values))
        }

        result.sort { $0.day < $1.day }
        return result
    }

    // MARK: - Accumulation helpers

    private func accumulator(for day: DayKey) -> DayAccumulator {
        if let existing = days[day.ordinal] { return existing }
        let fresh = DayAccumulator()
        days[day.ordinal] = fresh
        return fresh
    }

    private func sourceID(_ name: String) -> Int32 {
        if let existing = sourceIDs[name] { return existing }
        let id = nextSourceID
        nextSourceID += 1
        sourceIDs[name] = id
        return id
    }

    private func addSum(_ value: Double, metric: Metric, day: DayKey, source: Int32) {
        guard value.isFinite else { return }
        let bucket = accumulator(for: day)
        bucket.sums[metric, default: [:]][source, default: 0] += value
    }

    private func addStat(_ value: Double, metric: Metric, day: DayKey) {
        guard value.isFinite else { return }
        let bucket = accumulator(for: day)
        var stat = bucket.stats[metric] ?? RunningStat()
        stat.add(value)
        bucket.stats[metric] = stat
    }

    // MARK: - Line estimate for progress

    /// Health exports are one element per line, so sampling the average line
    /// length off the front of the file gives a good enough denominator for a
    /// progress bar without a full pre-pass over several gigabytes.
    static func estimateLineCount(of url: URL) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return 1 }
        defer { try? handle.close() }
        let sampleSize = 4 * 1024 * 1024
        let sample = (try? handle.read(upToCount: sampleSize)) ?? Data()
        guard !sample.isEmpty else { return 1 }
        var newlines = 0
        sample.withUnsafeBytes { raw in
            for byte in raw where byte == 0x0A { newlines += 1 }
        }
        guard newlines > 0 else { return 1 }
        let averageLineLength = Double(sample.count) / Double(newlines)
        return Swift.max(1, size / averageLineLength)
    }

    private func reportProgress(_ parser: XMLParser) {
        guard recordCount - lastReportedRecordCount >= 50_000 else { return }
        lastReportedRecordCount = recordCount
        let fraction = (Double(parser.lineNumber) / estimatedLines).clamped(to: 0...0.94)
        let formatted = HealthExportParser.groupedNumber(recordCount)
        progressHandler?(ImportProgress(fraction: fraction,
                                        message: "Reading \(formatted) records…",
                                        recordsProcessed: recordCount))
    }

    static func groupedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - XMLParserDelegate

extension HealthExportParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName: String?,
                       attributes: [String: String]) {
        if let isCancelled, isCancelled() {
            cancelledDuringParse = true
            parser.abortParsing()
            return
        }

        switch elementName {
        case "Record":
            recordCount += 1
            handleRecord(attributes)
            reportProgress(parser)
        case "Workout":
            recordCount += 1
            beginWorkout(attributes)
        case "WorkoutStatistics":
            handleWorkoutStatistics(attributes)
        case "ActivitySummary":
            handleActivitySummary(attributes)
        case "Me":
            handleProfile(attributes)
        case "ExportDate":
            if let value = attributes["value"], let seconds = ExportTimestamp.epochSeconds(value) {
                exportedAt = Date(timeIntervalSince1970: seconds)
            }
        case "HealthData":
            sawHealthDataRoot = true
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName: String?) {
        if elementName == "Workout" { endWorkout() }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseErrorMessage = parseError.localizedDescription
    }

    // MARK: Records

    private func handleRecord(_ attributes: [String: String]) {
        guard let type = attributes["type"],
              let startDate = attributes["startDate"],
              let day = DayKey(exportPrefix: startDate)
        else { return }

        let identifier = HealthKitMapping.strip(type)
        let source = sourceID(attributes["sourceName"] ?? "unknown")

        if type.hasPrefix("HKCategoryTypeIdentifier") {
            handleCategoryRecord(identifier: identifier, attributes: attributes, day: day, source: source)
            return
        }

        guard let rawValue = attributes["value"], let value = Double(rawValue) else { return }
        let unit = attributes["unit"] ?? ""

        if identifier == HealthKitMapping.heartRateIdentifier {
            let bpm = HealthKitMapping.normalise(value, unit: unit, for: .heartRateAverage)
            addStat(bpm, metric: .heartRateAverage, day: day)
            addStat(bpm, metric: .heartRateMin, day: day)
            addStat(bpm, metric: .heartRateMax, day: day)
            return
        }

        guard let metric = HealthKitMapping.metric(forQuantityIdentifier: type) else { return }
        let normalised = HealthKitMapping.normalise(value, unit: unit, for: metric)

        if metric.aggregation == .sum {
            addSum(normalised, metric: metric, day: day, source: source)
        } else {
            addStat(normalised, metric: metric, day: day)
        }
    }

    private func handleCategoryRecord(identifier: String,
                                      attributes: [String: String],
                                      day: DayKey,
                                      source: Int32) {
        switch identifier {
        case "SleepAnalysis":
            guard let value = attributes["value"], value.contains("Asleep"),
                  let start = attributes["startDate"].flatMap(ExportTimestamp.epochSeconds),
                  let end = attributes["endDate"].flatMap(ExportTimestamp.epochSeconds),
                  end > start
            else { return }
            // A night is filed under the morning you woke up, matching how the
            // Health app presents "last night's sleep".
            let wakeDay = attributes["endDate"].flatMap(DayKey.init(exportPrefix:)) ?? day
            addSum((end - start) / 3600, metric: .sleepHours, day: wakeDay, source: source)

        case "AppleStandHour":
            guard let value = attributes["value"], value.hasSuffix("Stood") else { return }
            addSum(1, metric: .standHours, day: day, source: source)

        case "MindfulSession":
            guard let start = attributes["startDate"].flatMap(ExportTimestamp.epochSeconds),
                  let end = attributes["endDate"].flatMap(ExportTimestamp.epochSeconds),
                  end > start
            else { return }
            addSum((end - start) / 60, metric: .mindfulMinutes, day: day, source: source)

        default:
            break
        }
    }

    // MARK: Activity summaries

    private func handleActivitySummary(_ attributes: [String: String]) {
        guard let dateComponents = attributes["dateComponents"],
              let day = DayKey(exportPrefix: dateComponents)
        else { return }
        let bucket = accumulator(for: day)

        if let raw = attributes["activeEnergyBurned"], let value = Double(raw) {
            let unit = attributes["activeEnergyBurnedUnit"] ?? "kcal"
            bucket.summaryActiveEnergy = HealthKitMapping.normalise(value, unit: unit, for: .activeEnergy)
        }
        if let raw = attributes["appleExerciseTime"], let value = Double(raw) {
            let unit = attributes["appleExerciseTimeUnit"] ?? "min"
            bucket.summaryExerciseMinutes = HealthKitMapping.normalise(value, unit: unit, for: .exerciseMinutes)
        }
        if let raw = attributes["appleStandHours"], let value = Double(raw) {
            bucket.summaryStandHours = value
        }
        if let raw = attributes["appleMoveTime"], let value = Double(raw), value > 0 {
            // Additive metric, so it belongs in the de-duplicated sum bucket
            // rather than the running-statistics one.
            addSum(value, metric: .moveMinutes, day: day, source: sourceID("ActivitySummary"))
        }
    }

    private func handleProfile(_ attributes: [String: String]) {
        if let dob = attributes["HKCharacteristicTypeIdentifierDateOfBirth"], !dob.isEmpty {
            profile.dateOfBirth = DayKey(exportPrefix: dob)
        }
        if let sex = attributes["HKCharacteristicTypeIdentifierBiologicalSex"] {
            profile.biologicalSex = BiologicalSex(healthKitValue: sex)
        }
    }

    // MARK: Workouts

    private func beginWorkout(_ attributes: [String: String]) {
        guard let startRaw = attributes["startDate"],
              let day = DayKey(exportPrefix: startRaw),
              let start = ExportTimestamp.epochSeconds(startRaw)
        else { return }

        let end = attributes["endDate"].flatMap(ExportTimestamp.epochSeconds) ?? start
        var minutes = 0.0
        if let raw = attributes["duration"], let value = Double(raw) {
            minutes = HealthKitMapping.normalise(value, unit: attributes["durationUnit"] ?? "min", for: .workoutMinutes)
        } else if end > start {
            minutes = (end - start) / 60
        }

        var draft = WorkoutDraft(day: day,
                                 start: start,
                                 end: end,
                                 durationMinutes: minutes,
                                 activity: WorkoutActivity(identifier: attributes["workoutActivityType"] ?? ""),
                                 sourceName: attributes["sourceName"] ?? "Unknown")

        // iOS 15 and earlier put totals on the element itself; iOS 16+ moved
        // them into child <WorkoutStatistics> elements, so support both.
        if let raw = attributes["totalEnergyBurned"], let value = Double(raw) {
            draft.energyKcal = HealthKitMapping.normalise(value,
                                                          unit: attributes["totalEnergyBurnedUnit"] ?? "kcal",
                                                          for: .workoutEnergy)
        }
        if let raw = attributes["totalDistance"], let value = Double(raw), value > 0 {
            draft.distanceKm = HealthKitMapping.normalise(value,
                                                          unit: attributes["totalDistanceUnit"] ?? "km",
                                                          for: .workoutDistance)
        }
        currentWorkout = draft
    }

    private func handleWorkoutStatistics(_ attributes: [String: String]) {
        guard var draft = currentWorkout, let type = attributes["type"] else { return }
        let identifier = HealthKitMapping.strip(type)
        let unit = attributes["unit"] ?? ""

        switch identifier {
        case "ActiveEnergyBurned":
            if let raw = attributes["sum"], let value = Double(raw) {
                draft.energyKcal = HealthKitMapping.normalise(value, unit: unit, for: .workoutEnergy)
            }
        case "DistanceWalkingRunning", "DistanceCycling", "DistanceSwimming",
             "DistanceWheelchair", "DistanceDownhillSnowSports":
            if let raw = attributes["sum"], let value = Double(raw), value > 0 {
                draft.distanceKm = HealthKitMapping.normalise(value, unit: unit, for: .workoutDistance)
            }
        case "HeartRate":
            if let raw = attributes["average"], let value = Double(raw) {
                draft.averageHeartRate = value
            }
            if let raw = attributes["maximum"], let value = Double(raw) {
                draft.maxHeartRate = value
            }
        default:
            break
        }
        currentWorkout = draft
    }

    private func endWorkout() {
        guard let draft = currentWorkout else { return }
        currentWorkout = nil
        guard draft.durationMinutes > 0 else { return }

        workouts.append(WorkoutSummary(day: draft.day,
                                       start: draft.start,
                                       durationMinutes: draft.durationMinutes,
                                       energyKcal: draft.energyKcal,
                                       distanceKm: draft.distanceKm,
                                       averageHeartRate: draft.averageHeartRate,
                                       maxHeartRate: draft.maxHeartRate,
                                       activity: draft.activity,
                                       sourceName: draft.sourceName))

        let bucket = accumulator(for: draft.day)
        bucket.workoutCount += 1
        bucket.workoutMinutes += draft.durationMinutes
        bucket.workoutEnergy += draft.energyKcal ?? 0
        bucket.workoutDistance += draft.distanceKm ?? 0
    }
}
