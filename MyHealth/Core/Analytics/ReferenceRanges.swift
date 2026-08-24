import Foundation

/// Population reference ranges used to turn a raw measurement into a 0...100
/// subscore.
///
/// The VO₂ max and resting heart rate anchors follow the widely published
/// Cooper Institute style fitness categories (poor / fair / good / excellent /
/// superior) by age band and sex; the HRV curve follows the well-documented
/// decline of SDNN with age. They are population reference points, not medical
/// thresholds — the scores are here to make *your own* trajectory legible, and
/// the app says as much on screen.
public enum ReferenceRanges {

    /// Maps a value onto 0...100 through a piecewise-linear curve defined by
    /// (value, score) anchors, which must be sorted ascending by value.
    /// Values outside the anchors clamp to the end scores.
    public static func score(_ value: Double, anchors: [(Double, Double)]) -> Double {
        guard let firstAnchor = anchors.first, let lastAnchor = anchors.last else { return 0 }
        if value <= firstAnchor.0 { return firstAnchor.1 }
        if value >= lastAnchor.0 { return lastAnchor.1 }
        for index in 1..<anchors.count {
            let low = anchors[index - 1]
            let high = anchors[index]
            if value <= high.0 {
                let span = high.0 - low.0
                guard span > 1e-9 else { return high.1 }
                let fraction = (value - low.0) / span
                return low.1 + fraction * (high.1 - low.1)
            }
        }
        return lastAnchor.1
    }

    // MARK: - VO₂ max

    /// Category boundaries in mL/kg·min: poor, fair, good, excellent, superior.
    static func vo2MaxBoundaries(age: Int, sex: BiologicalSex) -> [Double] {
        let male: [Double]
        switch age {
        case ..<30: male = [30, 38, 44, 51, 56]
        case 30..<40: male = [28, 36, 42, 48, 54]
        case 40..<50: male = [26, 34, 40, 46, 52]
        case 50..<60: male = [24, 31, 36, 42, 48]
        default: male = [21, 27, 32, 38, 44]
        }
        switch sex {
        case .female:
            let female: [Double]
            switch age {
            case ..<30: female = [24, 31, 36, 41, 48]
            case 30..<40: female = [22, 29, 34, 39, 45]
            case 40..<50: female = [20, 27, 32, 37, 43]
            case 50..<60: female = [18, 24, 29, 34, 39]
            default: female = [16, 21, 26, 31, 36]
            }
            return female
        case .male:
            return male
        case .other, .unknown:
            // Split the difference when Health does not know.
            let female = vo2MaxBoundaries(age: age, sex: .female)
            return zip(male, female).map { ($0 + $1) / 2 }
        }
    }

    public static func vo2MaxScore(_ value: Double, age: Int?, sex: BiologicalSex) -> Double {
        let boundaries = vo2MaxBoundaries(age: age ?? 40, sex: sex)
        let anchors: [(Double, Double)] = [
            (boundaries[0] * 0.6, 0),
            (boundaries[0], 25),
            (boundaries[1], 45),
            (boundaries[2], 65),
            (boundaries[3], 85),
            (boundaries[4], 100)
        ]
        return score(value, anchors: anchors)
    }

    public static func vo2MaxCategory(_ value: Double, age: Int?, sex: BiologicalSex) -> String {
        let b = vo2MaxBoundaries(age: age ?? 40, sex: sex)
        switch value {
        case ..<b[0]: return "Low"
        case b[0]..<b[1]: return "Below average"
        case b[1]..<b[2]: return "Average"
        case b[2]..<b[3]: return "Above average"
        case b[3]..<b[4]: return "High"
        default: return "Superior"
        }
    }

    // MARK: - Resting heart rate

    public static func restingHeartRateScore(_ bpm: Double, age: Int?) -> Double {
        // Maximal heart rate falls with age, and so does the room available at
        // the bottom, so the curve shifts up very slightly for older ages.
        let shift = Double(max(0, (age ?? 40) - 40)) * 0.08
        let anchors: [(Double, Double)] = [
            (38 + shift, 100),
            (45 + shift, 92),
            (50 + shift, 84),
            (55 + shift, 74),
            (60 + shift, 62),
            (65 + shift, 50),
            (70 + shift, 36),
            (80 + shift, 15),
            (95 + shift, 0)
        ]
        return score(bpm, anchors: anchors)
    }

    // MARK: - Heart rate variability

    /// Typical overnight SDNN for an age, in milliseconds.
    public static func expectedHRV(age: Int?) -> Double {
        let a = Double(age ?? 40)
        return max(15, 70 - 0.7 * a)
    }

    public static func hrvScore(_ sdnn: Double, age: Int?) -> Double {
        let expected = expectedHRV(age: age)
        guard expected > 0 else { return 50 }
        let ratio = sdnn / expected
        return score(ratio, anchors: [
            (0.35, 0), (0.5, 20), (0.75, 40), (1.0, 60),
            (1.3, 75), (1.6, 86), (2.0, 95), (2.5, 100)
        ])
    }

    // MARK: - Activity

    /// Exercise minutes per week against the 150-minute guideline, with real
    /// credit for going beyond it and diminishing returns past ~450.
    public static func exerciseVolumeScore(minutesPerWeek: Double) -> Double {
        score(minutesPerWeek, anchors: [
            (0, 0), (30, 18), (75, 40), (150, 70),
            (250, 86), (350, 95), (450, 100)
        ])
    }

    public static func activeEnergyScore(kcalPerDay: Double) -> Double {
        score(kcalPerDay, anchors: [
            (0, 0), (150, 28), (300, 48), (450, 65),
            (600, 78), (800, 90), (1100, 100)
        ])
    }

    public static func stepsScore(perDay: Double) -> Double {
        score(perDay, anchors: [
            (0, 0), (2000, 18), (4000, 34), (6000, 50), (8000, 65),
            (10_000, 78), (12_500, 88), (15_000, 95), (20_000, 100)
        ])
    }

    public static func consistencyScore(activeDayFraction: Double) -> Double {
        score(activeDayFraction, anchors: [
            (0, 0), (0.2, 25), (0.35, 42), (0.5, 60),
            (0.7, 80), (0.85, 92), (1.0, 100)
        ])
    }
}
