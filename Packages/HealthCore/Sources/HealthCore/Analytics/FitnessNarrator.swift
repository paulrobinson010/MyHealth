import Foundation

/// Turns the numbers into English, deterministically.
///
/// This exists so "why am I fitter?" is answered by arithmetic on a machine
/// with Apple Intelligence switched off. When the on-device model is available
/// it rewrites this into better prose — but it never *decides* anything, it
/// only rephrases what is already established here.
public enum FitnessNarrator {

    public struct Briefing: Sendable {
        /// One-line verdict.
        public let headline: String
        /// Ordered supporting statements, strongest evidence first.
        public let findings: [String]
        /// What would move the index most, given what is currently weakest.
        public let suggestions: [String]
        /// Caveats the reader needs in order to trust the rest.
        public let caveats: [String]

        public var plainText: String {
            var lines = [headline, ""]
            lines.append(contentsOf: findings.map { "• \($0)" })
            if !suggestions.isEmpty {
                lines.append("")
                lines.append(contentsOf: suggestions.map { "→ \($0)" })
            }
            if !caveats.isEmpty {
                lines.append("")
                lines.append(contentsOf: caveats.map { "Note: \($0)" })
            }
            return lines.joined(separator: "\n")
        }
    }

    public static func brief(standing: FitnessStanding?,
                             components: [FitnessComponent],
                             trends: [MetricTrend],
                             energy: EnergyBalanceReport? = nil,
                             composition: EnergyBalance.BodyCompositionSignal? = nil) -> Briefing {
        guard let standing else {
            return Briefing(headline: "Not enough data to judge fitness yet.",
                            findings: [],
                            suggestions: ["Keep wearing your watch — the index needs a few weeks of continuous data."],
                            caveats: [])
        }

        let score = standing.current.value
        let band = standing.current.band.title.lowercased()
        let percentile = Int((standing.percentileAllTime * 100).rounded())

        let headline: String
        let change = standing.changeVs90Days
        if let change, change >= 3 {
            headline = "You are fitter than you were three months ago — index \(rounded(score)), up \(rounded(abs(change))) points."
        } else if let change, change <= -3 {
            headline = "You are less fit than you were three months ago — index \(rounded(score)), down \(rounded(abs(change))) points."
        } else {
            headline = "Your fitness is holding steady at \(rounded(score)) — \(band) shape, \(percentile)th percentile of your own history."
        }

        var findings: [String] = []

        if let best = standing.allTimeBest, best.day == standing.current.day {
            findings.append("This is the highest your index has ever been.")
        } else if let days = standing.daysSinceHigher {
            findings.append("It has been \(days) days since the index was last this high.")
        }

        // Rank components so the reader learns what is carrying them and what
        // is dragging.
        let ranked = components.sorted { $0.score > $1.score }
        if let strongest = ranked.first {
            findings.append("\(strongest.kind.title) is your strongest pillar at \(rounded(strongest.score))/100\(detailSuffix(strongest)).")
        }
        if let weakest = ranked.last, ranked.count > 1, weakest.score < 60 {
            findings.append("\(weakest.kind.title) is holding you back at \(rounded(weakest.score))/100\(detailSuffix(weakest)).")
        }

        // Only surface trends that actually moved and matter.
        let movers = trends
            .filter { abs($0.changeVsPrevious ?? 0) >= 0.05 && $0.direction != .unknown }
            .sorted { abs($0.changeVsPrevious ?? 0) > abs($1.changeVsPrevious ?? 0) }
            .prefix(3)
        for trend in movers {
            let arrow = trend.direction == .improving ? "improved" : "worsened"
            findings.append("\(trend.metric.title) has \(arrow) \(percent(trend.changeVsPrevious)) over the last \(trend.window) days.")
        }

        if let energy, energy.isCalibrationTrustworthy,
           let maintenance = energy.calibratedMaintenanceCalories {
            findings.append("From what you logged and what the scale did, your true maintenance is about \(rounded(maintenance)) kcal a day.")
            if let bias = energy.expenditureBias, abs(bias) > 150 {
                let over = bias > 0 ? "over" : "under"
                findings.append("Your watch \(over)estimates your daily burn by roughly \(rounded(abs(bias))) kcal.")
            }
        }

        if let composition, composition.isRecomposition {
            findings.append("Your weight is flat but your waist is down \(rounded(abs(composition.waistChangeCm ?? 0))) cm — that is body recomposition, not stalled progress.")
        }

        var suggestions: [String] = []
        if let weakest = ranked.last, weakest.score < 55 {
            suggestions.append(suggestion(for: weakest.kind))
        }
        if let second = ranked.dropLast().last, second.score < 45 {
            suggestions.append(suggestion(for: second.kind))
        }

        var caveats: [String] = []
        if standing.current.coverage < 0.75 {
            let missing = FitnessComponent.Kind.allCases
                .filter { kind in !components.contains { $0.kind == kind } }
                .map(\.title)
            if !missing.isEmpty {
                caveats.append("No data for \(list(missing)), so the index is built from what is left.")
            }
        }
        if let energy, energy.loggedDays > 0, energy.loggingCoverage < 0.6 {
            caveats.append("Food was logged on only \(Int(energy.loggingCoverage * 100))% of days, so the calorie figures understate reality.")
        }

        return Briefing(headline: headline, findings: findings,
                        suggestions: suggestions, caveats: caveats)
    }

    private static func suggestion(for kind: FitnessComponent.Kind) -> String {
        switch kind {
        case .cardio:
            return "VO₂ max responds to sustained hard efforts — two sessions a week at a pace you can just hold a conversation through will move it."
        case .restingHeart:
            return "Resting heart rate follows aerobic base and sleep. More easy-paced volume moves it more reliably than more intensity."
        case .recovery:
            return "HRV is dragged down by alcohol, short sleep and hard training back-to-back. The cheapest gain is usually the first of those."
        case .volume:
            return "You are short of the 150 minutes a week guideline. Two extra half-hour sessions would clear it."
        case .consistency:
            return "Your training is patchy rather than light — showing up more often would raise the index more than making sessions harder."
        case .movement:
            return "Daily step count is low outside workouts. Non-exercise movement is the easiest lever here."
        }
    }

    private static func detailSuffix(_ component: FitnessComponent) -> String {
        component.detail.map { " (\($0))" } ?? ""
    }

    private static func rounded(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.0f%%", abs(fraction * 100))
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
