import SwiftUI
import HealthCore
import HealthUI
import HealthIntelligence

/// The same combined view on iPhone and iPad.
///
/// Identical content to the Mac, laid out a little tighter on a phone. Sharing
/// the view rather than reimplementing it is the point: two screens that claim
/// to show the same thing and quietly disagree are worse than one screen.
struct PhoneProgressView: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var months = 12

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Range", selection: $months) {
                        Text("3M").tag(3)
                        Text("6M").tag(6)
                        Text("1Y").tag(12)
                        Text("All").tag(0)
                    }
                    .pickerStyle(.segmented)

                    if let combined = model.progressModel(monthsBack: months) {
                        BodyAndFitnessView(model: combined, compact: sizeClass != .regular)
                    } else {
                        Text("Reading your health data…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding()
            }
            .navigationTitle("Progress")
            .refreshable { await model.refreshBalance() }
        }
    }
}
