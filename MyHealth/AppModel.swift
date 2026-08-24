import Foundation
import SwiftUI

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

    static func build(from database: HealthDatabase) -> Analytics {
        let index = FitnessIndex(database: database)
        let scores = index.history()
        let recent = scores.suffix(90).map { $0 }
        return Analytics(
            fitnessScores: scores,
            standing: Rankings.standing(from: scores),
            months: Rankings.rankedPeriods(from: scores, bucket: .month, minimumDays: 10),
            quarters: Rankings.rankedPeriods(from: scores, bucket: .quarter, minimumDays: 25),
            years: Rankings.rankedPeriods(from: scores, bucket: .year, minimumDays: 60),
            topMovers: TrendAnalysis.topMovers(in: database, window: 28, limit: 6),
            componentAverages: Rankings.componentAverages(from: recent))
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

    private let store: HealthStore
    private let importService = ImportService()
    private let cancellation = CancellationFlag()
    private var folderWatcher: FolderWatcher?

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
        Task { await loadFromDisk() }
    }

    private func loadFromDisk() async {
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
    }

    private func apply(_ incoming: HealthDatabase, kind: DataSourceKind, persist: Bool) async {
        let merged: HealthDatabase
        if let existing = database, kind != .sample, existing.sourceFileName != "Sample data" {
            merged = importService.merge(existing: existing, incoming: incoming)
        } else {
            merged = incoming
        }

        database = merged
        sourceKind = kind
        loadState = .working(fraction: 0.97, message: "Analysing…")

        let computed = await Task.detached(priority: .userInitiated) {
            Analytics.build(from: merged)
        }.value

        analytics = computed
        loadState = .idle

        if persist, kind != .sample {
            do { try store.save(merged) } catch {
                lastError = "Could not save the database: \(error.localizedDescription)"
            }
        }
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

    static var watchedFolderBookmark: Data? {
        get { store.data(forKey: "watchedFolderBookmark") }
        set { store.set(newValue, forKey: "watchedFolderBookmark") }
    }
}
