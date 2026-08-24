import XCTest
@testable import HealthCore

final class EnergyBalanceTests: XCTestCase {

    /// Builds a history where the person eats `intake` a day, burns
    /// `expenditure` a day by the watch's reckoning, and loses weight at
    /// `kgPerDay`.
    private func database(days count: Int = 90,
                          intake: Double? = 2_400,
                          activeEnergy: Double = 600,
                          basalEnergy: Double = 1_700,
                          startMass: Double = 90,
                          kgPerDay: Double = -0.05,
                          logEveryNthDay: Int = 1) -> HealthDatabase {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var summaries: [DailySummary] = []
        for offset in 0..<count {
            var values: [Metric: Double] = [
                .activeEnergy: activeEnergy,
                .basalEnergy: basalEnergy,
                .bodyMass: startMass + kgPerDay * Double(offset)
            ]
            if let intake, offset % logEveryNthDay == 0 {
                values[.dietaryEnergy] = intake
            }
            summaries.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        return HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male, heightCm: 180),
            days: summaries)
    }

    func testDeficitIsExpenditureMinusIntake() throws {
        let report = EnergyBalance.report(for: database())
        XCTAssertEqual(try XCTUnwrap(report.averageIntake), 2_400, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(report.averageExpenditure), 2_300, accuracy: 1e-6)
        // Eating 2,400 against 2,300 out is a surplus, so the deficit is negative.
        XCTAssertEqual(try XCTUnwrap(report.averageDailyDeficit), -100, accuracy: 1e-6)
    }

    /// The headline calculation: what maintenance really is, given that the
    /// scale disagrees with the watch.
    func testCalibrationRecoversTrueMaintenanceFromTheWeightTrend() throws {
        // Eating 2,400 and losing 0.05 kg a day means burning
        // 2,400 + 0.05 × 7,700 = 2,785 kcal — not the 2,300 the watch claims.
        let report = EnergyBalance.report(for: database(intake: 2_400, kgPerDay: -0.05))
        XCTAssertTrue(report.isCalibrationTrustworthy)
        XCTAssertEqual(try XCTUnwrap(report.calibratedMaintenanceCalories), 2_785, accuracy: 15)

        // And it names the size of the watch's error.
        XCTAssertEqual(try XCTUnwrap(report.expenditureBias), -485, accuracy: 20)
    }

    func testStableWeightMeansMaintenanceEqualsIntake() throws {
        let report = EnergyBalance.report(for: database(intake: 2_600, kgPerDay: 0))
        XCTAssertEqual(try XCTUnwrap(report.calibratedMaintenanceCalories), 2_600, accuracy: 15)
    }

    func testGainingWeightLowersTheCalibratedMaintenance() throws {
        let report = EnergyBalance.report(for: database(intake: 3_000, kgPerDay: 0.03))
        // 3,000 − 0.03 × 7,700 = 2,769.
        XCTAssertEqual(try XCTUnwrap(report.calibratedMaintenanceCalories), 2_769, accuracy: 15)
    }

    func testPatchyLoggingIsRefusedRatherThanQuietlyWrong() {
        // Logging one day in four looks like an enormous deficit if you are
        // careless about it, so the report must decline to calibrate.
        let report = EnergyBalance.report(for: database(logEveryNthDay: 4))
        XCTAssertLessThan(report.loggingCoverage, 0.6)
        XCTAssertFalse(report.isCalibrationTrustworthy)
    }

    func testNoFoodLoggedAtAllProducesNoIntakeFigures() {
        let report = EnergyBalance.report(for: database(intake: nil))
        XCTAssertNil(report.averageIntake)
        XCTAssertNil(report.averageDailyDeficit)
        XCTAssertFalse(report.isCalibrationTrustworthy)
        XCTAssertEqual(report.loggedDays, 0)
    }

    func testBasalEnergyIsEstimatedWhenTheDeviceDidNotRecordIt() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let summaries = (0..<30).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: [.dietaryEnergy: 2_200, .activeEnergy: 500, .bodyMass: 80])
        }
        let database = HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male, heightCm: 180),
            days: summaries)

        let report = EnergyBalance.report(for: database)
        // Mifflin-St Jeor for an 80 kg, 180 cm man of 37: ~1,740, plus 500 active.
        XCTAssertEqual(try XCTUnwrap(report.averageExpenditure), 2_240, accuracy: 60)
    }

    func testTargetIntakeForAGoal() {
        // Losing half a kilo a week off a 2,800 maintenance means about 2,250.
        let target = EnergyBalance.targetIntake(forWeightChangeKgPerWeek: -0.5, maintenance: 2_800)
        XCTAssertEqual(target, 2_250, accuracy: 1)
    }

    func testMifflinStJeorMatchesPublishedValues() {
        XCTAssertEqual(EnergyBalance.estimatedBasalRate(massKg: 80, heightCm: 180, age: 30, sex: .male),
                       1_780, accuracy: 1)
        XCTAssertEqual(EnergyBalance.estimatedBasalRate(massKg: 65, heightCm: 165, age: 30, sex: .female),
                       1_370.25, accuracy: 1)
    }

    func testRecompositionIsDetectedWhenWaistMovesButWeightDoesNot() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let summaries = (0..<60).map { offset in
            DailySummary(day: start.adding(days: offset), values: [
                .bodyMass: 85 + (offset % 2 == 0 ? 0.1 : -0.1),   // flat, with noise
                .waistCircumference: 95 - 0.05 * Double(offset)    // steadily down
            ])
        }
        let signal = EnergyBalance.bodyComposition(for: HealthDatabase(days: summaries))
        XCTAssertEqual(try XCTUnwrap(signal.waistChangeCm), -2.9, accuracy: 0.3)
        XCTAssertTrue(signal.isRecomposition)
    }

    func testAlcoholCaloriesAreCountedFromDrinksWhenGramsAreMissing() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let summaries = (0..<14).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: [.dietaryEnergy: 2_500, .basalEnergy: 1_700,
                                  .alcoholicDrinks: 2])
        }
        let report = EnergyBalance.report(for: HealthDatabase(days: summaries))
        // 2 US standard drinks is 28 g of ethanol, so 196 kcal a day.
        XCTAssertEqual(try XCTUnwrap(report.alcoholCaloriesPerWeek), 196 * 7, accuracy: 5)
    }
}

final class CorrelationTests: XCTestCase {

    func testPerfectPositiveRelationship() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<40).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: [.steps: Double(offset) * 100,
                                  .activeEnergy: Double(offset) * 20 + 200])
        }
        let result = try XCTUnwrap(CorrelationAnalysis.correlate(.steps, with: .activeEnergy,
                                                                 in: HealthDatabase(days: days)))
        XCTAssertEqual(result.r, 1, accuracy: 1e-6)
        XCTAssertEqual(result.slope, 0.2, accuracy: 1e-6)
        XCTAssertEqual(result.count, 40)
        XCTAssertTrue(result.isNoteworthy)
    }

    func testPerfectNegativeRelationship() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<40).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: [.alcoholGrams: Double(offset),
                                  .hrv: 60 - Double(offset) * 0.5])
        }
        let result = try XCTUnwrap(CorrelationAnalysis.correlate(.alcoholGrams, with: .hrv,
                                                                 in: HealthDatabase(days: days)))
        XCTAssertEqual(result.r, -1, accuracy: 1e-6)
        XCTAssertEqual(result.direction, "falls as")
    }

    /// The one that matters: last night's drinking against this morning's HRV.
    func testLagPairsEachDayWithTheFollowingMorning() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<40 {
            let drank = offset % 2 == 0
            days.append(DailySummary(day: start.adding(days: offset), values: [
                .alcoholGrams: drank ? 60 : 0,
                // HRV is suppressed the morning after a drinking day.
                .hrv: (offset > 0 && (offset - 1) % 2 == 0) ? 35 : 60
            ]))
        }
        let database = HealthDatabase(days: days)

        let sameDay = try XCTUnwrap(CorrelationAnalysis.correlate(.alcoholGrams, with: .hrv,
                                                                  in: database, lagDays: 0))
        let nextDay = try XCTUnwrap(CorrelationAnalysis.correlate(.alcoholGrams, with: .hrv,
                                                                  in: database, lagDays: 1))
        // Drinking suppresses the FOLLOWING morning's HRV, so only the lagged
        // correlation finds it.
        XCTAssertLessThan(nextDay.r, -0.9, "drinking days should precede low-HRV mornings")
        // Without the lag the sign comes out backwards, which is the whole
        // reason the lag exists.
        XCTAssertGreaterThan(sameDay.r, 0)
    }

    func testUncorrelatedDataIsNotReportedAsNoteworthy() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var generator = SeededGenerator(seed: 99)
        let days = (0..<60).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: [.steps: generator.nextDouble() * 10_000,
                                  .hrv: generator.nextDouble() * 60])
        }
        let result = CorrelationAnalysis.correlate(.steps, with: .hrv, in: HealthDatabase(days: days))
        if let result {
            XCTAssertFalse(result.isNoteworthy, "random noise reported as a finding, r = \(result.r)")
        }
    }

    func testTooFewPairsReturnsNothing() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<4).map {
            DailySummary(day: start.adding(days: $0), values: [.steps: 100, .hrv: 40])
        }
        XCTAssertNil(CorrelationAnalysis.correlate(.steps, with: .hrv, in: HealthDatabase(days: days)))
    }

    func testPValueFallsAsEvidenceAccumulates() {
        let weak = CorrelationAnalysis.pValue(r: 0.3, n: 12)
        let strong = CorrelationAnalysis.pValue(r: 0.3, n: 400)
        XCTAssertGreaterThan(weak, 0.05)
        XCTAssertLessThan(strong, 0.01)
    }
}

final class HangoverProfileTests: XCTestCase {

    func testMorningsAfterDrinkingAreComparedWithDryMornings() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<60 {
            let drank = offset % 3 == 0
            let morningAfterDrinking = offset > 0 && (offset - 1) % 3 == 0
            days.append(DailySummary(day: start.adding(days: offset), values: [
                .alcoholGrams: drank ? 50 : 0,
                .restingHeartRate: morningAfterDrinking ? 60 : 54,
                .hrv: morningAfterDrinking ? 32 : 45
            ]))
        }

        let profile = OccasionAnalysis.hangoverProfile(for: HealthDatabase(days: days))
        XCTAssertTrue(profile.isMeaningful)
        XCTAssertEqual(try XCTUnwrap(profile.restingHeartRateDelta), 6, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(profile.hrvDelta), -13, accuracy: 0.5)
    }
}

final class FitnessNarratorTests: XCTestCase {

    private func standing(current: Double, ninetyDaysAgo: Double) -> FitnessStanding {
        let day = DayKey(year: 2024, month: 6, day: 1)
        let score = FitnessScore(day: day, value: current, components: [], coverage: 1)
        return FitnessStanding(current: score,
                               percentileAllTime: 0.8,
                               percentileLastYear: 0.75,
                               allTimeBest: score,
                               allTimeWorst: nil,
                               daysSinceHigher: nil,
                               changeVs30Days: nil,
                               changeVs90Days: current - ninetyDaysAgo,
                               changeVs365Days: nil)
    }

    func testImprovementIsStatedPlainly() {
        let briefing = FitnessNarrator.brief(
            standing: standing(current: 72, ninetyDaysAgo: 60),
            components: [FitnessComponent(kind: .cardio, score: 80, weight: 0.3, detail: "50 mL/kg·min")],
            trends: [])
        XCTAssertTrue(briefing.headline.contains("fitter"), briefing.headline)
        XCTAssertTrue(briefing.headline.contains("12"), "the size of the change belongs in the headline")
    }

    func testDeclineIsNotDressedUp() {
        let briefing = FitnessNarrator.brief(
            standing: standing(current: 55, ninetyDaysAgo: 70),
            components: [], trends: [])
        XCTAssertTrue(briefing.headline.contains("less fit"), briefing.headline)
    }

    func testFlatIsReportedAsSteady() {
        let briefing = FitnessNarrator.brief(
            standing: standing(current: 61, ninetyDaysAgo: 60),
            components: [], trends: [])
        XCTAssertTrue(briefing.headline.contains("steady"), briefing.headline)
    }

    func testWeakestComponentDrivesTheSuggestion() {
        let briefing = FitnessNarrator.brief(
            standing: standing(current: 60, ninetyDaysAgo: 60),
            components: [
                FitnessComponent(kind: .cardio, score: 85, weight: 0.3, detail: nil),
                FitnessComponent(kind: .consistency, score: 30, weight: 0.1, detail: nil)
            ],
            trends: [])
        XCTAssertTrue(briefing.findings.contains { $0.contains("Cardio Capacity") })
        XCTAssertTrue(briefing.findings.contains { $0.contains("Consistency") })
        XCTAssertFalse(briefing.suggestions.isEmpty)
    }

    func testPatchyFoodLoggingIsFlaggedAsACaveat() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<30).map { offset in
            DailySummary(day: start.adding(days: offset),
                         values: offset % 5 == 0
                            ? [.dietaryEnergy: 2_000, .basalEnergy: 1_700]
                            : [.basalEnergy: 1_700])
        }
        let energy = EnergyBalance.report(for: HealthDatabase(days: days))
        let briefing = FitnessNarrator.brief(standing: standing(current: 60, ninetyDaysAgo: 60),
                                             components: [], trends: [], energy: energy)
        XCTAssertTrue(briefing.caveats.contains { $0.contains("logged on only") },
                      "an unreliable calorie figure must carry its caveat")
    }

    func testNoDataProducesAnHonestAnswerRatherThanSilence() {
        let briefing = FitnessNarrator.brief(standing: nil, components: [], trends: [])
        XCTAssertFalse(briefing.headline.isEmpty)
        XCTAssertFalse(briefing.plainText.isEmpty)
    }
}
