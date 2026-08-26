import Foundation
import HealthCore
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct RefinedQuery {
    @Guide(description: "The next search term to try against a food database. Plain food words only — no brand, no venue, no portion size. Empty string if there is nothing sensible left to try.")
    var query: String

    @Guide(description: "One short sentence on why this term should work better than the last one.")
    var rationale: String
}
#endif

/// Reformulates a failed food search using the on-device model.
///
/// This is the agentic part, and the division of labour is deliberate: the
/// model decides *what to search for next*, which is an open-ended language
/// problem it is good at, while `AgenticNutritionResolver` decides *when the
/// answer is good enough*, which stays deterministic. The model never gets to
/// declare itself finished — otherwise a confident wrong answer ends the loop,
/// which is precisely the failure this whole design exists to prevent.
public struct LanguageModelRefiner: QueryRefiner {

    /// Used when the model is unavailable, and as a second opinion when it
    /// returns something useless.
    private let fallback = HeuristicRefiner()

    public init() {}

    public func refine(_ context: RefinementContext) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), AppleIntelligence.availability.isUsable {
            if let suggestion = await modelSuggestion(context) { return suggestion }
        }
        #endif
        return await fallback.refine(context)
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private func modelSuggestion(_ context: RefinementContext) async -> String? {
        let instructions = """
        You turn a person's description of something they ate into a search term for a food \
        nutrition database.

        Those databases index plain food names. They do not know about restaurants, pubs, \
        brands you have not heard of, portion sizes, or how something was described in \
        conversation. Your job is to strip a failed query back to the food itself.

        - Answer with search words only. No sentences, no punctuation beyond spaces.
        - Never repeat a term that has already been tried.
        - If a previous attempt returned the wrong food entirely, change the words rather \
          than shortening them.
        - If there is nothing sensible left to try, return an empty query.
        """

        var prompt = """
        The person logged: "\(context.originalItem)"

        Searches already tried, none of which worked: \
        \(context.attemptedQueries.map { "\"\($0)\"" }.joined(separator: ", "))

        What went wrong last time: \(context.reason.summary)
        """

        if !context.rejectedMatches.isEmpty {
            prompt += "\n\nThe database offered these, which were not the right food: "
                + context.rejectedMatches.prefix(5).map { "\"\($0)\"" }.joined(separator: ", ")
        }
        prompt += "\n\nWhat should be searched for next?"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: RefinedQuery.self)
            let query = response.content.query
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard !query.isEmpty,
                  query.count >= 3,
                  // Guard against the model ignoring the instruction and
                  // handing back something already tried.
                  !context.attemptedQueries.contains(where: {
                      $0.caseInsensitiveCompare(query) == .orderedSame
                  })
            else { return nil }

            return query
        } catch {
            return nil
        }
    }
    #endif
}

/// Assembles the resolver stack for a device, given what it is allowed to do.
///
/// Every capability is opt-in and reported honestly: `describeCapabilities`
/// tells the UI exactly which sources are live, because "1,470 kcal" from a
/// manufacturer's label and "1,470 kcal" from a guess deserve different
/// treatment on screen.
public struct ResolverFactory {

    public struct Settings: Sendable {
        /// Off by default. When false, nothing leaves the device.
        public var allowNetworkLookups: Bool
        /// Free key from fdc.nal.usda.gov. Optional.
        public var foodDataCentralKey: String?
        public var maximumAttempts: Int

        public init(allowNetworkLookups: Bool = false,
                    foodDataCentralKey: String? = nil,
                    maximumAttempts: Int = 4) {
            self.allowNetworkLookups = allowNetworkLookups
            self.foodDataCentralKey = foodDataCentralKey
            self.maximumAttempts = maximumAttempts
        }
    }

    public static func makeResolver(settings: Settings,
                                    client: NutritionHTTPClient = URLSessionNutritionClient())
    -> AgenticNutritionResolver {
        var providers: [NutritionProvider] = [BuiltInCatalogueProvider()]

        if settings.allowNetworkLookups {
            providers.append(OpenFoodFactsProvider(client: client))
            if let key = settings.foodDataCentralKey, !key.isEmpty {
                providers.append(FoodDataCentralProvider(client: client, apiKey: key))
            }
        }

        var configuration = AgenticNutritionResolver.Configuration()
        configuration.maximumAttempts = settings.maximumAttempts
        // With only the built-in table there is nothing to refine towards, so
        // looping would just burn time.
        if !settings.allowNetworkLookups { configuration.maximumAttempts = 1 }

        return AgenticNutritionResolver(
            resolver: NutritionResolver(providers: providers),
            refiner: LanguageModelRefiner(),
            configuration: configuration)
    }

    public static func describeCapabilities(settings: Settings) -> [String] {
        var lines = ["Built-in food and drink table (always on, never leaves the device)"]
        if settings.allowNetworkLookups {
            lines.append("Open Food Facts — packaged groceries and barcodes")
            if let key = settings.foodDataCentralKey, !key.isEmpty {
                lines.append("USDA FoodData Central — generic foods")
            } else {
                lines.append("USDA FoodData Central — add a free API key to enable")
            }
        } else {
            lines.append("Online lookups are switched off")
        }
        lines.append(AppleIntelligence.availability.isUsable
                     ? "Apple Intelligence — parses what you say and refines failed searches"
                     : "Apple Intelligence unavailable — falling back to keyword matching")
        return lines
    }
}
