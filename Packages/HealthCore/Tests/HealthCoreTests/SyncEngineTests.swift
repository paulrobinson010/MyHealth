import XCTest
@testable import HealthCore

/// An in-memory stand-in for CloudKit, with switches for the failure modes that
/// actually happen in the field.
final class FakeBackend: SyncBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: SyncRecord] = [:]
    private var tombstones: Set<UUID> = []
    private var version = 0

    var accountAvailable = true
    var failNextPush: SyncError?
    var failNextFetch: SyncError?
    var pageSize: Int?
    private(set) var pushCount = 0
    private(set) var fetchCount = 0

    func accountIsAvailable() async -> Bool { accountAvailable }

    func push(_ records: [SyncRecord], deletions: [UUID]) async throws -> SyncToken? {
        try lock.withLock { () -> SyncToken? in
            pushCount += 1
            if let failure = failNextPush {
                failNextPush = nil
                throw failure
            }
            for record in records {
                storage[record.id] = record
                tombstones.remove(record.id)
            }
            for id in deletions {
                storage.removeValue(forKey: id)
                tombstones.insert(id)
            }
            version += 1
            return nil
        }
    }

    func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet {
        try lock.withLock { () -> SyncChangeSet in
            fetchCount += 1
            if let failure = failNextFetch {
                failNextFetch = nil
                throw failure
            }
            let seen = token.flatMap { Int(String(decoding: $0.data, as: UTF8.self)) } ?? 0
            let all = Array(storage.values).sorted { $0.id.uuidString < $1.id.uuidString }

            if let pageSize, all.count > seen + pageSize {
                let page = Array(all[seen..<(seen + pageSize)])
                return SyncChangeSet(changed: page, deleted: [],
                                     token: SyncToken(data: Data("\(seen + pageSize)".utf8)),
                                     hasMore: true)
            }
            let remaining = seen < all.count ? Array(all[seen...]) : []
            return SyncChangeSet(changed: remaining,
                                 deleted: Array(tombstones),
                                 token: SyncToken(data: Data("\(all.count)".utf8)),
                                 hasMore: false)
        }
    }

    /// Simulates another device writing.
    func insert(_ record: SyncRecord) {
        lock.withLock { storage[record.id] = record }
    }

    var storedCount: Int {
        lock.withLock { storage.count }
    }
}

final class MemoryStateStore: SyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SyncState?
    private(set) var saveCount = 0

    func load() throws -> SyncState? {
        lock.withLock { state }
    }

    func save(_ state: SyncState) throws {
        lock.withLock {
            self.state = state
            saveCount += 1
        }
    }
}

final class SyncEngineTests: XCTestCase {

    private func record(_ id: UUID = UUID(), rank: Double = 1, payload: String = "x") -> SyncRecord {
        SyncRecord(id: id, kind: .entry, payload: Data(payload.utf8),
                   modified: Date(), rank: rank)
    }

    private func engine(_ backend: FakeBackend,
                        _ store: MemoryStateStore = MemoryStateStore()) -> SyncEngine {
        SyncEngine(backend: backend, stateStore: store)
    }

    func testAPushDeliversAndClearsTheOutbox() async {
        let backend = FakeBackend()
        let engine = engine(backend)

        await engine.enqueue([record(), record()])
        let pending = await engine.pendingCount
        XCTAssertEqual(pending, 2)

        let result = await engine.sync { _, _ in 0 }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.pushed, 2)
        XCTAssertEqual(backend.storedCount, 2)
        let remaining = await engine.pendingCount
        XCTAssertEqual(remaining, 0)
    }

    /// The guarantee that matters most: a failed sync must never lose a meal.
    func testAFailedPushKeepsTheOutboxIntactForNextTime() async {
        let backend = FakeBackend()
        backend.failNextPush = .networkUnavailable
        let engine = engine(backend)

        await engine.enqueue([record()])
        let first = await engine.sync { _, _ in 0 }
        XCTAssertFalse(first.succeeded)
        let stillQueued = await engine.pendingCount
        XCTAssertEqual(stillQueued, 1, "the entry must still be queued")
        XCTAssertEqual(backend.storedCount, 0)

        let second = await engine.sync { _, _ in 0 }
        XCTAssertTrue(second.succeeded)
        XCTAssertEqual(backend.storedCount, 1)
    }

    /// A crash between enqueueing and syncing must not lose anything either.
    func testTheOutboxSurvivesTheProcessDying() async {
        let backend = FakeBackend()
        let store = MemoryStateStore()

        let first = SyncEngine(backend: backend, stateStore: store)
        await first.enqueue([record()])
        // No sync — the app dies here.

        let revived = SyncEngine(backend: backend, stateStore: store)
        let revivedPending = await revived.pendingCount
        XCTAssertEqual(revivedPending, 1)
        _ = await revived.sync { _, _ in 0 }
        XCTAssertEqual(backend.storedCount, 1)
    }

    func testANewerLocalVersionSupersedesOneStillQueued() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let id = UUID()

        await engine.enqueue([record(id, rank: 1, payload: "estimate")])
        await engine.enqueue([record(id, rank: 4, payload: "looked-up")])
        let queued = await engine.pendingCount
        XCTAssertEqual(queued, 1, "one entry, not two versions of it")

        _ = await engine.sync { _, _ in 0 }
        XCTAssertEqual(backend.storedCount, 1)
    }

    func testAnOlderVersionDoesNotClobberANewerQueuedOne() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let id = UUID()

        await engine.enqueue([record(id, rank: 4, payload: "looked-up")])
        await engine.enqueue([record(id, rank: 1, payload: "estimate")])

        _ = await engine.sync { _, _ in 0 }
        XCTAssertEqual(backend.storedCount, 1)
    }

    func testChangesFromAnotherDeviceArePulled() async {
        let backend = FakeBackend()
        backend.insert(record(rank: 2, payload: "from the watch"))
        let engine = engine(backend)

        let received = RecordBox()
        let result = await engine.sync { changed, _ in
            received.store(changed)
            return 0
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(result.pulled, 1)
    }

    func testTheCursorMeansTheSameChangeIsNotPulledTwice() async {
        let backend = FakeBackend()
        backend.insert(record())
        let engine = engine(backend)

        _ = await engine.sync { _, _ in 0 }
        let secondRound = RecordBox()
        _ = await engine.sync { changed, _ in
            secondRound.store(changed)
            return 0
        }
        XCTAssertTrue(secondRound.value.isEmpty, "already-seen changes must not replay")
    }

    func testPagedResultsAreFollowedToTheEnd() async {
        let backend = FakeBackend()
        backend.pageSize = 2
        for _ in 0..<7 { backend.insert(record()) }
        let engine = engine(backend)

        let total = CounterBox()
        let result = await engine.sync { changed, _ in
            total.add(changed.count)
            return 0
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(total.value, 7)
    }

    func testAnExpiredTokenTriggersAFullRefetch() async {
        let backend = FakeBackend()
        backend.insert(record())
        let engine = engine(backend)

        _ = await engine.sync { _, _ in 0 }         // establishes a cursor
        backend.failNextFetch = .tokenExpired

        let replayed = CounterBox()
        let result = await engine.sync { changed, _ in
            replayed.add(changed.count)
            return 0
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(replayed.value, 1, "everything should be re-read after the token is rejected")
    }

    func testBeingSignedOutIsReportedRatherThanSwallowed() async {
        let backend = FakeBackend()
        backend.accountAvailable = false
        let engine = engine(backend)
        await engine.enqueue([record()])

        let result = await engine.sync { _, _ in 0 }
        XCTAssertEqual(result.error, .notSignedIn)
        XCTAssertFalse(result.error?.isTransient ?? true, "signing in is the user's job, not a retry")
        let stillQueued = await engine.pendingCount
        XCTAssertEqual(stillQueued, 1)
    }

    func testDeletionsPropagateAndAreNotResurrected() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let id = UUID()

        await engine.enqueue([record(id)])
        _ = await engine.sync { _, _ in 0 }
        XCTAssertEqual(backend.storedCount, 1)

        await engine.enqueueDeletions([id])
        _ = await engine.sync { _, _ in 0 }
        XCTAssertEqual(backend.storedCount, 0)

        let resurrected = RecordBox()
        _ = await engine.sync { changed, _ in
            resurrected.store(changed)
            return 0
        }
        XCTAssertTrue(resurrected.value.isEmpty)
    }

    func testDeletingSomethingStillInTheOutboxCancelsTheUpload() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let id = UUID()

        await engine.enqueue([record(id)])
        await engine.enqueueDeletions([id])
        _ = await engine.sync { _, _ in 0 }

        XCTAssertEqual(backend.storedCount, 0, "an entry deleted before it synced must never arrive")
    }

    func testRetryDelayBacksOff() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let initialDelay = await engine.retryDelay
        XCTAssertEqual(initialDelay, 0)

        backend.failNextPush = .networkUnavailable
        await engine.enqueue([record()])
        _ = await engine.sync { _, _ in 0 }
        let afterOne = await engine.retryDelay
        XCTAssertGreaterThan(afterOne, 0)

        backend.failNextPush = .networkUnavailable
        _ = await engine.sync { _, _ in 0 }
        let afterTwo = await engine.retryDelay
        XCTAssertGreaterThan(afterTwo, afterOne)
    }

    func testASuccessfulSyncRecordsWhenItHappened() async {
        let backend = FakeBackend()
        let engine = engine(backend)
        let before = await engine.lastSuccessfulSync
        XCTAssertNil(before)
        _ = await engine.sync { _, _ in 0 }
        let after = await engine.lastSuccessfulSync
        XCTAssertNotNil(after)
    }
}

final class LogSyncCoordinatorTests: XCTestCase {

    private let coordinator = LogSyncCoordinator()

    private func entry(_ id: UUID = UUID(), kcal: Double,
                       resolution: ResolutionState? = .pending) -> FoodEntry {
        FoodEntry(id: id, name: "curry",
                  timestamp: DayKey.today.localDate().timeIntervalSince1970 + 12 * 3600,
                  nutrition: Nutrition(kilocalories: kcal),
                  source: .naturalLanguage,
                  resolution: resolution)
    }

    private func resolved(_ confidence: Double) -> ResolutionState {
        .resolved(NutritionProvenance(source: .foodDataCentral, confidence: confidence))
    }

    func testAnIncomingEntryIsAdded() {
        let incoming = entry(kcal: 700)
        let records = coordinator.records(for: [incoming])
        let result = coordinator.apply(records, deleted: [], to: FoodLog())

        XCTAssertEqual(result.log.entries.count, 1)
        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.conflicts, 0)
    }

    /// Applying the same change twice must not double-count a meal.
    func testApplyingTheSameRecordTwiceIsANoOp() {
        let incoming = entry(kcal: 700)
        let records = coordinator.records(for: [incoming])

        let once = coordinator.apply(records, deleted: [], to: FoodLog())
        let twice = coordinator.apply(records, deleted: [], to: once.log)

        XCTAssertEqual(twice.log.entries.count, 1)
        XCTAssertEqual(twice.applied, 0, "a repeat delivery must change nothing")
    }

    func testABetterResolvedIncomingVersionWins() {
        let id = UUID()
        let local = FoodLog(entries: [entry(id, kcal: 650, resolution: .pending)])
        let records = coordinator.records(for: [entry(id, kcal: 900, resolution: resolved(0.9))])

        let result = coordinator.apply(records, deleted: [], to: local)
        XCTAssertEqual(result.log.entries.first?.nutrition.kilocalories, 900)
        XCTAssertEqual(result.conflicts, 0)
    }

    func testAWorseIncomingVersionLosesAndIsCountedAsAConflict() {
        let id = UUID()
        let local = FoodLog(entries: [entry(id, kcal: 900, resolution: resolved(0.9))])
        let records = coordinator.records(for: [entry(id, kcal: 650, resolution: .pending)])

        let result = coordinator.apply(records, deleted: [], to: local)
        XCTAssertEqual(result.log.entries.first?.nutrition.kilocalories, 900)
        XCTAssertEqual(result.conflicts, 1)
    }

    /// Two devices reconciling the same changes in opposite orders must agree.
    func testResolutionIsOrderIndependent() {
        let id = UUID()
        let weak = coordinator.records(for: [entry(id, kcal: 650, resolution: .pending)])
        let strong = coordinator.records(for: [entry(id, kcal: 900, resolution: resolved(0.9))])

        let forwards = coordinator.apply(strong, deleted: [],
                                         to: coordinator.apply(weak, deleted: [], to: FoodLog()).log)
        let backwards = coordinator.apply(weak, deleted: [],
                                          to: coordinator.apply(strong, deleted: [], to: FoodLog()).log)

        XCTAssertEqual(forwards.log.entries.first?.nutrition.kilocalories,
                       backwards.log.entries.first?.nutrition.kilocalories)
        XCTAssertEqual(forwards.log.entries.first?.nutrition.kilocalories, 900)
    }

    func testADeletionRemovesTheEntryAndTidiesItsOccasion() {
        let id = UUID()
        var local = FoodLog()
        let item = entry(id, kcal: 700)
        local.add(item, to: MealOccasion(context: .pub, evidence: .inferred, start: item.timestamp))

        let result = coordinator.apply([], deleted: [id], to: local)
        XCTAssertTrue(result.log.entries.isEmpty)
        XCTAssertTrue(result.log.occasions.isEmpty)
        XCTAssertEqual(result.removed, 1)
    }

    func testAStatedOccasionBeatsAnInferredOne() throws {
        let id = UUID()
        let start = Date().timeIntervalSince1970
        let local = FoodLog(occasions: [
            MealOccasion(id: id, context: .home, evidence: .inferred, start: start)
        ])
        let records = coordinator.records(for: [
            MealOccasion(id: id, context: .pub, evidence: .stated, venueName: "The Eagle", start: start)
        ])

        let result = coordinator.apply(records, deleted: [], to: local)
        let occasion = try XCTUnwrap(result.log.occasions.first)
        XCTAssertEqual(occasion.context, .pub)
        XCTAssertEqual(occasion.venueName, "The Eagle")
    }

    func testAnInferredOccasionDoesNotOverwriteAStatedOne() throws {
        let id = UUID()
        let start = Date().timeIntervalSince1970
        let local = FoodLog(occasions: [
            MealOccasion(id: id, context: .pub, evidence: .stated, venueName: "The Eagle", start: start)
        ])
        let records = coordinator.records(for: [
            MealOccasion(id: id, context: .home, evidence: .inferred, start: start)
        ])

        let result = coordinator.apply(records, deleted: [], to: local)
        XCTAssertEqual(try XCTUnwrap(result.log.occasions.first).context, .pub)
        XCTAssertEqual(result.conflicts, 1)
    }

    func testRoundTripThroughRecordsPreservesEverything() throws {
        let original = entry(kcal: 812, resolution: resolved(0.77))
        let records = coordinator.records(for: [original])
        let result = coordinator.apply(records, deleted: [], to: FoodLog())

        let restored = try XCTUnwrap(result.log.entries.first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.nutrition.kilocalories, 812)
        XCTAssertEqual(restored.provenance?.confidence, 0.77)
    }
}


/// The engine's apply closure is `@Sendable`, so tests cannot capture and
/// mutate a local `var` to observe it. These carry the observation out instead.
final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SyncRecord] = []

    func store(_ records: [SyncRecord]) {
        stored = records; 
    }

    var value: [SyncRecord] {
                return stored
    }
}

final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ amount: Int) {
        total += amount; 
    }

    var value: Int {
                return total
    }
}
