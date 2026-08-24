import Foundation

/// A reason to ask someone to log what they ate.
public struct LoggingPrompt: Sendable, Hashable {
    public enum Trigger: Sendable, Hashable {
        /// A meal window they normally log in has passed with nothing recorded.
        case missedMeal(name: String)
        /// The day is ending and nothing at all was logged.
        case endOfDay
        /// The deficit figure is blocked on coverage, and they should know.
        case coverageBlocking(loggedDays: Int, totalDays: Int)
        /// They were somewhere that usually costs them, and logged nothing.
        case likelyEatingOut

        public var identifier: String {
            switch self {
            case .missedMeal(let name): return "meal-\(name.lowercased())"
            case .endOfDay: return "endOfDay"
            case .coverageBlocking: return "coverage"
            case .likelyEatingOut: return "eatingOut"
            }
        }
    }

    public let trigger: Trigger
    public let title: String
    public let body: String
    public let urgency: WeighInCue.Urgency
}

/// When someone usually eats, learned from what they have logged.
///
/// Prompting at fixed times is how a reminder becomes something people switch
/// off. If they never eat breakfast, asking about it every morning at eight is
/// just noise, so the windows come from their own history.
public struct MealHabits: Sendable {
    public struct Window: Sendable, Hashable {
        public let name: String
        /// Local hour the meal usually starts.
        public let hour: Int
        /// How reliably they log it, 0...1.
        public let reliability: Double

        public init(name: String, hour: Int, reliability: Double) {
            self.name = name
            self.hour = hour
            self.reliability = reliability
        }
    }

    public let windows: [Window]

    public init(windows: [Window]) { self.windows = windows }

    public static let empty = MealHabits(windows: [])

    /// Derives meal windows from a log.
    ///
    /// Entries are bucketed into rough parts of the day, and a bucket only
    /// becomes a window if it is used often enough to be a habit.
    public static func learn(from log: FoodLog,
                             over days: Int = 30,
                             asOf today: DayKey = .today,
                             calendar: Calendar = .current) -> MealHabits {
        let cutoff = today.adding(days: -days)
        let recent = log.entries.filter { $0.day >= cutoff }
        guard !recent.isEmpty else { return .empty }

        let observedDays = Set(recent.map(\.day.ordinal)).count
        guard observedDays >= 3 else { return .empty }

        struct Bucket { let name: String; let range: Range<Int> }
        let buckets = [
            Bucket(name: "Breakfast", range: 5..<11),
            Bucket(name: "Lunch", range: 11..<15),
            Bucket(name: "Dinner", range: 17..<23)
        ]

        var windows: [Window] = []
        for bucket in buckets {
            let inBucket = recent.filter {
                bucket.range.contains(calendar.component(.hour, from: $0.date))
            }
            let daysWithThisMeal = Set(inBucket.map(\.day.ordinal)).count
            let reliability = Double(daysWithThisMeal) / Double(observedDays)
            // Under a third of days is not a habit worth interrupting for.
            guard reliability >= 0.34 else { continue }

            let hours = inBucket.map { calendar.component(.hour, from: $0.date) }.sorted()
            let median = hours[hours.count / 2]
            windows.append(Window(name: bucket.name, hour: median, reliability: reliability))
        }
        return MealHabits(windows: windows.sorted { $0.hour < $1.hour })
    }
}

/// Decides what, if anything, to ask about logging.
///
/// Driven by the deficit audit rather than a clock. If coverage is fine the
/// scheduler stays quiet, because a reminder that fires when nothing is wrong
/// teaches people to ignore it — and then it is not there when it matters.
public struct LoggingPromptScheduler: Sendable {

    public struct Context: Sendable {
        public var now: Date
        public var log: FoodLog
        public var habits: MealHabits
        /// The current audit, if there is one.
        public var integrity: DeficitIntegrity?
        /// Prompt identifiers already sent today.
        public var alreadySentToday: Set<String>
        public var calendar: Calendar

        public init(now: Date = Date(),
                    log: FoodLog = FoodLog(),
                    habits: MealHabits = .empty,
                    integrity: DeficitIntegrity? = nil,
                    alreadySentToday: Set<String> = [],
                    calendar: Calendar = .current) {
            self.now = now
            self.log = log
            self.habits = habits
            self.integrity = integrity
            self.alreadySentToday = alreadySentToday
            self.calendar = calendar
        }
    }

    public struct Settings: Sendable {
        public var quietUntil = 7
        public var quietFrom = 22
        /// Never more than this many in a day, whatever else is true.
        public var maximumPerDay = 3
        /// Do not prompt within this long of them logging something.
        public var silenceAfterLogging: TimeInterval = 45 * 60
        /// How long after a meal window opens before it counts as missed.
        public var mealGraceHours = 2
        public init() {}
    }

    private let settings: Settings

    public init(settings: Settings = Settings()) { self.settings = settings }

    public func prompts(_ context: Context) -> [LoggingPrompt] {
        let hour = context.calendar.component(.hour, from: context.now)
        guard hour >= settings.quietUntil, hour < settings.quietFrom else { return [] }
        guard context.alreadySentToday.count < settings.maximumPerDay else { return [] }

        let today = DayKey(date: context.now, calendar: context.calendar)
        let todaysEntries = context.log.entries(on: today)

        // Just logged something — leave them alone.
        if let latest = todaysEntries.map(\.timestamp).max(),
           context.now.timeIntervalSince1970 - latest < settings.silenceAfterLogging {
            return []
        }

        var results: [LoggingPrompt] = []

        // 1. A meal window they reliably log has come and gone.
        for window in context.habits.windows {
            let trigger = LoggingPrompt.Trigger.missedMeal(name: window.name)
            guard !context.alreadySentToday.contains(trigger.identifier) else { continue }
            guard hour >= window.hour + settings.mealGraceHours else { continue }
            // Something already logged inside the window means they did it.
            let loggedInWindow = todaysEntries.contains { entry in
                let entryHour = context.calendar.component(.hour, from: entry.date)
                return abs(entryHour - window.hour) <= settings.mealGraceHours
            }
            guard !loggedInWindow else { continue }

            results.append(LoggingPrompt(
                trigger: trigger,
                title: "\(window.name)?",
                body: "You usually log \(window.name.lowercased()) around now. A rough entry beats a missing day — an unlogged day counts as nothing eaten, which invents progress that did not happen.",
                urgency: window.reliability > 0.7 ? .normal : .gentle))
        }

        // 2. Evening, and nothing at all today.
        let endOfDay = LoggingPrompt.Trigger.endOfDay
        if hour >= 20, todaysEntries.isEmpty,
           !context.alreadySentToday.contains(endOfDay.identifier) {
            results.append(LoggingPrompt(
                trigger: endOfDay,
                title: "Nothing logged today",
                body: "Even a one-line entry keeps the week's figures honest.",
                urgency: .normal))
        }

        // 3. Coverage is actively blocking the deficit figure. This is the only
        //    prompt that earns being insistent, because it is the difference
        //    between a measurement and a guess.
        if let integrity = context.integrity,
           integrity.confidence == .unreliable,
           integrity.loggedDays * 2 < integrity.totalDays,
           hour >= 18,
           !context.alreadySentToday.contains(LoggingPrompt.Trigger
            .coverageBlocking(loggedDays: 0, totalDays: 0).identifier) {
            results.append(LoggingPrompt(
                trigger: .coverageBlocking(loggedDays: integrity.loggedDays,
                                           totalDays: integrity.totalDays),
                title: "Your deficit figure is not usable yet",
                body: "Only \(integrity.loggedDays) of the last \(integrity.totalDays) days have food logged. A fortnight of consistent logging is enough to turn it into a real number.",
                urgency: .important))
        }

        // Most urgent first, and never more than the daily budget allows.
        let remaining = settings.maximumPerDay - context.alreadySentToday.count
        return results
            .sorted { $0.urgency > $1.urgency }
            .prefix(max(0, remaining))
            .map { $0 }
    }
}
