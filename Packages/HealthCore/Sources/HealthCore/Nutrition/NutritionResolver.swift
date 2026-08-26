import Foundation

/// Turns a named food into the best nutrition figures available, and says how
/// much to trust them.
///
/// The order of operations matters. A language model's estimate is treated as a
/// *hypothesis*, not an answer: it is checked against real sources where they
/// exist, reconciled against physics either way, and the confidence that comes
/// out reflects what actually happened rather than how fluent the guess was.
public struct NutritionResolver: Sendable {

    public struct Resolution: Sendable {
        public let name: String
        public let nutrition: Nutrition
        public let provenance: NutritionProvenance
        /// Other candidates, so the UI can offer "did you mean".
        public let alternatives: [NutritionFacts]

        public var needsReview: Bool { provenance.needsReview }
    }

    private let providers: [NutritionProvider]
    private let candidatesPerProvider: Int

    public init(providers: [NutritionProvider], candidatesPerProvider: Int = 5) {
        self.providers = providers
        self.candidatesPerProvider = candidatesPerProvider
    }

    /// Providers that never touch the network — the default, and everything the
    /// app needs to work.
    public static var offline: NutritionResolver {
        NutritionResolver(providers: [BuiltInCatalogueProvider()])
    }

    public func resolve(name: String,
                        estimate: Nutrition? = nil,
                        estimateSource: NutritionSource = .languageModel,
                        servings: Double = 1) async -> Resolution {
        let candidates = await gather(for: name)

        struct Scored {
            let facts: NutritionFacts
            let validation: ValidationResult
            let score: Double
        }

        var scored: [Scored] = []
        for facts in candidates {
            let validation = NutritionValidator.validate(facts.perServing,
                                                         servingGrams: facts.servingGrams,
                                                         servings: servings)
            guard validation.isUsable else { continue }
            let relevance = NutritionResolver.nameSimilarity(name, facts.displayName)
            // A perfect database entry for the wrong food is worse than a rough
            // estimate for the right one, so relevance gates everything.
            guard relevance >= 0.34 else { continue }
            scored.append(Scored(facts: facts,
                                 validation: validation,
                                 score: facts.source.baseConfidence
                                     * validation.confidenceMultiplier
                                     * relevance))
        }
        scored.sort { $0.score > $1.score }

        guard let best = scored.first else {
            return fallback(name: name, estimate: estimate, source: estimateSource, servings: servings)
        }

        var nutrition = best.validation.corrected ?? best.facts.perServing
        var confidence = best.score
        var issues = best.validation.messages
        var disagreement: Double?

        // An independent estimate that lands close by is real corroboration;
        // one that does not is worth surfacing rather than burying.
        if let estimate, estimate.kilocalories > 0,
           let gap = NutritionValidator.compare(nutrition, estimate) {
            disagreement = gap
            if gap <= 0.15 {
                confidence = min(1, confidence * 1.15)
            } else if gap > NutritionValidator.significantDisagreement {
                // Recorded, and it costs a little confidence, but deliberately
                // not an "issue": issues mean the figure itself is doubtful,
                // and a looked-up value disagreeing with a guess is the guess
                // being wrong. Filing it as an issue stopped the loop
                // converging on exactly the lookups worth having.
                confidence *= 0.9
            }
        }

        // Two independent sources agreeing is the strongest signal available
        // short of weighing the food yourself.
        if let second = scored.dropFirst().first(where: { $0.facts.source != best.facts.source }),
           let gap = NutritionValidator.compare(nutrition, second.facts.perServing) {
            if gap <= 0.15 {
                confidence = min(1, confidence * 1.2)
            } else if gap > NutritionValidator.significantDisagreement {
                issues.append(String(format: "%@ and %@ disagree by %.0f%%.",
                                     best.facts.source.shortTitle,
                                     second.facts.source.shortTitle,
                                     gap * 100))
                confidence *= 0.85
            }
        }

        if best.validation.corrected != nil {
            issues.append("Energy was recalculated from the macros.")
            nutrition = best.validation.corrected ?? nutrition
        }

        return Resolution(
            name: best.facts.displayName,
            nutrition: nutrition,
            provenance: NutritionProvenance(source: best.facts.source,
                                            identifier: best.facts.identifier,
                                            matchedName: best.facts.displayName,
                                            confidence: confidence.clamped(to: 0...1),
                                            issues: issues,
                                            disagreementPercent: disagreement),
            alternatives: Array(scored.dropFirst().prefix(4).map(\.facts)))
    }

    /// Resolves a whole meal at once, running the lookups concurrently.
    public func resolve(entries: [FoodEntry]) async -> [(FoodEntry, Resolution)] {
        await withTaskGroup(of: (Int, FoodEntry, Resolution).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let resolution = await resolve(name: entry.name,
                                                   estimate: entry.nutrition,
                                                   estimateSource: entry.source == .naturalLanguage
                                                       ? .languageModel : .builtIn,
                                                   servings: entry.servings)
                    return (index, entry, resolution)
                }
            }
            var results: [(Int, FoodEntry, Resolution)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
        }
    }

    // MARK: - Gathering

    private func gather(for name: String) async -> [NutritionFacts] {
        await withTaskGroup(of: [NutritionFacts].self) { group in
            for provider in providers {
                group.addTask {
                    // A provider being down must never fail the log — the
                    // estimate still stands, just with lower confidence.
                    (try? await provider.search(name, limit: candidatesPerProvider)) ?? []
                }
            }
            var all: [NutritionFacts] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }

    private func fallback(name: String,
                          estimate: Nutrition?,
                          source: NutritionSource,
                          servings: Double) -> Resolution {
        guard let estimate else {
            return Resolution(name: name,
                              nutrition: .empty,
                              provenance: NutritionProvenance(source: .manual,
                                                              confidence: 0,
                                                              issues: ["Nothing found for this item."]),
                              alternatives: [])
        }
        let validation = NutritionValidator.validate(estimate, servings: servings)
        var issues = validation.messages
        issues.append("No database entry matched, so this is an estimate.")
        return Resolution(name: name,
                          nutrition: validation.corrected ?? estimate,
                          provenance: NutritionProvenance(
                            source: source,
                            matchedName: nil,
                            confidence: (source.baseConfidence * validation.confidenceMultiplier)
                                .clamped(to: 0...1),
                            issues: issues),
                          alternatives: [])
    }

    // MARK: - Matching

    /// Word overlap between what was said and what a database returned, 0...1.
    ///
    /// Free-text search engines return confident nonsense — searching a grocery
    /// database for "chicken tikka masala" will happily offer "tikka spice
    /// paste" — so relevance is scored here rather than trusting result order.
    static func nameSimilarity(_ query: String, _ candidate: String) -> Double {
        let stopWords: Set<String> = ["of", "a", "an", "the", "with", "and", "some",
                                      "my", "your", "one", "two", "three", "large",
                                      "small", "medium", "fresh"]

        func tokens(_ text: String) -> Set<String> {
            Set(text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 })
                .subtracting(stopWords)
        }

        let queryTokens = tokens(query)
        let candidateTokens = tokens(candidate)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let shared = queryTokens.intersection(candidateTokens).count
        guard shared > 0 else { return 0 }

        // Measured against the query, so a verbose product name is not punished
        // for carrying extra words the person did not say.
        let coverage = Double(shared) / Double(queryTokens.count)
        // ...but a candidate that is mostly unrelated words still loses ground.
        let precision = Double(shared) / Double(candidateTokens.count)
        return coverage * 0.75 + precision * 0.25
    }
}
