import Foundation
import SwiftUI
import HealthCore
import HealthIntelligence

/// Precomputed analysis of the loaded database.
///
/// Building the fitness index over a decade of days is hundreds of thousands of
/// window rollups, so it happens once off the main actor and every screen reads
/// the result rather than recomputing on each redraw.
struct Analytics: Sendable {
    var fitnessScores: [FitnessScore] = []
    var standing: FitnessStanding?
    var months: [RankedPeriod] = []
    var quarters: [RankedPeriod] = []
    var years: [RankedPeriod] = []
    var topMovers: [MetricTrend] = []
    var componentAverages: [FitnessComponent] = []
    var energy: EnergyBalanceReport?
    var composition: EnergyBalance.BodyCompositionSignal?
    var occasions: [OccasionImpact] = []
    var hangover: OccasionAnalysis.HangoverProfile?
    var correlations: [Correlation] = []
    var briefing: FitnessNarrator.Briefing?

    static func build(from database: HealthDatabase, log: FoodLog) -> Analytics {
        let index = FitnessIndex(database: database)
        let scores = index.history()
        let recent = scores.suffix(90).map { $0 }
        let standing = Rankings.standing(from: scores)
        let components = Rankings.componentAverages(from: recent)
        let movers = TrendAnalysis.topMovers(in: database, window: 28, limit: 6)

        // The last 90 days is the window worth reconciling: long enough for a
        // weight trend to be real, short enough to describe how you live now.
        let recentRange = database.dateRange.map {
            max($0.upperBound.adding(days: -89), $0.lowerBound)...$0.upperBound
        }
        let energy = EnergyBalance.report(for: database, range: recentRange)
        let composition = EnergyBalance.bodyComposition(for: database, range: recentRange)

        return Analytics(
            fitnessScores: scores,
            standing: standing,
            months: Rankings.rankedPeriods(from: scores, bucket: .month, minimumDays: 10),
            quarters: Rankings.rankedPeriods(from: scores, bucket: .quarter, minimumDays: 25),
            years: Rankings.rankedPeriods(from: scores, bucket: .year, minimumDays: 60),
            topMovers: movers,
            componentAverages: components,
            energy: energy,
            composition: composition,
            occasions: OccasionAnalysis.impacts(log: log, database: database),
            hangover: OccasionAnalysis.hangoverProfile(for: database),
            correlations: CorrelationAnalysis.strongestRelationships(
                for: .alcoholGrams, in: database, lags: [0, 1], limit: 6),
            briefing: FitnessNarrator.brief(standing: standing,
                                            components: components,
                                            trends: movers,
                                            energy: energy,
                                            composition: composition))
    }
}

enum LoadState: Equatable {
    case idle
    case working(fraction: Double, message: String)
    case failed(String)

    var isWorking: Bool { if case .working = self { return true }; return false }
}

/// Where the data in the app came from.
enum DataSourceKind: String, Codable {
    case healthKit
    case exportFile
    case sample

    var title: String {
        switch self {
        case .healthKit: return "HealthKit"
        case .exportFile: return "Health export"
        case .sample: return "Sample data"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var database: HealthDatabase?
    @Published private(set) var analytics = Analytics()
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var sourceKind: DataSourceKind?
    @Published var lastError: String?

    /// How far back to pull when syncing from HealthKit.
    @Published var healthKitHistoryYears: Int = Defaults.healthKitHistoryYears {
        didSet { Defaults.healthKitHistoryYears = healthKitHistoryYears }
    }
    @Published var autoSyncOnLaunch: Bool = Defaults.autoSyncOnLaunch {
        didSet { Defaults.autoSyncOnLaunch = autoSyncOnLaunch }
    }
    /// Opt-in. Off by default, because switching it on means food names leave
    /// the machine.
    @Published var allowNetworkLookups: Bool = Defaults.allowNetworkLookups {
        didSet { Defaults.allowNetworkLookups = allowNetworkLookups }
    }
    @Published var foodDataCentralKey: String = Defaults.foodDataCentralKey {
        didSet { Defaults.foodDataCentralKey = foodDataCentralKey }
    }
    @Published private(set) var isResolvingNutrition = false
    @Published private(set) var lastResolutionReport: ResolutionQueue.Report?

    @Published private(set) var foodLog = FoodLog()
    /// Prose written by Apple Intelligence, when it is available.
    @Published private(set) var narrative: String?

    private let store: HealthStore
    private var syncService: LogSyncService?
    /// Health metrics arriving from the iPhone and iPad. This is how the Mac
    /// sees activity at all: Apple does not publish the HealthKit entitlement
    /// for macOS, so nothing here can read a health store directly.
    private var metricSync: MetricSyncService?
    @Published private(set) var syncSummary = "Not synced yet"
    @Published private(set) var metricSyncSummary = "Not synced yet"
    @Published private(set) var syncIsHealthy = true
    @Published private(set) var deficitIntegrity: DeficitIntegrity?
    private let coach = HealthCoach()
    private var logChangeObserver: NSObjectProtocol?
    private let importService = ImportService()
    private let cancellation = CancellationFlag()
    private var folderWatcher: FolderWatcher?

    /// Must match the container in `Config/*.entitlements` and in the phone
    /// and watch models, on all three targets. They are one container.
    static let cloudContainer = "iCloud.com.example.MyHealth"

    var healthKitAvailability: HealthKitAvailability { HealthKitBridge.availability }

    init() {
        do {
            store = HealthStore(fileURL: try HealthStore.defaultURL())
        } catch {
            // Fall back to a temporary location rather than refusing to launch;
            // the user can still import and look at data this session.
            store = HealthStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MyHealth-health-database.plist"))
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard database == nil, !loadState.isWorking else { return }
        observeWatchLogs()
        Task { await loadFromDisk() }
    }

    /// Polls for changes from the Watch and phone.
    ///
    /// CloudKit push notifications are the efficient signal, but they are
    /// best-effort and a dropped one would mean a pint logged at the bar never
    /// appearing. A slow poll costs almost nothing and removes that failure.
    private func observeWatchLogs() {
        guard logChangeObserver == nil else { return }
        logChangeObserver = NSNull()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                guard let self else { return }
                await self.refreshFoodLogFromSync()
                await self.refreshHealthMetricsFromSync()
            }
        }
    }

    private func loadFromDisk() async {
        await loadFoodLog()
        await openMetricSync()
        do {
            if let stored = try store.load() {
                await apply(stored, kind: stored.sourceFileName == "HealthKit" ? .healthKit : .exportFile, persist: false)
            }
        } catch {
            lastError = "Stored data could not be read (\(error.localizedDescription)). Import again to rebuild it."
        }
        restoreFolderWatcher()
        if autoSyncOnLaunch, healthKitAvailability.isUsable, sourceKind != .sample {
            await syncFromHealthKit(silently: true)
        }
        if autoSyncOnLaunch, sourceKind != .sample {
            await refreshHealthMetricsFromSync()
        }
        await resolvePendingNutrition()
    }

    private func openMetricSync() async {
        guard metricSync == nil else { return }
        do {
            metricSync = MetricSyncService(
                store: store,
                backend: CloudKitSyncBackend(containerIdentifier: Self.cloudContainer,
                                             stream: .healthMetrics),
                stateStore: FileSyncStateStore(
                    fileURL: try FileSyncStateStore.url(named: "metric-sync-state.json")))
        } catch {
            lastError = "Could not open health data sync: \(error.localizedDescription)"
        }
    }

    /// Pulls days and workouts read on the iPhone or iPad, and pushes anything
    /// this Mac imported from an `export.zip` so the phone gets the deep
    /// history it never had room to keep.
    func refreshHealthMetricsFromSync() async {
        guard let metricSync, sourceKind != .sample else { return }
        _ = await metricSync.sync()
        let status = await metricSync.status()
        metricSyncSummary = status.summary

        // HealthDatabase is not Equatable — and should not be, since
        // `importedAt` differs on every construction. Compare what a redraw
        // would actually depend on.
        let incoming = await metricSync.currentDatabase
        guard !incoming.isEmpty,
              incoming.days != database?.days || incoming.workouts != database?.workouts
        else { return }
        database = incoming
        if sourceKind == nil { sourceKind = .healthKit }
        await analyse(incoming)
    }

    private func apply(_ incoming: HealthDatabase, kind: DataSourceKind, persist: Bool) async {
        var merged: HealthDatabase
        if let existing = database, kind != .sample, existing.sourceFileName != "Sample data" {
            merged = importService.merge(existing: existing, incoming: incoming)
        } else {
            merged = incoming
        }

        // Persist before showing, and take what the store came back with. The
        // sync service owns the file: letting it and an import each save their
        // own view is how a day ends up present on screen and absent on disk.
        // Publishing also seeds the other devices with whatever was imported —
        // a decade of export.zip history the phone never had room to keep.
        if persist, kind != .sample {
            if let metricSync {
                merged = await metricSync.publish(merged)
            } else {
                do { try store.save(merged) } catch {
                    lastError = "Could not save the database: \(error.localizedDescription)"
                }
            }
        }

        database = merged
        sourceKind = kind
        loadState = .working(fraction: 0.97, message: "Analysing…")
        await analyse(merged)
    }

    /// Rebuilds every derived figure. Runs off the main actor because the
    /// fitness history alone is hundreds of thousands of window rollups.
    private func analyse(_ database: HealthDatabase) async {
        let log = foodLog
        let combined = database.merging(log)
        let computed = await Task.detached(priority: .userInitiated) {
            Analytics.build(from: combined, log: log)
        }.value

        analytics = computed
        if let energy = computed.energy {
            let recentRange = combined.dateRange.map {
                max($0.upperBound.adding(days: -89), $0.lowerBound)...$0.upperBound
            }
            deficitIntegrity = DeficitAudit.audit(report: energy, log: log,
                                                  database: combined, range: recentRange)
        }
        loadState = .idle

        // The written summary is generated from the numbers first and only then
        // handed to the model to phrase, so there is always an answer on screen.
        if let briefing = computed.briefing {
            narrative = briefing.plainText
            let rewritten = await coach.narrate(briefing)
            if rewritten != narrative { narrative = rewritten }
        }
    }

    // MARK: - Nutrition lookup

    var lookupSettings: ResolverFactory.Settings {
        ResolverFactory.Settings(allowNetworkLookups: allowNetworkLookups,
                                 foodDataCentralKey: foodDataCentralKey)
    }

    var lookupCapabilities: [String] {
        ResolverFactory.describeCapabilities(settings: lookupSettings)
    }

    var pendingLookupCount: Int {
        ResolutionQueue(resolver: ResolverFactory.makeResolver(settings: lookupSettings))
            .pending(in: foodLog).count
    }

    /// Finishes off entries that were logged as estimates.
    ///
    /// The same queue runs on the phone. Whichever device gets to an entry
    /// first wins, and because resolution replaces an entry's figures rather
    /// than adding to them, both running at once is harmless.
    func resolvePendingNutrition() async {
        guard !isResolvingNutrition else { return }
        let queue = ResolutionQueue(resolver: ResolverFactory.makeResolver(settings: lookupSettings))
        guard !queue.pending(in: foodLog).isEmpty else { return }

        isResolvingNutrition = true
        defer { isResolvingNutrition = false }

        let snapshot = foodLog
        let (updated, report) = await queue.process(snapshot)
        // Merge rather than assign: the phone may have synced something new
        // while the lookups were running.
        let merged = LogSync.merge(local: foodLog, remote: updated)
        let corrected = merged.entries.filter { $0.provenance != nil }
        foodLog = merged
        if let service = syncService {
            foodLog = await service.replace(with: merged, uploading: corrected)
        }
        lastResolutionReport = report
        if report.improved > 0, let database { await analyse(database) }
    }

    // MARK: - Food log

    private func loadFoodLog() async {
        do {
            let service = LogSyncService(
                store: FoodLogStore(fileURL: try FoodLogStore.defaultURL()),
                backend: CloudKitSyncBackend(containerIdentifier: Self.cloudContainer),
                stateStore: FileSyncStateStore(fileURL: try FileSyncStateStore.defaultURL()))
            syncService = service
            foodLog = await service.currentLog
        } catch {
            lastError = "Could not open the food log: \(error.localizedDescription)"
        }
    }

    /// Pulls anything logged on the Watch or phone, and pushes what is queued.
    func refreshFoodLogFromSync() async {
        guard let service = syncService else { return }
        let before = foodLog.entries.count
        _ = await service.sync()
        foodLog = await service.currentLog
        let status = await service.status()
        syncSummary = status.summary
        syncIsHealthy = status.isHealthy

        if foodLog.entries.count != before, let database { await analyse(database) }
        await resolvePendingNutrition()
    }

    func fullResync() async {
        guard let service = syncService else { return }
        await service.uploadEverything()
        await refreshFoodLogFromSync()
    }

    func addEntries(_ entries: [FoodEntry], context: MealContext, venueName: String?) async {
        guard !entries.isEmpty else { return }
        let occasion = MealOccasion(context: context,
                                    evidence: venueName == nil ? .inferred : .stated,
                                    venueName: venueName,
                                    start: entries.map(\.timestamp).min() ?? Date().timeIntervalSince1970)
        if let service = syncService {
            foodLog = await service.record(entries, occasion: occasion)
        } else {
            for entry in entries { foodLog.add(entry, to: occasion) }
        }
        if let database { await analyse(database) }
        await resolvePendingNutrition()
    }

    func removeEntry(_ id: UUID) async {
        if let service = syncService {
            foodLog = await service.delete(id)
        } else {
            foodLog.remove(entryID: id)
        }
        if let database { await analyse(database) }
    }

    /// Corrects the occasion for a day after the fact — the Mac is where you
    /// fix "that was actually the pub", not the Watch.
    func setContext(_ context: MealContext, venueName: String?, on day: DayKey) async {
        if let index = foodLog.occasions.firstIndex(where: { $0.day == day }) {
            foodLog.occasions[index].context = context
            foodLog.occasions[index].evidence = .stated
            foodLog.occasions[index].venueName = venueName
        } else {
            let entries = foodLog.entries(on: day)
            guard !entries.isEmpty else { return }
            foodLog.occasions.append(MealOccasion(
                context: context,
                evidence: .stated,
                venueName: venueName,
                start: entries.map(\.timestamp).min() ?? day.localDate().timeIntervalSince1970,
                entryIDs: entries.map(\.id)))
            foodLog.occasions.sort { $0.start < $1.start }
        }
        if let service = syncService {
            foodLog = await service.replace(with: foodLog, uploading: [])
        }
        if let database { await analyse(database) }
    }

    // MARK: - HealthKit

    func syncFromHealthKit(silently: Bool = false) async {
        #if canImport(HealthKit)
        guard #available(macOS 26.0, *), healthKitAvailability.isUsable else {
            if !silently { lastError = healthKitAvailability.message }
            return
        }
        cancellation.reset()
        loadState = .working(fraction: 0, message: "Asking HealthKit for permission…")
        let source = HealthKitSource()
        do {
            try await source.requestAuthorization()
            let start = DayKey.today.adding(days: -365 * max(1, healthKitHistoryYears))
            let incoming = try await source.buildDatabase(from: start) { [weak self] progress in
                Task { @MainActor in
                    self?.loadState = .working(fraction: progress.fraction, message: progress.message)
                }
            }
            guard !incoming.isEmpty else {
                loadState = .idle
                if !silently {
                    lastError = "HealthKit returned no samples. Check System Settings › Privacy & Security › Health, and that iCloud Health sync has finished on this Mac."
                }
                return
            }
            await apply(incoming, kind: .healthKit, persist: true)
        } catch {
            loadState = .idle
            if !silently { lastError = error.localizedDescription }
        }
        #else
        if !silently { lastError = healthKitAvailability.message }
        #endif
    }

    // MARK: - File import

    func importExport(at url: URL) async {
        cancellation.reset()
        loadState = .working(fraction: 0, message: "Opening \(url.lastPathComponent)…")

        let service = importService
        let flag = cancellation
        let isCancelled: @Sendable () -> Bool = { flag.isCancelled }
        let report: @Sendable (ImportProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.loadState = .working(fraction: progress.fraction, message: progress.message)
            }
        }

        do {
            let incoming = try await Task.detached(priority: .userInitiated) {
                try service.importDatabase(from: url, progress: report, isCancelled: isCancelled)
            }.value
            await apply(incoming, kind: .exportFile, persist: true)
        } catch {
            loadState = .idle
            if let importError = error as? ImportError, case .cancelled = importError { return }
            lastError = error.localizedDescription
        }
    }

    func cancel() {
        cancellation.cancel()
    }

    func loadSampleData() async {
        loadState = .working(fraction: 0.4, message: "Generating sample history…")
        let sample = await Task.detached(priority: .userInitiated) { SampleData.database(years: 4) }.value
        database = nil
        await apply(sample, kind: .sample, persist: false)
    }

    func eraseStoredData() {
        do {
            try store.delete()
            database = nil
            analytics = Analytics()
            sourceKind = nil
        } catch {
            lastError = "Could not delete the stored database: \(error.localizedDescription)"
        }
    }

    // MARK: - Watched folder

    /// The folder iCloud Drive drops `export.zip` into. When it changes, the
    /// newest export is imported automatically.
    var watchedFolderURL: URL? {
        guard let bookmark = Defaults.watchedFolderBookmark else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale)
    }

    func setWatchedFolder(_ url: URL?) {
        folderWatcher = nil
        guard let url else {
            Defaults.watchedFolderBookmark = nil
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        Defaults.watchedFolderBookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil)
        restoreFolderWatcher()
    }

    private func restoreFolderWatcher() {
        guard let url = watchedFolderURL else { return }
        folderWatcher = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.importNewestExportFromWatchedFolder() }
        }
    }

    func importNewestExportFromWatchedFolder() async {
        guard !loadState.isWorking, let folder = watchedFolderURL else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        let candidates = contents.filter {
            ["zip", "xml"].contains($0.pathExtension.lowercased())
        }
        let newest = candidates.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        guard let newest else { return }
        // Skip a file we have already ingested.
        if let current = database?.sourceFileName, current == newest.lastPathComponent,
           let modified = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let imported = database?.importedAt, modified <= imported {
            return
        }
        await importExport(at: newest)
    }

    // MARK: - Convenience for views

    var hasData: Bool { (database?.isEmpty == false) }

    var latestDay: DayKey? { database?.days.last?.day }

    func trend(for metric: Metric, window: Int = 28) -> MetricTrend? {
        guard let database else { return nil }
        return TrendAnalysis.trend(for: metric, in: database, window: window)
    }
}

/// Cancellation shared with background import work. Deliberately not actor
/// isolated: the parser polls it from whatever thread it happens to be on.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// Thin typed wrapper over UserDefaults. `@AppStorage` only publishes changes
/// inside a View, so preferences owned by the model live here instead.
enum Defaults {
    private static let store = UserDefaults.standard

    static var healthKitHistoryYears: Int {
        get { store.object(forKey: "healthKitHistoryYears") as? Int ?? 10 }
        set { store.set(newValue, forKey: "healthKitHistoryYears") }
    }

    static var autoSyncOnLaunch: Bool {
        get { store.object(forKey: "autoSyncOnLaunch") as? Bool ?? true }
        set { store.set(newValue, forKey: "autoSyncOnLaunch") }
    }

    static var allowNetworkLookups: Bool {
        get { store.bool(forKey: "allowNetworkLookups") }   // opt-in: defaults to false
        set { store.set(newValue, forKey: "allowNetworkLookups") }
    }

    static var foodDataCentralKey: String {
        get { store.string(forKey: "foodDataCentralKey") ?? "" }
        set { store.set(newValue, forKey: "foodDataCentralKey") }
    }

    static var watchedFolderBookmark: Data? {
        get { store.data(forKey: "watchedFolderBookmark") }
        set { store.set(newValue, forKey: "watchedFolderBookmark") }
    }
}
