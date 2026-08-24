import SwiftUI
import HealthCore

struct LogFoodView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var meal: FoodPreset.Meal = LogFoodView.mealForNow()
    @State private var manualCalories = 500.0
    @State private var showingManual = false

    var body: some View {
        List {
            if !model.recentFoods.isEmpty {
                Section("Frequent") {
                    ForEach(model.recentFoods) { preset in
                        row(preset)
                    }
                }
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(FoodPreset.Meal.allCases, id: \.self) { option in
                        Label(option.title, systemImage: option.symbolName).tag(option)
                    }
                }
                ForEach(FoodPreset.catalogue.filter { $0.meal == meal }) { preset in
                    row(preset)
                }
            }

            Section {
                Button {
                    showingManual = true
                } label: {
                    Label("Quick calories", systemImage: "number")
                }
            }
        }
        .navigationTitle("Food")
        .sheet(isPresented: $showingManual) { manualSheet }
        .overlay(alignment: .bottom) { ConfirmationBar() }
    }

    private func row(_ preset: FoodPreset) -> some View {
        Button {
            Task { await model.logFood(preset, servings: 1) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.caption).lineLimit(2)
                Text("\(Int(preset.nutrition.kilocalories)) kcal · \(preset.servingDescription)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        // A long press logs a double helping without needing another screen.
        .contextMenu {
            Button("Log 2 servings") {
                Task { await model.logFood(preset, servings: 2) }
            }
            Button("Log half") {
                Task { await model.logFood(preset, servings: 0.5) }
            }
        }
    }

    private var manualSheet: some View {
        VStack(spacing: 10) {
            Text("\(Int(manualCalories)) kcal")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .focusable()
                .digitalCrownRotation($manualCalories, from: 0, through: 2_500, by: 25,
                                      sensitivity: .medium)
            Button("Log") {
                Task { await model.logManualCalories(manualCalories) }
                showingManual = false
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { showingManual = false }
                .buttonStyle(.plain)
                .font(.caption2)
        }
        .padding()
    }

    private static func mealForNow() -> FoodPreset.Meal {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<11: return .breakfast
        case 11..<15: return .lunch
        case 15..<18: return .snack
        default: return .dinner
        }
    }
}

/// Brief confirmation after a log, so nothing needs dismissing mid-round.
struct ConfirmationBar: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        if let confirmation = model.confirmation {
            Text(confirmation)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.green.opacity(0.85), in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: confirmation) {
                    try? await Task.sleep(for: .seconds(2))
                    model.confirmation = nil
                }
        }
    }
}
