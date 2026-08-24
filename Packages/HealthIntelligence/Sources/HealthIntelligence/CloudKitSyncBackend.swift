import Foundation
import HealthCore
#if canImport(CloudKit)
import CloudKit
#endif

/// CloudKit-backed sync for the food log.
///
/// Uses a dedicated record zone in the user's private database. The zone is the
/// point: only a custom zone supports change tokens, and without those every
/// sync would have to re-read the whole log, which is both slow and a good way
/// to lose a race with a concurrent write.
///
/// Nothing about this touches the user's health data. The zone holds food and
/// drink entries and their occasions — the same things that would otherwise sit
/// in a notes app — and it lives in their own private database, which Apple
/// cannot read and this project has no server for.
public struct CloudKitSyncBackend: SyncBackend {

    #if canImport(CloudKit)
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let recordType = "LogRecord"

    public init(containerIdentifier: String? = nil) {
        self.container = containerIdentifier.map { CKContainer(identifier: $0) } ?? .default()
        self.zoneID = CKRecordZone.ID(zoneName: "FoodLog", ownerName: CKCurrentUserDefaultName)
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

        do {
            // `.allKeys` because a later version of an entry is meant to
            // overwrite the earlier one wholesale — the rank comparison that
            // decides which version wins has already happened locally.
            _ = try await database.modifyRecords(saving: toSave,
                                                 deleting: toDelete,
                                                 savePolicy: .allKeys,
                                                 atomically: false)
        } catch {
            throw CloudKitSyncBackend.translate(error)
        }
        return nil
    }

    public func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet {
        try await ensureZone()

        let serverToken = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self, from: $0.data)
        }

        let configuration = CKFetchRecordZoneChangesOperation
            .ZoneConfiguration(previousServerChangeToken: serverToken,
                               resultsLimit: nil,
                               desiredKeys: nil)

        do {
            let result = try await database.recordZoneChanges(inZoneWith: zoneID,
                                                              since: serverToken)

            var changed: [SyncRecord] = []
            for modification in result.modificationResultsByID.values {
                guard case .success(let value) = modification else { continue }
                if let record = CloudKitSyncBackend.decode(value.record) { changed.append(record) }
            }

            let deleted = result.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }

            var nextToken: SyncToken?
            if let changeToken = result.changeToken,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: changeToken,
                                                            requiringSecureCoding: true) {
                nextToken = SyncToken(data: data)
            }

            _ = configuration
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
    public init(containerIdentifier: String? = nil) {}
    public func accountIsAvailable() async -> Bool { false }
    public func push(_ records: [SyncRecord], deletions: [UUID]) async throws -> SyncToken? {
        throw SyncError.backendFailure("CloudKit is not available in this build.")
    }
    public func fetchChanges(since token: SyncToken?) async throws -> SyncChangeSet {
        throw SyncError.backendFailure("CloudKit is not available in this build.")
    }
    #endif
}
