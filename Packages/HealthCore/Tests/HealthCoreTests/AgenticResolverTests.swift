import XCTest
@testable import HealthCore

final class HeuristicRefinerTests: XCTestCase {

    private func context(_ item: String, tried: [String] = [], attempt: Int = 0,
                         reason: RejectionReason = .noResults) -> RefinementContext {
        RefinementContext(originalItem: item,
                          attemptedQueries: tried.isEmpty ? [item] : tried,
                          rejectedMatches: [],
                          reason: reason,
                          attempt: attempt)
    }

    func testAVenueIsStrippedOffFirst() async {
        let next = await HeuristicRefiner().refine(
            context("chicken tikka masala from the Bengal Spice"))
        XCTAssertEqual(next, "chicken tikka masala")
    }

    func testPortionWordsAreDropped() async {
        let next = await HeuristicRefiner().refine(
            context("large homemade chicken curry", attempt: 1))
        XCTAssertEqual(next, "chicken curry")
    }

    func testItFallsBackToTheHeadNoun() async {
        let next = await HeuristicRefiner().refine(
            context("spicy grilled chicken thighs",
                    tried: ["spicy grilled chicken thighs", "spicy grilled chicken thighs"],
                    attempt: 2))
        XCTAssertEqual(next, "chicken thighs")
    }

    func testItGivesUpRatherThanLoopingForever() async {
        let next = await HeuristicRefiner().refine(context("bread", tried: ["bread"], attempt: 3))
        XCTAssertNil(next)
    }
}

final class AgenticResolverTests: XCTestCase {

    /// Returns results only for queries a test has scripted, so a loop can be
    /// made to succeed on exactly the nth attempt.
    struct ScriptedProvider: NutritionProvider {
        let source: NutritionSource
        let requiresNetwork = false
        let script: [String: [NutritionFacts]]

        func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
            script[query.lowercased()] ?? []
        }
    }

    /// Hands back a fixed sequence of queries, and records what it was asked.
    final class ScriptedRefiner: QueryRefiner, @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String]
        private(set) var reasons: [RejectionReason] = []

        init(_ queries: [String]) { self.queries = queries }

        func refine(_ context: RefinementContext) async -> String? {
            lock.withLock { () -> String? in
                reasons.append(context.reason)
                return queries.isEmpty ? nil : queries.removeFirst()
            }
        }
    }

    private func facts(_ name: String, kcal: Double, protein: Double,
                       carbs: Double, fat: Double) -> NutritionFacts {
        NutritionFacts(name: name, source: .foodDataCentral,
                       perServing: Nutrition(kilocalories: kcal, proteinGrams: protein,
                                             carbohydrateGrams: carbs, fatGrams: fat))
    }

    func testAGoodFirstHitStopsImmediately() async {
        let provider = ScriptedProvider(source: .foodDataCentral, script: [
            "porridge oats": [facts("Porridge oats", kcal: 300, protein: 12, carbs: 45, fat: 7)]
        ])
        let refiner = ScriptedRefiner(["should not be used"])
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: [provider]), refiner: refiner)

        let outcome = await resolver.resolve(name: "porridge oats")
        XCTAssertTrue(outcome.converged)
        XCTAssertEqual(outcome.trace.attempts, 1)
        XCTAssertTrue(refiner.reasons.isEmpty, "no need to refine a query that worked")
    }

    /// The whole point of the loop: the first query finds nothing, and a
    /// reformulation rescues it.
    func testItRetriesWithARefinedQueryAndSucceeds() async {
        let provider = ScriptedProvider(source: .foodDataCentral, script: [
            "chicken tikka masala": [facts("Chicken tikka masala",
                                           kcal: 900, protein: 45, carbs: 90, fat: 40)]
        ])
        let refiner = ScriptedRefiner(["chicken tikka masala"])
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: [provider]), refiner: refiner)

        let outcome = await resolver.resolve(name: "chicken tikka masala at the Bengal Spice")

        XCTAssertTrue(outcome.converged)
        XCTAssertEqual(outcome.trace.attempts, 2)
        XCTAssertEqual(outcome.resolution.nutrition.kilocalories, 900)
        XCTAssertEqual(outcome.trace.steps.first?.outcome.hasPrefix("rejected"), true)
        XCTAssertEqual(outcome.trace.steps.last?.outcome, "accepted")
    }

    func testTheRefinerIsToldWhyTheLastAttemptFailed() async {
        let refiner = ScriptedRefiner(["something else"])
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: []), refiner: refiner)
        _ = await resolver.resolve(name: "obscure thing")
        XCTAssertEqual(refiner.reasons.first, .noResults)
    }

    func testItStopsAfterTheAttemptLimit() async {
        let refiner = ScriptedRefiner(["one", "two", "three", "four", "five", "six"])
        var configuration = AgenticNutritionResolver.Configuration()
        configuration.maximumAttempts = 3
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: []), refiner: refiner,
            configuration: configuration)

        let outcome = await resolver.resolve(name: "nothing here")
        XCTAssertFalse(outcome.converged)
        XCTAssertEqual(outcome.trace.attempts, 3, "the loop must be bounded")
    }

    func testItNeverSearchesTheSameThingTwice() async {
        // A refiner that keeps proposing the original query must not cause an
        // infinite loop.
        let refiner = ScriptedRefiner(["stuck", "stuck", "stuck"])
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: []), refiner: refiner)
        let outcome = await resolver.resolve(name: "stuck")
        XCTAssertEqual(outcome.trace.attempts, 1)
    }

    func testRunningOutOfAttemptsStillReturnsTheBestFound() async {
        // A mediocre hit on the first go, nothing after — the mediocre one
        // should survive rather than being replaced by the last empty attempt.
        let provider = ScriptedProvider(source: .openFoodFacts, script: [
            "flapjack": [NutritionFacts(name: "Flapjack", source: .openFoodFacts,
                                        perServing: Nutrition(kilocalories: 380, proteinGrams: 5,
                                                              carbohydrateGrams: 50, fatGrams: 17))]
        ])
        let refiner = ScriptedRefiner(["oat bar", "cereal bar"])
        var configuration = AgenticNutritionResolver.Configuration()
        configuration.targetConfidence = 0.99   // deliberately unreachable
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: [provider]), refiner: refiner,
            configuration: configuration)

        let outcome = await resolver.resolve(name: "flapjack")
        XCTAssertFalse(outcome.converged)
        XCTAssertEqual(outcome.resolution.nutrition.kilocalories, 380,
                       "the best candidate seen must survive an unconverged loop")
    }

    /// A fluent wrong answer must not be able to end the loop — the stopping
    /// condition is deterministic, not the model's own say-so.
    func testAnEstimateNeverCountsAsConvergence() async {
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: []), refiner: ScriptedRefiner([]))
        let outcome = await resolver.resolve(
            name: "mystery pie",
            estimate: Nutrition(kilocalories: 600, proteinGrams: 20,
                                carbohydrateGrams: 60, fatGrams: 30))

        XCTAssertFalse(outcome.converged,
                       "a language-model estimate is a hypothesis, not a result")
        XCTAssertEqual(outcome.resolution.nutrition.kilocalories, 600,
                       "but it is still the best answer available")
    }

    func testAValidationFailureIsReportedToTheRefiner() async {
        let broken = NutritionFacts(name: "Soup", source: .openFoodFacts,
                                    perServing: Nutrition(kilocalories: 2_000, proteinGrams: 2,
                                                          carbohydrateGrams: 8, fatGrams: 1))
        let provider = ScriptedProvider(source: .openFoodFacts, script: ["soup": [broken]])
        let refiner = ScriptedRefiner(["vegetable soup"])
        let resolver = AgenticNutritionResolver(
            resolver: NutritionResolver(providers: [provider]), refiner: refiner)

        _ = await resolver.resolve(name: "soup")
        XCTAssertFalse(refiner.reasons.isEmpty)
    }
}

final class ResolutionQueueTests: XCTestCase {

    struct AlwaysFinds: NutritionProvider {
        let source = NutritionSource.foodDataCentral
        let requiresNetwork = false
        func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
            [NutritionFacts(name: query, source: .foodDataCentral,
                            perServing: Nutrition(kilocalories: 900, proteinGrams: 45,
                                                  carbohydrateGrams: 90, fatGrams: 40))]
        }
    }

    struct FindsNothing: NutritionProvider {
        let source = NutritionSource.foodDataCentral
        let requiresNetwork = false
        func search(_ query: String, limit: Int) async throws -> [NutritionFacts] { [] }
    }

    private func queue(_ providers: [NutritionProvider]) -> ResolutionQueue {
        ResolutionQueue(resolver: AgenticNutritionResolver(
            resolver: NutritionResolver(providers: providers),
            refiner: HeuristicRefiner()))
    }

    private func entry(_ name: String, kcal: Double, day: DayKey,
                       source: FoodEntry.EntrySource = .naturalLanguage,
                       resolution: ResolutionState? = .pending) -> FoodEntry {
        FoodEntry(name: name,
                  timestamp: day.localDate().timeIntervalSince1970 + 12 * 3600,
                  nutrition: Nutrition(kilocalories: kcal, proteinGrams: 30,
                                       carbohydrateGrams: 60, fatGrams: 25),
                  source: source,
                  resolution: resolution)
    }

    func testOnlyPendingEntriesAreQueued() {
        let today = DayKey.today
        var log = FoodLog()
        log.add(entry("chicken curry", kcal: 700, day: today))
        log.add(entry("pint of lager", kcal: 180, day: today, source: .catalogue,
                      resolution: .resolved(NutritionProvenance(source: .computed, confidence: 0.95))))
        log.add(entry("quick entry", kcal: 400, day: today, source: .manual,
                      resolution: .resolved(NutritionProvenance(source: .manual, confidence: 0.85))))

        let pending = queue([FindsNothing()]).pending(in: log, asOf: today)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.name, "chicken curry")
    }

    func testOldEntriesAreLeftAlone() {
        let today = DayKey.today
        var log = FoodLog()
        log.add(entry("ancient lunch", kcal: 500, day: today.adding(days: -200)))
        XCTAssertTrue(queue([AlwaysFinds()]).pending(in: log, asOf: today).isEmpty)
    }

    func testASuccessfulLookupReplacesTheFiguresAndRecordsProvenance() async throws {
        let today = DayKey.today
        var log = FoodLog()
        log.add(entry("chicken tikka masala", kcal: 650, day: today))

        let (updated, report) = await queue([AlwaysFinds()]).process(log, asOf: today)
        XCTAssertEqual(report.improved, 1)

        let resolved = try XCTUnwrap(updated.entries.first)
        XCTAssertEqual(resolved.total.kilocalories, 900)
        XCTAssertEqual(resolved.provenance?.source, .foodDataCentral)
        XCTAssertEqual(report.calorieDelta, 250, accuracy: 1)
        XCTAssertEqual(resolved.name, "chicken tikka masala",
                       "the person's own words must survive the lookup")
    }

    func testAFailedLookupIsMarkedSoItIsNotRetriedForever() async throws {
        let today = DayKey.today
        var log = FoodLog()
        log.add(entry("something nobody has heard of", kcal: 500, day: today))

        let (updated, report) = await queue([FindsNothing()]).process(log, asOf: today)
        XCTAssertEqual(report.givenUp, 1)

        let entry = try XCTUnwrap(updated.entries.first)
        XCTAssertFalse(entry.needsResolution, "a hopeless entry must leave the queue")
        XCTAssertEqual(entry.total.kilocalories, 500, "the estimate stands")
    }

    /// Two devices may run the queue at once; doing so must not corrupt anything.
    func testProcessingTwiceIsIdempotent() async throws {
        let today = DayKey.today
        var log = FoodLog()
        log.add(entry("chicken tikka masala", kcal: 650, day: today))

        let working = queue([AlwaysFinds()])
        let (once, _) = await working.process(log, asOf: today)
        let (twice, secondReport) = await working.process(once, asOf: today)

        XCTAssertEqual(secondReport.considered, 0, "nothing should be left to do")
        XCTAssertEqual(twice.entries.count, 1)
        XCTAssertEqual(try XCTUnwrap(twice.entries.first).total.kilocalories, 900)
    }

    func testAnEmptyQueueDoesNothing() async {
        let (updated, report) = await queue([AlwaysFinds()]).process(FoodLog())
        XCTAssertTrue(updated.isEmpty)
        XCTAssertFalse(report.didAnything)
    }

    func testEntriesLoggedWhileTheQueueRanAreNotLost() async throws {
        // The realistic race: the phone starts a lookup, the Watch logs a pint,
        // and the two logs are merged when the lookup finishes.
        let today = DayKey.today
        var before = FoodLog()
        before.add(entry("chicken tikka masala", kcal: 650, day: today))

        let (resolved, _) = await queue([AlwaysFinds()]).process(before, asOf: today)

        var arrivedMeanwhile = before
        arrivedMeanwhile.add(entry("pint of lager", kcal: 180, day: today, source: .catalogue,
                                   resolution: .resolved(NutritionProvenance(source: .computed,
                                                                             confidence: 0.95))))

        let merged = LogSync.merge(local: arrivedMeanwhile, remote: resolved)
        XCTAssertEqual(merged.entries.count, 2, "the pint must survive the lookup")

        // And the corrected figure must win over the stale local copy, which a
        // naive local-wins merge would have discarded.
        let curry = try XCTUnwrap(merged.entries.first { $0.name == "chicken tikka masala" })
        XCTAssertEqual(curry.total.kilocalories, 900)
        XCTAssertEqual(curry.provenance?.source, .foodDataCentral)
    }
}
