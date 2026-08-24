import Foundation

/// How a metric's samples collapse into a single value for a day.
public enum Aggregation: String, Codable, Sendable {
    /// Additive quantities (steps, kilometres, kilocalories). Summed per source
    /// and then de-duplicated across sources — see `DailyBuilder`.
    case sum
    /// Point-in-time measurements (heart rate, weight). Averaged.
    case mean
    case minimum
    case maximum
    /// Slow-moving measurements where the newest reading is the answer (VO2 max).
    case latest
}

public enum MetricCategory: String, Codable, CaseIterable, Sendable {
    case activity, heart, body, fitness, nutrition, mobility, wellbeing

    public var title: String {
        switch self {
        case .activity: return "Activity"
        case .heart: return "Heart"
        case .body: return "Body"
        case .fitness: return "Fitness"
        case .nutrition: return "Nutrition"
        case .mobility: return "Mobility"
        case .wellbeing: return "Wellbeing"
        }
    }
}

/// The canonical metrics MyHealth keeps a daily value for.
///
/// Everything is normalised to metric units at import time, so an export made
/// on a device set to miles and pounds produces exactly the same database as
/// one made in kilometres and kilograms.
public enum Metric: String, Codable, CaseIterable, Sendable {
    // Activity
    case steps
    case walkingRunningDistance
    case cyclingDistance
    case swimmingDistance
    case flightsClimbed
    case activeEnergy
    case basalEnergy
    case exerciseMinutes
    case standHours
    case moveMinutes

    // Heart
    case restingHeartRate
    case walkingHeartRate
    case heartRateAverage
    case heartRateMin
    case heartRateMax
    case hrv
    case respiratoryRate
    case oxygenSaturation
    case bloodPressureSystolic
    case bloodPressureDiastolic

    // Fitness
    case vo2Max
    case sixMinuteWalk
    case physicalEffort
    /// The composite index, materialised as a metric so it can be trended and
    /// correlated with everything else.
    case fitnessIndex

    // Body
    case bodyMass
    case bodyFatPercentage
    case leanBodyMass
    case bodyMassIndex
    case waistCircumference

    // Mobility
    case walkingSpeed
    case walkingStepLength
    case walkingAsymmetry
    case walkingDoubleSupport
    case stairAscentSpeed
    case stairDescentSpeed
    case walkingSteadiness
    case runningPower
    case runningSpeed
    case runningStrideLength
    case runningVerticalOscillation
    case runningGroundContactTime

    // Nutrition
    case dietaryEnergy
    case dietaryProtein
    case dietaryCarbohydrates
    case dietaryFat
    case dietaryFibre
    case dietarySugar
    case dietaryWater
    case alcoholGrams
    case alcoholicDrinks

    // Wellbeing
    case sleepHours
    case timeInDaylight
    case mindfulMinutes

    // Derived from <Workout> elements rather than <Record> elements
    case workoutMinutes
    case workoutEnergy
    case workoutDistance
    case workoutCount

    public var title: String {
        switch self {
        case .steps: return "Steps"
        case .walkingRunningDistance: return "Walking + Running Distance"
        case .cyclingDistance: return "Cycling Distance"
        case .swimmingDistance: return "Swimming Distance"
        case .flightsClimbed: return "Flights Climbed"
        case .activeEnergy: return "Active Energy"
        case .basalEnergy: return "Resting Energy"
        case .exerciseMinutes: return "Exercise Minutes"
        case .standHours: return "Stand Hours"
        case .moveMinutes: return "Move Minutes"
        case .restingHeartRate: return "Resting Heart Rate"
        case .walkingHeartRate: return "Walking Heart Rate"
        case .heartRateAverage: return "Average Heart Rate"
        case .heartRateMin: return "Lowest Heart Rate"
        case .heartRateMax: return "Peak Heart Rate"
        case .hrv: return "Heart Rate Variability"
        case .respiratoryRate: return "Respiratory Rate"
        case .oxygenSaturation: return "Blood Oxygen"
        case .bloodPressureSystolic: return "Blood Pressure (Systolic)"
        case .bloodPressureDiastolic: return "Blood Pressure (Diastolic)"
        case .vo2Max: return "VO₂ Max"
        case .sixMinuteWalk: return "Six-Minute Walk"
        case .physicalEffort: return "Physical Effort"
        case .fitnessIndex: return "Fitness Index"
        case .bodyMass: return "Weight"
        case .bodyFatPercentage: return "Body Fat"
        case .leanBodyMass: return "Lean Body Mass"
        case .bodyMassIndex: return "BMI"
        case .waistCircumference: return "Waist"
        case .walkingSpeed: return "Walking Speed"
        case .walkingStepLength: return "Step Length"
        case .walkingAsymmetry: return "Walking Asymmetry"
        case .walkingDoubleSupport: return "Double Support Time"
        case .stairAscentSpeed: return "Stair Ascent Speed"
        case .stairDescentSpeed: return "Stair Descent Speed"
        case .walkingSteadiness: return "Walking Steadiness"
        case .runningPower: return "Running Power"
        case .runningSpeed: return "Running Speed"
        case .runningStrideLength: return "Running Stride Length"
        case .runningVerticalOscillation: return "Vertical Oscillation"
        case .runningGroundContactTime: return "Ground Contact Time"
        case .dietaryEnergy: return "Calories Eaten"
        case .dietaryProtein: return "Protein"
        case .dietaryCarbohydrates: return "Carbohydrates"
        case .dietaryFat: return "Fat"
        case .dietaryFibre: return "Fibre"
        case .dietarySugar: return "Sugar"
        case .dietaryWater: return "Water"
        case .alcoholGrams: return "Alcohol"
        case .alcoholicDrinks: return "Drinks"
        case .sleepHours: return "Sleep"
        case .timeInDaylight: return "Time in Daylight"
        case .mindfulMinutes: return "Mindful Minutes"
        case .workoutMinutes: return "Workout Time"
        case .workoutEnergy: return "Workout Energy"
        case .workoutDistance: return "Workout Distance"
        case .workoutCount: return "Workouts"
        }
    }

    /// Canonical unit after import-time normalisation.
    public var unit: String {
        switch self {
        case .steps, .flightsClimbed, .workoutCount, .alcoholicDrinks: return "count"
        case .walkingRunningDistance, .cyclingDistance, .swimmingDistance, .workoutDistance: return "km"
        case .activeEnergy, .basalEnergy, .workoutEnergy, .dietaryEnergy: return "kcal"
        case .dietaryProtein, .dietaryCarbohydrates, .dietaryFat, .dietaryFibre,
             .dietarySugar, .alcoholGrams: return "g"
        case .dietaryWater: return "L"
        case .exerciseMinutes, .moveMinutes, .mindfulMinutes, .workoutMinutes, .timeInDaylight: return "min"
        case .standHours: return "hr"
        case .sleepHours: return "hr"
        case .restingHeartRate, .walkingHeartRate, .heartRateAverage, .heartRateMin, .heartRateMax,
             .respiratoryRate: return "bpm"
        case .hrv, .runningGroundContactTime: return "ms"
        case .oxygenSaturation, .bodyFatPercentage, .walkingAsymmetry, .walkingDoubleSupport,
             .walkingSteadiness: return "%"
        case .bloodPressureSystolic, .bloodPressureDiastolic: return "mmHg"
        case .vo2Max: return "mL/kg·min"
        case .sixMinuteWalk: return "m"
        case .physicalEffort: return "MET"
        case .fitnessIndex: return "index"
        case .bodyMass, .leanBodyMass: return "kg"
        case .bodyMassIndex: return "kg/m²"
        case .waistCircumference, .walkingStepLength, .runningStrideLength,
             .runningVerticalOscillation: return "cm"
        case .walkingSpeed, .runningSpeed, .stairAscentSpeed, .stairDescentSpeed: return "m/s"
        case .runningPower: return "W"
        }
    }

    public var aggregation: Aggregation {
        switch self {
        case .steps, .walkingRunningDistance, .cyclingDistance, .swimmingDistance, .flightsClimbed,
             .activeEnergy, .basalEnergy, .exerciseMinutes, .standHours, .moveMinutes,
             .sleepHours, .timeInDaylight, .mindfulMinutes,
             .workoutMinutes, .workoutEnergy, .workoutDistance, .workoutCount,
             .dietaryEnergy, .dietaryProtein, .dietaryCarbohydrates, .dietaryFat,
             .dietaryFibre, .dietarySugar, .dietaryWater, .alcoholGrams, .alcoholicDrinks:
            return .sum
        case .heartRateMin:
            return .minimum
        case .heartRateMax:
            return .maximum
        case .vo2Max:
            return .latest
        default:
            return .mean
        }
    }

    /// True when a rising line is the good news. Drives arrow direction and
    /// colour everywhere a trend is shown.
    public var higherIsBetter: Bool {
        switch self {
        case .restingHeartRate, .walkingHeartRate, .heartRateAverage, .heartRateMin, .heartRateMax,
             .respiratoryRate, .bodyFatPercentage, .waistCircumference,
             .bloodPressureSystolic, .bloodPressureDiastolic,
             .walkingAsymmetry, .walkingDoubleSupport, .runningGroundContactTime,
             .runningVerticalOscillation, .bodyMassIndex, .bodyMass,
             .alcoholGrams, .alcoholicDrinks, .dietarySugar:
            return false
        default:
            return true
        }
    }

    public var category: MetricCategory {
        switch self {
        case .steps, .walkingRunningDistance, .cyclingDistance, .swimmingDistance, .flightsClimbed,
             .activeEnergy, .basalEnergy, .exerciseMinutes, .standHours, .moveMinutes,
             .workoutMinutes, .workoutEnergy, .workoutDistance, .workoutCount:
            return .activity
        case .restingHeartRate, .walkingHeartRate, .heartRateAverage, .heartRateMin, .heartRateMax,
             .hrv, .respiratoryRate, .oxygenSaturation, .bloodPressureSystolic, .bloodPressureDiastolic:
            return .heart
        case .vo2Max, .sixMinuteWalk, .physicalEffort, .fitnessIndex:
            return .fitness
        case .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex, .waistCircumference:
            return .body
        case .sleepHours, .timeInDaylight, .mindfulMinutes:
            return .wellbeing
        case .dietaryEnergy, .dietaryProtein, .dietaryCarbohydrates, .dietaryFat,
             .dietaryFibre, .dietarySugar, .dietaryWater, .alcoholGrams, .alcoholicDrinks:
            return .nutrition
        case .walkingSpeed, .walkingStepLength, .walkingAsymmetry, .walkingDoubleSupport,
             .stairAscentSpeed, .stairDescentSpeed, .walkingSteadiness,
             .runningPower, .runningSpeed, .runningStrideLength, .runningVerticalOscillation,
             .runningGroundContactTime:
            return .mobility
        }
    }

    public var fractionDigits: Int {
        switch self {
        case .steps, .flightsClimbed, .activeEnergy, .basalEnergy, .workoutEnergy, .workoutCount,
             .dietaryEnergy, .dietaryProtein, .dietaryCarbohydrates, .dietaryFat, .dietaryFibre,
             .dietarySugar, .alcoholGrams,
             .runningPower, .sixMinuteWalk, .bloodPressureSystolic, .bloodPressureDiastolic,
             .runningGroundContactTime:
            return 0
        case .exerciseMinutes, .moveMinutes, .mindfulMinutes, .workoutMinutes, .timeInDaylight,
             .standHours, .restingHeartRate, .walkingHeartRate, .heartRateAverage, .heartRateMin,
             .heartRateMax, .hrv:
            return 0
        default:
            return 1
        }
    }

    /// Metrics that are summed over a period rather than averaged when the
    /// chart is showing weeks or months.
    public var isCumulative: Bool { aggregation == .sum }
}
