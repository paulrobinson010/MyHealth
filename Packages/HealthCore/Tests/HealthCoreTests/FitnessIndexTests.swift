import XCTest
@testable import HealthCore

final class ReferenceRangeTests: XCTestCase {

    func testPiecewiseScoreInterpolatesAndClamps() {
        let anchors: [(Double, Double)] = [(0, 0), (10, 50), (20, 100)]
        XCTAssertEqual(ReferenceRanges.score(-5, anchors: anchors), 0)
        XCTAssertEqual(ReferenceRanges.score(0, anchors: anchors), 0)
        XCTAssertEqual(ReferenceRanges.score(5, anchors: anchors), 25, accuracy: 1e-9)
        XCTAssertEqual(ReferenceRanges.score(15, anchors: anchors), 75, accuracy: 1e-9)
        XCTAssertEqual(ReferenceRanges.score(100, anchors: anchors), 100)
    }

    func testVO2MaxIsScoredAgainstAgeAndSex() {
        // The same absolute number is a better result for an older person...
        let young = ReferenceRanges.vo2MaxScore(42, age: 25, sex: .male)
        let older = ReferenceRanges.vo2MaxScore(42, age: 60, sex: .male)
        XCTAssertGreaterThan(older, young)

        // ...and against female reference ranges, which sit lower.
        let male = ReferenceRanges.vo2MaxScore(42, age: 40, sex: .male)
        let female = ReferenceRanges.vo2MaxScore(42, age: 40, sex: .female)
        XCTAssertGreaterThan(female, male)
    }

    func testVO2MaxCategoryLabels() {
        XCTAssertEqual(ReferenceRanges.vo2MaxCategory(18, age: 40, sex: .male), "Low")
        XCTAssertEqual(ReferenceRanges.vo2MaxCategory(60, age: 40, sex: .male), "Superior")
    }

    func testLowerRestingHeartRateScoresHigher() {
        XCTAssertGreaterThan(ReferenceRanges.restingHeartRateScore(48, age: 38),
                             ReferenceRanges.restingHeartRateScore(68, age: 38))
        XCTAssertEqual(ReferenceRanges.restingHeartRateScore(30, age: 38), 100)
    }

    func testHRVIsAgeAdjusted() {
        // 40 ms is unremarkable at 25 and good at 60.
        XCTAssertLessThan(ReferenceRanges.hrvScore(40, age: 25),
                          ReferenceRanges.hrvScore(40, age: 60))
    }

    func testExerciseVolumeRewardsTheGuidelineAndBeyond() {
        XCTAssertEqual(ReferenceRanges.exerciseVolumeScore(minutesPerWeek: 150), 70, accuracy: 1e-9)
        XCTAssertGreaterThan(ReferenceRanges.exerciseVolumeScore(minutesPerWeek: 300),
                             ReferenceRanges.exerciseVolumeScore(minutesPerWeek: 150))
        XCTAssertEqual(ReferenceRanges.exerciseVolumeScore(minutesPerWeek: 900), 100)
    }
}

final class FitnessIndexTests: XCTestCase {

    /// A database where every day carries the same numbers, so the index is
    /// stable and easy to reason about.
    private func flatDatabase(days count: Int = 120,
                              steps: Double = 10_000,
                              exercise: Double = 30,
                              activeEnergy: Double = 550,
                              restingHeartRate: Double = 55,
                              hrv: Double = 45,
                              vo2Max: Double? = 48) -> HealthDatabase {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<count {
            var values: [Metric: Double] = [
                .steps: steps,
                .exerciseMinutes: exercise,
                .activeEnergy: activeEnergy,
                .restingHeartRate: restingHeartRate,
                .hrv: hrv
            ]
            if let vo2Max, offset % 10 == 0 { values[.vo2Max] = vo2Max }
            days.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        return HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male),
            days: days)
    }

    func testScoreIsProducedAndBounded() throws {
        let index = FitnessIndex(database: flatDatabase())
        let score = try XCTUnwrap(index.score(on: DayKey(year: 2024, month: 3, day: 1)))
        XCTAssertGreaterThan(score.value, 0)
        XCTAssertLessThanOrEqual(score.value, 100)
        XCTAssertEqual(score.components.count, 6)
        XCTAssertEqual(score.coverage, 1, accuracy: 1e-9)
        // Weights are renormalised to sum to one.
        XCTAssertEqual(score.components.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
    }

    func testMissingComponentsRedistributeTheirWeight() throws {
        let index = FitnessIndex(database: flatDatabase(vo2Max: nil))
        let score = try XCTUnwrap(index.score(on: DayKey(year: 2024, month: 3, day: 1)))
        XCTAssertNil(score.component(.cardio))
        XCTAssertEqual(score.components.count, 5)
        // Still a full unit of weight spread across what remains.
        XCTAssertEqual(score.components.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
        XCTAssertLessThan(score.coverage, 1)
    }

    func testFitterInputsProduceAHigherIndex() throws {
        let modest = FitnessIndex(database: flatDatabase(steps: 4_000, exercise: 8,
                                                         activeEnergy: 220,
                                                         restingHeartRate: 72,
                                                         hrv: 22, vo2Max: 32))
        let strong = FitnessIndex(database: flatDatabase(steps: 13_000, exercise: 60,
                                                         activeEnergy: 780,
                                                         restingHeartRate: 46,
                                                         hrv: 70, vo2Max: 56))
        let day = DayKey(year: 2024, month: 3, day: 1)
        let low = try XCTUnwrap(modest.score(on: day)).value
        let high = try XCTUnwrap(strong.score(on: day)).value
        XCTAssertGreaterThan(high, low + 25)
    }

    func testTooLittleDataProducesNoScore() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<3).map {
            DailySummary(day: start.adding(days: $0), values: [.steps: 8_000])
        }
        let index = FitnessIndex(database: HealthDatabase(days: days))
        XCTAssertNil(index.score(on: start.adding(days: 2)))
    }

    func testHistorySkipsTheUnscorableWarmUpWindow() {
        let database = flatDatabase(days: 60)
        let history = FitnessIndex(database: database).history()
        XCTAssertFalse(history.isEmpty)
        // The first 27 days cannot have a full trailing window behind them.
        XCTAssertEqual(history.first?.day, DayKey(year: 2024, month: 1, day: 28))
        XCTAssertEqual(history.last?.day, database.days.last?.day)
    }

    func testConsistencyReflectsRestDays() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<60 {
            // Active every third day only.
            let active = offset % 3 == 0
            days.append(DailySummary(day: start.adding(days: offset), values: [
                .steps: active ? 12_000 : 2_000,
                .exerciseMinutes: active ? 45 : 0,
                .restingHeartRate: 55
            ]))
        }
        let score = try XCTUnwrap(FitnessIndex(database: HealthDatabase(days: days))
            .score(on: start.adding(days: 59)))
        let consistency = try XCTUnwrap(score.component(.consistency))
        XCTAssertLessThan(consistency.score, 50)
    }

    func testBandsMapToScores() {
        XCTAssertEqual(FitnessBand(score: 10), .needsWork)
        XCTAssertEqual(FitnessBand(score: 40), .fair)
        XCTAssertEqual(FitnessBand(score: 60), .good)
        XCTAssertEqual(FitnessBand(score: 75), .strong)
        XCTAssertEqual(FitnessBand(score: 92), .elite)
    }
}

final class RankingsTests: XCTestCase {

    private func scores(_ monthlyAverages: [(month: Int, value: Double)]) -> [FitnessScore] {
        var result: [FitnessScore] = []
        for entry in monthlyAverages {
            for day in 1...28 {
                let key = DayKey(year: 2024, month: entry.month, day: day)
                result.append(FitnessScore(day: key, value: entry.value, components: [], coverage: 1))
            }
        }
        return result.sorted { $0.day < $1.day }
    }

    func testMonthsAreRankedBestFirst() {
        let ranked = Rankings.rankedPeriods(
            from: scores([(1, 50), (2, 70), (3, 60)]), bucket: .month)
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.first { $0.label.hasPrefix("Feb") }?.rank, 1)
        XCTAssertEqual(ranked.first { $0.label.hasPrefix("Mar") }?.rank, 2)
        XCTAssertEqual(ranked.first { $0.label.hasPrefix("Jan") }?.rank, 3)
    }

    func testChangeFromPreviousPeriod() throws {
        let ranked = Rankings.rankedPeriods(from: scores([(1, 50), (2, 70)]), bucket: .month)
        let february = try XCTUnwrap(ranked.first { $0.label.hasPrefix("Feb") })
        XCTAssertEqual(try XCTUnwrap(february.changeFromPrevious), 20, accuracy: 1e-9)
    }

    func testPercentileOfBestPeriodIsOne() throws {
        let ranked = Rankings.rankedPeriods(from: scores([(1, 50), (2, 70), (3, 60)]), bucket: .month)
        let best = try XCTUnwrap(ranked.first { $0.rank == 1 })
        XCTAssertEqual(best.percentile, 1, accuracy: 1e-9)
    }

    func testShortPeriodsAreExcluded() {
        let partial = [FitnessScore(day: DayKey(year: 2024, month: 5, day: 1),
                                    value: 99, components: [], coverage: 1)]
        let ranked = Rankings.rankedPeriods(from: scores([(1, 50)]) + partial,
                                            bucket: .month,
                                            minimumDays: 10)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertTrue(ranked[0].label.hasPrefix("Jan"))
    }

    func testStandingPlacesTheCurrentScoreInItsOwnHistory() throws {
        // Rising through the year, so today is the best day on record.
        let rising = (0..<200).map { offset in
            FitnessScore(day: DayKey(year: 2024, month: 1, day: 1).adding(days: offset),
                         value: 40 + Double(offset) * 0.2,
                         components: [], coverage: 1)
        }
        let standing = try XCTUnwrap(Rankings.standing(from: rising))
        XCTAssertEqual(standing.percentileAllTime, 1, accuracy: 0.01)
        XCTAssertEqual(standing.allTimeBest?.day, rising.last?.day)
        XCTAssertEqual(try XCTUnwrap(standing.changeVs30Days), 6, accuracy: 0.5)
    }

    func testComponentAveragesCollapseAcrossDays() throws {
        let components = [
            FitnessComponent(kind: .cardio, score: 80, weight: 0.3, detail: "a"),
            FitnessComponent(kind: .movement, score: 40, weight: 0.7, detail: "b")
        ]
        let scores = (0..<10).map {
            FitnessScore(day: DayKey(year: 2024, month: 1, day: 1).adding(days: $0),
                         value: 60, components: components, coverage: 1)
        }
        let averaged = Rankings.componentAverages(from: scores)
        XCTAssertEqual(averaged.count, 2)
        XCTAssertEqual(try XCTUnwrap(averaged.first { $0.kind == .cardio }).score, 80, accuracy: 1e-9)
    }
}
