import Foundation

/// A reason to ask someone to step on the scale.
public struct WeighInCue: Sendable, Hashable {
    public enum Trigger: Sendable, Hashable {
        /// A workout, then the watch came off, then it went back on. They are
        /// almost certainly standing next to the scale right now.
        case afterShower
        /// The hour they usually weigh, learned from their own history.
        case usualTime
        /// Nothing for a while and the reconciliation is starving.
        case overdue(days: Int)

        public var identifier: String {
            switch self {
            case .afterShower: return "afterShower"
            case .usualTime: return "usualTime"
            case .overdue: return "overdue"
            }
        }
    }

    public let trigger: Trigger
    public let title: String
    public let body: String
    /// How strongly this is worth interrupting for.
    public let urgency: Urgency

    public enum Urgency: Int, Sendable, Comparable {
        case gentle = 0
        case normal = 1
        case important = 2
        public static func < (lhs: Urgency, rhs: Urgency) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

/// Decides whether now is a good moment to ask for a weigh-in.
///
/// The bar for interrupting someone is high, so this refuses far more often
/// than it fires: not if they already weighed today, not if it already asked
/// today, not at night, and not on a hunch alone.
public struct WeighInCueDetector: Sendable {

    public struct Context: Sendable {
        public var now: Date
        /// Heart-rate sample times from the last few hours.
        public var recentHeartRateSamples: [Date]
        /// Workouts that finished recently.
        public var recentWorkouts: [WorkoutSummary]
        /// Days on which a weight was recorded, most recent last.
        public var weighInDays: [DayKey]
        /// Times of day past weigh-ins happened, for learning the usual hour.
        public var weighInHours: [Int]
        public var alreadyPromptedToday: Bool
        public var calendar: Calendar

        public init(now: Date = Date(),
                    recentHeartRateSamples: [Date] = [],
                    recentWorkouts: [WorkoutSummary] = [],
                    weighInDays: [DayKey] = [],
                    weighInHours: [Int] = [],
                    alreadyPromptedToday: Bool = false,
                    calendar: Calendar = .current) {
            self.now = now
            self.recentHeartRateSamples = recentHeartRateSamples
            self.recentWorkouts = recentWorkouts
            self.weighInDays = weighInDays
            self.weighInHours = weighInHours
            self.alreadyPromptedToday = alreadyPromptedToday
            self.calendar = calendar
        }
    }

    public struct Settings: Sendable {
        /// No prompts before this hour or after `quietFrom`.
        public var quietUntil = 6
        public var quietFrom = 22
        /// How long without a weigh-in before it starts asking.
        public var overdueAfterDays = 3
        /// Once it is overdue, how often to raise it again.
        public var overdueRepeatDays = 2
        public init() {}
    }

    private let settings: Settings

    public init(settings: Settings = Settings()) { self.settings = settings }

    public func cue(_ context: Context) -> WeighInCue? {
        let today = DayKey(date: context.now, calendar: context.calendar)
        let hour = context.calendar.component(.hour, from: context.now)

        // Never twice in a day, and never at night.
        guard !context.alreadyPromptedToday else { return nil }
        guard hour >= settings.quietUntil, hour < settings.quietFrom else { return nil }
        // Already done it — nothing to ask for.
        guard !context.weighInDays.contains(today) else { return nil }

        let daysSince = context.weighInDays.last.map { today - $0 }

        // 1. The strong signal: a workout, then the watch off, then back on.
        if let gap = WearAnalysis.gapJustEnded(
            WearAnalysis.gaps(inHeartRateSamples: context.recentHeartRateSamples),
            now: context.now),
           gap.looksLikeAShower,
           context.recentWorkouts.contains(where: {
               WearAnalysis.gap(gap, follows: $0.startDate.addingTimeInterval($0.durationMinutes * 60))
           }) {
            return WeighInCue(
                trigger: .afterShower,
                title: "Weigh in?",
                body: "You are out of the shower and the scale is right there. It takes ten seconds and it is what makes the deficit real rather than a guess.",
                urgency: .normal)
        }

        // 2. The hour they usually do it.
        if let usual = usualHour(context.weighInHours), hour == usual,
           (daysSince ?? Int.max) >= 1 {
            return WeighInCue(
                trigger: .usualTime,
                title: "Weigh in?",
                body: "This is when you usually weigh yourself.",
                urgency: .gentle)
        }

        // 3. Overdue. Escalates, but never becomes a daily nag.
        if let daysSince, daysSince >= settings.overdueAfterDays,
           (daysSince - settings.overdueAfterDays) % max(1, settings.overdueRepeatDays) == 0,
           hour >= 7, hour <= 11 {
            return WeighInCue(
                trigger: .overdue(days: daysSince),
                title: "\(daysSince) days since your last weigh-in",
                body: "Without a weight trend the calorie figures are arithmetic on an estimate rather than a measurement.",
                urgency: daysSince >= 7 ? .important : .normal)
        }

        // 4. Never weighed at all.
        if context.weighInDays.isEmpty, hour >= 7, hour <= 11 {
            return WeighInCue(
                trigger: .overdue(days: 0),
                title: "Add a weigh-in",
                body: "One weight and one waist measurement is all it takes to turn the food log into a measured deficit.",
                urgency: .normal)
        }

        return nil
    }

    /// The hour they most often weigh, once there is enough history to tell.
    func usualHour(_ hours: [Int]) -> Int? {
        guard hours.count >= 4 else { return nil }
        var counts: [Int: Int] = [:]
        for hour in hours { counts[hour, default: 0] += 1 }
        guard let (hour, count) = counts.max(by: { $0.value < $1.value }),
              // Only if it is genuinely a habit rather than a coincidence.
              Double(count) / Double(hours.count) >= 0.35 else { return nil }
        return hour
    }
}
