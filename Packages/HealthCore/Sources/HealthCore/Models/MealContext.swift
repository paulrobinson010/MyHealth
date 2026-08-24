import Foundation

/// Where a meal happened. The interesting question is never "how many calories
/// was that curry" — it is "what does a night at the pub actually cost me", and
/// that needs the occasion attached to the food.
public enum MealContext: String, Codable, CaseIterable, Sendable {
    case home
    case pub
    case restaurant
    case takeaway
    case cafe
    case work
    case travel
    case unknown

    public var title: String {
        switch self {
        case .home: return "Home"
        case .pub: return "Pub"
        case .restaurant: return "Restaurant"
        case .takeaway: return "Takeaway"
        case .cafe: return "Café"
        case .work: return "Work"
        case .travel: return "Travelling"
        case .unknown: return "Unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: return "house"
        case .pub: return "mug"
        case .restaurant: return "fork.knife"
        case .takeaway: return "takeoutbag.and.cup.and.straw"
        case .cafe: return "cup.and.saucer"
        case .work: return "building.2"
        case .travel: return "airplane"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Contexts that tend to blow a day's budget, used to group the "eating
    /// out" analysis.
    public var isEatingOut: Bool {
        switch self {
        case .pub, .restaurant, .takeaway, .cafe, .travel: return true
        case .home, .work, .unknown: return false
        }
    }
}

/// How confident we are about the context, and why. Kept explicit so the UI can
/// be honest about the difference between "your phone was in a pub" and "you
/// logged four pints on a Friday night".
public enum ContextEvidence: String, Codable, Sendable {
    /// Confirmed against a nearby point of interest.
    case location
    /// The person said so.
    case stated
    /// Inferred from what was logged and when.
    case inferred
    case none
}

public struct MealOccasion: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var context: MealContext
    public var evidence: ContextEvidence
    /// Name of the venue, when location or the person supplied one.
    public var venueName: String?
    /// Epoch seconds.
    public var start: Double
    public var entryIDs: [UUID]

    public init(id: UUID = UUID(),
                context: MealContext,
                evidence: ContextEvidence,
                venueName: String? = nil,
                start: Double,
                entryIDs: [UUID] = []) {
        self.id = id
        self.context = context
        self.evidence = evidence
        self.venueName = venueName
        self.start = start
        self.entryIDs = entryIDs
    }

    public var day: DayKey { DayKey(date: Date(timeIntervalSince1970: start)) }
}

/// Guesses where a set of entries was eaten, from the entries themselves.
///
/// This runs before any language model is involved and stands on its own, so
/// the feature works on a Mac with Apple Intelligence switched off. The model,
/// when available, gets this as a starting point rather than a blank page.
public enum ContextClassifier {

    public struct Signals: Sendable {
        public var alcoholGrams: Double
        public var totalCalories: Double
        public var distinctDrinks: Int
        public var itemCount: Int
        /// Local hour, 0...23.
        public var hour: Int
        /// 0 = Sunday.
        public var weekday: Int
        public var mentionsTakeaway: Bool

        public init(alcoholGrams: Double, totalCalories: Double, distinctDrinks: Int,
                    itemCount: Int, hour: Int, weekday: Int, mentionsTakeaway: Bool = false) {
            self.alcoholGrams = alcoholGrams
            self.totalCalories = totalCalories
            self.distinctDrinks = distinctDrinks
            self.itemCount = itemCount
            self.hour = hour
            self.weekday = weekday
            self.mentionsTakeaway = mentionsTakeaway
        }
    }

    public struct Guess: Sendable {
        public let context: MealContext
        /// 0...1.
        public let confidence: Double
        public let reason: String
    }

    public static func classify(_ signals: Signals) -> Guess {
        let isEvening = signals.hour >= 17
        let isWeekend = signals.weekday == 5 || signals.weekday == 6 || signals.weekday == 0

        // Several drinks and very little food is a pub, at any hour.
        if signals.distinctDrinks >= 3 && signals.totalCalories - signals.alcoholGrams * 7 < 600 {
            return Guess(context: .pub,
                         confidence: isEvening ? 0.8 : 0.65,
                         reason: "\(signals.distinctDrinks) drinks with little food")
        }

        if signals.mentionsTakeaway {
            return Guess(context: .takeaway, confidence: 0.85, reason: "takeaway named")
        }

        // Drinks alongside a substantial meal in the evening reads as going out.
        if signals.alcoholGrams > 16, signals.totalCalories > 800, isEvening {
            return Guess(context: .restaurant,
                         confidence: isWeekend ? 0.7 : 0.55,
                         reason: "large evening meal with alcohol")
        }

        if signals.hour < 11, signals.totalCalories < 400, signals.itemCount <= 2 {
            return Guess(context: .cafe, confidence: 0.4, reason: "small morning order")
        }

        if signals.hour >= 11, signals.hour <= 14, signals.weekday >= 1, signals.weekday <= 5,
           signals.alcoholGrams == 0 {
            return Guess(context: .work, confidence: 0.45, reason: "weekday lunchtime")
        }

        if signals.alcoholGrams == 0, signals.itemCount >= 2 {
            return Guess(context: .home, confidence: 0.5, reason: "no alcohol, cooked-meal pattern")
        }

        return Guess(context: .unknown, confidence: 0.2, reason: "not enough signal")
    }

    /// Point-of-interest categories that map onto a context, for when location
    /// is available and can settle it outright.
    public static func context(forPointOfInterestCategory raw: String) -> MealContext? {
        switch raw.lowercased() {
        case let value where value.contains("brewery") || value.contains("nightlife")
            || value.contains("winery") || value.contains("pub") || value.contains("bar"):
            return .pub
        case let value where value.contains("restaurant") || value.contains("food"):
            return .restaurant
        case let value where value.contains("cafe") || value.contains("bakery")
            || value.contains("coffee"):
            return .cafe
        case let value where value.contains("airport") || value.contains("station")
            || value.contains("hotel"):
            return .travel
        default:
            return nil
        }
    }
}
