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

struct PhoneRootView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        TabView {
            PhoneTodayView()
                .tabItem { Label("Today", systemImage: "square.grid.2x2") }
            PhoneLogView()
                .tabItem { Label("Log", systemImage: "text.bubble") }
            PhoneSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
