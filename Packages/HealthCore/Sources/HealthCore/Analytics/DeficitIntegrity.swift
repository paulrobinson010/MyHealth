import Foundation

/// An audit of whether a calorie-deficit figure can be trusted.
///
/// A deficit is a small difference between two large, independently error-prone
/// numbers, so it inherits the worst of both. Reporting one without saying what
/// could be wrong with it is how a calorie tracker becomes confidently useless.
/// This enumerates every reason the figure might mislead, before anyone acts on
/// it.
public struct DeficitIntegrity: Sendable {

    public enum Confidence: String, Sendable {
        /// Enough coverage and corroboration to act on.
        case solid
        /// Directionally right, but do not read the last few hundred calories.
        case indicative
        /// Not worth quoting.
        case unreliable

        public var title: String {
            switch self {
            case .solid: return "Reliable"
            case .indicative: return "Indicative"
            case .unreliable: return "Not reliable yet"
            }
        }
    }

    public struct Finding: Sendable, Identifiable, Hashable {
        public enum Impact: Int, Sendable, Comparable {
            case note = 0
            case caution = 1
            case blocking = 2
            public static func < (lhs: Impact, rhs: Impact) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public var id: String { message }
        public let impact: Impact
        public let message: String
        /// What the person could do about it, when there is something.
        public let remedy: String?

        public init(impact: Impact, message: String, remedy: String? = nil) {
            self.impact = impact
            self.message = message
            self.remedy = remedy
        }
    }

    public let confidence: Confidence
    public let findings: [Finding]
    /// Days in the window with food logged.
    public let loggedDays: Int
    public let totalDays: Int
    /// Share of logged calories that came from a real lookup rather than a guess.
    public let verifiedCalorieShare: Double
    /// The window's deficit, and how wide the uncertainty around it is.
    public let dailyDeficit: Double?
    public let uncertaintyRange: ClosedRange<Double>?

    public var isActionable: Bool { confidence != .unreliable }

    public var blockingFindings: [Finding] { findings.filter { $0.impact == .blocking } }
}

public enum DeficitAudit {

    /// Everything that can make a deficit figure wrong, checked in order of how
    /// badly it distorts the answer.
    public static func audit(report: EnergyBalanceReport,
                             log: FoodLog,
                             database: HealthDatabase,
                             range: ClosedRange<DayKey>?) -> DeficitIntegrity {
        var findings: [DeficitIntegrity.Finding] = []

        // 1. Unlogged days are the single biggest distortion. A missed day does
        //    not read as missing — it reads as a day you ate nothing.
        let coverage = report.loggingCoverage
        if report.loggedDays == 0 {
            findings.append(.init(impact: .blocking,
                                  message: "No food logged in this period.",
                                  remedy: "Log what you eat for a fortnight and this becomes meaningful."))
        } else if coverage < 0.6 {
            findings.append(.init(
                impact: .blocking,
                message: String(format: "Food logged on only %.0f%% of days (%d of %d).",
                                coverage * 100, report.loggedDays, report.totalDays),
                remedy: "Unlogged days look like zero-calorie days, which invents a deficit that never happened. Aim for 60% before trusting the number."))
        } else if coverage < 0.85 {
            findings.append(.init(
                impact: .caution,
                message: String(format: "%d of %d days have no food logged.",
                                report.totalDays - report.loggedDays, report.totalDays),
                remedy: "Those days are excluded rather than counted as zero, but the average still leans towards the days you remembered to log."))
        }

        // 2. How much of what was logged is a real figure rather than a guess.
        let entries = log.entries.filter { entry in
            range.map { $0.contains(entry.day) } ?? true
        }
        let totalCalories = entries.reduce(0.0) { $0 + $1.total.kilocalories }
        let verifiedCalories = entries.reduce(0.0) { running, entry in
            guard let provenance = entry.provenance, provenance.isTrustworthy,
                  provenance.source != .languageModel else { return running }
            return running + entry.total.kilocalories
        }
        let verifiedShare = totalCalories > 0 ? verifiedCalories / totalCalories : 0

        if totalCalories > 0, verifiedShare < 0.4 {
            findings.append(.init(
                impact: .caution,
                message: String(format: "%.0f%% of the calories you logged are estimates rather than looked-up figures.",
                                (1 - verifiedShare) * 100),
                remedy: "Turn on online lookups, or pick items from the list rather than describing them, to firm this up."))
        }

        // 3. Entries flagged during validation.
        let flagged = entries.filter { ($0.provenance?.issues.isEmpty == false) }
        if flagged.count > 2 {
            findings.append(.init(
                impact: .caution,
                message: "\(flagged.count) logged items have unresolved warnings against their figures.",
                remedy: "Check them on the Energy Balance screen — a single mis-scaled entry can swamp a week's deficit."))
        }

        // 4. Weight data is what turns a claimed deficit into a measured one.
        let weightDays = database.series(.bodyMass, in: range).count
        if weightDays < 8 {
            findings.append(.init(
                impact: .blocking,
                message: "Not enough weigh-ins to check the deficit against reality.",
                remedy: "Weigh yourself most mornings. Without it this is arithmetic on an estimate, not a measurement."))
        } else if weightDays < report.totalDays / 3 {
            findings.append(.init(
                impact: .caution,
                message: "Only \(weightDays) weigh-ins in this period.",
                remedy: "More frequent weighing tightens the trend the calibration rests on."))
        }

        // 5. Does the claimed deficit match what the scale did? This is the
        //    check that catches systematic under-logging, which no amount of
        //    coverage will reveal on its own.
        if let predicted = report.predictedWeightChangeKg,
           let actual = report.actualWeightChangeKg,
           weightDays >= 8 {
            let gap = abs(predicted - actual)
            if gap > 1.5 {
                let direction = actual > predicted ? "less" : "more"
                findings.append(.init(
                    impact: .caution,
                    message: String(format: "Your logged deficit predicts %+.1f kg but the scale says %+.1f kg.",
                                    predicted, actual),
                    remedy: "A gap this size usually means systematic under-logging — the deficit is \(direction) real than it looks. The calibrated maintenance figure already corrects for it."))
            }
        }

        // 6. Resting energy. If the device never recorded it, expenditure is a
        //    formula, and formulas are wrong by 10-15% for individuals.
        let basalDays = database.series(.basalEnergy, in: range).count
        if basalDays < report.totalDays / 2 {
            findings.append(.init(
                impact: .note,
                message: "Resting energy is estimated from height, weight and age on most days.",
                remedy: "Wearing your watch overnight lets it measure this instead."))
        }

        // 7. Alcohol is the most commonly forgotten source of calories, and it
        //    is dense enough to hide a whole deficit.
        let alcoholDays = entries.filter { $0.total.alcoholGrams > 0 }.count
        if alcoholDays == 0, report.loggedDays > 14 {
            findings.append(.init(
                impact: .note,
                message: "No alcohol logged at all in this period.",
                remedy: "If that is right, ignore this. If not, it is the easiest way for a few hundred calories a day to go missing."))
        }

        let worst = findings.map(\.impact).max() ?? .note
        let confidence: DeficitIntegrity.Confidence
        switch worst {
        case .blocking: confidence = .unreliable
        case .caution: confidence = .indicative
        case .note: confidence = .solid
        }

        // The uncertainty band widens with everything that could be wrong. It
        // is a plain-spoken error bar, not a statistical interval, and the app
        // says so rather than implying more rigour than exists.
        var uncertainty: ClosedRange<Double>?
        if let deficit = report.averageDailyDeficit {
            var margin = 100.0
            margin += (1 - coverage) * 500
            margin += (1 - verifiedShare) * 250
            if basalDays < report.totalDays / 2 { margin += 150 }
            uncertainty = (deficit - margin)...(deficit + margin)
        }

        return DeficitIntegrity(confidence: confidence,
                                findings: findings.sorted { $0.impact > $1.impact },
                                loggedDays: report.loggedDays,
                                totalDays: report.totalDays,
                                verifiedCalorieShare: verifiedShare,
                                dailyDeficit: report.averageDailyDeficit,
                                uncertaintyRange: uncertainty)
    }
}
