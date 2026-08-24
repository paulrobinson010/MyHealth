import Foundation
import HealthCore
#if canImport(HealthKit)
import HealthKit
#endif

enum WriterError: LocalizedError {
    case unavailable
    case notAuthorised

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this watch."
        case .notAuthorised:
            return "MyHealth is not allowed to write health data. Check the Watch app's privacy settings on your iPhone."
        }
    }
}

/// Writes logged food, drink and body measurements into HealthKit on the Watch.
///
/// Writing rather than keeping our own store is deliberate: it means the data
/// shows up in the Health app alongside everything else, and it reaches the Mac
/// through Apple's sync without this project needing a server or an account.
actor HealthKitWriter {

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    private static var shareTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for identifier: HKQuantityTypeIdentifier in [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates, .dietaryFatTotal,
            .dietaryFiber, .dietarySugar, .numberOfAlcoholicBeverages,
            .bodyMass, .waistCircumference
        ] {
            types.insert(HKQuantityType(identifier))
        }
        return types
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WriterError.unavailable }
        try await store.requestAuthorization(toShare: HealthKitWriter.shareTypes,
                                             read: Set<HKObjectType>())
    }

    func write(_ entry: FoodEntry) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WriterError.unavailable }
        let nutrition = entry.total
        let date = entry.date
        var samples: [HKSample] = []

        func add(_ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double) {
            guard value > 0 else { return }
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            samples.append(HKQuantitySample(type: HKQuantityType(identifier),
                                            quantity: quantity,
                                            start: date,
                                            end: date,
                                            metadata: [HKMetadataKeyFoodType: entry.name]))
        }

        add(.dietaryEnergyConsumed, .kilocalorie(), nutrition.kilocalories)
        add(.dietaryProtein, .gram(), nutrition.proteinGrams)
        add(.dietaryCarbohydrates, .gram(), nutrition.carbohydrateGrams)
        add(.dietaryFatTotal, .gram(), nutrition.fatGrams)
        add(.dietaryFiber, .gram(), nutrition.fibreGrams)
        add(.dietarySugar, .gram(), nutrition.sugarGrams)

        // HealthKit counts US standard drinks, so the conversion happens here
        // rather than anywhere the user can see it.
        if nutrition.alcoholGrams > 0 {
            add(.numberOfAlcoholicBeverages, .count(),
                AlcoholUnits.standardDrinks(grams: nutrition.alcoholGrams))
        }

        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }

    func writeBody(massKg: Double?, waistCm: Double?) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WriterError.unavailable }
        let now = Date()
        var samples: [HKSample] = []

        if let massKg, massKg > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.bodyMass),
                quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: massKg),
                start: now, end: now))
        }
        if let waistCm, waistCm > 0 {
            samples.append(HKQuantitySample(
                type: HKQuantityType(.waistCircumference),
                quantity: HKQuantity(unit: .meterUnit(with: .centi), doubleValue: waistCm),
                start: now, end: now))
        }

        guard !samples.isEmpty else { return }
        try await store.save(samples)
    }
    #else
    func requestAuthorization() async throws { throw WriterError.unavailable }
    func write(_ entry: FoodEntry) async throws { throw WriterError.unavailable }
    func writeBody(massKg: Double?, waistCm: Double?) async throws { throw WriterError.unavailable }
    #endif
}
