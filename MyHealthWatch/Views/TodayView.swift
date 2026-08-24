import SwiftUI
import HealthCore

struct TodayView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(model.todayTotal.kilocalories))")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                    Text("kcal today").font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    macro("P", model.todayTotal.proteinGrams, .green)
                    macro("C", model.todayTotal.carbohydrateGrams, .orange)
                    macro("F", model.todayTotal.fatGrams, .yellow)
                }

                if model.todayTotal.alcoholGrams > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "mug.fill").font(.caption2)
                        Text(String(format: "%.1f UK units", model.todayUKUnits))
                            .font(.caption)
                        Text("· \(Int(model.todayTotal.alcoholKilocalories)) kcal")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.orange)
                }

                if !model.todayEntries.isEmpty {
                    Divider()
                    ForEach(model.todayEntries.prefix(8)) { entry in
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.servings > 1
                                 ? "\(formatted(entry.servings))× \(entry.name)" : entry.name)
                            .font(.caption2)
                            .lineLimit(2)
                            Spacer(minLength: 4)
                            Text("\(Int(entry.total.kilocalories))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Undo last", systemImage: "arrow.uturn.backward") {
                        Task { await model.undoLast() }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                } else {
                    Text("Nothing logged yet. Swipe down to add.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Today")
    }

    private func macro(_ label: String, _ grams: Double, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(Int(grams))g").font(.caption.monospacedDigit().weight(.medium))
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
    }

    private func formatted(_ servings: Double) -> String {
        abs(servings - servings.rounded()) < 0.01
            ? String(Int(servings.rounded()))
            : String(format: "%.1f", servings)
    }
}
