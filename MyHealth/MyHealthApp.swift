import SwiftUI
import HealthCore

@main
struct MyHealthApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Sync from HealthKit") {
                    Task { await model.syncFromHealthKit() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.healthKitAvailability.isUsable || model.loadState.isWorking)

                Button("Import Health Export…") {
                    Task { await ImportPanel.present(model: model) }
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.loadState.isWorking)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 430)
        }
    }
}

/// Sections in the sidebar.
enum Screen: String, CaseIterable, Identifiable, Hashable {
    case dashboard, coach, fitness, activity, nutrition, trends, workouts, body, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .coach: return "Coach"
        case .nutrition: return "Energy Balance"
        case .fitness: return "Fitness Rank"
        case .activity: return "Activity"
        case .trends: return "Trends"
        case .workouts: return "Workouts"
        case .body: return "Body & Vitals"
        case .data: return "Data Source"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .coach: return "bubble.left.and.text.bubble.right"
        case .nutrition: return "fork.knife"
        case .fitness: return "trophy"
        case .activity: return "flame"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .body: return "heart.text.square"
        case .data: return "externaldrive"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var screen: Screen? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                ForEach(Screen.allCases) { item in
                    Label(item.title, systemImage: item.symbolName).tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 178, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch screen ?? .dashboard {
                case .dashboard: DashboardView()
                case .coach: CoachView()
                case .nutrition: NutritionView()
                case .fitness: FitnessRankView()
                case .activity: ActivityView()
                case .trends: TrendsView()
                case .workouts: WorkoutsView()
                case .body: BodyView()
                case .data: DataSourceView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbarContent }
        }
        .task { model.onAppear() }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.lastError != nil },
                                    set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .overlay(alignment: .top) {
            if case .working(let fraction, let message) = model.loadState {
                ProgressBanner(fraction: fraction, message: message) { model.cancel() }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.loadState)
    }

    @ViewBuilder
    private var sidebarFooter: some View {
        if let database = model.database, let range = database.dateRange {
            VStack(alignment: .leading, spacing: 3) {
                Divider()
                Text(model.sourceKind?.title ?? "Data")
                    .font(.caption.weight(.medium))
                Text("\(Format.day(range.lowerBound, style: .short)) – \(Format.day(range.upperBound, style: .short))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Format.decimal(Double(database.days.count))) days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.syncFromHealthKit() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.healthKitAvailability.isUsable || model.loadState.isWorking)
            .help(model.healthKitAvailability.isUsable
                  ? "Read the latest data from HealthKit"
                  : model.healthKitAvailability.message)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await ImportPanel.present(model: model) }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(model.loadState.isWorking)
            .help("Import an export.zip from the iPhone Health app")
        }
    }
}

struct ProgressBanner: View {
    let fraction: Double
    let message: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: fraction.clamped(to: 0...1))
                .frame(width: 160)
            Text(message)
                .font(.callout)
                .lineLimit(1)
            Button("Cancel", action: onCancel)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
