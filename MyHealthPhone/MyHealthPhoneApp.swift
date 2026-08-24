import SwiftUI
import HealthCore
import HealthIntelligence

/// The iPhone companion.
///
/// This is where the agentic lookup actually belongs. The phone has the
/// on-device model, a real network connection and a battery that can afford a
/// few round trips — none of which is true of the Watch. So the Watch logs
/// instantly and marks entries pending, and this app finishes the job and syncs
/// the corrected figures back.
@main
struct MyHealthPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environmentObject(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming to the foreground is the natural moment to pick up
            // whatever the Watch logged while the phone was in a pocket.
            if phase == .active {
                Task { await model.refreshAndResolve() }
            }
        }
    }
}

/// One app, two shapes.
///
/// An iPad running a stretched phone layout is a worse iPad app than one that
/// uses the width, and on a 13-inch screen the log and the day's totals want to
/// be visible at the same time — which is exactly how you use it while eating.
struct PhoneRootView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: Section? = .today

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case today, log, balance, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "Today"
            case .log: return "Log"
            case .balance: return "Energy Balance"
            case .settings: return "Settings"
            }
        }

        var symbolName: String {
            switch self {
            case .today: return "square.grid.2x2"
            case .log: return "text.bubble"
            case .balance: return "flame"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(Section.allCases, selection: $section) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.symbolName)
                    }
                }
                .navigationTitle("MyHealth")
                .safeAreaInset(edge: .bottom) { SyncStatusBar() }
            } detail: {
                detail(for: section ?? .today)
            }
        } else {
            TabView {
                PhoneTodayView()
                    .tabItem { Label("Today", systemImage: "square.grid.2x2") }
                PhoneLogView()
                    .tabItem { Label("Log", systemImage: "text.bubble") }
                PhoneBalanceView()
                    .tabItem { Label("Balance", systemImage: "flame") }
                PhoneSettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }
    }

    @ViewBuilder
    private func detail(for section: Section) -> some View {
        switch section {
        case .today: PhoneTodayView()
        case .log: PhoneLogView()
        case .balance: PhoneBalanceView()
        case .settings: PhoneSettingsView()
        }
    }
}

/// Always-visible sync state.
///
/// Hiding sync behind a silent spinner is how people end up trusting a log that
/// has not left the device in a fortnight, so this says plainly what is
/// outstanding.
struct SyncStatusBar: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.syncSummary.contains("waiting")
                  ? "icloud.and.arrow.up" : "checkmark.icloud")
            .font(.caption)
            Text(model.syncSummary)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(model.syncIsHealthy ? .secondary : .orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
