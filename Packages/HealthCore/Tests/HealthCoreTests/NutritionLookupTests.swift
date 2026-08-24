import XCTest
@testable import HealthCore

/// Serves canned JSON so provider decoding is tested without a network.
final class StubHTTPClient: NutritionHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []
    var error: Error?

    init(responses: [Data]) { self.responses = responses }
    convenience init(json: String) { self.init(responses: [Data(json.utf8)]) }

    func data(for request: URLRequest) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if let error { throw error }
        return responses.isEmpty ? Data("{}".utf8) : responses.removeFirst()
    }
}

final class OpenFoodFactsProviderTests: XCTestCase {

    func testDecodesAProductWithPerServingValues() async throws {
        let json = """
        { "products": [ {
            "code": "5000112637922",
            "product_name": "Chicken Tikka Masala",
            "brands": "Tesco",
            "serving_size": "400 g",
            "serving_quantity": 400,
            "nutriments": {
              "energy-kcal_100g": 145, "energy-kcal_serving": 580,
              "proteins_100g": 8, "proteins_serving": 32,
              "carbohydrates_100g": 12, "carbohydrates_serving": 48,
              "fat_100g": 7, "fat_serving": 28,
              "fiber_100g": 1.5, "fiber_serving": 6,
              "sugars_100g": 3, "sugars_serving": 12
            } } ] }
        """
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: json))
        let results = try await provider.search("chicken tikka masala", limit: 5)

        let facts = try XCTUnwrap(results.first)
        XCTAssertEqual(facts.displayName, "Tesco Chicken Tikka Masala")
        XCTAssertEqual(facts.identifier, "5000112637922")
        XCTAssertEqual(facts.perServing.kilocalories, 580)
        XCTAssertEqual(facts.perServing.proteinGrams, 32)
        XCTAssertEqual(facts.servingGrams, 400)
    }

    func testScalesPer100gValuesWhenNoServingFiguresExist() async throws {
        let json = """
        { "products": [ {
            "code": "1", "product_name": "Porridge oats", "serving_quantity": 50,
            "nutriments": { "energy-kcal_100g": 380, "proteins_100g": 12,
                            "carbohydrates_100g": 60, "fat_100g": 8 } } ] }
        """
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: json))
        let facts = try XCTUnwrap(try await provider.search("porridge", limit: 5).first)
        // Half a 100 g basis.
        XCTAssertEqual(facts.perServing.kilocalories, 190, accuracy: 0.01)
        XCTAssertEqual(facts.perServing.proteinGrams, 6, accuracy: 0.01)
    }

    /// Open Food Facts records alcohol as % by volume, not grams. Reading it as
    /// grams would put a spirit out by a factor of three.
    func testAlcoholIsConvertedFromPercentByVolume() async throws {
        let json = """
        { "products": [ {
            "code": "2", "product_name": "Lager", "serving_quantity": 568,
            "nutriments": { "energy-kcal_100g": 43, "alcohol_100g": 4.5,
                            "carbohydrates_100g": 3 } } ] }
        """
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: json))
        let facts = try XCTUnwrap(try await provider.search("lager", limit: 5).first)
        // 568 mL at 4.5% = 20.2 g of ethanol, not 4.5 g.
        XCTAssertEqual(facts.perServing.alcoholGrams, 20.2, accuracy: 0.3)
    }

    /// The database is filled in by hand, so the same field arrives as a number
    /// in one record and a string in the next.
    func testNumbersArrivingAsStringsAreStillRead() async throws {
        let json = """
        { "products": [ {
            "code": 12345, "product_name": "Yoghurt", "serving_quantity": "125",
            "nutriments": { "energy-kcal_100g": "97", "proteins_100g": "5,5",
                            "carbohydrates_100g": 12, "fat_100g": "3" } } ] }
        """
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: json))
        let facts = try XCTUnwrap(try await provider.search("yoghurt", limit: 5).first)
        XCTAssertEqual(facts.identifier, "12345", "a numeric barcode must still read as text")
        XCTAssertEqual(facts.perServing.kilocalories, 121.25, accuracy: 0.5)
        // European decimal comma.
        XCTAssertEqual(facts.perServing.proteinGrams, 6.875, accuracy: 0.05)
    }

    func testProductsWithoutUsableEnergyAreDropped() async throws {
        let json = """
        { "products": [
            { "code": "1", "product_name": "Mystery item", "nutriments": {} },
            { "code": "2", "product_name": "", "nutriments": { "energy-kcal_100g": 200 } }
        ] }
        """
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: json))
        let results = try await provider.search("mystery", limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testIdentifiesItselfAsOpenFoodFactsAsks() async throws {
        let client = StubHTTPClient(json: #"{"products":[]}"#)
        _ = try await OpenFoodFactsProvider(client: client).search("bread", limit: 3)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("search_terms=bread"), url)
    }

    func testEmptyPayloadIsNotAnError() async throws {
        let provider = OpenFoodFactsProvider(client: StubHTTPClient(json: "{}"))
        let results = try await provider.search("nothing", limit: 5)
        XCTAssertTrue(results.isEmpty)
    }
}

final class FoodDataCentralProviderTests: XCTestCase {

    func testDecodesNutrientsByNumber() async throws {
        let json = """
        { "foods": [ {
            "fdcId": 171077,
            "description": "Chicken, breast, grilled",
            "foodNutrients": [
              { "nutrientNumber": "208", "nutrientName": "Energy", "value": 165, "unitName": "KCAL" },
              { "nutrientNumber": "203", "nutrientName": "Protein", "value": 31, "unitName": "G" },
              { "nutrientNumber": "204", "nutrientName": "Total lipid (fat)", "value": 3.6, "unitName": "G" },
              { "nutrientNumber": "205", "nutrientName": "Carbohydrate, by difference", "value": 0, "unitName": "G" }
            ] } ] }
        """
        let provider = FoodDataCentralProvider(client: StubHTTPClient(json: json), apiKey: "test")
        let facts = try XCTUnwrap(try await provider.search("chicken breast", limit: 5).first)

        XCTAssertEqual(facts.name, "Chicken, breast, grilled")
        XCTAssertEqual(facts.identifier, "171077")
        XCTAssertEqual(facts.perServing.kilocalories, 165)
        XCTAssertEqual(facts.perServing.proteinGrams, 31)
        XCTAssertEqual(facts.servingGrams, 100, "FoodData Central figures are per 100 g")
    }

    func testRefusesToCallWithoutAKeyRatherThanFailingOpaquely() async {
        let provider = FoodDataCentralProvider(client: StubHTTPClient(json: "{}"), apiKey: "")
        do {
            _ = try await provider.search("anything", limit: 5)
            XCTFail("expected a configuration error")
        } catch let error as LookupError {
            guard case .notConfigured = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}

final class BuiltInCatalogueProviderTests: XCTestCase {

    func testFindsADrinkAndMarksItAsCalculated() async throws {
        let results = try await BuiltInCatalogueProvider().search("pint of lager", limit: 5)
        let facts = try XCTUnwrap(results.first)
        XCTAssertEqual(facts.source, .computed,
                       "alcohol from volume and ABV is arithmetic, not a lookup")
        XCTAssertGreaterThan(facts.perServing.alcoholGrams, 15)
    }

    func testFindsFoodByPartialName() async throws {
        let results = try await BuiltInCatalogueProvider().search("chicken tikka masala", limit: 5)
        XCTAssertTrue(results.contains { $0.name.contains("Chicken tikka masala") })
    }

    func testNeverTouchesTheNetwork() {
        XCTAssertFalse(BuiltInCatalogueProvider().requiresNetwork)
    }
}

final class NutritionResolverTests: XCTestCase {

    /// A provider that returns exactly what a test tells it to.
    struct FakeProvider: NutritionProvider {
        let source: NutritionSource
        let requiresNetwork = false
        var results: [NutritionFacts] = []
        var failure: Error?

        func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
            if let failure { throw failure }
            return results
        }
    }

    private func facts(_ name: String, _ source: NutritionSource,
                       kcal: Double, protein: Double = 0, carbs: Double = 0,
                       fat: Double = 0, grams: Double? = nil) -> NutritionFacts {
        NutritionFacts(name: name, source: source,
                       perServing: Nutrition(kilocalories: kcal, proteinGrams: protein,
                                             carbohydrateGrams: carbs, fatGrams: fat),
                       servingGrams: grams)
    }

    func testADatabaseMatchBeatsTheModelsEstimate() async {
        let resolver = NutritionResolver(providers: [
            FakeProvider(source: .foodDataCentral,
                         results: [facts("Chicken tikka masala", .foodDataCentral,
                                         kcal: 900, protein: 45, carbs: 90, fat: 40)])
        ])
        let resolution = await resolver.resolve(
            name: "chicken tikka masala",
            estimate: Nutrition(kilocalories: 650))

        XCTAssertEqual(resolution.provenance.source, .foodDataCentral)
        XCTAssertEqual(resolution.nutrition.kilocalories, 900)
    }

    func testAgreementBetweenTwoSourcesRaisesConfidence() async {
        let single = NutritionResolver(providers: [
            FakeProvider(source: .foodDataCentral,
                         results: [facts("Porridge oats", .foodDataCentral,
                                         kcal: 300, protein: 12, carbs: 45, fat: 7)])
        ])
        let both = NutritionResolver(providers: [
            FakeProvider(source: .foodDataCentral,
                         results: [facts("Porridge oats", .foodDataCentral,
                                         kcal: 300, protein: 12, carbs: 45, fat: 7)]),
            FakeProvider(source: .openFoodFacts,
                         results: [facts("Porridge oats", .openFoodFacts,
                                         kcal: 310, protein: 12, carbs: 46, fat: 7)])
        ])

        let alone = await single.resolve(name: "porridge oats")
        let corroborated = await both.resolve(name: "porridge oats")
        XCTAssertGreaterThan(corroborated.provenance.confidence, alone.provenance.confidence)
    }

    func testDisagreementBetweenSourcesIsSurfacedNotHidden() async {
        let resolver = NutritionResolver(providers: [
            FakeProvider(source: .foodDataCentral,
                         results: [facts("Flapjack", .foodDataCentral,
                                         kcal: 300, protein: 4, carbs: 40, fat: 14)]),
            FakeProvider(source: .openFoodFacts,
                         results: [facts("Flapjack", .openFoodFacts,
                                         kcal: 520, protein: 6, carbs: 65, fat: 25)])
        ])
        let resolution = await resolver.resolve(name: "flapjack")
        XCTAssertTrue(resolution.provenance.issues.contains { $0.contains("disagree") },
                      "issues: \(resolution.provenance.issues)")
    }

    func testAnImpossibleCandidateIsRejectedEntirely() async {
        let resolver = NutritionResolver(providers: [
            // Energy nowhere near what the macros support.
            FakeProvider(source: .openFoodFacts,
                         results: [facts("Soup", .openFoodFacts,
                                         kcal: 4_000, protein: 2, carbs: 8, fat: 1)])
        ])
        let resolution = await resolver.resolve(name: "soup",
                                                estimate: Nutrition(kilocalories: 120,
                                                                    proteinGrams: 2,
                                                                    carbohydrateGrams: 8,
                                                                    fatGrams: 6))
        XCTAssertNotEqual(resolution.provenance.source, .openFoodFacts,
                          "a physically impossible entry must not win")
        XCTAssertEqual(resolution.nutrition.kilocalories, 120)
    }

    /// Free-text search returns confident nonsense; relevance has to gate it.
    func testAnIrrelevantSearchHitIsIgnored() async {
        let resolver = NutritionResolver(providers: [
            FakeProvider(source: .openFoodFacts,
                         results: [facts("Tikka spice paste", .openFoodFacts,
                                         kcal: 120, protein: 2, carbs: 10, fat: 8, grams: 100)])
        ])
        let resolution = await resolver.resolve(
            name: "chicken tikka masala",
            estimate: Nutrition(kilocalories: 900, proteinGrams: 45,
                                carbohydrateGrams: 90, fatGrams: 40))
        XCTAssertEqual(resolution.nutrition.kilocalories, 900,
                       "the spice paste is not the curry")
    }

    func testAProviderFailingDoesNotLoseTheEntry() async {
        struct Boom: Error {}
        let resolver = NutritionResolver(providers: [
            FakeProvider(source: .openFoodFacts, results: [], failure: Boom())
        ])
        let resolution = await resolver.resolve(
            name: "chicken curry",
            estimate: Nutrition(kilocalories: 800, proteinGrams: 40,
                                carbohydrateGrams: 80, fatGrams: 36))

        XCTAssertEqual(resolution.nutrition.kilocalories, 800)
        XCTAssertEqual(resolution.provenance.source, .languageModel)
        XCTAssertTrue(resolution.provenance.issues.contains { $0.contains("estimate") })
    }

    func testNothingFoundAndNothingEstimatedIsHonestAboutIt() async {
        let resolver = NutritionResolver(providers: [])
        let resolution = await resolver.resolve(name: "something unheard of")
        XCTAssertEqual(resolution.nutrition.kilocalories, 0)
        XCTAssertEqual(resolution.provenance.confidence, 0)
        XCTAssertTrue(resolution.needsReview)
    }

    func testTheOfflineResolverNeverNeedsANetwork() async {
        let resolution = await NutritionResolver.offline.resolve(name: "pint of IPA")
        XCTAssertFalse(resolution.provenance.source.isNetworkSource)
        XCTAssertGreaterThan(resolution.nutrition.alcoholGrams, 15)
    }

    func testAWholeMealResolvesInOrder() async {
        let entries = [
            FoodEntry(name: "pint of lager", timestamp: 0,
                      nutrition: Nutrition(kilocalories: 180, alcoholGrams: 20)),
            FoodEntry(name: "chicken tikka masala", timestamp: 0,
                      nutrition: Nutrition(kilocalories: 900, proteinGrams: 45,
                                           carbohydrateGrams: 90, fatGrams: 40))
        ]
        let resolved = await NutritionResolver.offline.resolve(entries: entries)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].0.name, "pint of lager")
        XCTAssertEqual(resolved[1].0.name, "chicken tikka masala")
    }
}
