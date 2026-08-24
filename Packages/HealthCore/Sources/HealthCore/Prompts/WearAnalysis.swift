import Foundation

/// A stretch where the watch appears to have been off the wrist.
public struct WearGap: Sendable, Hashable, Identifiable {
    public var id: Double { start.timeIntervalSince1970 }
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var minutes: Double { duration / 60 }

    /// Long enough to be a shower, short enough not to be a night's sleep or a
    /// charging session.
    public var looksLikeAShower: Bool { minutes >= 5 && minutes <= 45 }
}

/// Infers when the watch came off, from gaps in the data it produces.
///
/// There is no "wrist off" sample type — HealthKit does not expose one — so
/// this reads it from absence instead. An Apple Watch logs heart rate every few
/// minutes whenever it is worn, so a quiet stretch in the middle of the day is
/// the watch sitting on a shelf.
///
/// That makes it inference, not measurement, and the cue logic downstream treats
/// it that way: a gap on its own proves nothing, a gap straight after a workout
/// is worth acting on.
public enum WearAnalysis {

    /// A worn watch samples heart rate at least this often, so a longer silence
    /// means it is off. Six minutes leaves room for the sampling interval to
    /// stretch without crying wolf.
    public static let minimumGapSeconds: TimeInterval = 6 * 60
    /// Beyond this it is sleep, a flat battery or a day left at home — none of
    /// which is a cue to weigh yourself.
    public static let maximumGapSeconds: TimeInterval = 3 * 3600

    /// Finds off-wrist windows in a series of heart-rate sample times.
    /// `times` need not be sorted.
    public static func gaps(inHeartRateSamples times: [Date],
                            minimumGap: TimeInterval = minimumGapSeconds,
                            maximumGap: TimeInterval = maximumGapSeconds) -> [WearGap] {
        guard times.count >= 2 else { return [] }
        let sorted = times.sorted()
        var gaps: [WearGap] = []
        for index in 1..<sorted.count {
            let interval = sorted[index].timeIntervalSince(sorted[index - 1])
            guard interval >= minimumGap, interval <= maximumGap else { continue }
            gaps.append(WearGap(start: sorted[index - 1], end: sorted[index]))
        }
        return gaps
    }

    /// The gap that just ended, if the watch went back on within `within`.
    ///
    /// This is the moment worth acting on: they are out of the shower, dressed
    /// or dressing, and standing within a few feet of the scale.
    public static func gapJustEnded(_ gaps: [WearGap],
                                    now: Date,
                                    within: TimeInterval = 12 * 60) -> WearGap? {
        gaps
            .filter { $0.end <= now && now.timeIntervalSince($0.end) <= within }
            .max { $0.end < $1.end }
    }

    /// Whether a gap plausibly follows a workout, allowing for the walk home.
    public static func gap(_ gap: WearGap,
                           follows workoutEnd: Date,
                           within: TimeInterval = 3 * 3600) -> Bool {
        let delay = gap.start.timeIntervalSince(workoutEnd)
        return delay >= -300 && delay <= within
    }
}
