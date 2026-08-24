import SwiftUI
import Charts
import HealthCore
import HealthUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let headlineMetrics: [Metric] = [
        .steps, .activeEnergy, .exerciseMinutes, .walkingRunningDistance,
        .restingHeartRate, .hrv, .sleepHours, .vo2Max
    ]

    var body: some View {
        if let database = model.database, !database.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    header(database)
                    fitnessSummary
                    lastFourWeeks(database)
                    activityChart(database)
                    movers
                }
                .padding(20)
            }
            .navigationTitle("Dashboard")
        } else {
            NoDataView()
        }
    }

    // MARK: - Sections

    private func header(_ database: HealthDatabase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your health over \(yearsCovered(database))")
                .font(.largeTitle.weight(.semibold))
            if let range = database.dateRange {
                Text("\(Format.day(range.lowerBound)) – \(Format.day(range.upperBound)) · \(Format.decimal(Double(database.days.count))) days · \(Format.decimal(Double(database.workouts.count))) workouts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fitnessSummary: some View {
        if let standing = model.analytics.standing {
            Card {
                HStack(alignment: .center, spacing: 28) {
                    ScoreRing(score: standing.current.value,
                              band: standing.current.band,
                              diameter: 172,
                              caption: "Fitness Index")

                    VStack(alignment: .leading, spacing: 14) {
                        Text(headline(for: standing))
                            .font(.title3.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 24) {
                            deltaColumn("vs 30 days", standing.changeVs30Days)
                            deltaColumn("vs 90 days", standing.changeVs90Days)
                            deltaColumn("vs 1 year", standing.changeVs365Days)
                        }

                        if let best = standing.allTimeBest {
                            Text("Personal best \(Format.decimal(best.value, fractionDigits: 0)) on \(Format.day(best.day)).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if model.analytics.fitnessScores.count > 3 {
                    Chart {
                        ForEach(sampledScores) { score in
                            AreaMark(x: .value("Day", score.day.localDate()),
                                     y: .value("Index", score.value))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.color(for: score.band).opacity(0.35),
                                                        Theme.color(for: score.band).opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Day", score.day.localDate()),
                                     y: .value("Index", score.value))
                            .foregroundStyle(Theme.color(for: standing.current.band))
                            .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: fitnessDomain)
                    .frame(height: 130)
                }
            }
        }
    }

    private func deltaColumn(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Format.signed(value, fractionDigits: 1))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(color(for: value))
        }
    }

    private func color(for delta: Double?) -> Color {
        guard let delta, abs(delta) > 0.4 else { return .secondary }
        return delta > 0 ? Theme.color(for: .improving) : Theme.color(for: .declining)
    }

    private func lastFourWeeks(_ database: HealthDatabase) -> some View {
        Card("Last 28 days", subtitle: "Compared with the 28 days before that") {
            TileGrid {
                ForEach(headlineMetrics, id: \.self) { metric in
                    if let trend = model.trend(for: metric), trend.current != nil {
                        StatTile(title: metric.title,
                                 value: Format.metric(displayValue(trend), metric),
                                 trend: trend,
                                 symbolName: symbol(for: metric),
                                 tint: Theme.color(for: metric.category))
                    }
                }
            }
        }
    }

    /// Additive metrics read better as a daily average than as a 28-day total.
    private func displayValue(_ trend: MetricTrend) -> Double? {
        guard let current = trend.current else { return nil }
        return trend.metric.isCumulative ? current / Double(trend.window) : current
    }

    private func activityChart(_ database: HealthDatabase) -> some View {
        Card("Activity this year",
             subtitle: "Daily active energy, with a 28-day average through it") {
            let range = DateRangeOption.year.range(in: database)
            let series = database.series(.activeEnergy, in: range)
            let smoothed = series.rollingMean(window: 28)

            if series.count > 5 {
                Chart {
                    ForEach(series.points) { point in
                        BarMark(x: .value("Day", point.day.localDate()),
                                y: .value("kcal", point.value),
                                width: .fixed(2))
                        .foregroundStyle(Theme.color(for: .activity).opacity(0.35))
                    }
                    ForEach(smoothed.points) { point in
                        LineMark(x: .value("Day", point.day.localDate()),
                                 y: .value("28-day average", point.value))
                        .foregroundStyle(Theme.color(for: .activity))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    }
                }
                .frame(height: 190)
                .chartXAxis { AxisMarks(values: .stride(by: .month)) }
            } else {
                Text("Not enough active energy data yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var movers: some View {
        let movers = model.analytics.topMovers
        if !movers.isEmpty {
            Card("Biggest movers", subtitle: "What changed most in the last 28 days") {
                VStack(spacing: 0) {
                    ForEach(Array(movers.enumerated()), id: \.element.id) { index, trend in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Theme.color(for: trend.metric.category))
                                .frame(width: 8, height: 8)
                            Text(trend.metric.title)
                                .frame(width: 220, alignment: .leading)
                                .lineLimit(1)
                            if let database = model.database {
                                Sparkline(points: database.series(trend.metric)
                                    .trailing(120)
                                    .rollingMean(window: 7).points,
                                          tint: Theme.color(for: trend.metric.category))
                                .frame(height: 26)
                            }
                            Text(Format.metric(displayValue(trend), trend.metric))
                                .font(.callout.monospacedDigit())
                                .frame(width: 130, alignment: .trailing)
                            TrendBadge(trend: trend, showsWindow: false)
                                .frame(width: 88, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        if index < movers.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var sampledScores: [FitnessScore] {
        let scores = model.analytics.fitnessScores
        guard scores.count > 800 else { return scores }
        let step = scores.count / 800 + 1
        return scores.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    private var fitnessDomain: ClosedRange<Double> {
        let values = model.analytics.fitnessScores.map(\.value)
        let low = max(0, (values.min() ?? 0) - 6)
        let high = min(100, (values.max() ?? 100) + 6)
        return low...max(low + 10, high)
    }

    private func headline(for standing: FitnessStanding) -> String {
        let percentile = Int((standing.percentileAllTime * 100).rounded())
        let band = standing.current.band.title.lowercased()
        if percentile >= 95 {
            return "You are at your fittest on record — \(band) shape, better than \(percentile)% of all the days you have tracked."
        } else if percentile >= 70 {
            return "You are in \(band) shape, ahead of \(percentile)% of the days in your history."
        } else if percentile >= 40 {
            return "You are in \(band) shape, around the middle of your own range (\(percentile)th percentile)."
        } else if let days = standing.daysSinceHigher {
            return "You are in \(band) shape. It has been \(days) days since your index was last this high or higher."
        }
        return "You are in \(band) shape, below \(100 - percentile)% of the days you have tracked."
    }

    private func yearsCovered(_ database: HealthDatabase) -> String {
        guard let range = database.dateRange else { return "time" }
        let years = Double(range.upperBound - range.lowerBound) / 365.25
        if years < 1 { return "\(Int((years * 12).rounded())) months" }
        return "\(Format.decimal(years, fractionDigits: 1)) years"
    }

    private func symbol(for metric: Metric) -> String {
        switch metric {
        case .steps: return "figure.walk"
        case .activeEnergy: return "flame.fill"
        case .exerciseMinutes: return "stopwatch"
        case .walkingRunningDistance: return "location.fill"
        case .restingHeartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleepHours: return "bed.double.fill"
        case .vo2Max: return "lungs.fill"
        default: return "circle.fill"
        }
    }
}

/// Shared placeholder for every screen when nothing is loaded yet.
struct NoDataView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            EmptyStateView(
                symbolName: "heart.text.square",
                title: "No health data yet",
                message: model.healthKitAvailability.isUsable
                    ? "Sync directly from HealthKit, or import the export.zip your iPhone's Health app creates."
                    : model.healthKitAvailability.message)

            HStack(spacing: 12) {
                if model.healthKitAvailability.isUsable {
                    Button("Sync from HealthKit") {
                        Task { await model.syncFromHealthKit() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Import export.zip…") {
                    Task { await ImportPanel.present(model: model) }
                }
                .controlSize(.large)
                Button("Explore with sample data") {
                    Task { await model.loadSampleData() }
                }
                .controlSize(.large)
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
