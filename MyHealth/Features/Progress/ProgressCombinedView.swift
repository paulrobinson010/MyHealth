import SwiftUI
import HealthCore
import HealthUI

/// The Mac's home for the shared fitness-and-body view.
///
/// Deliberately thin. All the layout and every judgement lives in
/// `BodyAndFitnessView` in the shared package, so the Mac, iPhone and iPad
/// cannot drift apart in what they say about the same data.
struct ProgressView_Combined: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: DateRangeOption = .year
    @State private var policy: UnloggedDayPolicy = .reconcile

    var body: some View {
        if let database = model.database, !database.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Progress").font(.title2.weight(.semibold))
                            Text("Fitness, weight and waist against each other")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DateRangePicker(selection: $range)
                    }

                    Picker("Unlogged days", selection: $policy) {
                        ForEach(UnloggedDayPolicy.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help(policy.explanation)

                    Text(policy.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BodyAndFitnessView(model: buildModel(database))
                }
                .padding(20)
            }
            .navigationTitle("Progress")
        } else {
            NoDataView()
        }
    }

    private func buildModel(_ database: HealthDatabase) -> BodyAndFitnessView.Model {
        BodyAndFitnessView.Model.build(database: database.merging(model.foodLog),
                                       scores: model.analytics.fitnessScores,
                                       range: range.range(in: database),
                                       policy: policy)
    }
}
