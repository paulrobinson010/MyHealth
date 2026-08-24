import XCTest
@testable import HealthCore

final class AlcoholTests: XCTestCase {

    func testEthanolFromVolumeAndStrength() {
        // A UK pint of 4.5% lager: 568 mL × 4.5% × 0.789 g/mL ≈ 20.2 g.
        let grams = AlcoholUnits.grams(millilitres: 568, abvPercent: 4.5)
        XCTAssertEqual(grams, 20.16, accuracy: 0.1)
        // Which is about 2.6 UK units — the pub answer of "2.5 units" rounded.
        XCTAssertEqual(AlcoholUnits.ukUnits(grams: grams), 2.55, accuracy: 0.05)
    }

    func testUnitConventionsDoNotGetMixedUp() {
        // The same drink counted three ways. Confusing these throws a night out
        // off by a factor of two.
        let grams = AlcoholUnits.grams(ukUnits: 10)
        XCTAssertEqual(grams, 78.93, accuracy: 0.01)
        XCTAssertEqual(AlcoholUnits.standardDrinks(grams: grams), 5.64, accuracy: 0.01)
        XCTAssertEqual(AlcoholUnits.ukUnits(grams: grams), 10, accuracy: 1e-9)
    }

    func testDrinkPresetCaloriesIncludeTheEthanol() {
        let pint = DrinkPreset(name: "Test pint", millilitres: 568, abvPercent: 4.5,
                               residualKilocalories: 40)
        // 20.16 g × 7 kcal/g + 40 residual ≈ 181 kcal, which is the right ballpark.
        XCTAssertEqual(pint.nutrition.kilocalories, 181, accuracy: 2)
        XCTAssertEqual(pint.nutrition.alcoholGrams, 20.16, accuracy: 0.1)
    }

    func testAlcoholShareOfCalories() {
        let nutrition = Nutrition(kilocalories: 700, alcoholGrams: 50)
        XCTAssertEqual(nutrition.alcoholKilocalories, 350, accuracy: 1e-9)
        XCTAssertEqual(nutrition.alcoholShareOfCalories, 0.5, accuracy: 1e-9)
    }
}

final class FoodLogTests: XCTestCase {

    private func entry(_ name: String, day: DayKey, kcal: Double,
                       alcohol: Double = 0, servings: Double = 1) -> FoodEntry {
        FoodEntry(name: name,
                  timestamp: day.localDate().timeIntervalSince1970 + 12 * 3600,
                  servings: servings,
                  nutrition: Nutrition(kilocalories: kcal, proteinGrams: 10,
                                       carbohydrateGrams: 20, fatGrams: 5,
                                       alcoholGrams: alcohol))
    }

    func testServingsScaleTheWholeEntry() {
        let day = DayKey(year: 2024, month: 5, day: 1)
        let doubled = entry("Pint", day: day, kcal: 180, alcohol: 20, servings: 3)
        XCTAssertEqual(doubled.total.kilocalories, 540, accuracy: 1e-9)
        XCTAssertEqual(doubled.total.alcoholGrams, 60, accuracy: 1e-9)
    }

    func testDailyTotalsAndMetricRollup() {
        let day = DayKey(year: 2024, month: 5, day: 1)
        var log = FoodLog()
        log.add(entry("Curry", day: day, kcal: 900))
        log.add(entry("Pint", day: day, kcal: 180, alcohol: 20, servings: 3))

        let total = log.total(on: day)
        XCTAssertEqual(total.kilocalories, 1_440, accuracy: 1e-9)
        XCTAssertEqual(total.alcoholGrams, 60, accuracy: 1e-9)

        let metrics = log.dailyMetrics()[day.ordinal]
        XCTAssertEqual(metrics?[.dietaryEnergy], 1_440)
        XCTAssertEqual(metrics?[.alcoholGrams], 60)
        // Stored for HealthKit as US standard drinks, not UK units.
        XCTAssertEqual(try XCTUnwrap(metrics?[.alcoholicDrinks]), 60 / 14, accuracy: 1e-9)
    }

    func testRemovingAnEntryAlsoTidiesItsOccasion() {
        let day = DayKey(year: 2024, month: 5, day: 1)
        var log = FoodLog()
        let item = entry("Pint", day: day, kcal: 180, alcohol: 20)
        let occasion = MealOccasion(context: .pub, evidence: .inferred, start: item.timestamp)
        log.add(item, to: occasion)
        XCTAssertEqual(log.occasions.count, 1)

        log.remove(entryID: item.id)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(log.occasions.isEmpty, "an occasion with no entries should not survive")
    }

    func testMergingIntoTheDatabaseLetsFoodBeTrendedLikeAnythingElse() {
        let day = DayKey(year: 2024, month: 5, day: 1)
        var log = FoodLog()
        log.add(entry("Curry", day: day, kcal: 900))

        let database = HealthDatabase(days: [
            DailySummary(day: day, values: [.steps: 9_000])
        ])
        let merged = database.merging(log)
        let summary = merged.days.first { $0.day == day }
        XCTAssertEqual(summary?[.steps], 9_000, "existing metrics must survive the merge")
        XCTAssertEqual(summary?[.dietaryEnergy], 900)
    }
}

final class LogSyncTests: XCTestCase {

    final class MemoryStore: LogSyncBacking {
        var storage: [String: Data] = [:]
        func syncedData(forKey key: String) -> Data? { storage[key] }
        func setSyncedData(_ data: Data?, forKey key: String) { storage[key] = data }
        func pushChanges() -> Bool { true }
    }

    private func entry(daysAgo: Int, from today: DayKey) -> FoodEntry {
        FoodEntry(name: "Item \(daysAgo)",
                  timestamp: today.adding(days: -daysAgo).localDate().timeIntervalSince1970 + 12 * 3600,
                  nutrition: Nutrition(kilocalories: 100))
    }

    func testRoundTrip() throws {
        let store = MemoryStore()
        let sync = LogSync(backing: store)
        let today = DayKey(year: 2024, month: 6, day: 1)

        var log = FoodLog()
        log.add(entry(daysAgo: 1, from: today))
        sync.push(log, asOf: today)

        let pulled = try XCTUnwrap(sync.pull())
        XCTAssertEqual(pulled.entries.count, 1)
        XCTAssertEqual(pulled.entries[0].id, log.entries[0].id)
    }

    func testPruningDropsHistoryOutsideTheWindow() {
        let today = DayKey(year: 2024, month: 6, day: 1)
        var log = FoodLog()
        log.add(entry(daysAgo: 10, from: today))
        log.add(entry(daysAgo: 400, from: today))

        let pruned = LogSync.prune(log, asOf: today)
        XCTAssertEqual(pruned.entries.count, 1)
        XCTAssertEqual(pruned.entries[0].name, "Item 10")
    }

    func testMergingIsIdempotentSoAMealCannotBeCountedTwice() {
        let today = DayKey(year: 2024, month: 6, day: 1)
        var local = FoodLog()
        local.add(entry(daysAgo: 1, from: today))
        let remote = local

        let merged = LogSync.merge(local: local, remote: remote)
        XCTAssertEqual(merged.entries.count, 1, "the same entry syncing twice must not duplicate")
    }

    func testMergingUnionsDistinctEntriesFromBothDevices() {
        let today = DayKey(year: 2024, month: 6, day: 1)
        var watch = FoodLog()
        watch.add(entry(daysAgo: 1, from: today))
        var mac = FoodLog()
        mac.add(entry(daysAgo: 2, from: today))

        XCTAssertEqual(LogSync.merge(local: watch, remote: mac).entries.count, 2)
    }

    func testStatedContextBeatsAnInferredOne() throws {
        let start = Date().timeIntervalSince1970
        let id = UUID()
        let watch = FoodLog(occasions: [
            MealOccasion(id: id, context: .home, evidence: .inferred, start: start)
        ])
        let mac = FoodLog(occasions: [
            MealOccasion(id: id, context: .pub, evidence: .stated, venueName: "The Eagle", start: start)
        ])

        let merged = LogSync.merge(local: watch, remote: mac)
        let occasion = try XCTUnwrap(merged.occasions.first)
        XCTAssertEqual(occasion.context, .pub)
        XCTAssertEqual(occasion.venueName, "The Eagle")
    }
}

final class ContextClassifierTests: XCTestCase {

    func testSeveralDrinksAndLittleFoodIsAPub() {
        let guess = ContextClassifier.classify(.init(
            alcoholGrams: 60, totalCalories: 700, distinctDrinks: 3,
            itemCount: 3, hour: 20, weekday: 5))
        XCTAssertEqual(guess.context, .pub)
        XCTAssertGreaterThan(guess.confidence, 0.6)
    }

    func testBigEveningMealWithWineIsARestaurant() {
        let guess = ContextClassifier.classify(.init(
            alcoholGrams: 36, totalCalories: 1_400, distinctDrinks: 2,
            itemCount: 4, hour: 20, weekday: 6))
        XCTAssertEqual(guess.context, .restaurant)
    }

    func testWeekdayLunchWithNoAlcoholIsWork() {
        let guess = ContextClassifier.classify(.init(
            alcoholGrams: 0, totalCalories: 550, distinctDrinks: 0,
            itemCount: 1, hour: 13, weekday: 3))
        XCTAssertEqual(guess.context, .work)
    }

    func testCookedMealWithNoAlcoholIsHome() {
        let guess = ContextClassifier.classify(.init(
            alcoholGrams: 0, totalCalories: 800, distinctDrinks: 0,
            itemCount: 3, hour: 19, weekday: 2))
        XCTAssertEqual(guess.context, .home)
    }

    func testPointOfInterestCategoriesMapToContexts() {
        XCTAssertEqual(ContextClassifier.context(forPointOfInterestCategory: "MKPOICategoryBrewery"), .pub)
        XCTAssertEqual(ContextClassifier.context(forPointOfInterestCategory: "MKPOICategoryRestaurant"), .restaurant)
        XCTAssertEqual(ContextClassifier.context(forPointOfInterestCategory: "MKPOICategoryCafe"), .cafe)
        XCTAssertNil(ContextClassifier.context(forPointOfInterestCategory: "MKPOICategoryLaundry"))
    }

    func testEatingOutGrouping() {
        XCTAssertTrue(MealContext.pub.isEatingOut)
        XCTAssertTrue(MealContext.takeaway.isEatingOut)
        XCTAssertFalse(MealContext.home.isEatingOut)
        XCTAssertFalse(MealContext.unknown.isEatingOut)
    }
}

final class ResolutionMergeTests: XCTestCase {

    private func entry(id: UUID, kcal: Double, resolution: ResolutionState?) -> FoodEntry {
        FoodEntry(id: id, name: "curry",
                  timestamp: DayKey.today.localDate().timeIntervalSince1970 + 12 * 3600,
                  nutrition: Nutrition(kilocalories: kcal),
                  source: .naturalLanguage,
                  resolution: resolution)
    }

    func testABetterResolvedCopyWinsAMerge() throws {
        let id = UUID()
        let stale = FoodLog(entries: [entry(id: id, kcal: 650, resolution: .pending)])
        let fresh = FoodLog(entries: [entry(id: id, kcal: 900, resolution: .resolved(
            NutritionProvenance(source: .foodDataCentral, confidence: 0.9)))])

        let merged = LogSync.merge(local: stale, remote: fresh)
        XCTAssertEqual(merged.entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(merged.entries.first).nutrition.kilocalories, 900)
    }

    func testAWorseCopyDoesNotOverwriteAResolvedOne() throws {
        let id = UUID()
        let good = FoodLog(entries: [entry(id: id, kcal: 900, resolution: .resolved(
            NutritionProvenance(source: .foodDataCentral, confidence: 0.9)))])
        let stale = FoodLog(entries: [entry(id: id, kcal: 650, resolution: .pending)])

        let merged = LogSync.merge(local: good, remote: stale)
        XCTAssertEqual(try XCTUnwrap(merged.entries.first).nutrition.kilocalories, 900)
    }

    func testTheMoreConfidentOfTwoResolutionsWins() throws {
        let id = UUID()
        let weak = FoodLog(entries: [entry(id: id, kcal: 700, resolution: .resolved(
            NutritionProvenance(source: .openFoodFacts, confidence: 0.5)))])
        let strong = FoodLog(entries: [entry(id: id, kcal: 900, resolution: .resolved(
            NutritionProvenance(source: .foodDataCentral, confidence: 0.9)))])

        XCTAssertEqual(try XCTUnwrap(LogSync.merge(local: weak, remote: strong).entries.first)
            .nutrition.kilocalories, 900)
    }
}
