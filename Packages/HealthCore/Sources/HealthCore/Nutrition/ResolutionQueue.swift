import Foundation

/// Finishes off entries that were logged in a hurry.
///
/// The Watch cannot do this work: Foundation Models does not reach watchOS
/// until watchOS 27, a multi-round network search is expensive on a wrist
/// battery, and nobody wants to wait four seconds to log a pint. So the Watch
/// logs instantly against the built-in table, marks the entry `pending`, and
/// this queue picks it up on whichever device next has a model and a network —
/// the iPhone usually, the Mac if it is the one awake.
///
/// The queue is idempotent by design. Two devices running it at once produce
/// the same answer, and merging their logs cannot double-apply anything,
/// because resolution replaces an entry's numbers rather than adding to them.
public struct ResolutionQueue: Sendable {

    public struct Report: Sendable {
        public let considered: Int
        public let improved: Int
        public let unchanged: Int
        public let givenUp: Int
        /// Total change in the day's calories, so a big correction is visible
        /// rather than silently rewriting history.
        public let calorieDelta: Double

        public var didAnything: Bool { improved > 0 || givenUp > 0 }
    }

    private let resolver: AgenticNutritionResolver
    /// Entries older than this are left alone — a correction to last month's
    /// lunch is not worth a network round trip.
    private let maximumAgeDays: Int
    private let batchLimit: Int

    public init(resolver: AgenticNutritionResolver,
                maximumAgeDays: Int = 30,
                batchLimit: Int = 25) {
        self.resolver = resolver
        self.maximumAgeDays = maximumAgeDays
        self.batchLimit = batchLimit
    }

    /// Entries this device should attempt, newest first.
    public func pending(in log: FoodLog, asOf today: DayKey = .today) -> [FoodEntry] {
        let cutoff = today.adding(days: -maximumAgeDays)
        return log.entries
            .filter { $0.needsResolution && $0.day >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(batchLimit)
            .map { $0 }
    }

    /// Resolves what is outstanding and returns an updated log.
    ///
    /// Takes and returns the whole log rather than mutating in place so the
    /// caller can merge the result with whatever else arrived while this was
    /// running, which on a phone is often quite a lot.
    public func process(_ log: FoodLog,
                        asOf today: DayKey = .today,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async -> (FoodLog, Report) {
        let outstanding = pending(in: log, asOf: today)
        guard !outstanding.isEmpty else {
            return (log, Report(considered: 0, improved: 0, unchanged: 0,
                                givenUp: 0, calorieDelta: 0))
        }

        var updated = log
        var improved = 0, unchanged = 0, givenUp = 0
        var calorieDelta = 0.0

        let outcomes = await resolver.resolve(entries: outstanding)
        for (index, pair) in outcomes.enumerated() {
            progress?(index + 1, outcomes.count)
            let (entry, outcome) = pair
            guard let position = updated.entries.firstIndex(where: { $0.id == entry.id }) else {
                continue
            }

            let provenance = outcome.resolution.provenance

            // Only overwrite when the loop actually found something better than
            // the guess it started from. An unconverged loop that fell back to
            // the original estimate must not be recorded as a lookup.
            let foundSomethingBetter = outcome.converged
                && !provenance.source.isEstimate
                && provenance.confidence > (entry.provenance?.confidence ?? 0)

            if foundSomethingBetter {
                let before = updated.entries[position].total.kilocalories
                updated.entries[position].nutrition = outcome.resolution.nutrition
                // Keep what the person said, not the database's phrasing — they
                // will not recognise "CHICKEN TIKKA MASALA 400G TWIN PACK".
                updated.entries[position].resolution = .resolved(provenance)
                calorieDelta += updated.entries[position].total.kilocalories - before
                improved += 1
            } else if outcome.trace.attempts >= 1 && !outcome.converged {
                updated.entries[position].resolution = .unresolvable(
                    reason: "Searched \(outcome.trace.attempts) time(s) without a confident match.")
                givenUp += 1
            } else {
                updated.entries[position].resolution = .pending
                unchanged += 1
            }
        }

        return (updated, Report(considered: outstanding.count,
                                improved: improved,
                                unchanged: unchanged,
                                givenUp: givenUp,
                                calorieDelta: calorieDelta))
    }
}

extension NutritionSource {
    /// True for sources that are a guess rather than a measurement.
    var isEstimate: Bool { self == .languageModel }
}
