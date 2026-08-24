import Foundation
import HealthCore
#if canImport(HealthKit)
import HealthKit
#endif

public enum WriterError: LocalizedError {
    case unavailable
    case notAuthorised

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "HealthKit is not available on this watch."
        case .notAuthorised:
            return "MyHealth is not allowed to write health data. Check the Watch app's privacy settings on your iPhone."
        }
    }
}

/// Writes logged food, drink and body measurements into HealthKit.
///
/// Shared by the Watch and the iPhone. Writing into HealthKit rather than
/// keeping our own store is deliberate: the data shows up in the Health app
/// alongside everything else, and it reaches the Mac through Apple's own sync
/// without this project needing a server or an account.
///
/// Entries are tagged with a stable UUID in their metadata, so an entry
/// corrected later by the resolution queue can be found and rewritten rather
/// than written twice.
@available(macOS 26.0, iOS 17.0, watchOS 10.0, *)
public actor HealthKitLogWriter {

    public init() {}

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    static var shareTypes: Set<HKSampleType> {
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

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WriterError.unavailable }
        try await store.requestAuthorization(toShare: HealthKitLogWriter.shareTypes,
                                             read: Set<HKObjectType>())
    }

    public func write(_ entry: FoodEntry) async throws {
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
                                            metadata: [
                                                HKMetadataKeyFoodType: entry.name,
                                                HealthKitLogWriter.entryIDKey: entry.id.uuidString
                                            ]))
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

    /// Our own metadata key, so an entry we wrote can be located again.
    public static let entryIDKey = "com.myhealth.entryID"

    /// Replaces the samples previously written for an entry. Used when the
    /// resolution queue corrects a figure — otherwise a re-logged meal would
    /// be counted twice in the Health app.
    public func rewrite(_ entry: FoodEntry) async throws {
        try await deleteSamples(forEntry: entry.id)
        try await write(entry)
    }

    private func deleteSamples(forEntry id: UUID) async throws {
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HealthKitLogWriter.entryIDKey,
            operatorType: .equalTo,
            value: id.uuidString)
        for type in HealthKitLogWriter.shareTypes {
            // A type with nothing to delete throws; that is not a failure here.
            _ = try? await store.deleteObjects(of: type, predicate: predicate)
        }
    }

    public func writeBody(massKg: Double?, waistCm: Double?) async throws {
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
    public static let entryIDKey = "com.myhealth.entryID"
    public func requestAuthorization() async throws { throw WriterError.unavailable }
    public func write(_ entry: FoodEntry) async throws { throw WriterError.unavailable }
    public func rewrite(_ entry: FoodEntry) async throws { throw WriterError.unavailable }
    public func writeBody(massKg: Double?, waistCm: Double?) async throws { throw WriterError.unavailable }
    #endif
}
