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

    private let sync = LogSync(backing: UbiquitousLogStore())
    private var store: FoodLogStore?
    private var observer: NSObjectProtocol?

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
            let store = FoodLogStore(fileURL: try FoodLogStore.defaultURL())
            self.store = store
            if let saved = try store.load() { log = saved }
        } catch {
            lastError = "Could not open the local log: \(error.localizedDescription)"
        }

        observeSync()
        await refreshAndResolve()

        if #available(iOS 17.0, *) {
            do { try await HealthKitLogWriter().requestAuthorization() }
            catch { lastError = error.localizedDescription }
        }
    }

    private func observeSync() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UbiquitousLogStore.didChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshAndResolve() }
            }
    }

    /// Pull whatever the Watch logged, then finish off anything still pending.
    func refreshAndResolve() async {
        if let remote = sync.pull() {
            let merged = LogSync.merge(local: log, remote: remote)
            if merged.entries.count != log.entries.count {
                log = merged
                persist(push: false)
            }
        }
        recomputeToday()
        await resolvePending()
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
        log = LogSync.merge(local: log, remote: updated)
        lastReport = report
        persist()
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
        log.add(entry, to: occasion)
        persist()
        recomputeToday()

        if #available(iOS 17.0, *) {
            do { try await HealthKitLogWriter().write(entry) }
            catch { lastError = "Saved locally, but HealthKit refused it: \(error.localizedDescription)" }
        }

        await resolvePending()
    }

    func remove(_ id: UUID) {
        log.remove(entryID: id)
        persist()
        recomputeToday()
    }

    private func recomputeToday() { todayTotal = log.total(on: today) }

    private func persist(push: Bool = true) {
        do { try store?.save(log) }
        catch { lastError = "Could not save the log: \(error.localizedDescription)" }
        if push { sync.push(log) }
    }
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
