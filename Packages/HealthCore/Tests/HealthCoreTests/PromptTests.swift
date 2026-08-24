import XCTest
@testable import HealthCore

final class WearAnalysisTests: XCTestCase {

    private func samples(everyMinutes: Int, count: Int, from start: Date) -> [Date] {
        (0..<count).map { start.addingTimeInterval(Double($0 * everyMinutes * 60)) }
    }

    func testAWornWatchProducesNoGaps() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(WearAnalysis.gaps(inHeartRateSamples: samples(everyMinutes: 5,
                                                                    count: 20,
                                                                    from: start)).isEmpty)
    }

    func testAShowerLengthSilenceIsDetected() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var times = samples(everyMinutes: 5, count: 6, from: start)
        // Watch comes off for 20 minutes.
        let resume = times[times.count - 1].addingTimeInterval(20 * 60)
        times += samples(everyMinutes: 5, count: 6, from: resume)

        let gaps = WearAnalysis.gaps(inHeartRateSamples: times)
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.minutes, 20, accuracy: 0.1)
        XCTAssertTrue(gap.looksLikeAShower)
    }

    func testOvernightSilenceIsNotAShower() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let times = [start, start.addingTimeInterval(8 * 3600)]
        XCTAssertTrue(WearAnalysis.gaps(inHeartRateSamples: times).isEmpty,
                      "eight hours is sleep or a charger, not a shower")
    }

    func testUnsortedSamplesStillWork() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let times = [start.addingTimeInterval(1_800), start, start.addingTimeInterval(2_100)]
        let gap = try XCTUnwrap(WearAnalysis.gaps(inHeartRateSamples: times).first)
        XCTAssertEqual(gap.minutes, 30, accuracy: 0.1)
    }

    func testTheMomentTheWatchGoesBackOnIsIdentified() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gap = WearGap(start: now.addingTimeInterval(-25 * 60),
                          end: now.addingTimeInterval(-3 * 60))
        XCTAssertNotNil(WearAnalysis.gapJustEnded([gap], now: now))

        let stale = WearGap(start: now.addingTimeInterval(-120 * 60),
                            end: now.addingTimeInterval(-100 * 60))
        XCTAssertNil(WearAnalysis.gapJustEnded([stale], now: now),
                     "an hour later they are not standing by the scale")
    }

    func testAGapIsMatchedToAWorkoutThatPrecededIt() {
        let workoutEnd = Date(timeIntervalSince1970: 1_700_000_000)
        let soonAfter = WearGap(start: workoutEnd.addingTimeInterval(15 * 60),
                                end: workoutEnd.addingTimeInterval(35 * 60))
        XCTAssertTrue(WearAnalysis.gap(soonAfter, follows: workoutEnd))

        let muchLater = WearGap(start: workoutEnd.addingTimeInterval(6 * 3600),
                                end: workoutEnd.addingTimeInterval(6 * 3600 + 20 * 60))
        XCTAssertFalse(WearAnalysis.gap(muchLater, follows: workoutEnd))
    }
}

final class WeighInCueTests: XCTestCase {

    private let detector = WeighInCueDetector()

    private func date(hour: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2024; components.month = 6; components.day = day
        components.hour = hour; components.minute = 30
        return Calendar.current.date(from: components) ?? Date()
    }

    private func workout(endingAt end: Date, minutes: Double = 45) -> WorkoutSummary {
        WorkoutSummary(day: DayKey(date: end),
                       start: end.timeIntervalSince1970 - minutes * 60,
                       durationMinutes: minutes,
                       activity: WorkoutActivity(rawValue: "Running"),
                       sourceName: "Apple Watch")
    }

    /// The signal the whole feature is built around.
    func testAShowerAfterAWorkoutIsTheCue() throws {
        let now = date(hour: 18)
        let workoutEnd = now.addingTimeInterval(-40 * 60)
        // Samples stop 5 minutes after the workout, resume 3 minutes ago.
        let times = [workoutEnd.addingTimeInterval(300), now.addingTimeInterval(-180)]

        let cue = try XCTUnwrap(detector.cue(.init(
            now: now,
            recentHeartRateSamples: times,
            recentWorkouts: [workout(endingAt: workoutEnd)],
            weighInDays: [DayKey(date: now).adding(days: -1)],
            weighInHours: [])))

        XCTAssertEqual(cue.trigger, .afterShower)
    }

    func testAGapWithNoWorkoutBeforeItIsNotACue() {
        let now = date(hour: 14)
        let times = [now.addingTimeInterval(-30 * 60), now.addingTimeInterval(-180)]
        let cue = detector.cue(.init(now: now,
                                     recentHeartRateSamples: times,
                                     recentWorkouts: [],
                                     weighInDays: [DayKey(date: now).adding(days: -1)]))
        XCTAssertNotEqual(cue?.trigger, .afterShower,
                          "taking a watch off at lunchtime proves nothing")
    }

    func testItNeverAsksTwiceInADay() {
        let now = date(hour: 18)
        let workoutEnd = now.addingTimeInterval(-40 * 60)
        let times = [workoutEnd.addingTimeInterval(300), now.addingTimeInterval(-180)]
        XCTAssertNil(detector.cue(.init(now: now,
                                        recentHeartRateSamples: times,
                                        recentWorkouts: [workout(endingAt: workoutEnd)],
                                        weighInDays: [],
                                        alreadyPromptedToday: true)))
    }

    func testItStaysQuietOnceTheyHaveWeighed() {
        let now = date(hour: 18)
        let workoutEnd = now.addingTimeInterval(-40 * 60)
        let times = [workoutEnd.addingTimeInterval(300), now.addingTimeInterval(-180)]
        XCTAssertNil(detector.cue(.init(now: now,
                                        recentHeartRateSamples: times,
                                        recentWorkouts: [workout(endingAt: workoutEnd)],
                                        weighInDays: [DayKey(date: now)])))
    }

    func testItDoesNotWakeAnyoneUp() {
        let now = date(hour: 3)
        XCTAssertNil(detector.cue(.init(now: now, weighInDays: [])))
    }

    func testTheUsualHourIsLearnedFromHabit() throws {
        let now = date(hour: 7)
        let cue = try XCTUnwrap(detector.cue(.init(
            now: now,
            weighInDays: [DayKey(date: now).adding(days: -1)],
            weighInHours: [7, 7, 7, 8, 7, 7])))
        XCTAssertEqual(cue.trigger, .usualTime)
    }

    func testAnInconsistentHistoryTeachesNoHabit() {
        XCTAssertNil(detector.usualHour([6, 9, 13, 17, 21, 8]))
        XCTAssertNil(detector.usualHour([7, 7]), "two readings is not a habit")
    }

    func testBeingOverdueEscalates() throws {
        let now = date(hour: 9)
        let cue = try XCTUnwrap(detector.cue(.init(
            now: now,
            weighInDays: [DayKey(date: now).adding(days: -9)])))
        guard case .overdue(let days) = cue.trigger else {
            return XCTFail("expected an overdue cue")
        }
        XCTAssertEqual(days, 9)
        XCTAssertEqual(cue.urgency, .important)
    }

    func testOverdueDoesNotBecomeADailyNag() {
        let now = date(hour: 9)
        // Days 3 and 5 fire; day 4 does not.
        func cueAfter(_ days: Int) -> WeighInCue? {
            detector.cue(.init(now: now, weighInDays: [DayKey(date: now).adding(days: -days)]))
        }
        XCTAssertNotNil(cueAfter(3))
        XCTAssertNil(cueAfter(4))
        XCTAssertNotNil(cueAfter(5))
    }

    func testSomeoneWhoHasNeverWeighedIsAskedOnce() throws {
        let cue = try XCTUnwrap(detector.cue(.init(now: date(hour: 9), weighInDays: [])))
        XCTAssertEqual(cue.trigger, .overdue(days: 0))
    }
}

final class MealHabitsTests: XCTestCase {

    private func log(hours: [Int], days: Int) -> FoodLog {
        var log = FoodLog()
        let today = DayKey.today
        for offset in 0..<days {
            let day = today.adding(days: -offset)
            for hour in hours {
                log.add(FoodEntry(
                    name: "meal",
                    timestamp: day.localDate().timeIntervalSince1970 + Double(hour) * 3600,
                    nutrition: Nutrition(kilocalories: 600)))
            }
        }
        return log
    }

    func testHabitualMealsBecomeWindows() throws {
        let habits = MealHabits.learn(from: log(hours: [8, 13, 19], days: 20))
        XCTAssertEqual(habits.windows.count, 3)
        XCTAssertEqual(habits.windows.map(\.name), ["Breakfast", "Lunch", "Dinner"])
        XCTAssertEqual(try XCTUnwrap(habits.windows.first).hour, 8)
    }

    /// Someone who never eats breakfast should not be asked about breakfast.
    func testAMealTheyDoNotEatIsNotAWindow() {
        let habits = MealHabits.learn(from: log(hours: [13, 19], days: 20))
        XCTAssertFalse(habits.windows.contains { $0.name == "Breakfast" })
    }

    func testTooLittleHistoryTeachesNothing() {
        XCTAssertTrue(MealHabits.learn(from: log(hours: [8, 13], days: 2)).windows.isEmpty)
    }

    func testReliabilityReflectsHowOftenTheyActuallyLogIt() throws {
        var log = FoodLog()
        let today = DayKey.today
        for offset in 0..<20 {
            let day = today.adding(days: -offset)
            // Dinner every day, lunch every other day.
            log.add(FoodEntry(name: "dinner",
                              timestamp: day.localDate().timeIntervalSince1970 + 19 * 3600,
                              nutrition: Nutrition(kilocalories: 800)))
            if offset % 2 == 0 {
                log.add(FoodEntry(name: "lunch",
                                  timestamp: day.localDate().timeIntervalSince1970 + 13 * 3600,
                                  nutrition: Nutrition(kilocalories: 600)))
            }
        }
        let habits = MealHabits.learn(from: log)
        let dinner = try XCTUnwrap(habits.windows.first { $0.name == "Dinner" })
        let lunch = try XCTUnwrap(habits.windows.first { $0.name == "Lunch" })
        XCTAssertGreaterThan(dinner.reliability, lunch.reliability)
    }
}

final class LoggingPromptSchedulerTests: XCTestCase {

    private let scheduler = LoggingPromptScheduler()

    private func date(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2024; components.month = 6; components.day = 15
        components.hour = hour; components.minute = 5
        return Calendar.current.date(from: components) ?? Date()
    }

    private var habits: MealHabits {
        MealHabits(windows: [
            .init(name: "Breakfast", hour: 8, reliability: 0.9),
            .init(name: "Lunch", hour: 13, reliability: 0.8),
            .init(name: "Dinner", hour: 19, reliability: 0.9)
        ])
    }

    func testAMissedMealIsRaisedOnceTheGracePeriodHasPassed() throws {
        let prompts = scheduler.prompts(.init(now: date(hour: 15), habits: habits))
        XCTAssertTrue(prompts.contains { $0.trigger == .missedMeal(name: "Breakfast") })
        XCTAssertTrue(prompts.contains { $0.trigger == .missedMeal(name: "Lunch") })
        XCTAssertFalse(prompts.contains { $0.trigger == .missedMeal(name: "Dinner") },
                       "dinner has not happened yet")
    }

    func testAMealThatWasLoggedIsNotRaised() {
        var log = FoodLog()
        log.add(FoodEntry(name: "eggs",
                          timestamp: date(hour: 8).timeIntervalSince1970,
                          nutrition: Nutrition(kilocalories: 400)))
        let prompts = scheduler.prompts(.init(now: date(hour: 11), log: log, habits: habits))
        XCTAssertFalse(prompts.contains { $0.trigger == .missedMeal(name: "Breakfast") })
    }

    /// A reminder that fires just after someone logged is how people learn to
    /// ignore reminders.
    func testItStaysQuietJustAfterSomethingWasLogged() {
        var log = FoodLog()
        log.add(FoodEntry(name: "lunch",
                          timestamp: date(hour: 15).timeIntervalSince1970 - 600,
                          nutrition: Nutrition(kilocalories: 700)))
        XCTAssertTrue(scheduler.prompts(.init(now: date(hour: 15), log: log,
                                              habits: habits)).isEmpty)
    }

    func testNothingFiresAtNight() {
        XCTAssertTrue(scheduler.prompts(.init(now: date(hour: 2), habits: habits)).isEmpty)
        XCTAssertTrue(scheduler.prompts(.init(now: date(hour: 23), habits: habits)).isEmpty)
    }

    func testTheDailyBudgetIsRespected() {
        let prompts = scheduler.prompts(.init(
            now: date(hour: 21),
            habits: habits,
            alreadySentToday: ["meal-breakfast", "meal-lunch"]))
        XCTAssertLessThanOrEqual(prompts.count, 1)
    }

    func testNothingRepeatsWithinADay() {
        let prompts = scheduler.prompts(.init(
            now: date(hour: 15), habits: habits, alreadySentToday: ["meal-breakfast"]))
        XCTAssertFalse(prompts.contains { $0.trigger == .missedMeal(name: "Breakfast") })
    }

    func testAnEmptyDayIsRaisedInTheEvening() {
        let prompts = scheduler.prompts(.init(now: date(hour: 21), habits: .empty))
        XCTAssertTrue(prompts.contains { $0.trigger == .endOfDay })
    }

    /// The only prompt that earns being insistent.
    func testBlockedCoverageIsRaisedWithUrgency() throws {
        let integrity = DeficitIntegrity(confidence: .unreliable,
                                         findings: [],
                                         loggedDays: 6,
                                         totalDays: 30,
                                         verifiedCalorieShare: 0.5,
                                         dailyDeficit: nil,
                                         uncertaintyRange: nil)
        let prompts = scheduler.prompts(.init(now: date(hour: 19),
                                              habits: .empty,
                                              integrity: integrity))
        let prompt = try XCTUnwrap(prompts.first { $0.urgency == .important })
        XCTAssertTrue(prompt.body.contains("6 of the last 30"))
    }

    /// If nothing is wrong, say nothing.
    func testGoodCoverageProducesSilence() {
        let integrity = DeficitIntegrity(confidence: .solid,
                                         findings: [],
                                         loggedDays: 29,
                                         totalDays: 30,
                                         verifiedCalorieShare: 0.9,
                                         dailyDeficit: 400,
                                         uncertaintyRange: 300...500)
        var log = FoodLog()
        log.add(FoodEntry(name: "dinner",
                          timestamp: date(hour: 19).timeIntervalSince1970,
                          nutrition: Nutrition(kilocalories: 700)))
        XCTAssertTrue(scheduler.prompts(.init(now: date(hour: 20), log: log,
                                              habits: .empty, integrity: integrity)).isEmpty)
    }

    func testMoreUrgentPromptsComeFirst() {
        let integrity = DeficitIntegrity(confidence: .unreliable, findings: [],
                                         loggedDays: 2, totalDays: 30,
                                         verifiedCalorieShare: 0, dailyDeficit: nil,
                                         uncertaintyRange: nil)
        let prompts = scheduler.prompts(.init(now: date(hour: 21),
                                              habits: habits,
                                              integrity: integrity))
        XCTAssertEqual(prompts.first?.urgency, .important)
    }
}
