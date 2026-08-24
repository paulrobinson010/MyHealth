import SwiftUI
import Charts

/// Everything you did, over whatever span you pick.
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: DateRangeOption = .year
    @State private var metric: Metric = .steps

    private let selectableMetrics: [Metric] = [
        .steps, .activeEnergy, .exerciseMinutes, .walkingRunningDistance,
        .cyclingDistance, .flightsClimbed, .standHours, .workoutMinutes
    ]

    var body: some View {
        if let database = model.database, !database.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    controls
                    summaryTiles(database)
                    mainChart(database)
                    HStack(alignment: .top, spacing: Theme.gridSpacing) {
                        weekdayProfile(database)
                        goalCard(database)
                    }
                    heatmap(database)
                }
                .padding(20)
            }
            .navigationTitle("Activity")
        } else {
            NoDataView()
        }
    }

    private var controls: some View {
        HStack {
            Picker("Metric", selection: $metric) {
                ForEach(selectableMetrics, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .frame(width: 260)
            Spacer()
            DateRangePicker(selection: $range)
        }
    }

    private func summaryTiles(_ database: HealthDatabase) -> some View {
        let series = visibleSeries(database)
        let days = max(1, series.count)
        return TileGrid(minimumWidth: 190) {
            StatTile(title: "Daily average",
                     value: Format.metric(series.mean, metric),
                     caption: "\(days) days with data",
                     symbolName: "chart.bar",
                     tint: Theme.color(for: metric.category))
            if metric.isCumulative {
                StatTile(title: "Total in range",
                         value: Format.metric(series.total, metric),
                         caption: rangeCaption(database),
                         symbolName: "sum",
                         tint: Theme.color(for: metric.category))
            }
            StatTile(title: "Best day",
                     value: Format.metric(series.maximum?.value, metric),
                     caption: series.maximum.map { Format.day($0.day) },
                     symbolName: "arrow.up.circle",
                     tint: Theme.color(for: metric.category))
            if let trend = model.trend(for: metric) {
                StatTile(title: "Last 28 days",
                         value: Format.metric(trend.metric.isCumulative
                                              ? trend.current.map { $0 / 28 }
                                              : trend.current, metric),
                         trend: trend,
                         symbolName: "calendar",
                         tint: Theme.color(for: metric.category))
            }
            if let best = TrendAnalysis.personalBest(for: metric, in: database, bucket: .week) {
                StatTile(title: "Best week ever",
                         value: Format.metric(best.value, metric),
                         caption: best.label,
                         symbolName: "trophy",
                         tint: Theme.color(for: metric.category))
            }
        }
    }

    private func mainChart(_ database: HealthDatabase) -> some View {
        Card(metric.title, subtitle: chartSubtitle) {
            let series = visibleSeries(database)
            let bucket = range.bucket
            if series.count < 3 {
                Text("Not enough data in this range.").foregroundStyle(.secondary)
            } else if bucket == .day {
                let smoothed = series.rollingMean(window: 7)
                Chart {
                    ForEach(series.points) { point in
                        BarMark(x: .value("Day", point.day.localDate()),
                                y: .value(metric.title, point.value))
                        .foregroundStyle(Theme.color(for: metric.category).opacity(0.45))
                    }
                    ForEach(smoothed.points) { point in
                        LineMark(x: .value("Day", point.day.localDate()),
                                 y: .value("7-day average", point.value))
                        .foregroundStyle(Theme.color(for: metric.category))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    }
                }
                .frame(height: 280)
            } else {
                let buckets = series.bucketed(by: bucket)
                Chart(buckets) { item in
                    BarMark(x: .value(bucket.title, item.start.localDate()),
                            y: .value(metric.title, item.value))
                    .foregroundStyle(Theme.color(for: metric.category))
                    .cornerRadius(3)
                }
                .frame(height: 280)
                .chartXAxis {
                    AxisMarks(values: .stride(by: bucket == .week ? .month : .year))
                }
            }
        }
    }

    private func weekdayProfile(_ database: HealthDatabase) -> some View {
        Card("By day of the week", subtitle: "Average within the selected range") {
            let profile = ActivityStats.weekdayProfile(for: metric,
                                                       in: database,
                                                       range: range.range(in: database))
            Chart(profile) { entry in
                BarMark(x: .value("Day", entry.name),
                        y: .value(metric.title, entry.average))
                .foregroundStyle(Theme.color(for: metric.category).opacity(entry.average > 0 ? 0.9 : 0.2))
                .cornerRadius(3)
            }
            .frame(height: 180)
        }
    }

    private func goalCard(_ database: HealthDatabase) -> some View {
        Card("Consistency", subtitle: "Days clearing \(Format.metric(goal, metric))") {
            let attainment = ActivityStats.goalAttainment(for: metric,
                                                          in: database,
                                                          goal: goal,
                                                          range: range.range(in: database))
            let fraction = attainment.total > 0
                ? Double(attainment.met) / Double(attainment.total) : 0
            let streak = TrendAnalysis.streak(for: metric, in: database, atLeast: goal)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                    Text("of days")
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Theme.color(for: metric.category))
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 10)
                Text("\(attainment.met) of \(attainment.total) days in range")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current streak").font(.caption).foregroundStyle(.secondary)
                        Text("\(streak.current) days").font(.callout.weight(.semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Longest streak").font(.caption).foregroundStyle(.secondary)
                        Text("\(streak.longest) days").font(.callout.weight(.semibold))
                        if let end = streak.longestEnd {
                            Text("ended \(Format.day(end, style: .short))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func heatmap(_ database: HealthDatabase) -> some View {
        Card("Every day, at a glance",
             subtitle: "Darker is more \(metric.title.lowercased()). Hover for the value.") {
            if let full = range.range(in: database) {
                CalendarHeatmap(cells: ActivityStats.heatmap(for: metric, in: database, range: full),
                                metric: metric)
                HStack(spacing: 6) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.heatColor(level))
                            .frame(width: 11, height: 11)
                    }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private func visibleSeries(_ database: HealthDatabase) -> TimeSeries {
        database.series(metric, in: range.range(in: database))
    }

    private var chartSubtitle: String {
        switch range.bucket {
        case .day: return "Daily values with a 7-day rolling average"
        case .week: return "Weekly \(metric.isCumulative ? "totals" : "averages")"
        default: return "Monthly \(metric.isCumulative ? "totals" : "averages")"
        }
    }

    private func rangeCaption(_ database: HealthDatabase) -> String {
        guard let r = range.range(in: database) else { return "" }
        return "\(Format.day(r.lowerBound, style: .short)) – \(Format.day(r.upperBound, style: .short))"
    }

    /// Sensible per-metric daily goal for the consistency card.
    private var goal: Double {
        switch metric {
        case .steps: return 10_000
        case .activeEnergy: return 500
        case .exerciseMinutes, .workoutMinutes: return 30
        case .walkingRunningDistance: return 5
        case .cyclingDistance: return 10
        case .flightsClimbed: return 10
        case .standHours: return 12
        default: return 1
        }
    }
}
