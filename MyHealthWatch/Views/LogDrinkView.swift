import SwiftUI
import HealthCore

struct LogDrinkView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        List {
            if model.todayTotal.alcoholGrams > 0 {
                Section {
                    HStack {
                        Text(String(format: "%.1f units", model.todayUKUnits))
                            .font(.headline)
                        Spacer()
                        Text("\(Int(model.todayTotal.alcoholKilocalories)) kcal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !model.recentDrinks.isEmpty {
                Section("Usual") {
                    ForEach(model.recentDrinks) { preset in row(preset) }
                }
            }

            Section("All") {
                ForEach(DrinkPreset.standard) { preset in row(preset) }
            }
        }
        .navigationTitle("Drink")
        .overlay(alignment: .bottom) { ConfirmationBar() }
    }

    private func row(_ preset: DrinkPreset) -> some View {
        Button {
            Task { await model.logDrink(preset, servings: 1) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.caption).lineLimit(2)
                Text(String(format: "%.1f units · %d kcal",
                            preset.ukUnits, Int(preset.nutrition.kilocalories)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Log a round of 2") {
                Task { await model.logDrink(preset, servings: 2) }
            }
            Button("Log a half") {
                Task { await model.logDrink(preset, servings: 0.5) }
            }
        }
    }
}
