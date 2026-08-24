import Foundation

/// Everything MyHealth knows, in one value type.
///
/// Small enough to hold in memory (a decade of data is a few thousand
/// `DailySummary` values) and to persist as a single binary property list, so
/// there is no database engine, no migration story and no partial-write window.
public struct HealthDatabase: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profile: UserProfile
    /// Sorted ascending by day.
    public var days: [DailySummary]
    /// Sorted ascending by start time.
    public var workouts: [WorkoutSummary]
    public var importedAt: Date
    public var exportedAt: Date?
    public var sourceFileName: String?

    public init(profile: UserProfile = UserProfile(),
                days: [DailySummary] = [],
                workouts: [WorkoutSummary] = [],
                importedAt: Date = Date(),
                exportedAt: Date? = nil,
                sourceFileName: String? = nil) {
        self.schemaVersion = HealthDatabase.currentSchemaVersion
        self.profile = profile
        self.days = days.sorted { $0.day < $1.day }
        self.workouts = workouts.sorted { $0.start < $1.start }
        self.importedAt = importedAt
        self.exportedAt = exportedAt
        self.sourceFileName = sourceFileName
    }

    public var isEmpty: Bool { days.isEmpty && workouts.isEmpty }

    public var dateRange: ClosedRange<DayKey>? {
        guard let first = days.first?.day, let last = days.last?.day else { return nil }
        return first...last
    }

    /// Day-indexed lookup, built once and reused by the analytics layer.
    public func indexed() -> [Int: DailySummary] {
        var map = [Int: DailySummary](minimumCapacity: days.count)
        for d in days { map[d.day.ordinal] = d }
        return map
    }

    /// All non-nil values for a metric, ascending by day.
    public func series(_ metric: Metric, in range: ClosedRange<DayKey>? = nil) -> TimeSeries {
        var points: [TimeSeries.Point] = []
        points.reserveCapacity(days.count)
        for summary in days {
            if let range, !range.contains(summary.day) { continue }
            if let value = summary.values[metric] {
                points.append(.init(day: summary.day, value: value))
            }
        }
        return TimeSeries(metric: metric, points: points)
    }

    /// Folds locally logged food and drink into the daily summaries.
    ///
    /// The log wins over HealthKit for these metrics: an entry logged here is
    /// the original, and the HealthKit copy is what this app wrote out from it.
    public func merging(_ log: FoodLog) -> HealthDatabase {
        let derived = log.dailyMetrics()
        guard !derived.isEmpty else { return self }

        var byOrdinal: [Int: DailySummary] = [:]
        for summary in days { byOrdinal[summary.day.ordinal] = summary }
        for (ordinal, values) in derived {
            var summary = byOrdinal[ordinal] ?? DailySummary(day: DayKey(ordinal: ordinal))
            for (metric, value) in values { summary.values[metric] = value }
            byOrdinal[ordinal] = summary
        }

        var copy = self
        copy.days = byOrdinal.values.sorted { $0.day < $1.day }
        return copy
    }

    /// Metrics that actually carry data, in a stable order — used to build the
    /// Trends picker so it only offers things worth looking at.
    public func availableMetrics(minimumDays: Int = 5) -> [Metric] {
        var counts: [Metric: Int] = [:]
        for summary in days {
            for (metric, value) in summary.values where value.isFinite {
                counts[metric, default: 0] += 1
            }
        }
        return Metric.allCases.filter { (counts[$0] ?? 0) >= minimumDays }
    }
}

/// Reads and writes the database to Application Support.
public struct HealthStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let folder = base.appendingPathComponent("MyHealth", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("health-database.plist")
    }

    public func load() throws -> HealthDatabase? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = PropertyListDecoder()
        return try decoder.decode(HealthDatabase.self, from: data)
    }

    public func save(_ database: HealthDatabase) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(database)
        // Write beside the target and swap, so an interrupted save can never
        // leave a half-written database behind.
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent("health-database-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
