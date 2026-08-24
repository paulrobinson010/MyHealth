import Foundation

/// Anything that can hold the synced log. Injectable so the sync logic is
/// testable without iCloud.
public protocol LogSyncBacking: AnyObject {
    func syncedData(forKey key: String) -> Data?
    func setSyncedData(_ data: Data?, forKey key: String)
    @discardableResult func pushChanges() -> Bool
}

/// Carries the food log between the Watch and the Mac.
///
/// The nutrition itself already travels through HealthKit, but HealthKit has
/// nowhere to record "a pint of Guinness at The Eagle" — and the venue is the
/// part that makes the analysis interesting. iCloud's key-value store handles
/// that: it is built into Foundation on both platforms, syncs on its own
/// between devices on the same Apple Account, and needs no server.
///
/// It caps out at 1 MB, so the log is pruned to a rolling window before it is
/// written. Long-term history lives in each device's own file; this is only the
/// channel between them.
public struct LogSync {

    public static let key = "com.myhealth.foodlog.v1"
    /// How much history to carry. 120 days of ordinary logging is comfortably
    /// inside the 1 MB budget.
    public static let windowDays = 120
    /// Leave headroom — the store rejects the whole payload when it is over.
    public static let maximumBytes = 900_000

    private let backing: LogSyncBacking

    public init(backing: LogSyncBacking) { self.backing = backing }

    /// Trims a log to what is worth syncing.
    /// How far through the lookup pipeline an entry has got, as a sortable
    /// number. Higher wins a merge.
    static func rank(_ state: ResolutionState?) -> Double {
        switch state {
        case .none: return 0
        case .pending: return 1
        case .unresolvable: return 2
        case .resolved(let provenance): return 3 + provenance.confidence
        }
    }

    public static func prune(_ log: FoodLog, asOf today: DayKey = .today) -> FoodLog {
        let cutoff = today.adding(days: -windowDays)
        var pruned = FoodLog(
            entries: log.entries.filter { $0.day >= cutoff },
            occasions: log.occasions.filter { $0.day >= cutoff },
            favourites: log.favourites)

        // If it is still too large, drop the oldest days until it fits rather
        // than failing to sync at all.
        while let encoded = try? JSONEncoder().encode(pruned),
              encoded.count > maximumBytes,
              let oldest = pruned.entries.first?.day {
            pruned.entries.removeAll { $0.day == oldest }
            pruned.occasions.removeAll { $0.day == oldest }
        }
        return pruned
    }

    public func push(_ log: FoodLog, asOf today: DayKey = .today) {
        let pruned = LogSync.prune(log, asOf: today)
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        backing.setSyncedData(data, forKey: LogSync.key)
        backing.pushChanges()
    }

    public func pull() -> FoodLog? {
        guard let data = backing.syncedData(forKey: LogSync.key) else { return nil }
        return try? JSONDecoder().decode(FoodLog.self, from: data)
    }

    /// Combines a local log with one that arrived from another device.
    ///
    /// Entries carry stable UUIDs, so the union is unambiguous and the same
    /// entry syncing twice cannot double-count a meal.
    ///
    /// Where both sides hold the same entry, the better-resolved copy wins
    /// rather than the local one. That matters more than it looks: the phone
    /// finishes a lookup while the Watch is still holding the original
    /// estimate, and a naive local-wins merge would quietly throw the corrected
    /// figures away every time.
    public static func merge(local: FoodLog, remote: FoodLog) -> FoodLog {
        var entriesByID: [UUID: FoodEntry] = [:]
        for entry in local.entries { entriesByID[entry.id] = entry }
        for entry in remote.entries {
            guard let existing = entriesByID[entry.id] else {
                entriesByID[entry.id] = entry
                continue
            }
            if rank(entry.resolution) > rank(existing.resolution) {
                entriesByID[entry.id] = entry
            }
        }

        var occasionsByID: [UUID: MealOccasion] = [:]
        for occasion in local.occasions { occasionsByID[occasion.id] = occasion }
        for occasion in remote.occasions {
            if var existing = occasionsByID[occasion.id] {
                // Keep the stronger evidence if the two devices disagree.
                if existing.evidence == .inferred && occasion.evidence != .inferred {
                    existing.context = occasion.context
                    existing.evidence = occasion.evidence
                    existing.venueName = occasion.venueName ?? existing.venueName
                }
                existing.entryIDs = Array(Set(existing.entryIDs + occasion.entryIDs))
                occasionsByID[occasion.id] = existing
            } else {
                occasionsByID[occasion.id] = occasion
            }
        }

        return FoodLog(
            entries: entriesByID.values.sorted { $0.timestamp < $1.timestamp },
            occasions: occasionsByID.values.sorted { $0.start < $1.start },
            favourites: Array(Set(local.favourites + remote.favourites)).sorted())
    }
}

/// Adapter over iCloud's key-value store. A wrapper rather than an extension
/// on `NSUbiquitousKeyValueStore`, so its own `set(_:forKey:)` overloads cannot
/// be shadowed or accidentally recursed into.
public final class UbiquitousLogStore: LogSyncBacking {
    private let store: NSUbiquitousKeyValueStore

    public init(store: NSUbiquitousKeyValueStore = .default) { self.store = store }

    public func syncedData(forKey key: String) -> Data? { store.data(forKey: key) }

    public func setSyncedData(_ data: Data?, forKey key: String) {
        if let data {
            store.set(data, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }

    @discardableResult
    public func pushChanges() -> Bool { store.synchronize() }

    /// Fires when another device writes a new log.
    public static let didChangeNotification =
        NSUbiquitousKeyValueStore.didChangeExternallyNotification

    public func startObserving() { store.synchronize() }
}
