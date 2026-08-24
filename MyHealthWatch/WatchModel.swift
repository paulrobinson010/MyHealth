import Foundation
import SwiftUI
import HealthCore
import HealthIntelligence

@MainActor
final class WatchModel: ObservableObject {

    @Published private(set) var log = FoodLog()
    @Published private(set) var todayTotal = Nutrition.empty
    @Published var lastError: String?
    @Published private(set) var isSaving = false
    /// Set briefly after a successful log so the UI can confirm without a modal.
    @Published var confirmation: String?

    private let writer = HealthKitLogWriter()
    /// Durable locally the moment it is tapped; iCloud when there is a chance.
    /// A watch is offline more often than not, so a log that waited on the
    /// network would be a log nobody trusts.
    private var service: LogSyncService?
    @Published private(set) var syncSummary = ""associated

    var today: DayKey { .today }

    func start() async {
        do {
            let service = LogSyncService(
                store: FoodLogStore(fileURL: try FoodLogStore.defaultURL()),
                backend: CloudKitSyncBackend(containerIdentifier: "iCloud.com.example.MyHealth"),
                stateStore: FileSyncStateStore(fileURL: try FileSyncStateStore.defaultURL()))
            self.service = service
            log = await service.currentLog
        } catch {
            lastError = "Could not open the local log: \(error.localizedDescription)"
        }

        recomputeToday()
        await syncNow()

        do {
            try await writer.requestAuthorization()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Logging

    func logFood(_ preset: FoodPreset, servings: Double) async {
        // Straight from the built-in table, so it is already as good as it
        // gets — no need to trouble the lookup queue with it.
        let entry = FoodEntry(name: preset.name,
                              timestamp: Date().timeIntervalSince1970,
                              servings: servings,
                              nutrition: preset.nutrition,
                              source: .catalogue,
                              resolution: .resolved(NutritionProvenance(source: .builtIn,
                                                                        confidence: 0.75)))
        await record(entry, confirmation: "\(preset.name) logged")
    }

    func logDrink(_ preset: DrinkPreset, servings: Double) async {
        // Alcohol from volume and ABV is arithmetic, not a lookup.
        let entry = FoodEntry(name: preset.name,
                              timestamp: Date().timeIntervalSince1970,
                              servings: servings,
                              nutrition: preset.nutrition,
                              source: .catalogue,
                              resolution: .resolved(NutritionProvenance(source: .computed,
                                                                        confidence: 0.95)))
        let units = preset.ukUnits * servings
        await record(entry, confirmation: String(format: "%.1f units logged", units))
    }

    func logManualCalories(_ kilocalories: Double, name: String = "Quick entry") async {
        let entry = FoodEntry(name: name,
                              timestamp: Date().timeIntervalSince1970,
                              nutrition: Nutrition(kilocalories: kilocalories),
                              source: .manual,
                              resolution: .resolved(NutritionProvenance(source: .manual,
                                                                        confidence: 0.85)))
        await record(entry, confirmation: "\(Int(kilocalories)) kcal logged")
    }

    private func record(_ entry: FoodEntry, confirmation message: String) async {
        isSaving = true
        defer { isSaving = false }

        // The occasion is guessed here and can be corrected later on the Mac;
        // the Watch is the wrong place to interrogate someone mid-pint.
        let guess = classify(adding: entry)
        let occasion = currentOccasion(for: guess, at: entry.date)
        if let service {
            log = await service.record([entry], occasion: occasion)
        } else {
            log.add(entry, to: occasion)
        }
        recomputeToday()

        do {
            try await writer.write(entry)
            confirmation = message
        } catch {
            // The local log still holds it, so nothing is lost — but say so
            // rather than showing a tick over a failed write.
            lastError = "Saved locally, but HealthKit refused it: \(error.localizedDescription)"
        }
    }

    func logBody(massKg: Double?, waistCm: Double?) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await writer.writeBody(massKg: massKg, waistCm: waistCm)
            var parts: [String] = []
            if let massKg { parts.append(String(format: "%.1f kg", massKg)) }
            if let waistCm { parts.append(String(format: "%.0f cm", waistCm)) }
            confirmation = parts.joined(separator: " · ") + " logged"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func undoLast() async {
        guard let last = log.entries.last else { return }
        if let service {
            log = await service.delete(last.id)
        } else {
            log.remove(entryID: last.id)
        }
        recomputeToday()
        confirmation = "Removed \(last.name)"
        // The HealthKit sample stays; deleting it needs share authorisation for
        // that exact sample, and silently failing would be worse than an
        // honest note here.
    }

    // MARK: - Derived

    var todayEntries: [FoodEntry] { log.entries(on: today).reversed() }

    var todayUKUnits: Double { AlcoholUnits.ukUnits(grams: todayTotal.alcoholGrams) }

    var recentFoods: [FoodPreset] {
        let names = Set(log.mostFrequent(limit: 8))
        let frequent = FoodPreset.catalogue.filter { names.contains($0.name) }
        return frequent.isEmpty ? Array(FoodPreset.catalogue.prefix(8)) : frequent
    }

    var recentDrinks: [DrinkPreset] {
        let names = Set(log.mostFrequent(limit: 20))
        let frequent = DrinkPreset.standard.filter { names.contains($0.name) }
        return frequent.isEmpty ? Array(DrinkPreset.standard.prefix(6)) : frequent
    }

    private func recomputeToday() {
        todayTotal = log.total(on: today)
    }

    private func classify(adding entry: FoodEntry) -> ContextClassifier.Guess {
        // Judge the occasion from the last few hours, not just this one item —
        // the third pint is what makes it a pub, and the first told you nothing.
        let window = entry.timestamp - 4 * 3600
        let recent = log.entries.filter { $0.timestamp >= window } + [entry]
        let total = recent.reduce(Nutrition.empty) { $0 + $1.total }
        let drinks = recent.filter { $0.nutrition.alcoholGrams > 0 }.reduce(0.0) { $0 + $1.servings }
        let calendar = Calendar.current
        return ContextClassifier.classify(.init(
            alcoholGrams: total.alcoholGrams,
            totalCalories: total.kilocalories,
            distinctDrinks: Int(drinks.rounded()),
            itemCount: recent.count,
            hour: calendar.component(.hour, from: entry.date),
            weekday: calendar.component(.weekday, from: entry.date) - 1))
    }

    /// Reuses an occasion that is still running rather than starting a new one
    /// for every round.
    private func currentOccasion(for guess: ContextClassifier.Guess, at date: Date) -> MealOccasion {
        let cutoff = date.timeIntervalSince1970 - 4 * 3600
        if var open = log.occasions.last, open.start >= cutoff {
            if open.evidence == .inferred, guess.confidence > 0.6 {
                open.context = guess.context
            }
            return open
        }
        return MealOccasion(context: guess.context,
                            evidence: .inferred,
                            start: date.timeIntervalSince1970)
    }

    /// Pushes and pulls. Cheap enough to run on wake, and the only way a pint
    /// logged at the bar reaches the phone before the phone is next opened.
    func syncNow() async {
        guard let service else { return }
        _ = await service.sync()
        log = await service.currentLog
        let status = await service.status()
        syncSummary = status.summary
        recomputeToday()
    }
}
