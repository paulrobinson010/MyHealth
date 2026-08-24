import Foundation

/// A single thing eaten or drunk, as logged on the Watch.
///
/// Entries are written straight into HealthKit so they reach the Mac through
/// the normal sync path; this type is the local record that keeps the *name*
/// of what was logged, which HealthKit does not preserve in a useful form.
public struct FoodEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Epoch seconds when it was consumed.
    public var timestamp: Double
    public var servings: Double
    public var nutrition: Nutrition
    public var source: EntrySource

    public enum EntrySource: String, Codable, Sendable {
        /// Chosen from the built-in food table.
        case catalogue
        /// Typed in as free text and parsed on-device.
        case naturalLanguage
        /// Calories entered by hand.
        case manual
        case favourite
    }

    public init(id: UUID = UUID(),
                name: String,
                timestamp: Double,
                servings: Double = 1,
                nutrition: Nutrition,
                source: EntrySource = .catalogue) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.servings = servings
        self.nutrition = nutrition
        self.source = source
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
    public var day: DayKey { DayKey(date: date) }

    /// Nutrition scaled by the number of servings.
    public var total: Nutrition { nutrition.scaled(by: servings) }
}

/// Macronutrients for one serving.
public struct Nutrition: Codable, Hashable, Sendable {
    public var kilocalories: Double
    public var proteinGrams: Double
    public var carbohydrateGrams: Double
    public var fatGrams: Double
    public var fibreGrams: Double
    public var sugarGrams: Double
    /// Pure ethanol, which is what actually matters for both the calorie count
    /// and every downstream correlation.
    public var alcoholGrams: Double

    public init(kilocalories: Double = 0,
                proteinGrams: Double = 0,
                carbohydrateGrams: Double = 0,
                fatGrams: Double = 0,
                fibreGrams: Double = 0,
                sugarGrams: Double = 0,
                alcoholGrams: Double = 0) {
        self.kilocalories = kilocalories
        self.proteinGrams = proteinGrams
        self.carbohydrateGrams = carbohydrateGrams
        self.fatGrams = fatGrams
        self.fibreGrams = fibreGrams
        self.sugarGrams = sugarGrams
        self.alcoholGrams = alcoholGrams
    }

    public static let empty = Nutrition()

    public func scaled(by factor: Double) -> Nutrition {
        Nutrition(kilocalories: kilocalories * factor,
                  proteinGrams: proteinGrams * factor,
                  carbohydrateGrams: carbohydrateGrams * factor,
                  fatGrams: fatGrams * factor,
                  fibreGrams: fibreGrams * factor,
                  sugarGrams: sugarGrams * factor,
                  alcoholGrams: alcoholGrams * factor)
    }

    public static func + (lhs: Nutrition, rhs: Nutrition) -> Nutrition {
        Nutrition(kilocalories: lhs.kilocalories + rhs.kilocalories,
                  proteinGrams: lhs.proteinGrams + rhs.proteinGrams,
                  carbohydrateGrams: lhs.carbohydrateGrams + rhs.carbohydrateGrams,
                  fatGrams: lhs.fatGrams + rhs.fatGrams,
                  fibreGrams: lhs.fibreGrams + rhs.fibreGrams,
                  sugarGrams: lhs.sugarGrams + rhs.sugarGrams,
                  alcoholGrams: lhs.alcoholGrams + rhs.alcoholGrams)
    }

    /// Calories that came from alcohol alone, at 7 kcal per gram.
    public var alcoholKilocalories: Double { alcoholGrams * 7 }

    public var alcoholShareOfCalories: Double {
        kilocalories > 0 ? (alcoholKilocalories / kilocalories).clamped(to: 0...1) : 0
    }
}

/// Alcohol has three competing conventions and mixing them up throws a day's
/// numbers out by a factor of two, so everything is stored as grams of ethanol
/// and converted only for display.
public enum AlcoholUnits {
    /// A UK unit is 10 mL of ethanol, which is 7.89 g.
    public static let gramsPerUKUnit = 7.893
    /// A US standard drink is 14 g of ethanol — this is what HealthKit's
    /// `numberOfAlcoholicBeverages` counts.
    public static let gramsPerUSStandardDrink = 14.0

    public static func grams(ukUnits: Double) -> Double { ukUnits * gramsPerUKUnit }
    public static func ukUnits(grams: Double) -> Double { grams / gramsPerUKUnit }
    public static func standardDrinks(grams: Double) -> Double { grams / gramsPerUSStandardDrink }

    /// Grams of ethanol in a drink of a given volume and strength.
    /// Ethanol's density is 0.789 g/mL.
    public static func grams(millilitres: Double, abvPercent: Double) -> Double {
        millilitres * (abvPercent / 100) * 0.789
    }
}

/// A drink you can log in one tap on the Watch.
public struct DrinkPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let millilitres: Double
    public let abvPercent: Double
    /// Calories beyond the ethanol itself — residual sugars and carbohydrate.
    public let residualKilocalories: Double

    public init(name: String, millilitres: Double, abvPercent: Double, residualKilocalories: Double) {
        self.name = name
        self.millilitres = millilitres
        self.abvPercent = abvPercent
        self.residualKilocalories = residualKilocalories
    }

    public var alcoholGrams: Double {
        AlcoholUnits.grams(millilitres: millilitres, abvPercent: abvPercent)
    }

    public var ukUnits: Double { AlcoholUnits.ukUnits(grams: alcoholGrams) }

    public var nutrition: Nutrition {
        Nutrition(kilocalories: alcoholGrams * 7 + residualKilocalories,
                  carbohydrateGrams: residualKilocalories / 4,
                  sugarGrams: residualKilocalories / 4,
                  alcoholGrams: alcoholGrams)
    }

    /// The drinks worth having one tap away. Volumes are UK serves.
    public static let standard: [DrinkPreset] = [
        DrinkPreset(name: "Pint of lager (4.5%)", millilitres: 568, abvPercent: 4.5, residualKilocalories: 40),
        DrinkPreset(name: "Pint of bitter (4%)", millilitres: 568, abvPercent: 4.0, residualKilocalories: 45),
        DrinkPreset(name: "Pint of stout (4.2%)", millilitres: 568, abvPercent: 4.2, residualKilocalories: 50),
        DrinkPreset(name: "Pint of IPA (5.5%)", millilitres: 568, abvPercent: 5.5, residualKilocalories: 55),
        DrinkPreset(name: "Bottle of beer (330 mL)", millilitres: 330, abvPercent: 5.0, residualKilocalories: 25),
        DrinkPreset(name: "Large glass of wine (250 mL)", millilitres: 250, abvPercent: 13.0, residualKilocalories: 20),
        DrinkPreset(name: "Medium glass of wine (175 mL)", millilitres: 175, abvPercent: 13.0, residualKilocalories: 14),
        DrinkPreset(name: "Small glass of wine (125 mL)", millilitres: 125, abvPercent: 13.0, residualKilocalories: 10),
        DrinkPreset(name: "Glass of prosecco (125 mL)", millilitres: 125, abvPercent: 11.5, residualKilocalories: 12),
        DrinkPreset(name: "Single spirit (25 mL)", millilitres: 25, abvPercent: 40.0, residualKilocalories: 0),
        DrinkPreset(name: "Double spirit (50 mL)", millilitres: 50, abvPercent: 40.0, residualKilocalories: 0),
        DrinkPreset(name: "Gin and tonic", millilitres: 50, abvPercent: 40.0, residualKilocalories: 60),
        DrinkPreset(name: "Cider, pint (4.5%)", millilitres: 568, abvPercent: 4.5, residualKilocalories: 90)
    ]
}

/// A small built-in food table, so the Watch is useful before anything is
/// typed. Values are per the stated serving.
public struct FoodPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let servingDescription: String
    public let nutrition: Nutrition
    public let meal: Meal

    public enum Meal: String, Codable, CaseIterable, Sendable {
        case breakfast, lunch, dinner, snack, drink

        public var title: String { rawValue.capitalized }

        public var symbolName: String {
            switch self {
            case .breakfast: return "sunrise"
            case .lunch: return "sun.max"
            case .dinner: return "moon"
            case .snack: return "carrot"
            case .drink: return "cup.and.saucer"
            }
        }
    }

    public init(name: String, servingDescription: String, nutrition: Nutrition, meal: Meal) {
        self.name = name
        self.servingDescription = servingDescription
        self.nutrition = nutrition
        self.meal = meal
    }

    static func make(_ name: String, _ serving: String, _ meal: Meal,
                     kcal: Double, protein: Double, carbs: Double, fat: Double,
                     fibre: Double = 0, sugar: Double = 0) -> FoodPreset {
        FoodPreset(name: name,
                   servingDescription: serving,
                   nutrition: Nutrition(kilocalories: kcal,
                                        proteinGrams: protein,
                                        carbohydrateGrams: carbs,
                                        fatGrams: fat,
                                        fibreGrams: fibre,
                                        sugarGrams: sugar),
                   meal: meal)
    }

    public static let catalogue: [FoodPreset] = [
        // Breakfast
        .make("Porridge with milk", "1 bowl (60 g oats)", .breakfast, kcal: 300, protein: 12, carbs: 45, fat: 7, fibre: 6, sugar: 12),
        .make("Greek yoghurt with berries", "170 g pot", .breakfast, kcal: 160, protein: 15, carbs: 15, fat: 4, fibre: 2, sugar: 13),
        .make("Two scrambled eggs on toast", "2 eggs, 2 slices", .breakfast, kcal: 400, protein: 22, carbs: 32, fat: 20, fibre: 4, sugar: 3),
        .make("Full English breakfast", "1 plate", .breakfast, kcal: 850, protein: 40, carbs: 50, fat: 55, fibre: 6, sugar: 8),
        .make("Croissant", "1 medium", .breakfast, kcal: 230, protein: 5, carbs: 26, fat: 12, fibre: 1, sugar: 6),
        .make("Banana", "1 medium", .snack, kcal: 105, protein: 1, carbs: 27, fat: 0, fibre: 3, sugar: 14),
        // Mains
        .make("Chicken breast, grilled", "150 g", .dinner, kcal: 250, protein: 47, carbs: 0, fat: 6),
        .make("Salmon fillet", "150 g", .dinner, kcal: 310, protein: 34, carbs: 0, fat: 19),
        .make("Steak, sirloin", "225 g", .dinner, kcal: 500, protein: 55, carbs: 0, fat: 30),
        .make("Chicken tikka masala with rice", "1 portion", .dinner, kcal: 950, protein: 45, carbs: 95, fat: 42, fibre: 6, sugar: 14),
        .make("Spaghetti bolognese", "1 portion", .dinner, kcal: 650, protein: 33, carbs: 75, fat: 22, fibre: 7, sugar: 11),
        .make("Margherita pizza", "1 whole, 12 inch", .dinner, kcal: 900, protein: 38, carbs: 105, fat: 34, fibre: 6, sugar: 12),
        .make("Chicken salad", "1 bowl", .lunch, kcal: 380, protein: 35, carbs: 18, fat: 19, fibre: 6, sugar: 7),
        .make("Cheese sandwich", "2 slices bread", .lunch, kcal: 450, protein: 20, carbs: 42, fat: 23, fibre: 4, sugar: 4),
        .make("Ham and cheese baguette", "1 baguette", .lunch, kcal: 550, protein: 26, carbs: 60, fat: 22, fibre: 4, sugar: 5),
        .make("Jacket potato with beans", "1 large", .lunch, kcal: 480, protein: 17, carbs: 92, fat: 3, fibre: 14, sugar: 14),
        .make("Sushi, mixed", "10 pieces", .lunch, kcal: 480, protein: 24, carbs: 80, fat: 7, fibre: 3, sugar: 10),
        .make("Burger and chips", "1 serving", .dinner, kcal: 1_100, protein: 45, carbs: 95, fat: 60, fibre: 7, sugar: 12),
        .make("Fish and chips", "1 portion", .dinner, kcal: 950, protein: 40, carbs: 90, fat: 48, fibre: 8, sugar: 3),
        .make("Stir fry with noodles", "1 portion", .dinner, kcal: 600, protein: 28, carbs: 78, fat: 19, fibre: 8, sugar: 12),
        // Sides and snacks
        .make("Rice, cooked", "180 g", .snack, kcal: 235, protein: 5, carbs: 51, fat: 1, fibre: 1),
        .make("Slice of bread", "1 slice", .snack, kcal: 90, protein: 4, carbs: 17, fat: 1, fibre: 2),
        .make("Packet of crisps", "30 g", .snack, kcal: 160, protein: 2, carbs: 15, fat: 10, fibre: 1),
        .make("Chocolate bar", "45 g", .snack, kcal: 240, protein: 3, carbs: 27, fat: 13, fibre: 1, sugar: 25),
        .make("Protein shake", "1 scoop in water", .snack, kcal: 120, protein: 25, carbs: 3, fat: 1),
        .make("Handful of nuts", "30 g", .snack, kcal: 180, protein: 6, carbs: 6, fat: 16, fibre: 3),
        .make("Apple", "1 medium", .snack, kcal: 95, protein: 0, carbs: 25, fat: 0, fibre: 4, sugar: 19),
        .make("Flat white", "1 regular", .drink, kcal: 120, protein: 7, carbs: 10, fat: 6, sugar: 10),
        .make("Black coffee", "1 cup", .drink, kcal: 2, protein: 0, carbs: 0, fat: 0),
        .make("Orange juice", "250 mL", .drink, kcal: 110, protein: 2, carbs: 26, fat: 0, sugar: 21),
        .make("Cola", "330 mL can", .drink, kcal: 139, protein: 0, carbs: 35, fat: 0, sugar: 35)
    ]

    public static func search(_ query: String) -> [FoodPreset] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return catalogue }
        return catalogue.filter { $0.name.lowercased().contains(needle) }
    }
}
