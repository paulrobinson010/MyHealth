import Foundation

/// Carries HealthKit-derived data between devices.
///
/// This exists because the Mac cannot read HealthKit: Apple publishes
/// `com.apple.developer.healthkit` for iOS, iPadOS and visionOS only, so a Mac
/// app has no health store however it is signed. The phone and the watch do
/// have one. So they read, and this ships the daily rollups — not raw samples —
/// to every other device through the same engine the food log uses.
///
/// Three properties matter and are what the tests pin down:
///
/// 1. **Record identity is derived, not invented.** Two devices reading the
///    same day must produce the same record ID, or CloudKit would accumulate a
///    duplicate per device per day.
/// 2. **Merging is a union, never a replacement.** A watch that read six
///    metrics for a day must not erase the forty the phone read.
/// 3. **Merging is commutative.** Devices reconcile in whatever order the
///    network delivers, and must still converge on the same answer.
public struct MetricSyncCoordinator: Sendable {

    public struct ApplyResult: Sendable {
        public let database: HealthDatabase
        public let applied: Int
        /// Incoming versions that lost to a more complete local one. A steady
        /// stream means two devices are reading different subsets, which is
        /// worth knowing about but is not an error.
        public let conflicts: Int
        public let removed: Int
    }

    public init() {}

    // Coders are classes with mutable state; holding one would stop this being
    // Sendable, and it has to be — the engine hands it to a @Sendable closure.
    private var encoder: JSONEncoder { JSONEncoder() }
    private var decoder: JSONDecoder { JSONDecoder() }

    // MARK: - Record identity

    /// A namespace tag, so an ID minted here is recognisable in a debugger and
    /// cannot collide with the log's genuinely random UUIDs.
    private static let magic: [UInt8] = [0x4D, 0x48, 0x53, 0x31]   // "MHS1"

    private enum Tag: UInt8 {
        case day = 1
        case workout = 2
        case profile = 3
    }

    private static func identifier(_ tag: Tag, _ payload: [UInt8]) -> UUID {
        var bytes = magic + [tag.rawValue] + payload
        precondition(bytes.count <= 16, "identifier payload overflows a UUID")
        bytes += Array(repeating: 0, count: 16 - bytes.count)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    /// FNV-1a. Not cryptographic and does not need to be — it disambiguates a
    /// handful of workout types within a single second of a single day.
    private static func hash(_ text: String) -> UInt32 {
        var value: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value = value &* 16_777_619
        }
        return value
    }

    public static func recordID(forDay day: DayKey) -> UUID {
        identifier(.day, bigEndianBytes(UInt32(bitPattern: Int32(truncatingIfNeeded: day.ordinal))))
    }

    /// Start time and activity are enough: the day is derivable from the start,
    /// and a person cannot begin two workouts of the same type in the same
    /// second. Deliberately not the source device — the same run read on the
    /// phone and on the watch is one run, and must land on one record.
    public static func recordID(forWorkout workout: WorkoutSummary) -> UUID {
        // `Int(someDouble)` traps on NaN and on anything past Int.max, and this
        // runs over whatever a decade-old export happens to contain.
        let seconds = Int64(exactly: workout.start.rounded()) ?? 0
        return identifier(.workout,
                          bigEndianBytes(UInt32(truncatingIfNeeded: seconds))
                          + bigEndianBytes(hash(workout.activity.rawValue)))
    }

    public static let profileRecordID = identifier(.profile, [])

    // MARK: - Ranking

    /// How complete a read is. A device that saw forty metrics for a day beats
    /// one that saw six, which is the only ordering that makes sense when the
    /// two disagree about whether a value exists at all.
    public static func rank(_ summary: DailySummary) -> Double {
        Double(summary.values.count)
    }

    /// Workouts are immutable once they happen, so the only thing to rank is
    /// how much of the optional detail came through.
    public static func rank(_ workout: WorkoutSummary) -> Double {
        var score = 1.0
        if workout.energyKcal != nil { score += 1 }
        if workout.distanceKm != nil { score += 1 }
        if workout.averageHeartRate != nil { score += 1 }
        if workout.maxHeartRate != nil { score += 1 }
        return score
    }

    public static func rank(_ profile: UserProfile) -> Double {
        var score = 0.0
        if profile.heightCm != nil { score += 1 }
        if profile.dateOfBirth != nil { score += 1 }
        if profile.biologicalSex != .unknown { score += 1 }
        return score
    }

    // MARK: - Outgoing

    public func records(forDays days: [DailySummary]) -> [SyncRecord] {
        days.compactMap { summary in
            guard let payload = try? encoder.encode(summary) else { return nil }
            return SyncRecord(id: MetricSyncCoordinator.recordID(forDay: summary.day),
                              kind: .dailySummary,
                              payload: payload,
                              modified: Date(),
                              rank: MetricSyncCoordinator.rank(summary))
        }
    }

    public func records(forWorkouts workouts: [WorkoutSummary]) -> [SyncRecord] {
        workouts.compactMap { workout in
            guard let payload = try? encoder.encode(workout) else { return nil }
            return SyncRecord(id: MetricSyncCoordinator.recordID(forWorkout: workout),
                              kind: .workout,
                              payload: payload,
                              modified: Date(),
                              rank: MetricSyncCoordinator.rank(workout))
        }
    }

    public func record(forProfile profile: UserProfile) -> SyncRecord? {
        guard let payload = try? encoder.encode(profile) else { return nil }
        return SyncRecord(id: MetricSyncCoordinator.profileRecordID,
                          kind: .profile,
                          payload: payload,
                          modified: Date(),
                          rank: MetricSyncCoordinator.rank(profile))
    }

    public func allRecords(in database: HealthDatabase) -> [SyncRecord] {
        var records = records(forDays: database.days) + records(forWorkouts: database.workouts)
        if let profile = record(forProfile: database.profile) { records.append(profile) }
        return records
    }

    // MARK: - Incoming

    /// Folds remote reads into the local database.
    ///
    /// Days are merged metric by metric rather than replaced wholesale, so no
    /// device can delete another's data by having read less of it. Deletions
    /// are honoured for workouts only: a day is not a thing anyone deletes, and
    /// treating an absent day as a deletion would let a device that has not
    /// finished importing wipe the history on every other one.
    public func apply(_ changed: [SyncRecord],
                      deleted: [UUID],
                      to database: HealthDatabase) -> ApplyResult {
        // Merge rather than `uniqueKeysWithValues`: a database carrying the same
        // day twice is a bug, but trapping on it would take the app down at
        // launch rather than healing it.
        var daysByOrdinal = Dictionary(database.days.map { ($0.day.ordinal, $0) },
                                       uniquingKeysWith: { $0.merged(with: $1) })
        var workoutsByID = Dictionary(database.workouts.map {
            (MetricSyncCoordinator.recordID(forWorkout: $0), $0)
        }, uniquingKeysWith: { first, _ in first })
        var profile = database.profile
        var applied = 0
        var conflicts = 0

        for record in changed {
            switch record.kind {
            case .dailySummary:
                guard let incoming = try? decoder.decode(DailySummary.self, from: record.payload) else {
                    continue
                }
                if let existing = daysByOrdinal[incoming.day.ordinal] {
                    let merged = existing.merged(with: incoming)
                    if merged != existing { applied += 1 }
                    if merged != incoming { conflicts += 1 }
                    daysByOrdinal[incoming.day.ordinal] = merged
                } else {
                    daysByOrdinal[incoming.day.ordinal] = incoming
                    applied += 1
                }

            case .workout:
                guard let incoming = try? decoder.decode(WorkoutSummary.self, from: record.payload) else {
                    continue
                }
                let id = MetricSyncCoordinator.recordID(forWorkout: incoming)
                if let existing = workoutsByID[id] {
                    let existingRank = MetricSyncCoordinator.rank(existing)
                    let incomingRank = MetricSyncCoordinator.rank(incoming)
                    if incomingRank > existingRank {
                        workoutsByID[id] = incoming
                        applied += 1
                    } else if incomingRank < existingRank {
                        conflicts += 1
                    }
                } else {
                    workoutsByID[id] = incoming
                    applied += 1
                }

            case .profile:
                guard let incoming = try? decoder.decode(UserProfile.self, from: record.payload) else {
                    continue
                }
                let merged = profile.merged(with: incoming)
                if merged != profile { applied += 1 }
                if merged != incoming { conflicts += 1 }
                profile = merged

            case .entry, .occasion:
                // The food log's stream. Sharing a zone is possible and this
                // has to ignore what is not its own.
                continue
            }
        }

        var removed = 0
        for id in deleted {
            if workoutsByID.removeValue(forKey: id) != nil { removed += 1 }
        }

        var result = database
        result.profile = profile
        result.days = daysByOrdinal.values.sorted { $0.day < $1.day }
        result.workouts = workoutsByID.values.sorted { $0.start < $1.start }

        return ApplyResult(database: result, applied: applied, conflicts: conflicts, removed: removed)
    }

    /// Combines two whole databases with the same rules `apply` uses, without
    /// the encode/decode round trip. Sync needs this on every pull that
    /// changed anything, and re-serialising a decade of days to merge one
    /// arriving day would make the common case cost the same as the first.
    public func merge(_ incoming: HealthDatabase, into base: HealthDatabase) -> HealthDatabase {
        var daysByOrdinal = Dictionary(base.days.map { ($0.day.ordinal, $0) },
                                       uniquingKeysWith: { $0.merged(with: $1) })
        for day in incoming.days {
            daysByOrdinal[day.day.ordinal] = daysByOrdinal[day.day.ordinal]?.merged(with: day) ?? day
        }

        var workoutsByID = Dictionary(base.workouts.map {
            (MetricSyncCoordinator.recordID(forWorkout: $0), $0)
        }, uniquingKeysWith: { first, _ in first })
        for workout in incoming.workouts {
            let id = MetricSyncCoordinator.recordID(forWorkout: workout)
            let existingRank = workoutsByID[id].map { MetricSyncCoordinator.rank($0) } ?? -1
            if MetricSyncCoordinator.rank(workout) > existingRank { workoutsByID[id] = workout }
        }

        var result = base
        result.profile = base.profile.merged(with: incoming.profile)
        result.days = daysByOrdinal.values.sorted { $0.day < $1.day }
        result.workouts = workoutsByID.values.sorted { $0.start < $1.start }
        return result
    }
}

// MARK: - Merging

extension DailySummary {

    /// Two devices' reads of the same day, combined without losing either.
    ///
    /// This is a join: **commutative, associative and idempotent**. All three
    /// are needed, not just the first. Devices apply changes in whatever order
    /// the network delivers them, a record can arrive twice, and with three
    /// devices the groupings differ too — so a rule that is merely commutative
    /// still lets two Macs settle on different answers and then publish them at
    /// each other forever.
    ///
    /// That constraint decides the disagreement rule. A metric only one side
    /// has is taken as-is. Where both have it, extrema keep their direction and
    /// everything else takes the larger value — the same de-duplication rule
    /// the importer uses across sources, where a device that saw part of a walk
    /// must not shrink the day.
    ///
    /// The cost is real and worth stating: for a point-in-time measurement like
    /// body mass, `max` is not "the true reading", it is the higher of two.
    /// An earlier draft preferred whichever side had read more of the day,
    /// which is better on any single pair and *not associative* — three devices
    /// merging in different orders landed on different VO2 max values. Given
    /// the choice between a rule that is usually more accurate and one that
    /// always converges, converging wins: a deficit that quietly differs per
    /// device is the failure this whole layer exists to prevent. It also barely
    /// arises, because both devices read the same synced HealthKit store and
    /// only a partial read makes them disagree at all.
    public func merged(with other: DailySummary) -> DailySummary {
        precondition(day == other.day, "merging summaries for different days")

        var result = self
        for (metric, incoming) in other.values {
            guard let mine = values[metric] else {
                result.values[metric] = incoming
                continue
            }
            switch metric.aggregation {
            case .minimum:
                result.values[metric] = Swift.min(mine, incoming)
            case .sum, .maximum, .mean, .latest:
                result.values[metric] = Swift.max(mine, incoming)
            }
        }
        return result
    }
}

extension UserProfile {

    /// Field-by-field union. A device that has not been told the user's height
    /// must not blank it everywhere else, so a known value always beats an
    /// unknown one and neither side can win by having less.
    public func merged(with other: UserProfile) -> UserProfile {
        var result = self
        if result.heightCm == nil { result.heightCm = other.heightCm }
        if result.dateOfBirth == nil { result.dateOfBirth = other.dateOfBirth }
        if result.biologicalSex == .unknown { result.biologicalSex = other.biologicalSex }
        return result
    }
}
