import Foundation
import HealthCore

/// Ties the sync engine, the coordinator and the on-disk log together.
///
/// Every app target uses this rather than talking to the engine directly, so
/// the ordering rule that keeps the ledger honest — **write locally, then
/// sync** — is enforced in one place instead of being remembered three times.
public actor LogSyncService {

    public struct Status: Sendable {
        public let pendingUploads: Int
        public let lastSuccessfulSync: Date?
        public let lastError: SyncError?
        public let isSyncing: Bool

        public var summary: String {
            if isSyncing { return "Syncing…" }
            if let lastError { return lastError.localizedDescription }
            if pendingUploads > 0 {
                return "\(pendingUploads) change\(pendingUploads == 1 ? "" : "s") waiting to sync"
            }
            guard let lastSuccessfulSync else { return "Not synced yet" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSuccessfulSync, relativeTo: Date()))"
        }

        public var isHealthy: Bool { lastError == nil || lastError?.isTransient == true }
    }

    private let engine: SyncEngine
    private let coordinator = LogSyncCoordinator()
    private let store: FoodLogStore
    private var log: FoodLog
    private var lastError: SyncError?
    private var isSyncing = false

    public init(store: FoodLogStore, backend: SyncBackend, stateStore: SyncStateStore) {
        self.store = store
        self.engine = SyncEngine(backend: backend, stateStore: stateStore)
        self.log = (try? store.load()) ?? FoodLog()
    }

    public var currentLog: FoodLog { log }

    public func status() async -> Status {
        Status(pendingUploads: await engine.pendingCount,
               lastSuccessfulSync: await engine.lastSuccessfulSync,
               lastError: lastError,
               isSyncing: isSyncing)
    }

    // MARK: - Local writes

    /// Saves locally and queues for upload. Returns once the change is durable
    /// on this device, without waiting for the network — a log that blocks on
    /// iCloud is a log people stop using.
    @discardableResult
    public func record(_ entries: [FoodEntry], occasion: MealOccasion? = nil) -> FoodLog {
        for entry in entries { log.add(entry, to: occasion) }
        persist()
        var records = coordinator.records(for: entries)
        if let occasion { records += coordinator.records(for: [occasion]) }
        Task { await engine.enqueue(records) }
        return log
    }

    @discardableResult
    public func update(_ entries: [FoodEntry]) -> FoodLog {
        for entry in entries {
            guard let index = log.entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            log.entries[index] = entry
        }
        persist()
        let records = coordinator.records(for: entries)
        Task { await engine.enqueue(records) }
        return log
    }

    @discardableResult
    public func delete(_ id: UUID) -> FoodLog {
        log.remove(entryID: id)
        persist()
        Task { await engine.enqueueDeletions([id]) }
        return log
    }

    /// Replaces the whole log, for the case where another part of the app
    /// rebuilt it — the resolution queue, mainly.
    @discardableResult
    public func replace(with updated: FoodLog, uploading changed: [FoodEntry]) -> FoodLog {
        log = updated
        persist()
        let records = coordinator.records(for: changed)
        Task { await engine.enqueue(records) }
        return log
    }

    // MARK: - Sync

    @discardableResult
    public func sync() async -> SyncEngine.Result {
        isSyncing = true
        defer { isSyncing = false }

        // The apply closure runs inside the engine while it holds the cursor,
        // so a crash between applying and committing the token replays the
        // change rather than skipping it.
        let coordinator = self.coordinator
        var applied: LogSyncCoordinator.ApplyResult?
        let snapshot = log

        let result = await engine.sync { changed, deleted in
            let outcome = coordinator.apply(changed, deleted: deleted, to: snapshot)
            applied = outcome
            return outcome.conflicts
        }

        if let applied, applied.applied > 0 || applied.removed > 0 {
            // Merge rather than assign — anything logged while the sync ran
            // must survive it.
            log = LogSync.merge(local: log, remote: applied.log)
            persist()
        }

        lastError = result.error
        return result
    }

    /// Sends the entire log. Used the first time a device joins, and when the
    /// user asks for a full resync after something has gone wrong.
    public func uploadEverything() async {
        await engine.resetToken()
        await engine.enqueue(coordinator.allRecords(in: log))
    }

    private func persist() {
        try? store.save(log)
    }
}
