import SwiftUI
import HealthCore

/// The Watch companion.
///
/// Everything logged here is written straight into HealthKit on the Watch,
/// which means it reaches the phone and then the Mac through Apple's own sync
/// rather than anything of ours. The names and venues that HealthKit cannot
/// hold travel separately through iCloud's key-value store.
@main
struct MyHealthWatchApp: App {
    @StateObject private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        TabView {
            TodayView()
            LogFoodView()
            LogDrinkView()
            LogBodyView()
        }
        .tabViewStyle(.verticalPage)
    }
}
