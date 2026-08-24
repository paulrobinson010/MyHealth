import Foundation

/// Somewhere nutrition facts can be looked up.
public protocol NutritionProvider: Sendable {
    var source: NutritionSource { get }
    /// True when using this provider sends anything off the machine.
    var requiresNetwork: Bool { get }
    func search(_ query: String, limit: Int) async throws -> [NutritionFacts]
}

/// The single point where this app touches the network, kept behind a protocol
/// so every provider is testable against fixtures and never over the wire.
public protocol NutritionHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> Data
}

public struct URLSessionNutritionClient: NutritionHTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 12) {
        self.session = session
        self.timeout = timeout
    }

    public func data(for request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LookupError.badResponse(http.statusCode)
        }
        return data
    }
}

public enum LookupError: LocalizedError {
    case badResponse(Int)
    case notConfigured(String)
    case nothingFound

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "The nutrition service returned HTTP \(code)."
        case .notConfigured(let detail): return detail
        case .nothingFound: return "No matching food was found."
        }
    }
}

/// The app's own table, wrapped as a provider so it sits in the same pipeline
/// as everything else and needs no special-casing in the resolver.
public struct BuiltInCatalogueProvider: NutritionProvider {
    public let source = NutritionSource.builtIn
    public let requiresNetwork = false

    public init() {}

    public func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var results: [NutritionFacts] = []

        // Drinks first: for anything alcoholic our own arithmetic on volume and
        // ABV beats any database, because it is exact.
        for drink in DrinkPreset.standard where matches(needle, drink.name) {
            results.append(NutritionFacts(name: drink.name,
                                          source: .computed,
                                          perServing: drink.nutrition,
                                          servingGrams: drink.millilitres,
                                          servingDescription: "\(Int(drink.millilitres)) mL at \(drink.abvPercent)%"))
        }

        for food in FoodPreset.catalogue where matches(needle, food.name) {
            results.append(NutritionFacts(name: food.name,
                                          source: .builtIn,
                                          perServing: food.nutrition,
                                          servingDescription: food.servingDescription))
        }

        return Array(results.prefix(limit))
    }

    /// Loose word-overlap match — "two pints of lager" should still find
    /// "Pint of lager (4.5%)".
    private func matches(_ needle: String, _ candidate: String) -> Bool {
        let candidateLower = candidate.lowercased()
        if candidateLower.contains(needle) || needle.contains(candidateLower) { return true }

        let stopWords: Set<String> = ["of", "a", "an", "the", "with", "and", "some"]
        let needleWords = Set(needle.split(separator: " ").map(String.init))
            .subtracting(stopWords)
        let candidateWords = Set(candidateLower
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init))
            .subtracting(stopWords)

        guard !needleWords.isEmpty, !candidateWords.isEmpty else { return false }
        let overlap = needleWords.intersection(candidateWords).count
        // Two shared meaningful words, or one when the candidate is a single word.
        return overlap >= min(2, candidateWords.count)
    }
}

// MARK: - Open Food Facts

/// Crowd-sourced packaged-product data. Free, no key, strong UK grocery
/// coverage — and essentially no coverage of restaurant or pub meals, which is
/// why the resolver never relies on it alone.
public struct OpenFoodFactsProvider: NutritionProvider {
    public let source = NutritionSource.openFoodFacts
    public let requiresNetwork = true

    private let client: NutritionHTTPClient
    private let userAgent: String

    public init(client: NutritionHTTPClient, userAgent: String = "MyHealth - macOS - Version 1.0") {
        self.client = client
        self.userAgent = userAgent
    }

    public func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
        var components = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")
        components?.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(limit)),
            URLQueryItem(name: "fields",
                         value: "code,product_name,brands,serving_size,serving_quantity,nutriments")
        ]
        guard let url = components?.url else { throw LookupError.nothingFound }
        return try OpenFoodFactsProvider.decode(try await client.data(for: request(url)))
    }

    /// Barcode lookup — the case Open Food Facts is genuinely excellent at.
    public func product(barcode: String) async throws -> NutritionFacts? {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json") else {
            throw LookupError.nothingFound
        }
        let payload = try JSONDecoder().decode(SingleProductPayload.self,
                                               from: try await client.data(for: request(url)))
        guard payload.status == 1, let product = payload.product else { return nil }
        return OpenFoodFactsProvider.facts(from: product)
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Open Food Facts asks every client to identify itself, and rate-limits
        // those that do not.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: Decoding

    struct SearchPayload: Decodable { let products: [Product]? }
    struct SingleProductPayload: Decodable {
        let status: Int
        let product: Product?
    }

    struct Product: Decodable {
        let code: LenientString?
        let productName: LenientString?
        let brands: LenientString?
        let servingSize: LenientString?
        let servingQuantity: LenientDouble?
        let nutriments: [String: LenientDouble]?

        enum CodingKeys: String, CodingKey {
            case code
            case productName = "product_name"
            case brands
            case servingSize = "serving_size"
            case servingQuantity = "serving_quantity"
            case nutriments
        }
    }

    static func decode(_ data: Data) throws -> [NutritionFacts] {
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        return (payload.products ?? []).compactMap(facts(from:))
    }

    static func facts(from product: Product) -> NutritionFacts? {
        let name = product.productName?.value ?? ""
        guard !name.isEmpty, let nutriments = product.nutriments else { return nil }

        func value(_ key: String) -> Double? { nutriments[key]?.value }

        // Prefer the per-serving figures when the contributor supplied them;
        // otherwise scale the per-100 g ones by the stated serving weight.
        let servingGrams = product.servingQuantity?.value
        let hasServingValues = value("energy-kcal_serving") != nil

        let scale: Double
        let basisGrams: Double?
        if hasServingValues {
            scale = 1
            basisGrams = servingGrams
        } else if let servingGrams, servingGrams > 0 {
            scale = servingGrams / 100
            basisGrams = servingGrams
        } else {
            scale = 1
            basisGrams = 100
        }

        func nutrient(_ base: String) -> Double {
            if hasServingValues, let serving = value("\(base)_serving") { return serving }
            return (value("\(base)_100g") ?? 0) * scale
        }

        let energy = hasServingValues
            ? (value("energy-kcal_serving") ?? 0)
            : (value("energy-kcal_100g") ?? 0) * scale

        // Open Food Facts records alcohol as % by volume, not grams. Converting
        // it as if it were grams would understate a spirit threefold.
        let alcoholByVolume = value("alcohol_100g") ?? 0
        let millilitres = basisGrams ?? 100
        let alcoholGrams = alcoholByVolume > 0
            ? AlcoholUnits.grams(millilitres: millilitres, abvPercent: alcoholByVolume)
            : 0

        let nutrition = Nutrition(kilocalories: energy,
                                  proteinGrams: nutrient("proteins"),
                                  carbohydrateGrams: nutrient("carbohydrates"),
                                  fatGrams: nutrient("fat"),
                                  fibreGrams: nutrient("fiber"),
                                  sugarGrams: nutrient("sugars"),
                                  alcoholGrams: alcoholGrams)

        guard nutrition.kilocalories > 0 || nutrition.alcoholGrams > 0 else { return nil }

        return NutritionFacts(
            name: name,
            brand: product.brands?.value,
            identifier: product.code?.value,
            source: .openFoodFacts,
            perServing: nutrition,
            servingGrams: basisGrams,
            servingDescription: product.servingSize?.value
                ?? (hasServingValues ? "1 serving" : "100 g"))
    }
}

// MARK: - USDA FoodData Central

/// Curated generic foods — "chicken breast, grilled" rather than a specific
/// brand's ready meal. Needs a free API key.
public struct FoodDataCentralProvider: NutritionProvider {
    public let source = NutritionSource.foodDataCentral
    public let requiresNetwork = true

    private let client: NutritionHTTPClient
    private let apiKey: String

    public init(client: NutritionHTTPClient, apiKey: String) {
        self.client = client
        self.apiKey = apiKey
    }

    public func search(_ query: String, limit: Int) async throws -> [NutritionFacts] {
        guard !apiKey.isEmpty else {
            throw LookupError.notConfigured("No FoodData Central API key is set.")
        }
        var components = URLComponents(string: "https://api.nal.usda.gov/fdc/v1/foods/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "pageSize", value: String(limit)),
            URLQueryItem(name: "dataType", value: "Foundation,SR Legacy,Survey (FNDDS)"),
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components?.url else { throw LookupError.nothingFound }
        return try FoodDataCentralProvider.decode(try await client.data(for: URLRequest(url: url)))
    }

    struct SearchPayload: Decodable { let foods: [Food]? }

    struct Food: Decodable {
        let fdcId: Int?
        let description: String?
        let brandOwner: String?
        let foodNutrients: [FoodNutrient]?
    }

    struct FoodNutrient: Decodable {
        let nutrientNumber: String?
        let nutrientName: String?
        let value: LenientDouble?
        let unitName: String?
    }

    /// FoodData Central identifies nutrients by number, which is stable where
    /// the names are not.
    enum NutrientNumber {
        static let energyKcal = "208"
        static let protein = "203"
        static let fat = "204"
        static let carbohydrate = "205"
        static let fibre = "291"
        static let sugars = "269"
        static let alcohol = "221"
    }

    static func decode(_ data: Data) throws -> [NutritionFacts] {
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)
        return (payload.foods ?? []).compactMap(facts(from:))
    }

    static func facts(from food: Food) -> NutritionFacts? {
        guard let description = food.description, !description.isEmpty,
              let nutrients = food.foodNutrients else { return nil }

        var byNumber: [String: Double] = [:]
        for nutrient in nutrients {
            guard let number = nutrient.nutrientNumber, let value = nutrient.value?.value else { continue }
            byNumber[number] = value
        }

        // Every FoodData Central figure is per 100 g.
        let nutrition = Nutrition(kilocalories: byNumber[NutrientNumber.energyKcal] ?? 0,
                                  proteinGrams: byNumber[NutrientNumber.protein] ?? 0,
                                  carbohydrateGrams: byNumber[NutrientNumber.carbohydrate] ?? 0,
                                  fatGrams: byNumber[NutrientNumber.fat] ?? 0,
                                  fibreGrams: byNumber[NutrientNumber.fibre] ?? 0,
                                  sugarGrams: byNumber[NutrientNumber.sugars] ?? 0,
                                  alcoholGrams: byNumber[NutrientNumber.alcohol] ?? 0)

        guard nutrition.kilocalories > 0 else { return nil }

        return NutritionFacts(name: description,
                              brand: food.brandOwner,
                              identifier: food.fdcId.map(String.init),
                              source: .foodDataCentral,
                              perServing: nutrition,
                              servingGrams: 100,
                              servingDescription: "100 g")
    }
}

// MARK: - Lenient JSON scalars

/// Open Food Facts is contributed by hand, so the same field arrives as a
/// number in one record and a string in the next. Decoding strictly would throw
/// away most of the database.
struct LenientDouble: Decodable, Hashable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            let cleaned = text
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.-").inverted)
            value = Double(cleaned) ?? 0
        } else if let flag = try? container.decode(Bool.self) {
            value = flag ? 1 : 0
        } else {
            value = 0
        }
    }
}

struct LenientString: Decodable, Hashable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Double.self) {
            value = number == number.rounded() ? String(Int(number)) : String(number)
        } else {
            value = ""
        }
    }
}
