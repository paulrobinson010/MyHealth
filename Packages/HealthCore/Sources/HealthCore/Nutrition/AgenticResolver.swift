import Foundation

/// Proposes the next search query when the previous one did not produce a good
/// enough answer.
///
/// This is the agentic half. The loop below decides *whether* an answer is good
/// enough — that judgement stays deterministic — but deciding *what to search
/// for next* is exactly the kind of open-ended reformulation a language model
/// is better at than any rule. "Chicken tikka masala from the Bengal Spice"
/// finds nothing; "chicken tikka masala" finds plenty, and knowing to drop the
/// restaurant name is a language problem.
public protocol QueryRefiner: Sendable {
    /// Returns the next query to try, or nil to stop.
    func refine(_ context: RefinementContext) async -> String?
}

public struct RefinementContext: Sendable {
    /// What the person actually said.
    public let originalItem: String
    /// Queries already tried, in order.
    public let attemptedQueries: [String]
    /// Names the search returned last time, which were rejected.
    public let rejectedMatches: [String]
    /// Why the loop is asking again.
    public let reason: RejectionReason
    public let attempt: Int

    public init(originalItem: String, attemptedQueries: [String], rejectedMatches: [String],
                reason: RejectionReason, attempt: Int) {
        self.originalItem = originalItem
        self.attemptedQueries = attemptedQueries
        self.rejectedMatches = rejectedMatches
        self.reason = reason
        self.attempt = attempt
    }
}

public enum RejectionReason: Sendable, Equatable {
    /// The search came back empty.
    case noResults
    /// Results came back but none were about the right food.
    case irrelevant(bestSimilarity: Double)
    /// A match was found but its numbers failed validation.
    case failedValidation(issues: [String])
    /// Found something usable, but not confidently enough to stop.
    case lowConfidence(Double)

    public var summary: String {
        switch self {
        case .noResults:
            return "nothing came back"
        case .irrelevant(let similarity):
            return String(format: "results were not about the right food (best match %.0f%%)",
                          similarity * 100)
        case .failedValidation(let issues):
            return "the numbers did not stand up: \(issues.joined(separator: "; "))"
        case .lowConfidence(let confidence):
            return String(format: "only %.0f%% confident", confidence * 100)
        }
    }
}

/// Rule-based reformulation, used when no language model is available.
///
/// Deliberately crude, and enough to matter: most failed food searches fail
/// because the query carries a venue, a brand or a portion that the database
/// has never heard of.
public struct HeuristicRefiner: QueryRefiner {
    public init() {}

    private static let noiseWords: Set<String> = [
        "large", "small", "medium", "regular", "big", "huge", "double", "single",
        "half", "portion", "serving", "plate", "bowl", "glass", "some", "a", "an",
        "the", "my", "homemade", "home", "made", "fresh", "leftover", "leftovers"
    ]

    public func refine(_ context: RefinementContext) async -> String? {
        let base = context.attemptedQueries.last ?? context.originalItem
        let words = base.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        switch context.attempt {
        case 0:
            // Everything after "from"/"at" is a venue, not a food.
            for separator in [" from ", " at ", " in "] {
                if let range = base.lowercased().range(of: separator) {
                    let trimmed = String(base[base.startIndex..<range.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, trimmed != base { return trimmed }
                }
            }
            fallthrough
        case 1:
            // Drop portion and quality adjectives.
            let cleaned = words.filter { !HeuristicRefiner.noiseWords.contains($0) }
            let candidate = cleaned.joined(separator: " ")
            if !candidate.isEmpty, candidate != base.lowercased() { return candidate }
            fallthrough
        case 2:
            // Fall back to the last two words, which is usually the food itself:
            // "spicy grilled chicken thighs" -> "chicken thighs".
            let cleaned = words.filter { !HeuristicRefiner.noiseWords.contains($0) }
            guard cleaned.count > 2 else { return nil }
            let candidate = cleaned.suffix(2).joined(separator: " ")
            return context.attemptedQueries.contains(candidate) ? nil : candidate
        default:
            return nil
        }
    }
}

/// Runs the lookup as a loop rather than a single shot: search, judge, refine,
/// search again — until a deterministic quality bar is cleared or the attempts
/// run out.
///
/// The stopping condition is the important design decision. The model never
/// declares itself finished; `NutritionValidator` and a relevance threshold do,
/// which is what keeps a fluent wrong answer from ending the loop.
public struct AgenticNutritionResolver: Sendable {

    public struct Configuration: Sendable {
        /// Stop once a candidate reaches this confidence.
        public var targetConfidence: Double = 0.7
        /// Never search more than this many times for one item.
        public var maximumAttempts: Int = 4
        /// A candidate below this relevance is not about the right food.
        public var minimumRelevance: Double = 0.34
        public init() {}
    }

    /// A record of how the answer was reached, for the UI and for debugging a
    /// bad result later.
    public struct Trace: Sendable {
        public struct Step: Sendable {
            public let query: String
            public let resultCount: Int
            public let bestConfidence: Double
            public let outcome: String
        }
        public let steps: [Step]
        public var attempts: Int { steps.count }
    }

    public struct Outcome: Sendable {
        public let resolution: NutritionResolver.Resolution
        public let trace: Trace
        /// True when the loop cleared its own bar rather than simply running out
        /// of attempts.
        public let converged: Bool
    }

    private let resolver: NutritionResolver
    private let refiner: QueryRefiner
    private let configuration: Configuration

    public init(resolver: NutritionResolver,
                refiner: QueryRefiner = HeuristicRefiner(),
                configuration: Configuration = Configuration()) {
        self.resolver = resolver
        self.refiner = refiner
        self.configuration = configuration
    }

    public func resolve(name: String,
                        estimate: Nutrition? = nil,
                        estimateSource: NutritionSource = .languageModel,
                        servings: Double = 1) async -> Outcome {
        var steps: [Trace.Step] = []
        var attemptedQueries: [String] = []
        var best: NutritionResolver.Resolution?
        var query = name

        for attempt in 0..<max(1, configuration.maximumAttempts) {
            attemptedQueries.append(query)

            let resolution = await resolver.resolve(name: query,
                                                    estimate: estimate,
                                                    estimateSource: estimateSource,
                                                    servings: servings)

            // Keep the best answer seen, so running out of attempts still
            // returns the strongest candidate rather than the last one.
            if best == nil || resolution.provenance.confidence > best!.provenance.confidence {
                best = resolution
            }

            let confidence = resolution.provenance.confidence
            let cleared = confidence >= configuration.targetConfidence
                && resolution.provenance.issues.isEmpty
                && resolution.provenance.source != .languageModel

            steps.append(Trace.Step(
                query: query,
                resultCount: resolution.alternatives.count + 1,
                bestConfidence: confidence,
                outcome: cleared ? "accepted" : "rejected — \(reason(for: resolution).summary)"))

            if cleared {
                return Outcome(resolution: best ?? resolution,
                               trace: Trace(steps: steps),
                               converged: true)
            }

            let context = RefinementContext(
                originalItem: name,
                attemptedQueries: attemptedQueries,
                rejectedMatches: resolution.alternatives.map(\.displayName),
                reason: reason(for: resolution),
                attempt: attempt)

            guard let next = await refiner.refine(context)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !next.isEmpty,
                  !attemptedQueries.contains(where: { $0.caseInsensitiveCompare(next) == .orderedSame })
            else { break }

            query = next
        }

        let resolution = best ?? NutritionResolver.Resolution(
            name: name,
            nutrition: estimate ?? .empty,
            provenance: NutritionProvenance(source: estimateSource, confidence: 0,
                                            issues: ["Nothing usable was found."]),
            alternatives: [])

        return Outcome(resolution: resolution, trace: Trace(steps: steps), converged: false)
    }

    private func reason(for resolution: NutritionResolver.Resolution) -> RejectionReason {
        if !resolution.provenance.issues.isEmpty
            && resolution.provenance.source != .languageModel {
            return .failedValidation(issues: resolution.provenance.issues)
        }
        if resolution.provenance.source == .languageModel || resolution.provenance.confidence == 0 {
            return .noResults
        }
        return .lowConfidence(resolution.provenance.confidence)
    }

    /// Resolves every item in a meal, each with its own loop, concurrently.
    public func resolve(entries: [FoodEntry]) async -> [(FoodEntry, Outcome)] {
        await withTaskGroup(of: (Int, FoodEntry, Outcome).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let outcome = await resolve(name: entry.name,
                                                estimate: entry.nutrition,
                                                estimateSource: entry.source == .naturalLanguage
                                                    ? .languageModel : .builtIn,
                                                servings: entry.servings)
                    return (index, entry, outcome)
                }
            }
            var results: [(Int, FoodEntry, Outcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }
}
