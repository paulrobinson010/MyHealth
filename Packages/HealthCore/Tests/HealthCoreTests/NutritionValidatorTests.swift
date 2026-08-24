import XCTest
@testable import HealthCore

final class NutritionValidatorTests: XCTestCase {

    func testAtwaterReconcilesAHonestLabel() {
        // 30 g protein, 45 g carbs, 12 g fat = 120 + 180 + 108 = 408 kcal.
        let nutrition = Nutrition(kilocalories: 408, proteinGrams: 30,
                                  carbohydrateGrams: 45, fatGrams: 12)
        let result = NutritionValidator.validate(nutrition)
        XCTAssertEqual(result.severity, .fine)
        XCTAssertEqual(result.confidenceMultiplier, 1, accuracy: 1e-9)
        XCTAssertNil(result.corrected)
    }

    func testRoundingOnALabelIsToleratedRatherThanFlagged() {
        // Real labels round every field, so a few percent must not raise a flag.
        let nutrition = Nutrition(kilocalories: 400, proteinGrams: 30,
                                  carbohydrateGrams: 45, fatGrams: 12)
        XCTAssertEqual(NutritionValidator.validate(nutrition).severity, .fine)
    }

    /// The classic Open Food Facts defect: kilojoules typed into the kcal field.
    func testKilojoulesInTheCalorieFieldIsCaughtAndCorrected() throws {
        let nutrition = Nutrition(kilocalories: 1_707,   // 408 kcal in kJ
                                  proteinGrams: 30, carbohydrateGrams: 45, fatGrams: 12)
        let result = NutritionValidator.validate(nutrition)
        XCTAssertEqual(result.severity, .impossible)
        let corrected = try XCTUnwrap(result.corrected)
        XCTAssertEqual(corrected.kilocalories, 408, accuracy: 5)
        XCTAssertLessThan(result.confidenceMultiplier, 0.3)
    }

    /// The classic language-model defect: a confident number with macros that
    /// do not support it.
    func testAnInventedCalorieCountIsCaught() {
        let nutrition = Nutrition(kilocalories: 250, proteinGrams: 40,
                                  carbohydrateGrams: 60, fatGrams: 20)  // implies 580
        let result = NutritionValidator.validate(nutrition)
        XCTAssertEqual(result.severity, .impossible)
        XCTAssertTrue(result.messages.contains { $0.contains("macros add up") })
    }

    func testBothLabellingConventionsForFibreAreAccepted() {
        // EU: carbohydrate excludes fibre. 20 P + 30 C + 10 Fibre + 5 F
        // = 80 + 120 + 20 + 45 = 265.
        let european = Nutrition(kilocalories: 265, proteinGrams: 20,
                                 carbohydrateGrams: 30, fatGrams: 5, fibreGrams: 10)
        XCTAssertEqual(NutritionValidator.validate(european).severity, .fine)

        // US: total carbohydrate includes the fibre, so the same food reads
        // 40 C with 10 of it fibre = 80 + 120 + 20 + 45 = 265 again.
        let american = Nutrition(kilocalories: 265, proteinGrams: 20,
                                 carbohydrateGrams: 40, fatGrams: 5, fibreGrams: 10)
        XCTAssertEqual(NutritionValidator.validate(american).severity, .fine,
                       "a US-convention label must not be flagged as wrong")
    }

    func testAlcoholContributesSevenCaloriesPerGram() {
        // A pint of lager: ~20 g ethanol = 140 kcal, plus 10 g carbs = 180.
        let pint = Nutrition(kilocalories: 180, carbohydrateGrams: 10, alcoholGrams: 20)
        XCTAssertEqual(NutritionValidator.validate(pint).severity, .fine)

        // Forgetting the alcohol is what every naive calorie counter does.
        let missingAlcohol = Nutrition(kilocalories: 40, carbohydrateGrams: 10, alcoholGrams: 20)
        XCTAssertEqual(NutritionValidator.validate(missingAlcohol).severity, .impossible)
    }

    func testNothingIsDenserThanPureFat() {
        let nutrition = Nutrition(kilocalories: 1_200, fatGrams: 100)
        let result = NutritionValidator.validate(nutrition, servingGrams: 100)
        XCTAssertEqual(result.severity, .impossible)
        XCTAssertTrue(result.messages.contains { $0.contains("denser than pure fat") })
    }

    func testMacrosCannotOutweighTheServing() {
        // 200 g of macros in a 100 g serving is not a rounding error.
        let nutrition = Nutrition(kilocalories: 800, proteinGrams: 100,
                                  carbohydrateGrams: 100, fatGrams: 0)
        let result = NutritionValidator.validate(nutrition, servingGrams: 100)
        XCTAssertEqual(result.severity, .impossible)
    }

    func testAnEnormousSinglePortionIsQueried() {
        let nutrition = Nutrition(kilocalories: 3_000, proteinGrams: 100,
                                  carbohydrateGrams: 350, fatGrams: 120)
        let result = NutritionValidator.validate(nutrition)
        XCTAssertTrue(result.messages.contains { $0.contains("very large") })
        XCTAssertTrue(result.isUsable, "large is suspicious, not impossible")
    }

    func testMissingEnergyIsFilledInFromTheMacros() throws {
        let nutrition = Nutrition(kilocalories: 0, proteinGrams: 25,
                                  carbohydrateGrams: 30, fatGrams: 10)
        let result = NutritionValidator.validate(nutrition)
        let corrected = try XCTUnwrap(result.corrected)
        XCTAssertEqual(corrected.kilocalories, 310, accuracy: 1)
    }

    func testMoreSugarThanCarbohydrateIsFlagged() {
        let nutrition = Nutrition(kilocalories: 100, carbohydrateGrams: 10, sugarGrams: 25)
        XCTAssertTrue(NutritionValidator.validate(nutrition).messages
            .contains { $0.contains("More sugar") })
    }

    func testCrossSourceComparison() throws {
        let a = Nutrition(kilocalories: 500)
        let b = Nutrition(kilocalories: 520)
        XCTAssertEqual(try XCTUnwrap(NutritionValidator.compare(a, b)), 0.039, accuracy: 0.005)

        let far = Nutrition(kilocalories: 900)
        XCTAssertGreaterThan(try XCTUnwrap(NutritionValidator.compare(a, far)),
                             NutritionValidator.significantDisagreement)
    }

    func testEmptyNutritionIsNotFlagged() {
        // Black coffee is genuinely nothing; that must not read as an error.
        XCTAssertEqual(NutritionValidator.validate(.empty).severity, .fine)
    }
}

final class NameSimilarityTests: XCTestCase {

    func testExactWordsScoreHighly() {
        XCTAssertGreaterThan(
            NutritionResolver.nameSimilarity("chicken tikka masala", "Chicken Tikka Masala"), 0.9)
    }

    func testAVerboseProductNameIsNotPunishedForExtraWords() {
        let score = NutritionResolver.nameSimilarity(
            "chicken tikka masala", "Tesco Finest Chicken Tikka Masala with Pilau Rice")
        XCTAssertGreaterThan(score, 0.5)
    }

    /// The failure this exists to prevent: a grocery search confidently
    /// returning a spice paste for a curry.
    func testAWrongButPlausibleResultScoresLow() {
        let score = NutritionResolver.nameSimilarity("chicken tikka masala", "Tikka spice paste")
        XCTAssertLessThan(score, 0.5)
    }

    func testUnrelatedFoodScoresZero() {
        XCTAssertEqual(NutritionResolver.nameSimilarity("pint of lager", "Greek yoghurt"), 0)
    }

    func testFillerWordsAreIgnored() {
        XCTAssertGreaterThan(
            NutritionResolver.nameSimilarity("a large glass of red wine", "Red wine"), 0.4)
    }
}
