import Foundation

/// The outcome of checking a set of nutrition numbers for internal consistency.
public struct ValidationResult: Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case fine = 0
        case suspect = 1
        case impossible = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Issue: Sendable, Hashable {
        public let severity: Severity
        public let message: String
    }

    public let issues: [Issue]
    /// Multiply a source's base confidence by this to get the final figure.
    public let confidenceMultiplier: Double
    /// Set when the energy figure was demonstrably wrong and the macros were
    /// sound enough to recompute it.
    public let corrected: Nutrition?

    public var severity: Severity { issues.map(\.severity).max() ?? .fine }
    public var isUsable: Bool { severity != .impossible }
    public var messages: [String] { issues.map(\.message) }
}

/// Checks nutrition numbers against physics and against themselves.
///
/// This matters more than where the numbers came from. A language model will
/// cheerfully invent a 90 g protein sandwich; Open Food Facts contains entries
/// where somebody typed the energy in kilojoules into the kilocalorie field.
/// Neither survives an Atwater reconciliation, so both get caught here without
/// the app needing to know which failure mode it is looking at.
public enum NutritionValidator {

    /// Energy yielded per gram, in kcal.
    public enum Atwater {
        public static let protein = 4.0
        public static let carbohydrate = 4.0
        public static let fat = 9.0
        public static let alcohol = 7.0
        /// Fibre is only partially metabolised; the EU uses 2 kcal/g.
        public static let fibre = 2.0
    }

    /// Pure fat is 900 kcal per 100 g. Nothing edible beats it.
    public static let maximumEnergyDensityPer100g = 900.0
    /// A single serving beyond this is nearly always a units mistake — a
    /// per-100 g figure mistaken for a portion, or a whole multipack.
    public static let implausibleServingKilocalories = 2_500.0

    /// Energy implied by the macros, under both labelling conventions.
    ///
    /// EU labels exclude fibre from carbohydrate; US labels include it. Getting
    /// this wrong is a 10–20% error on high-fibre foods, so both readings are
    /// computed and the closer one wins.
    public static func impliedEnergy(_ nutrition: Nutrition) -> (european: Double, american: Double) {
        let base = nutrition.proteinGrams * Atwater.protein
            + nutrition.fatGrams * Atwater.fat
            + nutrition.alcoholGrams * Atwater.alcohol

        let european = base
            + nutrition.carbohydrateGrams * Atwater.carbohydrate
            + nutrition.fibreGrams * Atwater.fibre

        let availableCarbs = max(0, nutrition.carbohydrateGrams - nutrition.fibreGrams)
        let american = base
            + availableCarbs * Atwater.carbohydrate
            + nutrition.fibreGrams * Atwater.fibre

        return (european, american)
    }

    /// Smallest relative gap between the stated energy and either convention.
    public static func energyDiscrepancy(_ nutrition: Nutrition) -> Double? {
        guard nutrition.kilocalories > 0 else { return nil }
        let implied = impliedEnergy(nutrition)
        guard implied.european > 0 || implied.american > 0 else { return nil }
        let gaps = [implied.european, implied.american]
            .filter { $0 > 0 }
            .map { abs($0 - nutrition.kilocalories) / nutrition.kilocalories }
        return gaps.min()
    }

    public static func validate(_ nutrition: Nutrition,
                                servingGrams: Double? = nil,
                                servings: Double = 1) -> ValidationResult {
        var issues: [ValidationResult.Issue] = []
        var multiplier = 1.0
        var corrected: Nutrition?

        let hasMacros = nutrition.proteinGrams > 0
            || nutrition.carbohydrateGrams > 0
            || nutrition.fatGrams > 0
            || nutrition.alcoholGrams > 0

        // 1. Does the energy reconcile with the macros?
        if hasMacros, nutrition.kilocalories > 0, let gap = energyDiscrepancy(nutrition) {
            // Labels round to the nearest gram and Atwater is itself an
            // approximation, so small foods need an absolute allowance too.
            let allowance = max(0.20, 30 / nutrition.kilocalories)
            if gap > allowance {
                let implied = impliedEnergy(nutrition)
                let best = abs(implied.european - nutrition.kilocalories)
                    <= abs(implied.american - nutrition.kilocalories)
                    ? implied.european : implied.american

                if gap > 0.6 {
                    issues.append(.init(
                        severity: .impossible,
                        message: String(format: "Stated %.0f kcal but the macros add up to %.0f.",
                                        nutrition.kilocalories, best)))
                    multiplier *= 0.25
                    // The macros are usually the honest part — energy is what
                    // gets mistyped, or entered in kilojoules.
                    var fixed = nutrition
                    fixed.kilocalories = best
                    corrected = fixed
                } else {
                    issues.append(.init(
                        severity: .suspect,
                        message: String(format: "Energy is %.0f%% away from what the macros imply.",
                                        gap * 100)))
                    multiplier *= 0.7
                }
            }
        }

        // 2. Is the energy density physically possible?
        if let servingGrams, servingGrams > 0 {
            let density = nutrition.kilocalories / servingGrams * 100
            if density > maximumEnergyDensityPer100g {
                issues.append(.init(
                    severity: .impossible,
                    message: String(format: "%.0f kcal per 100 g is denser than pure fat.", density)))
                multiplier *= 0.1
            }

            let macroGrams = nutrition.proteinGrams + nutrition.carbohydrateGrams
                + nutrition.fatGrams + nutrition.alcoholGrams
            if macroGrams > servingGrams * 1.05 {
                issues.append(.init(
                    severity: .impossible,
                    message: String(format: "Macros total %.0f g in a %.0f g serving.",
                                    macroGrams, servingGrams)))
                multiplier *= 0.1
            }
        }

        // 3. Is the portion plausible?
        let total = nutrition.kilocalories * servings
        if total > implausibleServingKilocalories {
            issues.append(.init(
                severity: .suspect,
                message: String(format: "%.0f kcal is a very large single entry — check the portion.", total)))
            multiplier *= 0.6
        }

        // 4. Contradictions.
        if nutrition.kilocalories <= 0, hasMacros {
            issues.append(.init(severity: .suspect,
                                message: "No energy recorded, but the macros are not zero."))
            multiplier *= 0.5
            var fixed = nutrition
            fixed.kilocalories = impliedEnergy(nutrition).european
            corrected = fixed
        }

        if nutrition.fibreGrams > nutrition.carbohydrateGrams + 0.5,
           nutrition.carbohydrateGrams > 0 {
            issues.append(.init(severity: .suspect,
                                message: "More fibre than carbohydrate, which usually means one is mislabelled."))
            multiplier *= 0.8
        }

        if nutrition.sugarGrams > nutrition.carbohydrateGrams + 0.5 {
            issues.append(.init(severity: .suspect,
                                message: "More sugar than total carbohydrate."))
            multiplier *= 0.8
        }

        return ValidationResult(issues: issues,
                                confidenceMultiplier: multiplier.clamped(to: 0...1),
                                corrected: corrected)
    }

    /// Compares two independent readings of the same food.
    ///
    /// Agreement between sources is the strongest evidence available short of
    /// weighing it yourself, and disagreement is worth showing rather than
    /// silently preferring one.
    public static func compare(_ lhs: Nutrition, _ rhs: Nutrition) -> Double? {
        let a = lhs.kilocalories, b = rhs.kilocalories
        guard a > 0, b > 0 else { return nil }
        return abs(a - b) / ((a + b) / 2)
    }

    public static let significantDisagreement = 0.25
}
