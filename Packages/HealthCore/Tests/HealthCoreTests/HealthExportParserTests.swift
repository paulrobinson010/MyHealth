import XCTest
@testable import HealthCore

final class HealthExportParserTests: XCTestCase {

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func write(_ xml: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("export.xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Fixtures

    /// Two devices logging the same day, mixed units, a workout with the modern
    /// child-element statistics, an activity summary, and sleep across midnight.
    private var fixture: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData locale="en_GB">
         <ExportDate value="2024-03-18 09:00:00 +0000"/>
         <Me HKCharacteristicTypeIdentifierDateOfBirth="1986-04-12" HKCharacteristicTypeIdentifierBiologicalSex="HKBiologicalSexMale"/>

         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2024-03-17 08:00:00 +0000" endDate="2024-03-17 08:10:00 +0000" value="4000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="iPhone" unit="count" startDate="2024-03-17 09:00:00 +0000" endDate="2024-03-17 09:10:00 +0000" value="1000"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" startDate="2024-03-17 08:00:00 +0000" endDate="2024-03-17 08:10:00 +0000" value="4500"/>
         <Record type="HKQuantityTypeIdentifierStepCount" sourceName="Apple Watch" unit="count" startDate="2024-03-17 09:00:00 +0000" endDate="2024-03-17 09:10:00 +0000" value="1200"/>

         <Record type="HKQuantityTypeIdentifierDistanceWalkingRunning" sourceName="Apple Watch" unit="mi" startDate="2024-03-17 08:00:00 +0000" endDate="2024-03-17 08:10:00 +0000" value="2"/>

         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2024-03-17 08:00:00 +0000" endDate="2024-03-17 08:00:10 +0000" value="60"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2024-03-17 12:00:00 +0000" endDate="2024-03-17 12:00:10 +0000" value="150"/>
         <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2024-03-17 18:00:00 +0000" endDate="2024-03-17 18:00:10 +0000" value="90"/>

         <Record type="HKQuantityTypeIdentifierRestingHeartRate" sourceName="Apple Watch" unit="count/min" startDate="2024-03-17 06:00:00 +0000" endDate="2024-03-17 06:00:00 +0000" value="54"/>
         <Record type="HKQuantityTypeIdentifierVO2Max" sourceName="Apple Watch" unit="mL/min·kg" startDate="2024-03-17 10:00:00 +0000" endDate="2024-03-17 10:00:00 +0000" value="48.5"/>
         <Record type="HKQuantityTypeIdentifierBodyMass" sourceName="Scale" unit="lb" startDate="2024-03-17 07:00:00 +0000" endDate="2024-03-17 07:00:00 +0000" value="176.37"/>

         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" value="HKCategoryValueSleepAnalysisAsleepCore" startDate="2024-03-16 23:00:00 +0000" endDate="2024-03-17 03:00:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" value="HKCategoryValueSleepAnalysisAsleepREM" startDate="2024-03-17 03:00:00 +0000" endDate="2024-03-17 06:00:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierSleepAnalysis" sourceName="Apple Watch" value="HKCategoryValueSleepAnalysisAwake" startDate="2024-03-17 06:00:00 +0000" endDate="2024-03-17 06:30:00 +0000"/>

         <Record type="HKCategoryTypeIdentifierAppleStandHour" sourceName="Apple Watch" value="HKCategoryValueAppleStandHourStood" startDate="2024-03-17 10:00:00 +0000" endDate="2024-03-17 11:00:00 +0000"/>
         <Record type="HKCategoryTypeIdentifierAppleStandHour" sourceName="Apple Watch" value="HKCategoryValueAppleStandHourIdle" startDate="2024-03-17 11:00:00 +0000" endDate="2024-03-17 12:00:00 +0000"/>

         <ActivitySummary dateComponents="2024-03-17" activeEnergyBurned="642" activeEnergyBurnedGoal="600" activeEnergyBurnedUnit="kcal" appleExerciseTime="47" appleExerciseTimeGoal="30" appleStandHours="12" appleStandHoursGoal="12"/>

         <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="42.5" durationUnit="min" sourceName="Apple Watch" startDate="2024-03-17 17:00:00 +0000" endDate="2024-03-17 17:42:30 +0000">
          <MetadataEntry key="HKIndoorWorkout" value="0"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierActiveEnergyBurned" startDate="2024-03-17 17:00:00 +0000" endDate="2024-03-17 17:42:30 +0000" sum="410" unit="kcal"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierDistanceWalkingRunning" startDate="2024-03-17 17:00:00 +0000" endDate="2024-03-17 17:42:30 +0000" sum="8.2" unit="km"/>
          <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" startDate="2024-03-17 17:00:00 +0000" endDate="2024-03-17 17:42:30 +0000" average="152" minimum="110" maximum="176" unit="count/min"/>
         </Workout>

         <Workout workoutActivityType="HKWorkoutActivityTypeTraditionalStrengthTraining" duration="30" durationUnit="min" totalEnergyBurned="180" totalEnergyBurnedUnit="kcal" sourceName="iPhone" startDate="2024-03-18 07:00:00 +0000" endDate="2024-03-18 07:30:00 +0000"/>
        </HealthData>
        """
    }

    // MARK: - Tests

    func testParsesProfileAndExportDate() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        XCTAssertEqual(database.profile.dateOfBirth?.description, "1986-04-12")
        XCTAssertEqual(database.profile.biologicalSex, .male)
        XCTAssertNotNil(database.exportedAt)
    }

    func testStepsAreDeduplicatedAcrossSourcesRatherThanSummed() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        // iPhone totals 5000, Watch totals 5700. Naive summing would give 10,700.
        XCTAssertEqual(day[.steps], 5700)
    }

    func testDistanceIsConvertedFromMiles() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        XCTAssertEqual(try XCTUnwrap(day[.walkingRunningDistance]), 3.218_688, accuracy: 1e-5)
    }

    func testHeartRateProducesAverageMinimumAndMaximum() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        XCTAssertEqual(try XCTUnwrap(day[.heartRateAverage]), 100, accuracy: 1e-9)
        XCTAssertEqual(day[.heartRateMin], 60)
        XCTAssertEqual(day[.heartRateMax], 150)
    }

    func testActivitySummaryOverridesRecords() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        XCTAssertEqual(day[.activeEnergy], 642)
        XCTAssertEqual(day[.exerciseMinutes], 47)
        // Apple's own ring value wins over the single "Stood" category record.
        XCTAssertEqual(day[.standHours], 12)
    }

    func testSleepIsFiledUnderTheWakeDayAndExcludesAwakeSegments() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        // 4h core + 3h REM, and the 30 minutes awake do not count.
        XCTAssertEqual(try XCTUnwrap(day[.sleepHours]), 7, accuracy: 1e-9)
    }

    func testWeightConvertsFromPounds() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        XCTAssertEqual(try XCTUnwrap(day[.bodyMass]), 80, accuracy: 0.01)
    }

    func testWorkoutsParseFromBothModernAndLegacyLayouts() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        XCTAssertEqual(database.workouts.count, 2)

        let run = try XCTUnwrap(database.workouts.first { $0.activity.rawValue == "Running" })
        XCTAssertEqual(run.durationMinutes, 42.5, accuracy: 1e-9)
        XCTAssertEqual(run.energyKcal, 410)          // from <WorkoutStatistics>
        XCTAssertEqual(run.distanceKm, 8.2)
        XCTAssertEqual(run.averageHeartRate, 152)
        XCTAssertEqual(run.maxHeartRate, 176)

        let lift = try XCTUnwrap(database.workouts.first { $0.activity.rawValue == "TraditionalStrengthTraining" })
        XCTAssertEqual(lift.energyKcal, 180)         // from legacy attributes
        XCTAssertEqual(lift.activity.title, "Strength Training")
    }

    func testWorkoutTotalsRollUpIntoTheDay() throws {
        let database = try HealthExportParser(fileURL: try write(fixture)).parse()
        let day = try XCTUnwrap(database.days.first { $0.day.description == "2024-03-17" })
        XCTAssertEqual(day[.workoutCount], 1)
        XCTAssertEqual(try XCTUnwrap(day[.workoutMinutes]), 42.5, accuracy: 1e-9)
        XCTAssertEqual(day[.workoutEnergy], 410)
        XCTAssertEqual(day[.workoutDistance], 8.2)
    }

    func testRejectsAFileThatIsNotAHealthExport() throws {
        let url = try write("<?xml version=\"1.0\"?><Something><Else/></Something>")
        XCTAssertThrowsError(try HealthExportParser(fileURL: url).parse()) { error in
            guard case ImportError.notAHealthExport = error else {
                return XCTFail("expected notAHealthExport, got \(error)")
            }
        }
    }

    func testReportsProgress() throws {
        let box = ProgressBox()
        _ = try HealthExportParser(fileURL: try write(fixture), progress: { box.record($0) }).parse()
        XCTAssertGreaterThan(box.updates.count, 0)
        XCTAssertEqual(box.updates.last?.fraction, 1)
    }
}

/// Collects progress callbacks from whatever thread they arrive on.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportProgress] = []

    func record(_ progress: ImportProgress) {
        lock.withLock { storage.append(progress) }
    }

    var updates: [ImportProgress] {
        lock.withLock { storage }
    }
}
