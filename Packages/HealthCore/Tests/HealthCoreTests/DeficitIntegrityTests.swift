import XCTest
@testable import HealthCore

final class DeficitIntegrityTests: XCTestCase {

    /// A well-behaved history: logged most days, weighed most days, real
    /// resting-energy readings.
    private func goodDatabase(days: Int = 90,
                              logEveryNthDay: Int = 1,
                              weighEveryNthDay: Int = 1,
                              includeBasal: Bool = true) -> HealthDatabase {
        let start = DayKey.today.adding(days: -(days - 1))
        var summaries: [DailySummary] = []
        for offset in 0..<days {
            var values: [Metric: Double] = [.activeEnergy: 600]
            if includeBasal { values[.basalEnergy] = 1_700 }
            if offset % logEveryNthDay == 0 { values[.dietaryEnergy] = 2_200 }
            if offset % weighEveryNthDay == 0 { values[.bodyMass] = 90 - 0.03 * Double(offset) }
            summaries.append(DailySummary(day: start.adding(days: offset), values: values))
        }
        return HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male, heightCm: 180),
            days: summaries)
    }

    private func log(days: Int, verified: Bool, kcal: Double = 2_200) -> FoodLog {
        var log = FoodLog()
        let start = DayKey.today.adding(days: -(days - 1))
        for offset in 0..<days {
            let day = start.adding(days: offset)
            let resolution: ResolutionState = verified
                ? .resolved(NutritionProvenance(source: .foodDataCentral, confidence: 0.9))
                : .pending
            log.add(FoodEntry(name: "meal",
                              timestamp: day.localDate().timeIntervalSince1970 + 12 * 3600,
                              nutrition: Nutrition(kilocalories: kcal),
                              source: .naturalLanguage,
                              resolution: resolution))
        }
        return log
    }

    private func audit(_ database: HealthDatabase, _ foodLog: FoodLog) -> DeficitIntegrity {
        let range = database.dateRange
        return DeficitAudit.audit(report: EnergyBalance.report(for: database, range: range),
                                  log: foodLog,
                                  database: database,
                                  range: range)
    }

    func testAWellKeptLogIsReportedAsReliable() {
        let result = audit(goodDatabase(), log(days: 90, verified: true))
        XCTAssertEqual(result.confidence, .solid)
        XCTAssertTrue(result.blockingFindings.isEmpty)
        XCTAssertGreaterThan(result.verifiedCalorieShare, 0.9)
    }

    /// The failure that makes calorie tracking useless: skipped days read as
    /// zero-calorie days, inventing a deficit that never existed.
    func testPatchyLoggingBlocksTheFigureEntirely() {
        let result = audit(goodDatabase(logEveryNthDay: 4), log(days: 22, verified: true))
        XCTAssertEqual(result.confidence, .unreliable)
        XCTAssertTrue(result.blockingFindings.contains { $0.message.contains("only") })
        XCTAssertFalse(result.isActionable)
    }

    func testNoWeighInsBlocksIt() {
        var database = goodDatabase()
        database.days = database.days.map { day in
            var copy = day
            copy.values[.bodyMass] = nil
            return copy
        }
        let result = audit(database, log(days: 90, verified: true))
        XCTAssertEqual(result.confidence, .unreliable)
        XCTAssertTrue(result.blockingFindings.contains { $0.message.contains("weigh-ins") })
    }

    func testMostlyGuessedCaloriesAreFlaggedButNotBlocking() {
        let result = audit(goodDatabase(), log(days: 90, verified: false))
        XCTAssertEqual(result.confidence, .indicative)
        XCTAssertLessThan(result.verifiedCalorieShare, 0.1)
        XCTAssertTrue(result.findings.contains { $0.message.contains("estimates") })
    }

    /// Systematic under-logging: the person logs every day, but not everything
    /// they ate. Coverage looks perfect and the number is still wrong — only
    /// the scale reveals it.
    func testUnderLoggingIsCaughtByComparingAgainstTheScale() {
        let start = DayKey.today.adding(days: -89)
        var summaries: [DailySummary] = []
        for offset in 0..<90 {
            summaries.append(DailySummary(day: start.adding(days: offset), values: [
                .dietaryEnergy: 1_600,       // claims a big deficit
                .activeEnergy: 600,
                .basalEnergy: 1_700,
                .bodyMass: 90                // but the weight has not moved at all
            ]))
        }
        let database = HealthDatabase(
            profile: UserProfile(dateOfBirth: DayKey(year: 1986, month: 4, day: 12),
                                 biologicalSex: .male, heightCm: 180),
            days: summaries)

        let result = audit(database, log(days: 90, verified: true, kcal: 1_600))
        XCTAssertTrue(result.findings.contains { $0.message.contains("scale says") },
                      "findings: \(result.findings.map(\.message))")
    }

    func testEstimatedRestingEnergyIsNotedButNotDamning() {
        let result = audit(goodDatabase(includeBasal: false), log(days: 90, verified: true))
        XCTAssertTrue(result.findings.contains { $0.message.contains("Resting energy is estimated") })
        XCTAssertNotEqual(result.confidence, .unreliable)
    }

    func testNoAlcoholAtAllIsWorthMentioning() {
        let result = audit(goodDatabase(), log(days: 90, verified: true))
        XCTAssertTrue(result.findings.contains { $0.message.contains("No alcohol logged") })
    }

    func testTheUncertaintyBandWidensAsEvidenceThins() throws {
        let tight = audit(goodDatabase(), log(days: 90, verified: true))
        let loose = audit(goodDatabase(logEveryNthDay: 2, includeBasal: false),
                          log(days: 45, verified: false))

        let tightRange = try XCTUnwrap(tight.uncertaintyRange)
        let looseRange = try XCTUnwrap(loose.uncertaintyRange)
        let tightWidth = tightRange.upperBound - tightRange.lowerBound
        let looseWidth = looseRange.upperBound - looseRange.lowerBound
        XCTAssertGreaterThan(looseWidth, tightWidth)
    }

    func testNothingLoggedAtAllSaysSoPlainly() {
        // `logEveryNthDay` can never produce zero logged days — offset 0 always
        // matches — so the intake has to be stripped explicitly.
        var database = goodDatabase()
        database.days = database.days.map { day in
            var copy = day
            copy.values[.dietaryEnergy] = nil
            return copy
        }
        let result = audit(database, FoodLog())
        XCTAssertEqual(result.confidence, .unreliable)
        XCTAssertTrue(result.findings.contains { $0.message.contains("No food logged") })
    }

    func testFindingsAreOrderedWorstFirst() {
        let result = audit(goodDatabase(logEveryNthDay: 4, includeBasal: false),
                           log(days: 22, verified: false))
        let impacts = result.findings.map(\.impact)
        XCTAssertEqual(impacts, impacts.sorted(by: >), "the blocking problem must lead")
    }

    func testEveryFindingOffersSomethingToDoAboutIt() {
        let result = audit(goodDatabase(logEveryNthDay: 4), log(days: 22, verified: false))
        for finding in result.findings where finding.impact != .note {
            XCTAssertNotNil(finding.remedy, "no remedy offered for: \(finding.message)")
        }
    }
}
