import SwiftUI
import Charts

struct WorkoutsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: DateRangeOption = .year
    @State private var activityFilter: String = "All"
    @State private var sortOrder = [KeyPathComparator(\WorkoutSummary.start, order: .reverse)]

    var body: some View {
        if let database = model.database, !database.workouts.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    HStack {
                        Picker("Activity", selection: $activityFilter) {
                            Text("All activities").tag("All")
                            ForEach(activityNames(database), id: \.self) { name in
                                Text(WorkoutActivity(rawValue: name).title).tag(name)
                            }
                        }
                        .frame(width: 240)
                        Spacer()
                        DateRangePicker(selection: $range)
                    }

                    summary(database)
                    volumeChart(database)
                    breakdown(database)
                    list(database)
                }
                .padding(20)
            }
            .navigationTitle("Workouts")
        } else if model.database != nil {
            EmptyStateView(symbolName: "figure.run",
                           title: "No workouts recorded",
                           message: "Nothing in this data set has workout samples. Logged workouts from an Apple Watch or a third-party app will show up here.")
        } else {
            NoDataView()
        }
    }

    // MARK: - Sections

    private func summary(_ database: HealthDatabase) -> some View {
        let workouts = filtered(database)
        let minutes = workouts.reduce(0) { $0 + $1.durationMinutes }
        let energy = workouts.reduce(0) { $0 + ($1.energyKcal ?? 0) }
        let distance = workouts.reduce(0) { $0 + ($1.distanceKm ?? 0) }
        let weeks = max(1.0, Double(rangeDays(database)) / 7)

        return TileGrid(minimumWidth: 175) {
            StatTile(title: "Workouts", value: Format.decimal(Double(workouts.count)),
                     caption: String(format: "%.1f per week", Double(workouts.count) / weeks),
                     symbolName: "figure.run", tint: Theme.color(for: .activity))
            StatTile(title: "Total time", value: Format.duration(minutes: minutes),
                     caption: "\(Format.duration(minutes: minutes / weeks)) per week",
                     symbolName: "stopwatch", tint: Theme.color(for: .activity))
            StatTile(title: "Energy", value: "\(Format.decimal(energy)) kcal",
                     caption: "\(Format.decimal(energy / weeks)) kcal per week",
                     symbolName: "flame.fill", tint: Theme.color(for: .activity))
            if distance > 0 {
                StatTile(title: "Distance", value: "\(Format.decimal(distance, fractionDigits: 1)) km",
                         caption: "\(Format.decimal(distance / weeks, fractionDigits: 1)) km per week",
                         symbolName: "location.fill", tint: Theme.color(for: .activity))
            }
            if let longest = workouts.max(by: { $0.durationMinutes < $1.durationMinutes }) {
                StatTile(title: "Longest session",
                         value: Format.duration(minutes: longest.durationMinutes),
                         caption: "\(longest.activity.title) · \(Format.day(longest.day, style: .short))",
                         symbolName: "trophy", tint: Theme.color(for: .activity))
            }
        }
    }

    private func volumeChart(_ database: HealthDatabase) -> some View {
        Card("Training volume by month", subtitle: "Minutes, stacked by activity") {
            let volumes = ActivityStats.monthlyVolume(filtered(database))
            if volumes.isEmpty {
                Text("No workouts in this range.").foregroundStyle(.secondary)
            } else {
                Chart(volumes) { item in
                    BarMark(x: .value("Month", item.month.localDate(), unit: .month),
                            y: .value("Minutes", item.minutes))
                    .foregroundStyle(by: .value("Activity", item.activity.title))
                    .cornerRadius(2)
                }
                .frame(height: 240)
                .chartLegend(position: .bottom, spacing: 10)
            }
        }
    }

    private func breakdown(_ database: HealthDatabase) -> some View {
        Card("By activity") {
            let groups = ActivityStats.groupWorkouts(filtered(database))
            Table(groups) {
                TableColumn("Activity") { group in
                    Text(group.activity.title)
                }
                TableColumn("Sessions") { group in
                    Text("\(group.count)").monospacedDigit()
                }
                .width(80)
                TableColumn("Total time") { group in
                    Text(Format.duration(minutes: group.totalMinutes)).monospacedDigit()
                }
                .width(100)
                TableColumn("Average") { group in
                    Text(Format.duration(minutes: group.averageMinutes)).monospacedDigit()
                }
                .width(90)
                TableColumn("Distance") { group in
                    Text(group.totalDistance > 0
                         ? "\(Format.decimal(group.totalDistance, fractionDigits: 1)) km" : "—")
                    .monospacedDigit()
                }
                .width(100)
                TableColumn("Energy") { group in
                    Text(group.totalEnergy > 0 ? "\(Format.decimal(group.totalEnergy)) kcal" : "—")
                        .monospacedDigit()
                }
                .width(110)
                TableColumn("Avg HR") { group in
                    Text(group.averageHeartRate.map { "\(Format.decimal($0)) bpm" } ?? "—")
                        .monospacedDigit()
                }
                .width(90)
            }
            .frame(minHeight: 180, maxHeight: 300)
        }
    }

    private func list(_ database: HealthDatabase) -> some View {
        Card("Sessions") {
            Table(filtered(database).sorted(using: sortOrder), sortOrder: $sortOrder) {
                TableColumn("Date", value: \.start) { workout in
                    Text(Format.dateTime(workout.startDate))
                }
                .width(180)
                TableColumn("Activity") { workout in
                    Text(workout.activity.title)
                }
                TableColumn("Duration", value: \.durationMinutes) { workout in
                    Text(Format.duration(minutes: workout.durationMinutes)).monospacedDigit()
                }
                .width(90)
                TableColumn("Distance") { workout in
                    Text(workout.distanceKm.map { "\(Format.decimal($0, fractionDigits: 2)) km" } ?? "—")
                        .monospacedDigit()
                }
                .width(100)
                TableColumn("Pace") { workout in
                    Text(workout.paceMinutesPerKm.map { paceString($0) } ?? "—")
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("Energy") { workout in
                    Text(workout.energyKcal.map { "\(Format.decimal($0)) kcal" } ?? "—")
                        .monospacedDigit()
                }
                .width(100)
                TableColumn("Avg HR") { workout in
                    Text(workout.averageHeartRate.map { "\(Format.decimal($0))" } ?? "—")
                        .monospacedDigit()
                }
                .width(80)
                TableColumn("Source") { workout in
                    Text(workout.sourceName).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minHeight: 320, maxHeight: 560)
        }
    }

    // MARK: - Helpers

    private func filtered(_ database: HealthDatabase) -> [WorkoutSummary] {
        let bounds = range.range(in: database)
        return database.workouts.filter { workout in
            if let bounds, !bounds.contains(workout.day) { return false }
            if activityFilter != "All", workout.activity.rawValue != activityFilter { return false }
            return true
        }
    }

    private func activityNames(_ database: HealthDatabase) -> [String] {
        Array(Set(database.workouts.map(\.activity.rawValue)))
            .sorted { WorkoutActivity(rawValue: $0).title < WorkoutActivity(rawValue: $1).title }
    }

    private func rangeDays(_ database: HealthDatabase) -> Int {
        guard let bounds = range.range(in: database) else { return 365 }
        return max(1, bounds.upperBound - bounds.lowerBound + 1)
    }

    private func paceString(_ minutesPerKm: Double) -> String {
        let minutes = Int(minutesPerKm)
        let seconds = Int((minutesPerKm - Double(minutes)) * 60)
        return String(format: "%d:%02d /km", minutes, seconds)
    }
}
