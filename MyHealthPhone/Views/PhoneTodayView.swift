import SwiftUI
import HealthCore
import HealthIntelligence

struct PhoneTodayView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(Int(model.todayTotal.kilocalories))")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                        Text("kcal").foregroundStyle(.secondary)
                        Spacer()
                        if model.todayTotal.alcoholGrams > 0 {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(String(format: "%.1f", model.todayUKUnits))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.orange)
                                Text("UK units").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        macro("Protein", model.todayTotal.proteinGrams, .green)
                        macro("Carbs", model.todayTotal.carbohydrateGrams, .orange)
                        macro("Fat", model.todayTotal.fatGrams, .yellow)
                    }
                }

                if let status = model.resolutionStatus {
                    Section {
                        HStack(spacing: 8) {
                            if model.isResolving { ProgressView() }
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        if let report = model.lastReport, abs(report.calorieDelta) >= 20 {
                            Label(String(format: "Lookups changed today's total by %+.0f kcal.",
                                         report.calorieDelta),
                                  systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Logged today") {
                    if model.todayEntries.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.todayEntries) { entry in
                        EntryRow(entry: entry)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            model.remove(model.todayEntries[index].id)
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .refreshable { await model.refreshAndResolve() }
            .toolbar {
                if model.pendingCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.resolvePending() }
                        } label: {
                            Label("\(model.pendingCount)", systemImage: "magnifyingglass")
                        }
                        .disabled(model.isResolving)
                    }
                }
            }
        }
    }

    private func macro(_ label: String, _ grams: Double, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(Int(grams))g").font(.callout.monospacedDigit().weight(.medium))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// One logged item, showing where its numbers came from.
///
/// The provenance badge is the point: an entry sourced from a manufacturer's
/// label and an entry a language model guessed at deserve to look different,
/// and burying that distinction is how a calorie diary quietly becomes fiction.
struct EntryRow: View {
    let entry: FoodEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.servings > 1
                     ? "\(servings) × \(entry.name)" : entry.name)
                .font(.callout)
                Spacer()
                Text("\(Int(entry.total.kilocalories)) kcal")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                badge
                if entry.total.alcoholGrams > 0 {
                    Text(String(format: "%.1f units",
                                AlcoholUnits.ukUnits(grams: entry.total.alcoholGrams)))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }

            if let provenance = entry.provenance, !provenance.issues.isEmpty {
                ForEach(provenance.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var servings: String {
        abs(entry.servings - entry.servings.rounded()) < 0.01
            ? String(Int(entry.servings.rounded()))
            : String(format: "%.1f", entry.servings)
    }

    @ViewBuilder
    private var badge: some View {
        switch entry.resolution {
        case .pending, .none:
            label("Estimate · not checked", "clock", .secondary)
        case .resolved(let provenance):
            label("\(provenance.source.shortTitle) · \(Int(provenance.confidence * 100))%",
                  provenance.isTrustworthy ? "checkmark.seal" : "questionmark.circle",
                  provenance.isTrustworthy ? .green : .orange)
        case .unresolvable:
            label("Estimate · no match found", "questionmark.circle", .secondary)
        }
    }

    private func label(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
    }
}
