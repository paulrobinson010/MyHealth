import Foundation
import SwiftUI
import HealthCore
import HealthIntelligence
import HealthUI

@MainActor
final class PhoneModel: ObservableObject {

    @Published private(set) var log = FoodLog()
    @Published private(set) var todayTotal = Nutrition.empty
    @Published private(set) var isResolving = false
    @Published private(set) var resolutionStatus: String?
    @Published private(set) var lastReport: ResolutionQueue.Report?
    @Published var lastError: String?

    @Published var allowNetworkLookups: Bool = PhoneDefaults.allowNetworkLookups {
        didSet { PhoneDefaults.allowNetworkLookups = allowNetworkLookups }
    }
    @Published var foodDataCentralKey: String = PhoneDefaults.foodDataCentralKey {
        didSet { PhoneDefaults.foodDataCentralKey = foodDataCentralKey }
    }

    /// Durable local write first, iCloud after — never the other way round.
    private var service: LogSyncService?
    @Published private(set) var syncSummary = "Not synced yet"
    @Published private(set) var syncIsHealthy = true
    @Published private(set) var integrity: DeficitIntegrity?
    @Published private(set) var energy: EnergyBalanceReport?
    @Published private(set) var healthDatabase: HealthDatabase?
    @Published private(set) var fitnessScores: [FitnessScore] = []
    private var syncTimer: Task<Void, Never>?

    var today: DayKey { .today }
    var todayEntries: [FoodEntry] { log.entries(on: today).reversed() }
    var todayUKUnits: Double { AlcoholUnits.ukUnits(grams: todayTotal.alcoholGrams) }
    var pendingCount: Int { queue.pending(in: log).count }

    var settings: ResolverFactory.Settings {
        ResolverFactory.Settings(allowNetworkLookups: allowNetworkLookups,
                                 foodDataCentralKey: foodDataCentralKey)
    }

    private var queue: ResolutionQueue {
        ResolutionQueue(resolver: ResolverFactory.makeResolver(settings: settings))
    }

    var capabilities: [String] { ResolverFactory.describeCapabilities(settings: settings) }

    // MARK: - Lifecycle

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
        await refreshAndResolve()
        startPeriodicSync()

        do { try await HealthKitLogWriter().requestAuthorization() }
        catch { lastError = error.localizedDescription }
    }

    /// A periodic pull as well as an on-foreground one.
    ///
    /// CloudKit push notifications are the efficient way to hear about a change
    /// from another device, but they are best-effort — they get dropped, and a
    /// dropped notification would mean a pint logged on the Watch never showing
    /// up. A slow poll is the belt to that braces.
    private func startPeriodicSync() {
        syncTimer?.cancel()
        syncTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.refreshAndResolve()
            }
        }
    }

    /// Pull whatever another device logged, then finish off anything pending.
    func refreshAndResolve() async {
        guard let service else { return }
        let result = await service.sync()
        log = await service.currentLog
        let status = await service.status()
        syncSummary = status.summary
        syncIsHealthy = status.isHealthy

        if let error = result.error, !error.isTransient {
            lastError = error.localizedDescription
        }

        recomputeToday()
        await resolvePending()
        await refreshBalance()
    }

    /// The combined fitness-and-body model, built from whatever has been read.
    func progressModel(monthsBack months: Int) -> BodyAndFitnessView.Model? {
        guard let database = healthDatabase else { return nil }
        let range: ClosedRange<DayKey>? = months > 0
            ? DayKey.today.adding(days: -months * 30)...DayKey.today
            : nil
        return BodyAndFitnessView.Model.build(database: database.merging(log),
                                              scores: fitnessScores,
                                              range: range)
    }

    /// Recomputes the deficit and, more importantly, whether it can be trusted.
    func refreshBalance() async {
        guard HealthKitSource.availability.isUsable else { return }
        let source = HealthKitSource()
        do {
            try await source.requestAuthorization()
            let start = DayKey.today.adding(days: -89)
            let database = try await source.buildDatabase(from: start)
            let combined = database.merging(log)
            let range = start...DayKey.today
            let report = EnergyBalance.report(for: combined, range: range)
            energy = report
            healthDatabase = database
            integrity = DeficitAudit.audit(report: report, log: log,
                                           database: combined, range: range)

            // The index is the expensive part, so it runs off the main actor.
            fitnessScores = await Task.detached(priority: .utility) {
                FitnessIndex(database: combined).history(stride: 3)
            }.value
        } catch {
            // Not fatal — logging still works without the balance view.
            energy = nil
        }
    }

    // MARK: - Resolution

    func resolvePending() async {
        guard !isResolving else { return }
        let outstanding = queue.pending(in: log)
        guard !outstanding.isEmpty else {
            resolutionStatus = nil
            return
        }

        isResolving = true
        resolutionStatus = "Looking up \(outstanding.count) item\(outstanding.count == 1 ? "" : "s")…"
        defer { isResolving = false }

        let working = queue
        let snapshot = log
        let (updated, report) = await working.process(snapshot) { [weak self] done, total in
            Task { @MainActor in
                self?.resolutionStatus = "Looking up \(done) of \(total)…"
            }
        }

        // Anything logged while the lookup was running has to survive it, so
        // merge rather than assign.
        let merged = LogSync.merge(local: log, remote: updated)
        let corrected = merged.entries.filter { entry in
            outstanding.contains { $0.id == entry.id } && entry.provenance != nil
        }
        log = merged
        if let service { _ = await service.replace(with: merged, uploading: corrected) }
        lastReport = report
        recomputeToday()

        // The Health app copy has to follow the correction, or the deficit
        // maths quietly runs on the superseded number.
        if report.improved > 0, #available(iOS 17.0, *) {
            let writer = HealthKitLogWriter()
            for entry in updated.entries where entry.provenance != nil {
                guard outstanding.contains(where: { $0.id == entry.id }) else { continue }
                try? await writer.rewrite(entry)
            }
        }

        resolutionStatus = report.didAnything
            ? "Updated \(report.improved) item\(report.improved == 1 ? "" : "s")"
            : nil
    }

    // MARK: - Logging

    func log(_ entry: FoodEntry, context: MealContext?) async {
        var entry = entry
        if entry.resolution == nil { entry.resolution = .pending }

        let occasion = context.map {
            MealOccasion(context: $0, evidence: .stated, start: entry.timestamp)
        }

        // Durable locally before anything else is attempted, so a dead network
        // or a crash mid-write cannot lose a meal.
        if let service {
            log = await service.record([entry], occasion: occasion)
        } else {
            log.add(entry, to: occasion)
        }
        recomputeToday()

        do { try await HealthKitLogWriter().write(entry) }
        catch { lastError = "Saved locally, but HealthKit refused it: \(error.localizedDescription)" }

        await resolvePending()
        Task { await refreshAndResolve() }
    }

    func remove(_ id: UUID) async {
        if let service {
            log = await service.delete(id)
        } else {
            log.remove(entryID: id)
        }
        recomputeToday()
    }

    func fullResync() async {
        guard let service else { return }
        await service.uploadEverything()
        await refreshAndResolve()
    }

    private func recomputeToday() { todayTotal = log.total(on: today) }
}

enum PhoneDefaults {
    private static let store = UserDefaults.standard

    static var allowNetworkLookups: Bool {
        get { store.bool(forKey: "allowNetworkLookups") }   // opt-in: defaults to false
        set { store.set(newValue, forKey: "allowNetworkLookups") }
    }

    static var foodDataCentralKey: String {
        get { store.string(forKey: "foodDataCentralKey") ?? "" }
        set { store.set(newValue, forKey: "foodDataCentralKey") }
    }
}
