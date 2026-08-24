import XCTest
@testable import HealthCore

final class UnitNormalisationTests: XCTestCase {

    func testDistanceConvertsToKilometres() {
        XCTAssertEqual(HealthKitMapping.normalise(1, unit: "mi", for: .walkingRunningDistance),
                       1.609_344, accuracy: 1e-6)
        XCTAssertEqual(HealthKitMapping.normalise(1500, unit: "m", for: .cyclingDistance),
                       1.5, accuracy: 1e-9)
        XCTAssertEqual(HealthKitMapping.normalise(5, unit: "km", for: .walkingRunningDistance),
                       5, accuracy: 1e-9)
    }

    func testEnergyConvertsFromKilojoules() {
        XCTAssertEqual(HealthKitMapping.normalise(418.4, unit: "kJ", for: .activeEnergy),
                       100, accuracy: 1e-6)
    }

    func testWeightConvertsFromPoundsAndStone() {
        XCTAssertEqual(HealthKitMapping.normalise(154, unit: "lb", for: .bodyMass),
                       69.85, accuracy: 0.01)
        XCTAssertEqual(HealthKitMapping.normalise(11, unit: "st", for: .bodyMass),
                       69.85, accuracy: 0.01)
    }

    func testDurationsNormaliseToMinutesAndHours() {
        XCTAssertEqual(HealthKitMapping.normalise(2, unit: "hr", for: .exerciseMinutes), 120)
        XCTAssertEqual(HealthKitMapping.normalise(90, unit: "min", for: .sleepHours), 1.5)
    }

    func testRatiosBecomePercentages() {
        // Health writes some percentage types as 0...1 ratios.
        XCTAssertEqual(HealthKitMapping.normalise(0.22, unit: "", for: .bodyFatPercentage),
                       22, accuracy: 1e-9)
        // ...and others already as whole percentages.
        XCTAssertEqual(HealthKitMapping.normalise(97.5, unit: "%", for: .oxygenSaturation),
                       97.5, accuracy: 1e-9)
    }

    func testSpeedConvertsToMetresPerSecond() {
        XCTAssertEqual(HealthKitMapping.normalise(3.6, unit: "km/hr", for: .walkingSpeed),
                       1.0, accuracy: 1e-9)
    }

    func testIdentifierMapping() {
        XCTAssertEqual(HealthKitMapping.metric(forQuantityIdentifier: "HKQuantityTypeIdentifierStepCount"), .steps)
        XCTAssertEqual(HealthKitMapping.metric(forQuantityIdentifier: "HKQuantityTypeIdentifierVO2Max"), .vo2Max)
        XCTAssertNil(HealthKitMapping.metric(forQuantityIdentifier: "HKQuantityTypeIdentifierDietaryCaffeine"))
    }
}
