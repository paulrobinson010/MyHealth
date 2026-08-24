import Foundation
import HealthCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the on-device model can be used right now.
public enum IntelligenceAvailability: Equatable {
    case available
    case notEnabled
    case deviceNotEligible
    case modelNotReady
    case notBuiltWithFoundationModels

    public var isUsable: Bool { self == .available }

    public var message: String {
        switch self {
        case .available:
            return "Apple Intelligence is ready."
        case .notEnabled:
            return "Turn on Apple Intelligence in System Settings to use the coach and conversational logging. Everything else works without it."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence. The written summary below is generated from your numbers directly."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Try again shortly."
        case .notBuiltWithFoundationModels:
            return "This build was compiled without the Foundation Models framework. Rebuild with the macOS 26 SDK or later."
        }
    }
}

/// Wraps Apple's on-device language model.
///
/// The important rule here, enforced by the shape of the code rather than by
/// hoping: **the model never decides anything**. Whether you are fitter is
/// settled by `FitnessIndex` and `FitnessNarrator`, which are plain arithmetic.
/// The model is handed those conclusions and asked to write them up nicely, and
/// separately does the one job it is genuinely better at than code — turning
/// "three pints and a curry" into structured nutrition.
@MainActor
final class HealthCoach {

    static var availability: IntelligenceAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .deviceNotEligible: return .deviceNotEligible
                case .modelNotReady: return .modelNotReady
                @unknown default: return .modelNotReady
                }
            @unknown default:
                return .modelNotReady
            }
        }
        return .deviceNotEligible
        #else
        return .notBuiltWithFoundationModels
        #endif
    }

    // MARK: - Fitness narrative

    /// Rewrites a deterministic briefing as prose. Returns the briefing's own
    /// plain text if the model is unavailable or declines — the reader always
    /// gets an answer.
    func narrate(_ briefing: FitnessNarrator.Briefing) async -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), HealthCoach.availability.isUsable else {
            return briefing.plainText
        }
        let instructions = """
        You are a concise, level-headed fitness analyst writing for one person about their own data.

        You will be given a set of findings that have ALREADY been computed from that person's health \
        records. Your job is to write them up as two or three short paragraphs of plain English.

        Rules you must follow:
        - Never invent a number, a trend or a conclusion that is not in the findings.
        - Never contradict the findings, even if they seem surprising.
        - Do not give medical advice or diagnose anything.
        - No greetings, no sign-off, no headings, no bullet points. Just the prose.
        - British English. Direct and unsentimental. No cheerleading.
        """

        let prompt = """
        Verdict: \(briefing.headline)

        Findings:
        \(briefing.findings.map { "- \($0)" }.joined(separator: "\n"))

        Things that would help:
        \(briefing.suggestions.map { "- \($0)" }.joined(separator: "\n"))

        Caveats that must be mentioned:
        \(briefing.caveats.map { "- \($0)" }.joined(separator: "\n"))
        """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? briefing.plainText : text
        } catch {
            return briefing.plainText
        }
        #else
        return briefing.plainText
        #endif
    }
}

// MARK: - Structured output for conversational logging

#if canImport(FoundationModels)

@available(macOS 26.0, *)
@Generable
enum ParsedContext {
    case home
    case pub
    case restaurant
    case takeaway
    case cafe
    case work
    case travel
    case unknown

    var mealContext: MealContext {
        switch self {
        case .home: return .home
        case .pub: return .pub
        case .restaurant: return .restaurant
        case .takeaway: return .takeaway
        case .cafe: return .cafe
        case .work: return .work
        case .travel: return .travel
        case .unknown: return .unknown
        }
    }
}

@available(macOS 26.0, *)
@Generable
struct ParsedItem {
    @Guide(description: "Plain name of the item, e.g. 'pint of lager' or 'chicken tikka masala'.")
    var name: String

    @Guide(description: "How many servings of it. Use 1 if not stated.")
    var servings: Double

    @Guide(description: "Calories in ONE serving.")
    var kilocalories: Int

    @Guide(description: "Grams of protein in one serving.")
    var proteinGrams: Int

    @Guide(description: "Grams of carbohydrate in one serving.")
    var carbohydrateGrams: Int

    @Guide(description: "Grams of fat in one serving.")
    var fatGrams: Int

    @Guide(description: "Grams of pure alcohol in one serving. Zero for food and soft drinks. A UK pint of 4.5% lager is about 20 grams; a 175 ml glass of 13% wine is about 18 grams; a 25 ml single spirit is about 8 grams.")
    var alcoholGrams: Int
}

@available(macOS 26.0, *)
@Generable
struct AgentTurn {
    @Guide(description: "A short reply to show the person. One or two sentences. British English, warm but not gushing.")
    var reply: String

    @Guide(description: "One question to ask next if something significant is missing or ambiguous, otherwise an empty string. Never ask more than one thing at a time.")
    var followUpQuestion: String

    @Guide(description: "Where this food and drink was consumed, judged from what was said.")
    var context: ParsedContext

    @Guide(description: "Name of the pub, restaurant or cafe if the person named one, otherwise an empty string.")
    var venueName: String

    @Guide(description: "How confident you are about the venue type, from 0 to 100.")
    var venueConfidence: Int

    @Guide(description: "Every distinct food or drink item mentioned in this message. Empty if the person did not mention any.")
    var items: [ParsedItem]
}

#endif

/// The result of one turn, in terms the app understands. Defined outside the
/// Foundation Models conditional so the UI compiles either way.
struct CoachTurn {
    var reply: String
    var followUpQuestion: String?
    var context: MealContext
    var venueName: String?
    var venueConfidence: Double
    var entries: [FoodEntry]

    var hasItems: Bool { !entries.isEmpty }
}

/// The conversational food-and-drink logger.
///
/// It keeps a single session so the conversation has memory — "and another two
/// of those" resolves against what was said a moment ago, which is the whole
/// reason to do this as a conversation rather than a form.
@MainActor
final class LoggingAgent {

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private var session: LanguageModelSession? {
        get { _session as? LanguageModelSession }
        set { _session = newValue }
    }
    private var _session: Any?
    #endif

    var availability: IntelligenceAvailability { HealthCoach.availability }

    /// Everything the model needs to ground its calorie estimates, so it leans
    /// on our table for the common things rather than inventing numbers.
    private static var groundingTable: String {
        let food = FoodPreset.catalogue.prefix(24).map {
            "\($0.name) (\($0.servingDescription)): \(Int($0.nutrition.kilocalories)) kcal, "
                + "P\(Int($0.nutrition.proteinGrams)) C\(Int($0.nutrition.carbohydrateGrams)) F\(Int($0.nutrition.fatGrams))"
        }
        let drink = DrinkPreset.standard.map {
            "\($0.name): \(Int($0.nutrition.kilocalories)) kcal, \(Int($0.alcoholGrams)) g alcohol, \(String(format: "%.1f", $0.ukUnits)) UK units"
        }
        return (food + drink).joined(separator: "\n")
    }

    private static var instructions: String {
        """
        You help one person keep a food and drink diary by talking to them. You are logging \
        what they say, not judging it.

        How to behave:
        - Extract every food and drink item they mention, with a sensible calorie estimate for each.
        - Work out where they were. Several drinks with little food is a pub. A big evening meal \
          with wine is a restaurant. A weekday sandwich at midday is work. No alcohol and a cooked \
          meal is home. If they name a venue, record it.
        - If something important is genuinely ambiguous — a portion size that changes the answer a \
          lot, or whether a drink was a pint or a half — ask ONE short follow-up question. \
          Otherwise ask nothing and just confirm what you logged.
        - Never lecture them about drinking or eating. Never give medical advice. No moralising, \
          no calorie warnings, no suggestions unless they ask.
        - British English. Portions are UK serves: a pint is 568 ml, a large wine is 250 ml.

        Use these reference values wherever the item matches; estimate for anything else:
        \(groundingTable)
        """
    }

    func reset() {
        #if canImport(FoundationModels)
        _session = nil
        #endif
    }

    /// The opening line. Deterministic, so the conversation starts instantly
    /// and identically whether or not the model is available.
    func greeting(alreadyLogged: Nutrition?, timeOfDay: Int) -> String {
        let meal: String
        switch timeOfDay {
        case 5..<11: meal = "for breakfast"
        case 11..<15: meal = "for lunch"
        case 15..<18: meal = "this afternoon"
        case 18..<23: meal = "this evening"
        default: meal = "today"
        }
        if let alreadyLogged, alreadyLogged.kilocalories > 0 {
            return "You are on \(Int(alreadyLogged.kilocalories)) kcal so far today. What have you had \(meal)?"
        }
        return "What have you had \(meal)?"
    }

    func send(_ text: String, at date: Date = Date()) async -> CoachTurn {
        await respond(to: text.trimmingCharacters(in: .whitespacesAndNewlines), at: date)
    }

    private func respond(to text: String, at date: Date) async -> CoachTurn {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability.isUsable {
            do {
                let active: LanguageModelSession
                if let existing = session {
                    active = existing
                } else {
                    active = LanguageModelSession(instructions: LoggingAgent.instructions)
                    session = active
                }
                let response = try await active.respond(to: text, generating: AgentTurn.self)
                return LoggingAgent.convert(response.content, at: date)
            } catch {
                return LoggingAgent.fallback(for: text, at: date,
                                             note: "I could not parse that with Apple Intelligence, so I matched what I could.")
            }
        }
        #endif
        return LoggingAgent.fallback(for: text, at: date, note: nil)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func convert(_ turn: AgentTurn, at date: Date) -> CoachTurn {
        let entries = turn.items.map { item in
            FoodEntry(name: item.name,
                      timestamp: date.timeIntervalSince1970,
                      servings: max(0.25, item.servings),
                      nutrition: Nutrition(kilocalories: Double(item.kilocalories),
                                           proteinGrams: Double(item.proteinGrams),
                                           carbohydrateGrams: Double(item.carbohydrateGrams),
                                           fatGrams: Double(item.fatGrams),
                                           alcoholGrams: Double(item.alcoholGrams)),
                      source: .naturalLanguage)
        }

        let stated = turn.context.mealContext
        // The model's guess is a proposal; when it is unsure, the deterministic
        // classifier gets the last word.
        let confidence = Double(turn.venueConfidence.clamped(to: 0...100)) / 100
        let resolved: MealContext
        if stated != .unknown && confidence >= 0.5 {
            resolved = stated
        } else {
            resolved = classify(entries, at: date).context
        }

        let venue = turn.venueName.trimmingCharacters(in: .whitespaces)
        return CoachTurn(reply: turn.reply,
                         followUpQuestion: turn.followUpQuestion.isEmpty ? nil : turn.followUpQuestion,
                         context: resolved,
                         venueName: venue.isEmpty ? nil : venue,
                         venueConfidence: confidence,
                         entries: entries)
    }
    #endif

    /// Keyword matching against the built-in tables. Not clever, but it means
    /// "two pints of lager" still logs correctly on a Mac with Apple
    /// Intelligence turned off.
    private static func fallback(for text: String, at date: Date, note: String?) -> CoachTurn {
        let lowered = text.lowercased()
        var entries: [FoodEntry] = []

        func quantity(before keyword: String) -> Double {
            let words = ["one": 1.0, "two": 2, "three": 3, "four": 4, "five": 5,
                         "six": 6, "a couple of": 2, "a": 1, "an": 1]
            guard let range = lowered.range(of: keyword) else { return 1 }
            let prefix = String(lowered[lowered.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            for (word, value) in words where prefix.hasSuffix(word) { return value }
            if let last = prefix.split(separator: " ").last, let number = Double(last) { return number }
            return 1
        }

        for drink in DrinkPreset.standard {
            let keyword = drink.name.split(separator: " ").prefix(2).joined(separator: " ").lowercased()
            guard lowered.contains(keyword) else { continue }
            entries.append(FoodEntry(name: drink.name,
                                     timestamp: date.timeIntervalSince1970,
                                     servings: quantity(before: keyword),
                                     nutrition: drink.nutrition,
                                     source: .catalogue))
            break
        }

        for food in FoodPreset.catalogue {
            let keyword = food.name.lowercased()
            let shortened = keyword.split(separator: ",").first.map(String.init) ?? keyword
            guard lowered.contains(shortened) else { continue }
            entries.append(FoodEntry(name: food.name,
                                     timestamp: date.timeIntervalSince1970,
                                     servings: quantity(before: shortened),
                                     nutrition: food.nutrition,
                                     source: .catalogue))
            break
        }

        let guess = classify(entries, at: date)
        let reply: String
        if entries.isEmpty {
            reply = note ?? "I did not recognise anything in that. Try naming the item and the portion, or add it from the food list."
        } else {
            let names = entries.map { $0.servings > 1 ? "\(Format.servings($0.servings)) × \($0.name)" : $0.name }
            reply = (note.map { $0 + " " } ?? "") + "Logged \(names.joined(separator: " and "))."
        }

        return CoachTurn(reply: reply,
                         followUpQuestion: nil,
                         context: guess.context,
                         venueName: nil,
                         venueConfidence: guess.confidence,
                         entries: entries)
    }

    static func classify(_ entries: [FoodEntry], at date: Date) -> ContextClassifier.Guess {
        let calendar = Calendar.current
        let total = entries.reduce(Nutrition.empty) { $0 + $1.total }
        let drinks = entries.filter { $0.nutrition.alcoholGrams > 0 }
            .reduce(0.0) { $0 + $1.servings }
        return ContextClassifier.classify(.init(
            alcoholGrams: total.alcoholGrams,
            totalCalories: total.kilocalories,
            distinctDrinks: Int(drinks.rounded()),
            itemCount: entries.count,
            hour: calendar.component(.hour, from: date),
            weekday: calendar.component(.weekday, from: date) - 1))
    }
}
