import XCTest
@testable import HealthCore

final class TimeSeriesTests: XCTestCase {

    private func series(_ metric: Metric, from start: DayKey, values: [Double]) -> TimeSeries {
        TimeSeries(metric: metric, points: values.enumerated().map {
            .init(day: start.adding(days: $0.offset), value: $0.element)
        })
    }

    func testRollingMeanUsesATrailingWindow() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let input = series(.steps, from: start, values: [10, 20, 30, 40, 50])
        let rolled = input.rollingMean(window: 3)
        XCTAssertEqual(rolled.count, 5)
        XCTAssertEqual(rolled.points[0].value, 10)            // only itself available
        XCTAssertEqual(rolled.points[1].value, 15)            // (10+20)/2
        XCTAssertEqual(rolled.points[4].value, 40)            // (30+40+50)/3
    }

    func testRollingMeanSkipsMissingDaysRatherThanTreatingThemAsZero() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        // A ten-day gap, then two more values.
        let points: [TimeSeries.Point] = [
            .init(day: start, value: 100),
            .init(day: start.adding(days: 20), value: 50),
            .init(day: start.adding(days: 21), value: 70)
        ]
        let rolled = TimeSeries(metric: .steps, points: points).rollingMean(window: 7)
        XCTAssertEqual(rolled.points[1].value, 50)            // the old value has aged out
        XCTAssertEqual(rolled.points[2].value, 60)            // (50+70)/2
    }

    func testRollingSum() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let rolled = series(.steps, from: start, values: [1, 2, 3, 4]).rollingSum(window: 2)
        XCTAssertEqual(rolled.points.map(\.value), [1, 3, 5, 7])
    }

    func testBucketingSumsAdditiveMetricsAndAveragesMeasurements() {
        let start = DayKey(year: 2024, month: 1, day: 1)  // a Monday
        let steps = series(.steps, from: start, values: Array(repeating: 1000, count: 14))
        let weeks = steps.bucketed(by: .week)
        XCTAssertEqual(weeks.count, 2)
        XCTAssertEqual(weeks[0].value, 7000)

        let resting = series(.restingHeartRate, from: start, values: Array(repeating: 55, count: 14))
        XCTAssertEqual(resting.bucketed(by: .week)[0].value, 55)
    }

    func testForceAverageMakesPartialPeriodsComparable() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let steps = series(.steps, from: start, values: Array(repeating: 1000, count: 3))
        XCTAssertEqual(steps.bucketed(by: .month)[0].value, 3000)
        XCTAssertEqual(steps.bucketed(by: .month, forceAverage: true)[0].value, 1000)
    }

    func testRegressionRecoversAKnownLine() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let values = (0..<30).map { 100.0 + 2.0 * Double($0) }
        let fit = try XCTUnwrap(series(.steps, from: start, values: values).regression())
        XCTAssertEqual(fit.slopePerDay, 2, accuracy: 1e-6)
        XCTAssertEqual(fit.rSquared, 1, accuracy: 1e-6)
        XCTAssertEqual(fit.value(at: start), 100, accuracy: 1e-6)
        XCTAssertEqual(fit.value(at: start.adding(days: 10)), 120, accuracy: 1e-6)
        XCTAssertEqual(fit.slopePerWeek, 14, accuracy: 1e-6)
    }

    func testFlatSeriesHasNoMeaningfulTrend() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let fit = try XCTUnwrap(series(.steps, from: start,
                                       values: Array(repeating: 42, count: 20)).regression())
        XCTAssertEqual(fit.slopePerDay, 0, accuracy: 1e-9)
        XCTAssertFalse(fit.isMeaningful)
    }

    func testQuantiles() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let input = series(.steps, from: start, values: [1, 2, 3, 4, 5])
        XCTAssertEqual(input.quantile(0.5), 3)
        XCTAssertEqual(input.quantile(0), 1)
        XCTAssertEqual(input.quantile(1), 5)
    }

    func testTrailingWindow() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let input = series(.steps, from: start, values: Array(repeating: 1, count: 100))
        XCTAssertEqual(input.trailing(7).count, 7)
    }
}

final class TrendAnalysisTests: XCTestCase {

    /// Steps that hold at 5,000 for 28 days and then rise to 7,500.
    private func steppedDatabase() -> HealthDatabase {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<56 {
            days.append(DailySummary(day: start.adding(days: offset),
                                     values: [.steps: offset < 28 ? 5_000 : 7_500]))
        }
        return HealthDatabase(days: days)
    }

    func testTrendComparesWindowAgainstThePreviousWindow() {
        let trend = TrendAnalysis.trend(for: .steps, in: steppedDatabase(), window: 28)
        XCTAssertEqual(trend.current, 7_500 * 28)
        XCTAssertEqual(trend.previous, 5_000 * 28)
        XCTAssertEqual(try XCTUnwrap(trend.changeVsPrevious), 0.5, accuracy: 1e-9)
        XCTAssertEqual(trend.direction, .improving)
    }

    func testDirectionRespectsWhetherHigherIsBetter() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<56 {
            days.append(DailySummary(day: start.adding(days: offset),
                                     values: [.restingHeartRate: offset < 28 ? 60 : 52]))
        }
        let trend = TrendAnalysis.trend(for: .restingHeartRate, in: HealthDatabase(days: days), window: 28)
        // The number went down, which for resting heart rate is an improvement.
        XCTAssertLessThan(try XCTUnwrap(trend.changeVsPrevious), 0)
        XCTAssertEqual(trend.direction, .improving)
    }

    func testSmallChangesReadAsSteady() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        var days: [DailySummary] = []
        for offset in 0..<56 {
            days.append(DailySummary(day: start.adding(days: offset),
                                     values: [.steps: offset < 28 ? 5_000 : 5_050]))
        }
        let trend = TrendAnalysis.trend(for: .steps, in: HealthDatabase(days: days), window: 28)
        XCTAssertEqual(trend.direction, .steady)
    }

    func testStreaks() {
        let start = DayKey(year: 2024, month: 1, day: 1)
        // Five good days, one bad, then three good.
        let pattern: [Double] = [12_000, 11_000, 10_500, 10_000, 10_200, 3_000, 10_100, 10_800, 11_500]
        let days = pattern.enumerated().map {
            DailySummary(day: start.adding(days: $0.offset), values: [.steps: $0.element])
        }
        let streak = TrendAnalysis.streak(for: .steps,
                                          in: HealthDatabase(days: days),
                                          atLeast: 10_000,
                                          endingAt: start.adding(days: 8))
        XCTAssertEqual(streak.longest, 5)
        XCTAssertEqual(streak.current, 3)
    }

    func testPersonalBestPicksTheRightDirection() throws {
        let start = DayKey(year: 2024, month: 1, day: 1)
        let days = (0..<21).map {
            DailySummary(day: start.adding(days: $0),
                         values: [.restingHeartRate: $0 == 10 ? 45 : 60])
        }
        let best = try XCTUnwrap(TrendAnalysis.personalBest(for: .restingHeartRate,
                                                            in: HealthDatabase(days: days),
                                                            bucket: .week))
        // Lower is better for resting heart rate, so the best week is the one
        // containing the 45 bpm day.
        XCTAssertLessThan(best.value, 60)
    }
}
