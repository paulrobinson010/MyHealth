import Foundation

/// Translates the `HKQuantityTypeIdentifier*` / `HKCategoryTypeIdentifier*`
/// strings and unit strings found in `export.xml` into MyHealth's canonical
/// metrics and units.
public enum HealthKitMapping {

    /// Quantity identifiers that map straight onto one metric.
    /// Keys are the identifier with the `HKQuantityTypeIdentifier` prefix stripped.
    static let quantity: [String: Metric] = [
        "StepCount": .steps,
        "DistanceWalkingRunning": .walkingRunningDistance,
        "DistanceCycling": .cyclingDistance,
        "DistanceSwimming": .swimmingDistance,
        "FlightsClimbed": .flightsClimbed,
        "ActiveEnergyBurned": .activeEnergy,
        "BasalEnergyBurned": .basalEnergy,
        "AppleExerciseTime": .exerciseMinutes,
        "AppleMoveTime": .moveMinutes,
        "RestingHeartRate": .restingHeartRate,
        "WalkingHeartRateAverage": .walkingHeartRate,
        "HeartRateVariabilitySDNN": .hrv,
        "RespiratoryRate": .respiratoryRate,
        "OxygenSaturation": .oxygenSaturation,
        "BloodPressureSystolic": .bloodPressureSystolic,
        "BloodPressureDiastolic": .bloodPressureDiastolic,
        "VO2Max": .vo2Max,
        "SixMinuteWalkTestDistance": .sixMinuteWalk,
        "PhysicalEffort": .physicalEffort,
        "BodyMass": .bodyMass,
        "BodyFatPercentage": .bodyFatPercentage,
        "LeanBodyMass": .leanBodyMass,
        "BodyMassIndex": .bodyMassIndex,
        "WaistCircumference": .waistCircumference,
        "WalkingSpeed": .walkingSpeed,
        "WalkingStepLength": .walkingStepLength,
        "WalkingAsymmetryPercentage": .walkingAsymmetry,
        "WalkingDoubleSupportPercentage": .walkingDoubleSupport,
        "StairAscentSpeed": .stairAscentSpeed,
        "StairDescentSpeed": .stairDescentSpeed,
        "AppleWalkingSteadiness": .walkingSteadiness,
        "RunningPower": .runningPower,
        "RunningSpeed": .runningSpeed,
        "RunningStrideLength": .runningStrideLength,
        "RunningVerticalOscillation": .runningVerticalOscillation,
        "RunningGroundContactTime": .runningGroundContactTime,
        "TimeInDaylight": .timeInDaylight
    ]

    /// Heart rate feeds three metrics at once (mean, min, max) so it is handled
    /// separately from the one-to-one table.
    static let heartRateIdentifier = "HeartRate"

    public static func metric(forQuantityIdentifier identifier: String) -> Metric? {
        quantity[strip(identifier)]
    }

    static func strip(_ identifier: String) -> String {
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataType"] {
            if identifier.hasPrefix(prefix) {
                return String(identifier.dropFirst(prefix.count))
            }
        }
        return identifier
    }

    // MARK: - Units

    /// Converts a raw exported value into the canonical unit for `metric`.
    ///
    /// Health writes values in whatever unit the exporting device was set to,
    /// so this is what keeps an export from a miles-and-pounds phone
    /// comparable with one from a kilometres-and-kilograms phone.
    public static func normalise(_ value: Double, unit rawUnit: String, for metric: Metric) -> Double {
        let unit = rawUnit.trimmingCharacters(in: .whitespaces)
        switch metric.unit {
        case "km":
            return value * distanceFactorToKilometres(unit)
        case "kcal":
            return unit == "kJ" ? value / 4.184 : value
        case "kg":
            switch unit {
            case "lb": return value * 0.453_592_37
            case "st": return value * 6.350_293_18
            case "g": return value / 1000
            default: return value
            }
        case "min":
            switch unit {
            case "hr": return value * 60
            case "s", "sec": return value / 60
            case "ms": return value / 60_000
            default: return value
            }
        case "hr":
            switch unit {
            case "min": return value / 60
            case "s", "sec": return value / 3600
            default: return value
            }
        case "m":
            return value * distanceFactorToKilometres(unit) * 1000
        case "cm":
            switch unit {
            case "m": return value * 100
            case "mm": return value / 10
            case "in": return value * 2.54
            case "ft": return value * 30.48
            default: return value
            }
        case "m/s":
            switch unit {
            case "km/hr", "km/h": return value / 3.6
            case "mi/hr", "mph": return value * 0.447_04
            case "ft/s": return value * 0.3048
            default: return value
            }
        case "ms":
            switch unit {
            case "s", "sec": return value * 1000
            default: return value
            }
        case "%":
            // Health writes ratios for some percentage types and whole
            // percentages for others; 0...1 can only be a ratio here.
            if unit == "%" { return value }
            return value <= 1.0 ? value * 100 : value
        default:
            return value
        }
    }

    private static func distanceFactorToKilometres(_ unit: String) -> Double {
        switch unit {
        case "km": return 1
        case "m": return 0.001
        case "cm": return 0.000_01
        case "mi": return 1.609_344
        case "ft": return 0.000_304_8
        case "yd": return 0.000_914_4
        case "in": return 0.000_025_4
        default: return 1
        }
    }
}
