import SwiftUI
import Charts
import HealthCore
import HealthUI

/// The calorie ledger, and what it says about your actual maintenance.
struct NutritionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: DateRangeOption = .quarter

    var body: some View {
        if model.database != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    HStack {
                        Text("Energy Balance").font(.title2.weight(.semibold))
                        Spacer()
                        DateRangePicker(selection: $range)
                    }
                    integrity
                    calibration
                    balanceChart
                    HStack(alignment: .top, spacing: Theme.gridSpacing) {
                        composition
                        alcohol
                    }
                    occasions
                }
                .padding(20)
            }
            .navigationTitle("Energy Balance")
        } else {
            NoDataView()
        }
    }

    private var report: EnergyBalanceReport? { model.analytics.energy }

    // MARK: - Integrity

    /// Whether the deficit below can be trusted, and precisely why not.
    ///
    /// This sits above the number on purpose. A deficit is a small difference
    /// between two large error-prone quantities, and presenting one without its
    /// caveats is how a calorie tracker ends up confidently wrong.
    @ViewBuilder
    private var integrity: some View {
        if let audit = model.deficitIntegrity {
            Card("Can you trust this?",
                 subtitle: "\(audit.loggedDays) of \(audit.totalDays) days logged · \(Int(audit.verifiedCalorieShare * 100))% of calories looked up rather than estimated") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(audit.confidence.title, systemImage: symbol(for: audit.confidence))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(colour(for: audit.confidence))
                        if let range = audit.uncertaintyRange, audit.dailyDeficit != nil {
                            Text(String(format: "Deficit is somewhere between %.0f and %.0f kcal a day.",
                                        range.lowerBound, range.upperBound))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 230, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(audit.findings) { finding in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(finding.message, systemImage: symbol(for: finding.impact))
                                    .font(.callout)
                                    .foregroundStyle(colour(for: finding.impact))
                                    .fixedSize(horizontal: false, vertical: true)
                                if let remedy = finding.remedy {
                                    Text(remedy)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if audit.findings.isEmpty {
                            Text("Nothing is undermining the figure below.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func symbol(for confidence: DeficitIntegrity.Confidence) -> String {
        switch confidence {
        case .solid: return "checkmark.seal.fill"
        case .indicative: return "exclamationmark.circle"
        case .unreliable: return "xmark.octagon"
        }
    }

    private func colour(for confidence: DeficitIntegrity.Confidence) -> Color {
        switch confidence {
        case .solid: return Theme.color(for: .improving)
        case .indicative: return .orange
        case .unreliable: return Theme.color(for: .declining)
        }
    }

    private func symbol(for impact: DeficitIntegrity.Finding.Impact) -> String {
        switch impact {
        case .blocking: return "xmark.octagon"
        case .caution: return "exclamationmark.triangle"
        case .note: return "info.circle"
        }
    }

    private func colour(for impact: DeficitIntegrity.Finding.Impact) -> Color {
        switch impact {
        case .blocking: return Theme.color(for: .declining)
        case .caution: return .orange
        case .note: return .secondary
        }
    }

    // MARK: - Calibration

    @ViewBuilder
    private var calibration: some View {
        Card("What you actually burn",
             subtitle: "Worked back from what you logged and what the scale did — not an estimate from a formula") {
            if let report, report.isCalibrationTrustworthy,
               let maintenance = report.calibratedMaintenanceCalories {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Format.decimal(maintenance)) kcal")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                        Text("your true maintenance").font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if let bias = report.expenditureBias, abs(bias) > 75 {
                            Label {
                                Text("Your watch \(bias > 0 ? "over" : "under")estimates your burn by about \(Format.decimal(abs(bias))) kcal a day.")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            .font(.callout)
                        }
                        Text("To lose 0.5 kg a week, eat about \(Format.decimal(EnergyBalance.targetIntake(forWeightChangeKgPerWeek: -0.5, maintenance: maintenance))) kcal a day. To hold steady, eat \(Format.decimal(maintenance)).")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                Divider()
                HStack(spacing: 28) {
                    figure("Logged intake", report.averageIntake.map { "\(Format.decimal($0)) kcal" })
                    figure("Watch says out", report.averageExpenditure.map { "\(Format.decimal($0)) kcal" })
                    figure("Predicted change",
                           report.predictedWeightChangeKg.map { String(format: "%+.1f kg", $0) })
                    figure("Actual change",
                           report.actualWeightChangeKg.map { String(format: "%+.1f kg", $0) })
                    figure("Days logged", "\(report.loggedDays) of \(report.totalDays)")
                }
            } else if let report, report.loggedDays > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not enough logging yet to calibrate.")
                        .font(.callout.weight(.medium))
                    Text("Food was logged on \(report.loggedDays) of the last \(report.totalDays) days. This needs at least 14 logged days covering 60% of the window, plus a weight trend to reconcile against — otherwise the unlogged days masquerade as a deficit that was never real.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: report.loggingCoverage)
                        .frame(maxWidth: 320)
                }
            } else {
                Text("Nothing logged yet. Log food on your Watch, or talk to the coach, and this fills in.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.monospacedDigit().weight(.semibold))
        }
    }

    // MARK: - Balance chart

    private var balanceChart: some View {
        Card("In versus out", subtitle: "Bars are what you ate; the line is what you burned") {
            let days = visibleDays
            if days.filter(\.isLogged).count < 3 {
                Text("Log a few more days to see the ledger.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(days) { day in
                        if let intake = day.intake {
                            BarMark(x: .value("Day", day.day.localDate()),
                                    y: .value("Eaten", intake))
                            .foregroundStyle(Theme.color(for: .nutrition).opacity(0.55))
                        }
                        if let expenditure = day.expenditure {
                            LineMark(x: .value("Day", day.day.localDate()),
                                     y: .value("Burned", expenditure))
                            .foregroundStyle(Theme.color(for: .activity))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                .frame(height: 230)

                if let report, let deficit = report.averageDailyDeficit {
                    Text(deficit > 0
                         ? "Average deficit of \(Format.decimal(deficit)) kcal a day across the days you logged."
                         : "Average surplus of \(Format.decimal(abs(deficit))) kcal a day across the days you logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Composition and alcohol

    private var composition: some View {
        Card("Weight and waist", subtitle: "Two measurements that disagree tell you more than either alone") {
            if let signal = model.analytics.composition {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 28) {
                        figure("Weight", signal.weightChangeKg.map { String(format: "%+.1f kg", $0) })
                        figure("Waist", signal.waistChangeCm.map { String(format: "%+.1f cm", $0) })
                        if let correlation = signal.correlation {
                            figure("They track each other",
                                   "r = \(Format.decimal(correlation.r, fractionDigits: 2))")
                        }
                    }
                    if signal.isRecomposition {
                        Label("Your weight is flat but your waist is shrinking. That is body recomposition — you are losing fat and holding muscle, and the scale cannot see it.",
                              systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(Theme.color(for: .improving))
                        .fixedSize(horizontal: false, vertical: true)
                    } else if signal.waistChangeCm == nil {
                        Text("Log your waist on the Watch to unlock this. Weight alone cannot distinguish losing fat from losing muscle.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Not enough measurements yet.").foregroundStyle(.secondary)
            }
        }
    }

    private var alcohol: some View {
        Card("Alcohol", subtitle: "Calories, and the morning after") {
            VStack(alignment: .leading, spacing: 10) {
                if let report, let perWeek = report.alcoholCaloriesPerWeek, perWeek > 0 {
                    HStack(spacing: 28) {
                        figure("Per week", "\(Format.decimal(perWeek)) kcal")
                        if let share = report.alcoholShareOfIntake {
                            figure("Of everything you eat", "\(Int((share * 100).rounded()))%")
                        }
                    }
                }

                if let hangover = model.analytics.hangover, hangover.isMeaningful {
                    Divider()
                    Text("Mornings after a drinking day, against your dry days:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        delta("Resting HR", hangover.restingHeartRateDelta, "bpm", higherIsWorse: true)
                        delta("HRV", hangover.hrvDelta, "ms", higherIsWorse: false)
                        delta("Sleep", hangover.sleepDelta, "h", higherIsWorse: false)
                        delta("Steps", hangover.stepsDelta, "", higherIsWorse: false)
                    }
                    Text("Based on \(hangover.drinkingDays) drinking days and \(hangover.dryDays) dry ones.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Once there are a couple of weeks of drinking and dry days, this compares the mornings after.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func delta(_ title: String, _ value: Double?, _ unit: String, higherIsWorse: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let value {
                let isBad = higherIsWorse ? value > 0 : value < 0
                Text(String(format: "%+.1f", value) + (unit.isEmpty ? "" : " \(unit)"))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(abs(value) < 0.5 ? Color.secondary
                                     : (isBad ? Theme.color(for: .declining) : Theme.color(for: .improving)))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Occasions

    @ViewBuilder
    private var occasions: some View {
        let impacts = model.analytics.occasions
        if !impacts.isEmpty {
            Card("What each kind of day costs you",
                 subtitle: "Grouped by where you ate, measured against your own average") {
                Table(impacts) {
                    TableColumn("Occasion") { impact in
                        Label(impact.context.title, systemImage: impact.context.symbolName)
                    }
                    TableColumn("Days") { impact in
                        Text("\(impact.dayCount)").monospacedDigit()
                    }
                    .width(60)
                    TableColumn("Calories") { impact in
                        Text(Format.decimal(impact.averageCalories)).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("vs typical") { impact in
                        Text(impact.caloriesVsTypicalDay.map { String(format: "%+.0f", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle((impact.caloriesVsTypicalDay ?? 0) > 200
                                             ? Theme.color(for: .declining) : .secondary)
                    }
                    .width(90)
                    TableColumn("Units") { impact in
                        Text(impact.averageUKUnits > 0
                             ? Format.decimal(impact.averageUKUnits, fractionDigits: 1) : "—")
                        .monospacedDigit()
                    }
                    .width(70)
                    TableColumn("Next-day HRV") { impact in
                        Text(impact.nextDayHRVDelta.map { String(format: "%+.0f ms", $0) } ?? "—")
                            .monospacedDigit()
                            .foregroundStyle((impact.nextDayHRVDelta ?? 0) < -3
                                             ? Theme.color(for: .declining) : .secondary)
                    }
                    .width(110)
                    TableColumn("Next-day RHR") { impact in
                        Text(impact.nextDayRestingHeartRateDelta.map { String(format: "%+.1f bpm", $0) } ?? "—")
                            .monospacedDigit()
                    }
                    .width(110)
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
        }
    }

    private var visibleDays: [EnergyDay] {
        guard let report else { return [] }
        guard let days = range.days, let last = report.days.last?.day else { return report.days }
        let cutoff = last.adding(days: -days)
        return report.days.filter { $0.day >= cutoff }
    }
}
