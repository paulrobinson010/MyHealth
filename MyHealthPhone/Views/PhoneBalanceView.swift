import SwiftUI
import HealthCore
import HealthIntelligence

/// The deficit, and — more usefully — whether you should believe it.
///
/// A deficit is a small difference between two large, error-prone numbers, so
/// it inherits the worst of both. Quoting one without saying what could be
/// wrong with it is how a calorie tracker becomes confidently useless, so the
/// integrity audit gets equal billing with the figure itself.
struct PhoneBalanceView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                if let integrity = model.integrity {
                    headline(integrity)
                    findings(integrity)
                } else {
                    Section {
                        Text("Reading your health data…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let report = model.energy {
                    figures(report)
                }
            }
            .navigationTitle("Energy Balance")
            .refreshable { await model.refreshBalance() }
        }
    }

    @ViewBuilder
    private func headline(_ integrity: DeficitIntegrity) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let deficit = integrity.dailyDeficit {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(String(format: "%.0f", abs(deficit)))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .foregroundStyle(integrity.isActionable ? .primary : .secondary)
                        Text(deficit >= 0 ? "kcal deficit / day" : "kcal surplus / day")
                            .foregroundStyle(.secondary)
                    }
                    if let range = integrity.uncertaintyRange {
                        Text(String(format: "Somewhere between %.0f and %.0f — a plain error bar, not a statistical interval.",
                                    range.lowerBound, range.upperBound))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not enough logged to compute a deficit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Label(integrity.confidence.title, systemImage: symbol(for: integrity.confidence))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(colour(for: integrity.confidence))
            }
            .padding(.vertical, 4)
        } footer: {
            Text("\(integrity.loggedDays) of \(integrity.totalDays) days logged · \(Int(integrity.verifiedCalorieShare * 100))% of calories from looked-up figures rather than estimates.")
        }
    }

    @ViewBuilder
    private func findings(_ integrity: DeficitIntegrity) -> some View {
        if !integrity.findings.isEmpty {
            Section("What could be wrong with this number") {
                ForEach(integrity.findings) { finding in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(finding.message, systemImage: symbol(for: finding.impact))
                            .font(.callout)
                            .foregroundStyle(colour(for: finding.impact))
                        if let remedy = finding.remedy {
                            Text(remedy)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func figures(_ report: EnergyBalanceReport) -> some View {
        Section("The numbers") {
            row("Eaten", report.averageIntake.map { "\(Int($0)) kcal/day" })
            row("Burned (device)", report.averageExpenditure.map { "\(Int($0)) kcal/day" })
            if report.isCalibrationTrustworthy,
               let maintenance = report.calibratedMaintenanceCalories {
                row("True maintenance", "\(Int(maintenance)) kcal/day")
                if let bias = report.expenditureBias, abs(bias) > 75 {
                    row("Device error", String(format: "%+.0f kcal/day", bias))
                }
            }
            row("Predicted change",
                report.predictedWeightChangeKg.map { String(format: "%+.1f kg", $0) })
            row("Actual change",
                report.actualWeightChangeKg.map { String(format: "%+.1f kg", $0) })
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "—").foregroundStyle(.secondary).monospacedDigit()
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
        case .solid: return .green
        case .indicative: return .orange
        case .unreliable: return .red
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
        case .blocking: return .red
        case .caution: return .orange
        case .note: return .secondary
        }
    }
}
