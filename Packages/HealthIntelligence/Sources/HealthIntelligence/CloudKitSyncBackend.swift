import Foundation
import HealthCore
#if canImport(CloudKit)
import CloudKit
#endif

/// CloudKit-backed sync, for the food log and for health metrics.
///
/// Uses a dedicated record zone in the user's private database. The zone is the
/// point: only a custom zone supports change tokens, and without those every
/// sync would have to re-read everything, which is both slow and a good way to
/// lose a race with a concurrent write.
///
/// **On privacy.** This does move health data — daily rollups read from
/// HealthKit on the phone, so that the Mac, which has no health store of its
/// own, can show them. It goes to the user's own private CloudKit database:
/// Apple states it cannot read a private database's contents, this project has
/// no server, and nothing is sent anywhere else. The alternative was the Mac
/// showing nothing, since Apple does not publish the HealthKit entitlement for
/// macOS. Whether to sync at all stays the user's choice — the app works from
/// a local export.zip import with sync switched off.
public struct CloudKitSyncBackend: SyncBackend {

    /// One stream of records: its own zone, its own record type, and therefore
    /// its own change token. The food log and the health metrics move at very
    /// different rates — a meal now and then against a decade of days on first
    /// sync — so putting them in one zone would make every meal re-page the
    /// entire history.
    public struct Stream: Sendable {
        public let zoneName: String
        public let recordType: String

        public init(zoneName: String, recordType: String) {
            self.zoneName = zoneName
            self.recordType = recordType
        }

        public static let foodLog = Stream(zoneName: "FoodLog", recordType: "LogRecord")
        public static let healthMetrics = Stream(zoneName: "HealthMetrics", recordType: "MetricRecord")
    }

    #if canImport(CloudKit)
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let recordType: String

    public init(containerIdentifier: String? = nil, stream: Stream = .foodLog) {
        self.container = containerIdentifier.map { CKContainer(identifier: $0) } ?? .default()
        self.zoneID = CKRecordZone.ID(zoneName: stream.zoneName, ownerName: CKCurrentUserDefaultName)
        self.recordType = stream.recordType
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    public func accountIsAvailable() async -> Bool {
        do { return try await container.accountStatus() == .available }
        catch { return false }
    }

    /// Creating the zone is idempotent, so this can run on every sync without
    /// needing to remember whether it has already happened.
    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already there.
        }
    }

    public func push(_ records: [SyncRecord], deletions: [UUID]) async throws -> SyncToken? {
        guard !records.isEmpty || !deletions.isEmpty else { return nil }
        try await ensureZone()

        let toSave = records.map { record -> CKRecord in
            let id = CKRecord.ID(recordName: record.id.uuidString, zoneID: zoneID)
            let ckRecord = CKRecord(recordType: recordType, recordID: id)
            ckRecord["kind"] = record.kind.rawValue as CKRecordValue
            ckRecord["payload"] = record.payload as CKRecordValue
            ckRecord["rank"] = record.rank as CKRecordValue
            ckRecord["modified"] = record.modified as CKRecordValue
            return ckRecord
        }
        let toDelete = deletions.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }

        // CloudKit rejects an oversized modify outright, and the first sync of
        // a decade of health data is thousands of records. Batch it. Not
        // atomic, and deliberately so: a partial push leaves the rest in the
        // outbox, which is exactly what the engine expects.
        for batch in CloudKitSyncBackend.batches(of: toSave, size: CloudKitSyncBackend.batchLimit) {
            do {
                // `.allKeys` because a later version of a record is meant to
                // overwrite the earlier one wholesale — the rank comparison
                // that decides which version wins has already happened locally.
                _ = try await database.modifyRecords(saving: batch,
                                                     deleting: [],
                                                     savePolicy: .allKeys,
                                                     atomically: false)
            } catch {
                throw CloudKitSyncBackend.translate(error)
            }
        }

        for batch in CloudKitSyncBackend.batches(of: toDelete, size: CloudKitSyncBackend.batchLimit) {
            do {
                _ = try await database.modifyRecords(saving: [],
                                                     deleting: batch,
                                                     savePolicy: .allKeys,
                                                     atomically: false)
            } catch {
                throw CloudKitSyncBackend.translate(error)
            }
        }
        return nil
    }

    /// CloudKit's documented ceiling is 400 items per modify operation.
    static let batchLimit = 350

    static func batches<T>(of items: [T], size: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<Swift.min($0 + size, items.count)])
        }
    }

    public func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet {
        try await ensureZone()

        let serverToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self, from: $0.data)
        }

        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID,
                                                              since: serverToken)

            var changed: [SyncRecord] = []
            for modification in result.modificationResultsByID.values {
                guard case .success(let value) = modification else { continue }
                if let record = CloudKitSyncBackend.decode(value.record) { changed.append(record) }
            }

            let deleted = result.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }

            // `changeToken` is not optional on this API — the server always
            // hands back a cursor, even when nothing changed.
            var nextToken: SyncToken?
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: result.changeToken,
                                                            requiringSecureCoding: true) {
                nextToken = SyncToken(data: data)
            }

            return SyncChangeSet(changed: changed,
                                 deleted: deleted,
                                 token: nextToken,
                                 hasMore: result.moreComing)
        } catch {
            throw CloudKitSyncBackend.translate(error)
        }
    }

    private static func decode(_ record: CKRecord) -> SyncRecord? {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let kindRaw = record["kind"] as? String,
              let kind = SyncRecord.Kind(rawValue: kindRaw),
              let payload = record["payload"] as? Data
        else { return nil }
        return SyncRecord(id: id,
                          kind: kind,
                          payload: payload,
                          modified: record["modified"] as? Date ?? Date(),
                          rank: record["rank"] as? Double ?? 0)
    }

    /// Maps CloudKit's error codes onto the small set the engine reasons about,
    /// so retry policy lives in one place instead of being scattered.
    static func translate(_ error: Error) -> SyncError {
        guard let ckError = error as? CKError else {
            return SyncError.backendFailure(error.localizedDescription)
        }
        switch ckError.code {
        case .changeTokenExpired:
            return .tokenExpired
        case .notAuthenticated:
            return .notSignedIn
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return .networkUnavailable
        case .quotaExceeded:
            return .quotaExceeded
        case .zoneNotFound, .userDeletedZone:
            // The zone will be recreated on the next push; a full re-read is
            // the correct recovery.
            return .tokenExpired
        default:
            return .backendFailure(ckError.localizedDescription)
        }
    }

    #else
    public init(containerIdentifier: String? = nil, stream: Stream = .foodLog) {}
    public func accountIsAvailable() async -> Bool { false }
    public func push(_ records: [SyncRecord], deletions: [UUID]) async throws -> SyncToken? {
        throw SyncError.backendFailure("CloudKit is not available in this build.")
    }
    public func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet {
        throw SyncError.backendFailure("CloudKit is not available in this build.")
    }
    #endif
}
