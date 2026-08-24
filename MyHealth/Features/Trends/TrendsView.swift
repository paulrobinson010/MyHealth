import SwiftUI
import Charts
import HealthCore
import HealthUI

/// Pick any metric, see its whole history with a fitted trend line and the
/// numbers that say whether the movement is real.
struct TrendsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var metric: Metric = .restingHeartRate
    @State private var range: DateRangeOption = .all
    @State private var window: Int = 28

    var body: some View {
        if let database = model.database, !database.isEmpty {
            HSplitView {
                metricList(database)
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
                detail(database)
            }
            .navigationTitle("Trends")
            .onAppear { ensureValidSelection(database) }
        } else {
            NoDataView()
        }
    }

    // MARK: - Sidebar of metrics

    private func metricList(_ database: HealthDatabase) -> some View {
        let available = database.availableMetrics()
        let grouped = Dictionary(grouping: available, by: \.category)
        return List(selection: Binding<Metric?>(get: { metric },
                                               set: { metric = $0 ?? metric })) {
            ForEach(MetricCategory.allCases, id: \.self) { group in
                if let metrics = grouped[group], !metrics.isEmpty {
                    Section(group.title) {
                        ForEach(metrics, id: \.self) { item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Theme.color(for: group))
                                    .frame(width: 7, height: 7)
                                Text(item.title).lineLimit(1)
                            }
                            .tag(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Detail

    private func detail(_ database: HealthDatabase) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title).font(.title2.weight(.semibold))
                        Text("Measured in \(metric.unit) · \(metric.higherIsBetter ? "higher is better" : "lower is better")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    DateRangePicker(selection: $range)
                }

                chart(database)
                statistics(database)
                distribution(database)
            }
            .padding(20)
        }
    }

    private func chart(_ database: HealthDatabase) -> some View {
        Card {
            let series = database.series(metric, in: range.range(in: database))
            if series.count < 3 {
                Text("Not enough data for \(metric.title) in this range.")
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                let smoothed = series.rollingMean(window: smoothingWindow(series))
                let fit = series.regression()
                Chart {
                    ForEach(series.points) { point in
                        PointMark(x: .value("Day", point.day.localDate()),
                                  y: .value(metric.title, point.value))
                        .foregroundStyle(Theme.color(for: metric.category).opacity(0.22))
                        .symbolSize(10)
                    }
                    ForEach(smoothed.points) { point in
                        LineMark(x: .value("Day", point.day.localDate()),
                                 y: .value("Rolling average", point.value),
                                 series: .value("Series", "rolling"))
                        .foregroundStyle(Theme.color(for: metric.category))
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                        .interpolationMethod(.monotone)
                    }
                    if let fit, fit.isMeaningful,
                       let first = series.first?.day, let last = series.last?.day {
                        ForEach([first, last], id: \.ordinal) { day in
                            LineMark(x: .value("Day", day.localDate()),
                                     y: .value("Trend", fit.value(at: day)),
                                     series: .value("Series", "trend"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                        }
                    }
                }
                .frame(height: 300)
                .chartLegend(.hidden)

                HStack(spacing: 14) {
                    legendSwatch(Theme.color(for: metric.category).opacity(0.35), "Daily values")
                    legendSwatch(Theme.color(for: metric.category), "\(smoothingWindow(series))-day average")
                    if let fit = series.regression(), fit.isMeaningful {
                        legendSwatch(.secondary, "Trend line (R² \(Format.decimal(fit.rSquared, fractionDigits: 2)))")
                    }
                }
            }
        }
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 14, height: 3)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statistics(_ database: HealthDatabase) -> some View {
        let trend = TrendAnalysis.trend(for: metric, in: database, window: window)
        let full = database.series(metric)
        return Card("The numbers",
                    accessory: AnyView(
                        Picker("Window", selection: $window) {
                            Text("7 days").tag(7)
                            Text("28 days").tag(28)
                            Text("90 days").tag(90)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230))) {
            TileGrid(minimumWidth: 175) {
                StatTile(title: "Last \(window) days",
                         value: Format.metric(windowValue(trend), metric),
                         trend: trend,
                         tint: Theme.color(for: metric.category))
                StatTile(title: "Vs a year ago",
                         value: Format.percentChange(trend.changeVsYearAgo),
                         caption: trend.yearAgo.map { Format.metric($0, metric) } ?? "no data",
                         tint: Theme.color(for: metric.category))
                if let drift = trend.monthlyDrift {
                    StatTile(title: "Trend",
                             value: "\(Format.signed(drift, fractionDigits: metric.fractionDigits + 1)) \(metric.unit)",
                             caption: "per month, fitted over \(window) days",
                             tint: Theme.color(for: metric.category))
                }
                StatTile(title: metric.higherIsBetter ? "All-time high" : "All-time low",
                         value: Format.metric(trend.best?.value, metric),
                         caption: trend.best.map { Format.day($0.day) },
                         symbolName: "trophy",
                         tint: Theme.color(for: metric.category))
                StatTile(title: "All-time average",
                         value: Format.metric(full.mean, metric),
                         caption: "\(full.count) days recorded",
                         tint: Theme.color(for: metric.category))
                if let median = full.quantile(0.5) {
                    StatTile(title: "Typical range",
                             value: Format.metric(median, metric),
                             caption: "\(Format.metric(full.quantile(0.1), metric, includeUnit: false)) – \(Format.metric(full.quantile(0.9), metric, includeUnit: false)) (10th–90th)",
                             tint: Theme.color(for: metric.category))
                }
            }
        }
    }

    private func distribution(_ database: HealthDatabase) -> some View {
        Card("Year on year", subtitle: "Each year's \(metric.isCumulative ? "daily average" : "average")") {
            let yearly = database.series(metric).bucketed(by: .year, forceAverage: true)
            if yearly.count < 2 {
                Text("Needs at least two years of data.").foregroundStyle(.secondary)
            } else {
                Chart(yearly) { item in
                    BarMark(x: .value("Year", item.label),
                            y: .value(metric.title, item.value))
                    .foregroundStyle(Theme.color(for: metric.category))
                    .cornerRadius(3)
                    .annotation(position: .top) {
                        Text(Format.metric(item.value, metric, includeUnit: false))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    // MARK: - Helpers

    private func windowValue(_ trend: MetricTrend) -> Double? {
        guard let current = trend.current else { return nil }
        return trend.metric.isCumulative ? current / Double(trend.window) : current
    }

    private func smoothingWindow(_ series: TimeSeries) -> Int {
        switch range {
        case .month: return 3
        case .quarter: return 7
        case .halfYear, .year: return 14
        default: return 28
        }
    }

    private func ensureValidSelection(_ database: HealthDatabase) {
        let available = database.availableMetrics()
        guard !available.isEmpty, !available.contains(metric) else { return }
        metric = available.first(where: { $0 == .restingHeartRate })
            ?? available.first(where: { $0 == .steps })
            ?? available[0]
    }
}
