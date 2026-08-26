import XCTest
@testable import HealthCore

/// The Mac has no HealthKit store, so everything it shows about activity
/// arrives through this path. If these properties do not hold, the Mac shows
/// something quietly wrong — which is worse than showing nothing.
final class MetricSyncTests: XCTestCase {

    private let coordinator = MetricSyncCoordinator()

    private func day(_ ordinal: Int) -> DayKey { DayKey(ordinal: ordinal) }

    private func summary(_ ordinal: Int, _ values: [Metric: Double]) -> DailySummary {
        DailySummary(day: day(ordinal), values: values)
    }

    // MARK: - Record identity

    func testSameDayProducesSameRecordIDOnEveryDevice() {
        // Two devices minting an ID for the same day must agree, or CloudKit
        // accumulates one duplicate record per device per day.
        let a = MetricSyncCoordinator.recordID(forDay: day(738_000))
        let b = MetricSyncCoordinator.recordID(forDay: day(738_000))
        XCTAssertEqual(a, b)
    }

    func testDifferentDaysProduceDifferentRecordIDs() {
        var seen = Set<UUID>()
        for ordinal in 730_000..<734_000 {
            seen.insert(MetricSyncCoordinator.recordID(forDay: day(ordinal)))
        }
        XCTAssertEqual(seen.count, 4_000, "a decade of days must not collide")
    }

    func testWorkoutIDsSeparateActivitiesInTheSameSecond() {
        let run = WorkoutSummary(day: day(738_000), start: 1_700_000_000, durationMinutes: 30,
                                 activity: WorkoutActivity(identifier: "HKWorkoutActivityTypeRunning"),
                                 sourceName: "Watch")
        var swim = run
        swim.activity = WorkoutActivity(identifier: "HKWorkoutActivityTypeSwimming")
        XCTAssertNotEqual(MetricSyncCoordinator.recordID(forWorkout: run),
                          MetricSyncCoordinator.recordID(forWorkout: swim))
    }

    func testDayAndWorkoutNamespacesDoNotOverlap() {
        let workout = WorkoutSummary(day: day(0), start: 0, durationMinutes: 1,
                                     activity: WorkoutActivity(identifier: "X"), sourceName: "s")
        XCTAssertNotEqual(MetricSyncCoordinator.recordID(forDay: day(0)),
                          MetricSyncCoordinator.recordID(forWorkout: workout))
        XCTAssertNotEqual(MetricSyncCoordinator.recordID(forDay: day(0)),
                          MetricSyncCoordinator.profileRecordID)
    }

    // MARK: - Merging days

    func testMergeIsAUnionSoNeitherDeviceLosesData() {
        // The watch read four metrics; the phone read a different four. The
        // day must end up with all eight.
        let watch = summary(1, [.steps: 8_000, .activeEnergy: 400])
        let phone = summary(1, [.restingHeartRate: 52, .bodyMass: 80])
        let merged = watch.merged(with: phone)
        XCTAssertEqual(merged.values.count, 4)
        XCTAssertEqual(merged[.steps], 8_000)
        XCTAssertEqual(merged[.bodyMass], 80)
    }

    func testMergeIsCommutative() {
        // Sync applies changes in whatever order the network delivers them.
        let a = summary(1, [.steps: 8_000, .restingHeartRate: 52, .vo2Max: 44])
        let b = summary(1, [.steps: 9_500, .restingHeartRate: 55, .bodyMass: 80])
        XCTAssertEqual(a.merged(with: b), b.merged(with: a))
    }

    func testMergeIsCommutativeOnEquallyCompleteDisagreement() {
        // The tie case: neither side is more credible, and picking "mine"
        // would silently make the two devices disagree forever.
        let a = summary(1, [.bodyMass: 80.0, .steps: 100])
        let b = summary(1, [.bodyMass: 81.5, .steps: 100])
        XCTAssertEqual(a.merged(with: b), b.merged(with: a))
    }

    func testASparseReadNeverShrinksACumulativeDay() {
        // The one that would corrupt the deficit: a watch that saw 3,000 of
        // the day's 11,200 steps must not lower the day on every other device.
        let full = summary(1, [.steps: 11_200, .activeEnergy: 780])
        let partial = summary(1, [.steps: 3_000, .activeEnergy: 210])
        let merged = full.merged(with: partial)
        XCTAssertEqual(merged[.steps], 11_200)
        XCTAssertEqual(merged[.activeEnergy], 780)
        XCTAssertEqual(merged, partial.merged(with: full))
    }

    func testMergeIsAssociative() {
        let a = summary(1, [.steps: 8_000, .vo2Max: 44])
        let b = summary(1, [.steps: 9_500, .restingHeartRate: 52])
        let c = summary(1, [.activeEnergy: 600, .vo2Max: 46])
        XCTAssertEqual(a.merged(with: b).merged(with: c),
                       a.merged(with: b.merged(with: c)))
    }

    func testPointInTimeDisagreementResolvesTheSameWayBothWays() {
        // `max` is not "the true reading" here, it is the higher of two. What
        // it is, is the same answer on every device — see the note on `merged`.
        let a = summary(1, [.bodyMass: 80, .steps: 1, .vo2Max: 44])
        let b = summary(1, [.bodyMass: 95])
        XCTAssertEqual(a.merged(with: b)[.bodyMass], b.merged(with: a)[.bodyMass])
    }

    func testCumulativeMetricsTakeTheLargerRead() {
        // Same de-duplication rule the importer uses across sources: a device
        // that saw part of a walk must not shrink the day.
        let partial = summary(1, [.steps: 3_000])
        let full = summary(1, [.steps: 11_200])
        XCTAssertEqual(partial.merged(with: full)[.steps], 11_200)
        XCTAssertEqual(Metric.steps.aggregation, .sum)
    }

    func testExtremaKeepTheirDirection() {
        // Taking `max` for everything would quietly raise the day's lowest
        // heart rate towards the higher of two partial reads.
        XCTAssertEqual(Metric.heartRateMin.aggregation, .minimum)
        XCTAssertEqual(Metric.heartRateMax.aggregation, .maximum)

        let a = summary(1, [.heartRateMin: 48, .heartRateMax: 160])
        let b = summary(1, [.heartRateMin: 55, .heartRateMax: 172])
        let merged = a.merged(with: b)
        XCTAssertEqual(merged[.heartRateMin], 48)
        XCTAssertEqual(merged[.heartRateMax], 172)
        XCTAssertEqual(merged, b.merged(with: a))
    }

    func testMergeIsIdempotent() {
        // The same record arriving twice — a retry after an ambiguous network
        // failure — must not move anything.
        let a = summary(1, [.steps: 8_000, .bodyMass: 80, .heartRateMin: 48])
        let b = summary(1, [.steps: 9_500, .vo2Max: 44])
        let once = a.merged(with: b)
        XCTAssertEqual(once.merged(with: b), once)
        XCTAssertEqual(once.merged(with: a), once)
        XCTAssertEqual(once.merged(with: once), once)
    }

    func testThreeDevicesConvergeWhateverOrderTheyMergeIn() {
        // The property an earlier draft failed. Preferring whichever side had
        // read more of the day is more accurate pairwise and not associative:
        // three devices grouped differently settled on different VO2 max
        // values and then published them at each other indefinitely.
        let a = summary(1, [.steps: 8_000, .vo2Max: 44])
        let b = summary(1, [.steps: 9_500, .restingHeartRate: 52])
        let c = summary(1, [.activeEnergy: 600, .vo2Max: 46])

        let orders: [DailySummary] = [
            a.merged(with: b).merged(with: c),
            a.merged(with: c).merged(with: b),
            b.merged(with: a).merged(with: c),
            b.merged(with: c).merged(with: a),
            c.merged(with: a).merged(with: b),
            c.merged(with: b).merged(with: a),
            a.merged(with: b.merged(with: c)),
        ]
        for (index, result) in orders.enumerated() {
            XCTAssertEqual(result, orders[0], "order \(index) diverged")
        }
    }

    // MARK: - Applying remote changes

    func testASparseRemoteReadCannotEraseARichLocalDay() {
        // The failure this guards against: a Mac holding a ten-year import
        // gets a one-metric record from a watch and blanks the day.
        let local = HealthDatabase(days: [summary(1, [.steps: 12_000, .activeEnergy: 700,
                                                      .exerciseMinutes: 45, .vo2Max: 44])])
        let thin = summary(1, [.steps: 12_000])
        let records = coordinator.records(forDays: [thin])

        let result = coordinator.apply(records, deleted: [], to: local)
        XCTAssertEqual(result.database.days.count, 1)
        XCTAssertEqual(result.database.days[0].values.count, 4)
        XCTAssertEqual(result.conflicts, 1, "the thin read lost, and that is worth counting")
    }

    func testAnAbsentDayIsNotADeletion() {
        // Days are never deleted. A device part-way through its first import
        // must not wipe everyone else's history.
        let local = HealthDatabase(days: [summary(1, [.steps: 100]), summary(2, [.steps: 200])])
        let result = coordinator.apply(coordinator.records(forDays: [summary(1, [.steps: 100])]),
                                       deleted: [MetricSyncCoordinator.recordID(forDay: day(2))],
                                       to: local)
        XCTAssertEqual(result.database.days.count, 2)
        XCTAssertEqual(result.removed, 0)
    }

    func testIncomingDaysArriveAndAreSorted() {
        let local = HealthDatabase(days: [summary(5, [.steps: 500])])
        let incoming = coordinator.records(forDays: [summary(3, [.steps: 300]),
                                                     summary(9, [.steps: 900])])
        let result = coordinator.apply(incoming, deleted: [], to: local)
        XCTAssertEqual(result.database.days.map(\.day.ordinal), [3, 5, 9])
        XCTAssertEqual(result.applied, 2)
    }

    func testFoodLogRecordsInTheSameStreamAreIgnoredNotDropped() {
        // The two streams have separate zones, but nothing guarantees a record
        // of the other kind never arrives, and it must be a no-op.
        let local = HealthDatabase(days: [summary(1, [.steps: 100])])
        let alien = SyncRecord(id: UUID(), kind: .entry, payload: Data(), modified: Date(), rank: 1)
        let result = coordinator.apply([alien], deleted: [], to: local)
        XCTAssertEqual(result.database.days, local.days)
        XCTAssertEqual(result.applied, 0)
    }

    // MARK: - Workouts

    func testRicherWorkoutReadWins() {
        let bare = WorkoutSummary(day: day(1), start: 100, durationMinutes: 30,
                                  activity: WorkoutActivity(identifier: "Running"), sourceName: "Phone")
        var rich = bare
        rich.energyKcal = 320
        rich.averageHeartRate = 148

        let local = HealthDatabase(workouts: [bare])
        let result = coordinator.apply(coordinator.records(forWorkouts: [rich]), deleted: [], to: local)
        XCTAssertEqual(result.database.workouts.first?.energyKcal, 320)

        // And the other way round: the bare read must not overwrite the rich one.
        let reverse = coordinator.apply(coordinator.records(forWorkouts: [bare]),
                                        deleted: [],
                                        to: HealthDatabase(workouts: [rich]))
        XCTAssertEqual(reverse.database.workouts.first?.energyKcal, 320)
        XCTAssertEqual(reverse.conflicts, 1)
    }

    func testWorkoutDeletionIsHonoured() {
        let workout = WorkoutSummary(day: day(1), start: 100, durationMinutes: 30,
                                     activity: WorkoutActivity(identifier: "Running"), sourceName: "Phone")
        let result = coordinator.apply([], deleted: [MetricSyncCoordinator.recordID(forWorkout: workout)],
                                       to: HealthDatabase(workouts: [workout]))
        XCTAssertTrue(result.database.workouts.isEmpty)
        XCTAssertEqual(result.removed, 1)
    }

    // MARK: - Profile

    func testProfileMergeNeverBlanksAKnownField() {
        let known = UserProfile(dateOfBirth: day(700_000), biologicalSex: .male, heightCm: 180)
        let empty = UserProfile()
        XCTAssertEqual(known.merged(with: empty), known)
        XCTAssertEqual(empty.merged(with: known), known)
    }

    func testProfileArrivesFromAnotherDevice() {
        let incoming = UserProfile(dateOfBirth: day(700_000), biologicalSex: .female, heightCm: 165)
        guard let record = coordinator.record(forProfile: incoming) else {
            return XCTFail("profile should encode")
        }
        let result = coordinator.apply([record], deleted: [], to: HealthDatabase())
        XCTAssertEqual(result.database.profile.heightCm, 165)
        XCTAssertEqual(result.database.profile.biologicalSex, .female)
    }

    // MARK: - Database merge

    func testDatabaseMergeMatchesRecordByRecordApply() {
        // `merge` exists only to skip the encode/decode round trip on every
        // pull, so it has to agree with the path it replaces.
        let base = HealthDatabase(days: [summary(1, [.steps: 100, .vo2Max: 44]),
                                         summary(2, [.steps: 200])],
                                  workouts: [])
        let incoming = HealthDatabase(days: [summary(1, [.steps: 150]),
                                             summary(3, [.activeEnergy: 500])])

        let viaRecords = coordinator.apply(coordinator.allRecords(in: incoming), deleted: [], to: base)
        let viaMerge = coordinator.merge(incoming, into: base)
        XCTAssertEqual(viaMerge.days, viaRecords.database.days)
        XCTAssertEqual(viaMerge.profile, viaRecords.database.profile)
    }

    func testMergingAnImportWithALiveFeedKeepsBoth() {
        // A Mac with a ten-year export.zip import, receiving today from the
        // phone. Neither may displace the other.
        let imported = HealthDatabase(days: (1...3_650).map { summary($0, [.steps: Double($0)]) })
        let today = HealthDatabase(days: [summary(3_651, [.steps: 9_000])])
        let merged = coordinator.merge(today, into: imported)
        XCTAssertEqual(merged.days.count, 3_651)
        XCTAssertEqual(merged.days.last?[.steps], 9_000)
        XCTAssertEqual(merged.days.first?[.steps], 1)
    }
}
