import Foundation

/// The local record of what was eaten, drunk and where.
///
/// The nutrition itself is written to HealthKit so it flows through the normal
/// sync path, but HealthKit has nowhere to put "a pint of Guinness at The
/// Eagle", and that context is the whole point of the feature. So the log keeps
/// names and occasions alongside.
public struct FoodLog: Codable, Sendable {
    public var entries: [FoodEntry]
    public var occasions: [MealOccasion]
    public var favourites: [String]

    public init(entries: [FoodEntry] = [], occasions: [MealOccasion] = [], favourites: [String] = []) {
        self.entries = entries
        self.occasions = occasions
        self.favourites = favourites
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func add(_ entry: FoodEntry, to occasion: MealOccasion? = nil) {
        entries.append(entry)
        entries.sort { $0.timestamp < $1.timestamp }
        if var occasion {
            if let index = occasions.firstIndex(where: { $0.id == occasion.id }) {
                occasions[index].entryIDs.append(entry.id)
            } else {
                occasion.entryIDs.append(entry.id)
                occasions.append(occasion)
                occasions.sort { $0.start < $1.start }
            }
        }
    }

    public mutating func remove(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        for index in occasions.indices {
            occasions[index].entryIDs.removeAll { $0 == entryID }
        }
        occasions.removeAll { $0.entryIDs.isEmpty }
    }

    public func entries(on day: DayKey) -> [FoodEntry] {
        entries.filter { $0.day == day }
    }

    public func total(on day: DayKey) -> Nutrition {
        entries(on: day).reduce(Nutrition.empty) { $0 + $1.total }
    }

    /// The context for a day, taking the most calorie-heavy occasion as the one
    /// that characterises it.
    public func dominantContext(on day: DayKey) -> MealOccasion? {
        let candidates = occasions.filter { $0.day == day }
        guard !candidates.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return candidates.max { lhs, rhs in
            let lhsCalories = lhs.entryIDs.compactMap { byID[$0]?.total.kilocalories }.reduce(0, +)
            let rhsCalories = rhs.entryIDs.compactMap { byID[$0]?.total.kilocalories }.reduce(0, +)
            return lhsCalories < rhsCalories
        }
    }

    /// Rolls the log up into the same daily metrics the rest of the app speaks,
    /// so logged food and drink can be trended and correlated exactly like
    /// anything HealthKit supplies.
    public func dailyMetrics() -> [Int: [Metric: Double]] {
        var result: [Int: [Metric: Double]] = [:]
        var totals: [Int: Nutrition] = [:]
        for entry in entries {
            let ordinal = entry.day.ordinal
            totals[ordinal] = (totals[ordinal] ?? .empty) + entry.total
        }
        for (ordinal, nutrition) in totals {
            var values: [Metric: Double] = [
                .dietaryEnergy: nutrition.kilocalories,
                .dietaryProtein: nutrition.proteinGrams,
                .dietaryCarbohydrates: nutrition.carbohydrateGrams,
                .dietaryFat: nutrition.fatGrams,
                .alcoholGrams: nutrition.alcoholGrams
            ]
            if nutrition.fibreGrams > 0 { values[.dietaryFibre] = nutrition.fibreGrams }
            if nutrition.sugarGrams > 0 { values[.dietarySugar] = nutrition.sugarGrams }
            if nutrition.alcoholGrams > 0 {
                values[.alcoholicDrinks] = AlcoholUnits.standardDrinks(grams: nutrition.alcoholGrams)
            }
            result[ordinal] = values
        }
        return result
    }

    /// Most-logged items, for the Watch's one-tap list.
    public func mostFrequent(limit: Int = 12) -> [String] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.name, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }
}

/// Reads and writes the food log next to the health database.
public struct FoodLogStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let folder = base.appendingPathComponent("MyHealth", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("food-log.json")
    }

    public func load() throws -> FoodLog? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(FoodLog.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ log: FoodLog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(log).write(to: fileURL, options: .atomic)
    }
}
