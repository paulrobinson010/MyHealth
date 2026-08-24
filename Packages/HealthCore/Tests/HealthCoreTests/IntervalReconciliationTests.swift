import XCTest
@testable import HealthCore

final class IntervalReconciliationTests: XCTestCase {

    /// Builds a history with explicit control over what was logged and when
    /// they weighed.
    private func database(days: Int,
                          startWeight: Double = 90,
                          kgPerDay: Double = 0,
                          expenditure: Double = 2_500,
                          loggedIntake: Double? = 2_200,
                          logOnDays: (Int) -> Bool = { _ in true },
                          weighOnDays: (Int) -> Bool = { _ in true }) -> HealthDatabase {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var summaries: [DailySummary] = []
        for offset in 0..<days {
            var values: [Metric: Double] = [
                .activeEnergy: expenditure - 1_700,
                .basalEnergy: 1_700
            ]
            if let loggedIntake, logOnDays(offset) { values[.dietaryEnergy] = loggedIntake }
            if weighOnDays(offset) { values[.bodyMass] = startWeight + kgPerDay * Double(offset) }
            summaries.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        return HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male, heightCm: 180),
            days: summaries)
    }

    // MARK: - The measured answer

    /// The point of the whole approach: between two weigh-ins the deficit is
    /// measured, not estimated, and it does not need the food diary at all.
    func testTheDeficitIsMeasuredFromWeightAlone() throws {
        // Losing 0.05 kg a day is 385 kcal a day of deficit, whatever was logged.
        let summary = IntervalReconciler.summarise(
            for: database(days: 60, kgPerDay: -0.05), policy: .reconcile)

        XCTAssertTrue(summary.hasMeasuredAnswer)
        XCTAssertEqual(try XCTUnwrap(summary.measuredDailyDeficit), 385, accuracy: 15)
        XCTAssertEqual(try XCTUnwrap(summary.dailyDeficit), 385, accuracy: 15)
    }

    func testGainingWeightReadsAsASurplus() throws {
        let summary = IntervalReconciler.summarise(
            for: database(days: 60, kgPerDay: 0.02), policy: .reconcile)
        XCTAssertLessThan(try XCTUnwrap(summary.measuredDailyDeficit), 0)
    }

    // MARK: - Working out the unlogged days

    /// The interesting one. Log five days in seven, hold weight steady, and the
    /// arithmetic says what the missing two days must have been.
    func testUnloggedDaysAreDerivedFromTheScale() throws {
        // Expenditure 2,500/day, weight flat, so total intake must equal total
        // expenditure. Logged days claim 2,200. The other days have to make up
        // the difference.
        let database = database(days: 63,
                                kgPerDay: 0,
                                expenditure: 2_500,
                                loggedIntake: 2_200,
                                logOnDays: { $0 % 7 < 5 })       // five days in seven

        let intervals = IntervalReconciler.intervals(database: database)
        XCTAssertFalse(intervals.isEmpty)

        let summary = IntervalReconciler.summarise(for: database, policy: .reconcile)
        let implied = try XCTUnwrap(summary.impliedUnloggedDailyIntake)

        // Five days at 2,200 plus two days at X must average 2,500:
        // (5 × 2200 + 2X) / 7 = 2500  ->  X = 3,250.
        XCTAssertEqual(implied, 3_250, accuracy: 150)
        XCTAssertGreaterThan(implied, 2_200, "the days you forget are not the quiet ones")
    }

    func testUnderLoggingIsQuantifiedPerDay() throws {
        let database = database(days: 63, kgPerDay: 0, expenditure: 2_500,
                                loggedIntake: 2_200, logOnDays: { $0 % 7 < 5 })
        let summary = IntervalReconciler.summarise(for: database, policy: .reconcile)

        // The diary claims a 300 kcal deficit; the scale says zero.
        XCTAssertEqual(try XCTUnwrap(summary.underLoggingPerDay), 300, accuracy: 60)
    }

    func testNothingIsImpliedWhenEveryDayWasLogged() {
        let summary = IntervalReconciler.summarise(
            for: database(days: 60, kgPerDay: -0.05), policy: .reconcile)
        XCTAssertNil(summary.impliedUnloggedDailyIntake)
    }

    // MARK: - Policies

    /// Excluding unlogged days flatters you; treating them as neutral does not.
    func testNeutralIsMoreConservativeThanExcluding() throws {
        let database = database(days: 60, kgPerDay: 0, expenditure: 2_500,
                                loggedIntake: 1_800, logOnDays: { $0 % 3 == 0 })

        let excluding = IntervalReconciler.summarise(for: database, policy: .exclude)
        let neutral = IntervalReconciler.summarise(for: database, policy: .neutral)

        let excludingDeficit = try XCTUnwrap(excluding.dailyDeficit)
        let neutralDeficit = try XCTUnwrap(neutral.dailyDeficit)
        XCTAssertLessThan(neutralDeficit, excludingDeficit,
                          "counting unlogged days as breaking even must not claim more progress")
    }

    func testNeutralDaysContributeNothingEitherWay() throws {
        // One day in three logged, 700 kcal deficit on those days.
        let database = database(days: 30, kgPerDay: 0, expenditure: 2_500,
                                loggedIntake: 1_800, logOnDays: { $0 % 3 == 0 })
        let neutral = try XCTUnwrap(IntervalReconciler.neutralDeficit(for: database))
        // 10 days at 700, 20 days at 0, over 30 days.
        XCTAssertEqual(neutral, 700.0 * 10 / 30, accuracy: 20)
    }

    func testReconcileFallsBackWhenThereAreNoWeighIns() {
        let database = database(days: 30, loggedIntake: 2_200, weighOnDays: { _ in false })
        let summary = IntervalReconciler.summarise(for: database, policy: .reconcile)
        XCTAssertTrue(summary.intervals.isEmpty)
        XCTAssertNil(summary.measuredDailyDeficit)
    }

    // MARK: - Guarding against noise

    func testIntervalsShorterThanAWeekAreNotTrusted() {
        let interval = ReconciledInterval(
            start: WeighIn(day: DayKey(year: 2024, month: 1, day: 1), kilograms: 90, rawKilograms: 90),
            end: WeighIn(day: DayKey(year: 2024, month: 1, day: 3), kilograms: 89, rawKilograms: 89),
            days: 2, loggedDays: 2, loggedIntake: 4_400, totalExpenditure: 5_000)
        XCTAssertEqual(interval.plausibility, .unusable,
                       "a kilo in two days is water, not fat")
    }

    func testImplausiblyFastWeightLossIsRejected() {
        let interval = ReconciledInterval(
            start: WeighIn(day: DayKey(year: 2024, month: 1, day: 1), kilograms: 90, rawKilograms: 90),
            end: WeighIn(day: DayKey(year: 2024, month: 1, day: 15), kilograms: 85, rawKilograms: 85),
            days: 14, loggedDays: 14, loggedIntake: 28_000, totalExpenditure: 35_000)
        XCTAssertEqual(interval.plausibility, .unusable)
    }

    func testAnAbsurdImpliedIntakeIsFlaggedRatherThanReported() {
        // Weight held steady while a tiny amount was logged and expenditure was
        // huge: the unlogged day would have to be enormous.
        let interval = ReconciledInterval(
            start: WeighIn(day: DayKey(year: 2024, month: 1, day: 1), kilograms: 90, rawKilograms: 90),
            end: WeighIn(day: DayKey(year: 2024, month: 1, day: 15), kilograms: 90, rawKilograms: 90),
            days: 14, loggedDays: 13, loggedIntake: 13_000, totalExpenditure: 42_000)
        XCTAssertEqual(interval.plausibility, .questionable)
    }

    func testDailyWeighingDoesNotProduceUselessOneDayIntervals() {
        let intervals = IntervalReconciler.intervals(
            database: database(days: 40, kgPerDay: -0.03))
        XCTAssertFalse(intervals.isEmpty)
        for interval in intervals {
            XCTAssertGreaterThanOrEqual(interval.days, IntervalReconciler.minimumIntervalDays)
        }
    }

    func testWeighInsAreSmoothedSoASingleHeavyMorningDoesNotMoveTheAnswer() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var summaries: [DailySummary] = []
        for offset in 0..<40 {
            // Flat weight, with one absurd reading in the middle.
            let weight = offset == 20 ? 95.0 : 90.0
            summaries.append(DailySummary(day: start.adding(days: offset),
                                          values: [.bodyMass: weight,
                                                   .basalEnergy: 1_700,
                                                   .activeEnergy: 800]))
        }
        let weighIns = IntervalReconciler.weighIns(in: HealthDatabase(days: summaries))
        let spike = try XCTUnwrap(weighIns.first { $0.day == start.adding(days: 20) })
        XCTAssertEqual(spike.rawKilograms, 95)
        XCTAssertLessThan(spike.kilograms, 91.5, "the smoothed value must absorb the spike")
    }

    func testExpenditureIsExtrapolatedOverDaysTheDeviceMissed() throws {
        // The watch was off for a third of the interval.
        let start = DayKey(year: 2024, month: 1, day: 1)
        var summaries: [DailySummary] = []
        for offset in 0..<30 {
            var values: [Metric: Double] = [.bodyMass: 90, .dietaryEnergy: 2_400]
            if offset % 3 != 0 {
                values[.basalEnergy] = 1_700
                values[.activeEnergy] = 800
            }
            summaries.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        let intervals = IntervalReconciler.intervals(database: HealthDatabase(days: summaries))
        let interval = try XCTUnwrap(intervals.first)
        // Roughly 2,500 a day across the whole interval, not just the days
        // the watch was worn.
        XCTAssertEqual(interval.totalExpenditure / Double(interval.days), 2_500, accuracy: 120)
    }
}
