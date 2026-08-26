import Foundation

/// Translates between the food log and the sync engine.
///
/// The engine deals in opaque records so its state machine can be tested on its
/// own; this is the only place that knows a record is a meal.
public struct LogSyncCoordinator: Sendable {

    public struct ApplyResult: Sendable {
        public let log: FoodLog
        /// How many incoming records lost to a better local version. Worth
        /// surfacing: a steady stream of conflicts means two devices are
        /// fighting, which is a bug, not normal operation.
        public let conflicts: Int
        public let applied: Int
        public let removed: Int
    }

    public init() {}

    // JSONEncoder and JSONDecoder are classes with mutable state, so holding
    // them would stop this struct being Sendable — and it has to be, because
    // the sync engine hands it to a `@Sendable` closure. They are cheap enough
    // to make per call.
    private var encoder: JSONEncoder { JSONEncoder() }
    private var decoder: JSONDecoder { JSONDecoder() }

    // MARK: - Outgoing

    public func records(for entries: [FoodEntry]) -> [SyncRecord] {
        entries.compactMap { entry in
            guard let payload = try? encoder.encode(entry) else { return nil }
            return SyncRecord(id: entry.id,
                              kind: .entry,
                              payload: payload,
                              modified: Date(),
                              rank: LogSync.rank(entry.resolution))
        }
    }

    public func records(for occasions: [MealOccasion]) -> [SyncRecord] {
        occasions.compactMap { occasion in
            guard let payload = try? encoder.encode(occasion) else { return nil }
            return SyncRecord(id: occasion.id,
                              kind: .occasion,
                              payload: payload,
                              modified: Date(),
                              // Evidence someone actually stated beats a guess.
                              rank: occasion.evidence == .inferred ? 1 : 2)
        }
    }

    public func allRecords(in log: FoodLog) -> [SyncRecord] {
        records(for: log.entries) + records(for: log.occasions)
    }

    // MARK: - Incoming

    /// Folds remote changes into a local log.
    ///
    /// Order-independent by construction: the winner of any pair is whichever
    /// version ranks higher, so two devices reconciling the same changes in
    /// different orders land in the same state. That is what makes a retry
    /// after an ambiguous network failure safe.
    public func apply(_ changed: [SyncRecord],
                      deleted: [UUID],
                      to log: FoodLog) -> ApplyResult {
        var entriesByID = Dictionary(uniqueKeysWithValues: log.entries.map { ($0.id, $0) })
        var occasionsByID = Dictionary(uniqueKeysWithValues: log.occasions.map { ($0.id, $0) })
        var conflicts = 0
        var applied = 0

        for record in changed {
            switch record.kind {
            case .entry:
                guard let incoming = try? decoder.decode(FoodEntry.self, from: record.payload) else {
                    continue
                }
                if let existing = entriesByID[incoming.id] {
                    let existingRank = LogSync.rank(existing.resolution)
                    let incomingRank = LogSync.rank(incoming.resolution)
                    if incomingRank > existingRank {
                        entriesByID[incoming.id] = incoming
                        applied += 1
                    } else if incomingRank < existingRank {
                        conflicts += 1
                    }
                    // Equal rank means the same version arriving twice, which
                    // must be a no-op rather than anything at all.
                } else {
                    entriesByID[incoming.id] = incoming
                    applied += 1
                }

            case .occasion:
                guard let incoming = try? decoder.decode(MealOccasion.self, from: record.payload) else {
                    continue
                }
                if let existing = occasionsByID[incoming.id] {
                    if existing.evidence == .inferred && incoming.evidence != .inferred {
                        var merged = incoming
                        merged.entryIDs = Array(Set(existing.entryIDs + incoming.entryIDs))
                        occasionsByID[incoming.id] = merged
                        applied += 1
                    } else {
                        var merged = existing
                        merged.entryIDs = Array(Set(existing.entryIDs + incoming.entryIDs))
                        occasionsByID[incoming.id] = merged
                        if incoming.evidence == .inferred && existing.evidence != .inferred {
                            conflicts += 1
                        }
                    }
                } else {
                    occasionsByID[incoming.id] = incoming
                    applied += 1
                }
            }
        }

        var removed = 0
        var lostAnEntry: Set<UUID> = []
        for id in deleted {
            if entriesByID.removeValue(forKey: id) != nil { removed += 1 }
            if occasionsByID.removeValue(forKey: id) != nil { removed += 1 }
            for key in Array(occasionsByID.keys)
            where occasionsByID[key]?.entryIDs.contains(id) == true {
                occasionsByID[key]?.entryIDs.removeAll { $0 == id }
                lostAnEntry.insert(key)
            }
        }
        // An occasion that just lost its last entry is no longer an occasion.
        // One that has not received its entries yet is a different thing
        // entirely: sync records arrive in any order, and dropping it would
        // lose the venue for good — which is the one thing HealthKit cannot
        // store and the whole reason occasions exist.
        for key in lostAnEntry where occasionsByID[key]?.entryIDs.isEmpty == true {
            occasionsByID.removeValue(forKey: key)
        }

        let merged = FoodLog(entries: entriesByID.values.sorted { $0.timestamp < $1.timestamp },
                             occasions: occasionsByID.values.sorted { $0.start < $1.start },
                             favourites: log.favourites)

        return ApplyResult(log: merged, conflicts: conflicts, applied: applied, removed: removed)
    }
}
