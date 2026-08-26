import Foundation
import SwiftUI
import HealthCore
import HealthIntelligence

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
    /// Publishes HealthKit rollups for the Mac, which has no health store of
    /// its own and cannot be given one. The phone is the authoritative reader:
    /// its HealthKit store already aggregates every device, so the watch
    /// deliberately does not publish and cannot contradict it.
    private var metricSync: MetricSyncService?
    @Published private(set) var syncSummary = "Not synced yet"
    @Published private(set) var metricSyncSummary = "Not synced yet"
    @Published private(set) var syncIsHealthy = true
    @Published private(set) var integrity: DeficitIntegrity?
    @Published private(set) var energy: EnergyBalanceReport?
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

    /// Must match `Config/*.entitlements` and the Mac and watch models.
    static let cloudContainer = "iCloud.com.example.MyHealth"

    func start() async {
        do {
            let service = LogSyncService(
                store: FoodLogStore(fileURL: try FoodLogStore.defaultURL()),
                backend: CloudKitSyncBackend(containerIdentifier: Self.cloudContainer),
                stateStore: FileSyncStateStore(fileURL: try FileSyncStateStore.defaultURL()))
            self.service = service
            log = await service.currentLog

            metricSync = MetricSyncService(
                store: HealthStore(fileURL: try HealthStore.defaultURL()),
                backend: CloudKitSyncBackend(containerIdentifier: Self.cloudContainer,
                                             stream: .healthMetrics),
                stateStore: FileSyncStateStore(
                    fileURL: try FileSyncStateStore.url(named: "metric-sync-state.json")))
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
            integrity = DeficitAudit.audit(report: report, log: log,
                                           database: combined, range: range)
            // Publish the raw HealthKit read, not `combined` — the food log
            // already syncs on its own stream, and sending the derived
            // nutrition metrics too would have the Mac count them twice.
            await publishHealthMetrics(database)
        } catch {
            // Not fatal — logging still works without the balance view.
            energy = nil
        }
    }

    // MARK: - Publishing health metrics

    /// Queues the days that actually changed and pushes them.
    ///
    /// `publish` merges into what is already held and returns only the deltas,
    /// so a routine 90-day read costs one or two records rather than ninety.
    private func publishHealthMetrics(_ database: HealthDatabase) async {
        guard let metricSync else { return }
        _ = await metricSync.publish(database)
        _ = await metricSync.sync()
        metricSyncSummary = await metricSync.status().summary
    }

    /// Reads further back than the rolling window and publishes it, so a Mac
    /// that has never seen an `export.zip` still gets real history. Slow and
    /// battery-hungry, so it is a deliberate action rather than automatic.
    func backfillHealthHistory(years: Int = 10) async {
        guard HealthKitSource.availability.isUsable else {
            lastError = HealthKitSource.availability.message
            return
        }
        let source = HealthKitSource()
        do {
            try await source.requestAuthorization()
            let start = DayKey.today.adding(days: -365 * max(1, years))
            let database = try await source.buildDatabase(from: start)
            await publishHealthMetrics(database)
        } catch {
            lastError = error.localizedDescription
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
