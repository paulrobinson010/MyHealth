import Foundation
import HealthCore

/// Ships HealthKit-derived data from the devices that can read it to the ones
/// that cannot.
///
/// The asymmetry is the whole design. iPhone, iPad and Watch have a health
/// store; the Mac does not, and cannot be given one. So the phone reads and
/// publishes, and every device subscribes. A Mac that has also imported an
/// `export.zip` keeps that history — incoming days are merged into it, never
/// substituted for it, so the deep archive and the live feed coexist.
public actor MetricSyncService {

    public struct Status: Sendable {
        public let pendingUploads: Int
        public let lastSuccessfulSync: Date?
        public let lastError: SyncError?
        public let isSyncing: Bool
        public let daysHeld: Int

        public var summary: String {
            if isSyncing { return "Syncing health data…" }
            if let lastError { return lastError.localizedDescription }
            if pendingUploads > 0 {
                return "\(pendingUploads) day\(pendingUploads == 1 ? "" : "s") waiting to upload"
            }
            guard let lastSuccessfulSync else { return "Not synced yet" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "\(daysHeld) days · synced \(formatter.localizedString(for: lastSuccessfulSync, relativeTo: Date()))"
        }

        public var isHealthy: Bool { lastError == nil || lastError?.isTransient == true }
    }

    private let engine: SyncEngine
    private let coordinator = MetricSyncCoordinator()
    private let store: HealthStore
    private var database: HealthDatabase
    private var lastError: SyncError?
    private var isSyncing = false

    public init(store: HealthStore, backend: SyncBackend, stateStore: SyncStateStore) {
        self.store = store
        self.engine = SyncEngine(backend: backend, stateStore: stateStore)
        self.database = (try? store.load()) ?? HealthDatabase()
    }

    public var currentDatabase: HealthDatabase { database }

    public func status() async -> Status {
        Status(pendingUploads: await engine.pendingCount,
               lastSuccessfulSync: await engine.lastSuccessfulSync,
               lastError: lastError,
               isSyncing: isSyncing,
               daysHeld: database.days.count)
    }

    // MARK: - Publishing

    /// Call after a HealthKit read on a device that has a health store.
    ///
    /// Merges into what is already held rather than replacing it — a one-year
    /// read must not truncate a ten-year import — and queues only the days that
    /// actually changed, so a daily sync uploads one record and not four
    /// thousand.
    @discardableResult
    public func publish(_ incoming: HealthDatabase) -> HealthDatabase {
        var existing = Dictionary(database.days.map { ($0.day.ordinal, $0) },
                                  uniquingKeysWith: { $0.merged(with: $1) })
        var changedDays: [DailySummary] = []

        for day in incoming.days {
            let merged = existing[day.day.ordinal].map { $0.merged(with: day) } ?? day
            if existing[day.day.ordinal] != merged {
                existing[day.day.ordinal] = merged
                changedDays.append(merged)
            }
        }

        var workoutsByID = Dictionary(database.workouts.map {
            (MetricSyncCoordinator.recordID(forWorkout: $0), $0)
        }, uniquingKeysWith: { first, _ in first })
        var changedWorkouts: [WorkoutSummary] = []
        for workout in incoming.workouts {
            let id = MetricSyncCoordinator.recordID(forWorkout: workout)
            // Spelled out rather than `.map(MetricSyncCoordinator.rank)`:
            // `rank` is overloaded three ways and the bare reference is
            // ambiguous.
            let existingRank = workoutsByID[id].map { MetricSyncCoordinator.rank($0) } ?? -1
            if MetricSyncCoordinator.rank(workout) > existingRank {
                workoutsByID[id] = workout
                changedWorkouts.append(workout)
            }
        }

        let mergedProfile = database.profile.merged(with: incoming.profile)
        let profileChanged = mergedProfile != database.profile

        database.days = existing.values.sorted { $0.day < $1.day }
        database.workouts = workoutsByID.values.sorted { $0.start < $1.start }
        database.profile = mergedProfile
        persist()

        var pending = coordinator.records(forDays: changedDays)
            + coordinator.records(forWorkouts: changedWorkouts)
        if profileChanged, let record = coordinator.record(forProfile: mergedProfile) {
            pending.append(record)
        }
        // Bind to a `let` before the Task: capturing a mutable local in a
        // @Sendable closure is exactly the pattern strict concurrency rejects.
        let outgoing = pending
        if !outgoing.isEmpty {
            Task { [engine] in await engine.enqueue(outgoing) }
        }
        return database
    }

    // MARK: - Sync

    @discardableResult
    public func sync() async -> SyncEngine.Result {
        isSyncing = true
        defer { isSyncing = false }

        let coordinator = self.coordinator
        let snapshot = database
        // The closure is @Sendable and runs inside the engine's actor, so it
        // cannot mutate a captured var — the result comes back in a locked box.
        let box = MetricApplyBox()

        let result = await engine.sync { changed, deleted in
            let outcome = coordinator.apply(changed, deleted: deleted, to: snapshot)
            box.store(outcome)
            return outcome.conflicts
        }

        if let outcome = box.value, outcome.applied > 0 || outcome.removed > 0 {
            // Merge against the live database rather than assigning the
            // snapshot: a HealthKit read may have landed while the sync ran,
            // and it must survive it.
            database = coordinator.merge(outcome.database, into: database)
            persist()
        }

        lastError = result.error
        return result
    }

    /// Sends everything and forgets the cursor. Used when a device joins, and
    /// when the user asks for a full resync after something has gone wrong.
    public func uploadEverything() async {
        await engine.resetToken()
        await engine.enqueue(coordinator.allRecords(in: database))
    }

    private func persist() {
        try? store.save(database)
    }
}

/// Carries a result out of a `@Sendable` closure without capturing a `var`.
final class MetricApplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MetricSyncCoordinator.ApplyResult?

    func store(_ result: MetricSyncCoordinator.ApplyResult) {
        lock.withLock { stored = result }
    }

    var value: MetricSyncCoordinator.ApplyResult? {
        lock.withLock { stored }
    }
}
