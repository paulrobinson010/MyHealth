import Foundation

/// Where a set of nutrition numbers came from. Every figure in the app carries
/// this, because "1,470 kcal" means something very different when it came off a
/// manufacturer's label than when a language model guessed it.
public enum NutritionSource: String, Codable, CaseIterable, Sendable {
    /// The app's own built-in table.
    case builtIn
    /// Open Food Facts — crowd-sourced packaged-product data.
    case openFoodFacts
    /// USDA FoodData Central — curated generic foods.
    case foodDataCentral
    /// Computed from volume and ABV. Exact, for drinks.
    case computed
    /// The on-device language model's estimate.
    case languageModel
    /// Typed in by hand.
    case manual

    public var title: String {
        switch self {
        case .builtIn: return "Built-in table"
        case .openFoodFacts: return "Open Food Facts"
        case .foodDataCentral: return "USDA FoodData Central"
        case .computed: return "Calculated"
        case .languageModel: return "Estimated"
        case .manual: return "Entered by hand"
        }
    }

    public var shortTitle: String {
        switch self {
        case .builtIn: return "Built-in"
        case .openFoodFacts: return "OFF"
        case .foodDataCentral: return "USDA"
        case .computed: return "Calculated"
        case .languageModel: return "Estimate"
        case .manual: return "Manual"
        }
    }

    /// How much to trust this source before any validation runs. Used to break
    /// ties when several sources return a candidate.
    public var baseConfidence: Double {
        switch self {
        case .computed: return 0.95      // arithmetic on volume and ABV
        case .foodDataCentral: return 0.90
        case .manual: return 0.85        // they know what they ate
        case .builtIn: return 0.75
        case .openFoodFacts: return 0.70 // crowd-sourced, quality varies wildly
        case .languageModel: return 0.35
        }
    }

    public var isNetworkSource: Bool {
        self == .openFoodFacts || self == .foodDataCentral
    }
}

/// Nutrition for a named food, with the provenance attached.
public struct NutritionFacts: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(source.rawValue)-\(identifier ?? name)" }

    public let name: String
    public let brand: String?
    /// The source's own identifier — a barcode, an FDC id — so a lookup can be
    /// repeated or corrected later.
    public let identifier: String?
    public let source: NutritionSource

    /// Nutrition for one serving as described by `servingDescription`.
    public let perServing: Nutrition
    /// Grams in one serving, when the source states it.
    public let servingGrams: Double?
    public let servingDescription: String?

    public init(name: String,
                brand: String? = nil,
                identifier: String? = nil,
                source: NutritionSource,
                perServing: Nutrition,
                servingGrams: Double? = nil,
                servingDescription: String? = nil) {
        self.name = name
        self.brand = brand
        self.identifier = identifier
        self.source = source
        self.perServing = perServing
        self.servingGrams = servingGrams
        self.servingDescription = servingDescription
    }

    public var displayName: String {
        guard let brand, !brand.isEmpty else { return name }
        return "\(brand) \(name)"
    }

    /// Energy per 100 g, the figure plausibility checks work in.
    public var kilocaloriesPer100g: Double? {
        guard let servingGrams, servingGrams > 0 else { return nil }
        return perServing.kilocalories / servingGrams * 100
    }
}

/// What a lookup ended up believing, and why.
public struct NutritionProvenance: Codable, Hashable, Sendable {
    public let source: NutritionSource
    public let identifier: String?
    public let matchedName: String?
    /// 0...1, after validation has had its say.
    public let confidence: Double
    /// Problems found during validation, kept so the UI can show them rather
    /// than silently presenting a suspect number as fact.
    public let issues: [String]
    /// Set when a second source was consulted and disagreed.
    public let disagreementPercent: Double?

    public init(source: NutritionSource,
                identifier: String? = nil,
                matchedName: String? = nil,
                confidence: Double,
                issues: [String] = [],
                disagreementPercent: Double? = nil) {
        self.source = source
        self.identifier = identifier
        self.matchedName = matchedName
        self.confidence = confidence
        self.issues = issues
        self.disagreementPercent = disagreementPercent
    }

    public var isTrustworthy: Bool { confidence >= 0.6 && issues.isEmpty }

    public var needsReview: Bool { confidence < 0.45 || !issues.isEmpty }
}
