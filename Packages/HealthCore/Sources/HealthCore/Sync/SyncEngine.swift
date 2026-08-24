import Foundation

/// One syncable thing, as bytes plus the metadata sync needs.
///
/// Deliberately opaque: the engine never interprets a payload, which keeps the
/// sync state machine testable without any model types in the way.
public struct SyncRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case entry
        case occasion
    }

    public let id: UUID
    public let kind: Kind
    public let payload: Data
    /// When this version was created locally. Used only for diagnostics —
    /// conflicts are settled by content, never by clock, because two devices'
    /// clocks disagree and the later write is not always the better one.
    public let modified: Date
    /// Sortable measure of how complete this version is. Higher wins.
    public let rank: Double

    public init(id: UUID, kind: Kind, payload: Data, modified: Date, rank: Double) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.modified = modified
        self.rank = rank
    }
}

/// Opaque server cursor. CloudKit hands back a change token; tests hand back an
/// integer.
public struct SyncToken: Codable, Hashable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public struct SyncChangeSet: Sendable {
    public let changed: [SyncRecord]
    public let deleted: [UUID]
    public let token: SyncToken?
    /// True when the server has more to give and `fetchChanges` should be
    /// called again straight away.
    public let hasMore: Bool

    public init(changed: [SyncRecord] = [], deleted: [UUID] = [],
                token: SyncToken? = nil, hasMore: Bool = false) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.hasMore = hasMore
    }
}

public enum SyncError: LocalizedError, Equatable {
    /// The server rejected the token; everything must be re-fetched.
    case tokenExpired
    case notSignedIn
    case networkUnavailable
    case quotaExceeded
    case backendFailure(String)

    public var errorDescription: String? {
        switch self {
        case .tokenExpired:
            return "iCloud asked for a full resync."
        case .notSignedIn:
            return "Sign in to iCloud to sync your food log between devices."
        case .networkUnavailable:
            return "No connection — your log is saved on this device and will sync when you are back online."
        case .quotaExceeded:
            return "Your iCloud storage is full, so new entries cannot sync yet."
        case .backendFailure(let detail):
            return "iCloud sync failed: \(detail)"
        }
    }

    /// Whether trying again later is worth it.
    public var isTransient: Bool {
        switch self {
        case .networkUnavailable, .backendFailure: return true
        case .tokenExpired: return true
        case .notSignedIn, .quotaExceeded: return false
        }
    }
}

/// Where records actually go. CloudKit in production, a fake in tests.
public protocol SyncBackend: Sendable {
    func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet
    /// Returns the token reached after the push.
    func push(_ records: [SyncRecord], deletions: [UUID]) async throws -> SyncToken?
    /// Cheap check so the engine can fail fast and say something useful.
    func accountIsAvailable() async -> Bool
}

/// Durable sync state: what is waiting to go out, and how far in we have read.
///
/// Persisted separately from the log itself so an interrupted sync resumes
/// exactly where it stopped rather than re-sending everything or, worse,
/// silently dropping a write.
public struct SyncState: Codable, Sendable {
    public var token: SyncToken?
    /// Records written locally that the server has not acknowledged.
    public var outbox: [UUID: SyncRecord]
    public var pendingDeletions: Set<UUID>
    public var lastSuccessfulSync: Date?
    public var consecutiveFailures: Int

    public init(token: SyncToken? = nil,
                outbox: [UUID: SyncRecord] = [:],
                pendingDeletions: Set<UUID> = [],
                lastSuccessfulSync: Date? = nil,
                consecutiveFailures: Int = 0) {
        self.token = token
        self.outbox = outbox
        self.pendingDeletions = pendingDeletions
        self.lastSuccessfulSync = lastSuccessfulSync
        self.consecutiveFailures = consecutiveFailures
    }

    public var hasUnsyncedWork: Bool { !outbox.isEmpty || !pendingDeletions.isEmpty }
}

/// Moves the food log between devices, and does not lose anything doing it.
///
/// The guarantees, in the order they matter for a calorie ledger:
///
/// 1. **A local write is never lost.** Changes go into a durable outbox before
///    any network call. A failed, cancelled or crashed sync leaves the outbox
///    intact and the next attempt resends it.
/// 2. **Nothing is counted twice.** Records are keyed by UUID and applying the
///    same one repeatedly is a no-op, so a retry after an ambiguous failure is
///    always safe.
/// 3. **Conflicts resolve the same way everywhere.** The winner is the
///    higher-ranked version — a looked-up entry beats the estimate it replaced
///    — never the later clock. Two devices reconciling in either order reach
///    the same state.
/// 4. **A deletion stays deleted.** Tombstones are held until the server
///    acknowledges them, so a stale copy on another device cannot resurrect a
///    meal you removed.
public actor SyncEngine {

    public struct Result: Sendable {
        public let pulled: Int
        public let pushed: Int
        public let deleted: Int
        public let conflictsResolved: Int
        public let error: SyncError?

        public var succeeded: Bool { error == nil }
        public var changedAnything: Bool { pulled > 0 || pushed > 0 || deleted > 0 }
    }

    private let backend: SyncBackend
    private let stateStore: SyncStateStore
    private var state: SyncState
    /// Guards against two syncs interleaving and double-sending the outbox.
    private var isSyncing = false

    public init(backend: SyncBackend, stateStore: SyncStateStore) {
        self.backend = backend
        self.stateStore = stateStore
        self.state = (try? stateStore.load()) ?? SyncState()
    }

    public var pendingCount: Int { state.outbox.count + state.pendingDeletions.count }
    public var lastSuccessfulSync: Date? { state.lastSuccessfulSync }
    public var hasUnsyncedWork: Bool { state.hasUnsyncedWork }

    // MARK: - Local changes

    /// Records a local change. Durable before it returns, so the caller can
    /// treat the write as committed even if sync never runs.
    public func enqueue(_ records: [SyncRecord]) {
        for record in records {
            // A newer local version supersedes an older one still queued;
            // re-sending both would be wasted round trips.
            if let existing = state.outbox[record.id], existing.rank > record.rank { continue }
            state.outbox[record.id] = record
            state.pendingDeletions.remove(record.id)
        }
        persist()
    }

    public func enqueueDeletions(_ ids: [UUID]) {
        for id in ids {
            state.outbox.removeValue(forKey: id)
            state.pendingDeletions.insert(id)
        }
        persist()
    }

    // MARK: - Syncing

    /// Pushes the outbox, then pulls whatever changed elsewhere.
    ///
    /// Push happens first on purpose: if the pull brings down an older version
    /// of something sitting in the outbox, the merge has to see the local
    /// version as already-sent rather than as a conflict to be re-resolved.
    public func sync(applying apply: @Sendable ([SyncRecord], [UUID]) -> Int) async -> Result {
        guard !isSyncing else {
            return Result(pulled: 0, pushed: 0, deleted: 0, conflictsResolved: 0, error: nil)
        }
        isSyncing = true
        defer { isSyncing = false }

        guard await backend.accountIsAvailable() else {
            return failure(.notSignedIn)
        }

        var pushed = 0
        var deleted = 0

        if state.hasUnsyncedWork {
            let outgoing = Array(state.outbox.values)
            let deletions = Array(state.pendingDeletions)
            do {
                let token = try await backend.push(outgoing, deletions: deletions)
                // Only clear what was actually sent. Anything enqueued while the
                // push was in flight stays queued for the next round.
                for record in outgoing {
                    if let current = state.outbox[record.id], current.rank <= record.rank {
                        state.outbox.removeValue(forKey: record.id)
                    }
                }
                for id in deletions { state.pendingDeletions.remove(id) }
                if let token { state.token = token }
                pushed = outgoing.count
                deleted = deletions.count
                persist()
            } catch {
                return failure(SyncEngine.classify(error))
            }
        }

        var pulled = 0
        var conflicts = 0
        var more = true
        var guardRail = 0

        while more {
            guardRail += 1
            guard guardRail <= 50 else { break }   // a server that never stops paging
            do {
                let changes = try await backend.fetchChanges(since: state.token)
                if !changes.changed.isEmpty || !changes.deleted.isEmpty {
                    conflicts += apply(changes.changed, changes.deleted)
                    pulled += changes.changed.count
                }
                // The token advances only after the changes are applied, so a
                // crash mid-apply replays them rather than skipping them.
                if let token = changes.token { state.token = token }
                persist()
                more = changes.hasMore
            } catch let error as SyncError where error == .tokenExpired {
                // Start again from nothing rather than guessing what was missed.
                state.token = nil
                persist()
                more = true
                if guardRail > 2 { return failure(.tokenExpired) }
            } catch {
                return failure(SyncEngine.classify(error))
            }
        }

        state.lastSuccessfulSync = Date()
        state.consecutiveFailures = 0
        persist()
        return Result(pulled: pulled, pushed: pushed, deleted: deleted,
                      conflictsResolved: conflicts, error: nil)
    }

    /// Seconds to wait before retrying, backing off as failures accumulate.
    public var retryDelay: TimeInterval {
        guard state.consecutiveFailures > 0 else { return 0 }
        return min(600, pow(2, Double(min(state.consecutiveFailures, 9))) * 2)
    }

    /// Forgets the cursor so the next sync re-reads everything. Used when the
    /// server says the token is stale, and when the user asks for a full resync.
    public func resetToken() {
        state.token = nil
        persist()
    }

    private func failure(_ error: SyncError) -> Result {
        state.consecutiveFailures += 1
        persist()
        return Result(pulled: 0, pushed: 0, deleted: 0, conflictsResolved: 0, error: error)
    }

    private func persist() {
        try? stateStore.save(state)
    }

    static func classify(_ error: Error) -> SyncError {
        if let syncError = error as? SyncError { return syncError }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .networkUnavailable }
        return .backendFailure(error.localizedDescription)
    }
}

/// Persistence for the engine's own state. Separate from the log so a corrupt
/// token can be thrown away without touching anyone's food diary.
public protocol SyncStateStore: Sendable {
    func load() throws -> SyncState?
    func save(_ state: SyncState) throws
}

public struct FileSyncStateStore: SyncStateStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("MyHealth", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("sync-state.json")
    }

    public func load() throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: SyncState) throws {
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
    }
}
