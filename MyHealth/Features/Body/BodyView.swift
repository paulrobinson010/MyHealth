import SwiftUI
import Charts

/// Heart, body composition and the vitals that move slowly.
struct BodyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: DateRangeOption = .year

    private let heartMetrics: [Metric] = [.restingHeartRate, .hrv, .walkingHeartRate, .respiratoryRate,
                                          .oxygenSaturation, .heartRateMin]
    private let bodyMetrics: [Metric] = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex,
                                         .waistCircumference]
    private let fitnessMetrics: [Metric] = [.vo2Max, .sixMinuteWalk, .walkingSpeed, .walkingSteadiness]

    var body: some View {
        if let database = model.database, !database.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    HStack {
                        Text("Body & Vitals").font(.title2.weight(.semibold))
                        Spacer()
                        DateRangePicker(selection: $range)
                    }
                    vo2Card(database)
                    section("Heart", heartMetrics, database)
                    section("Body composition", bodyMetrics, database)
                    section("Fitness & mobility", fitnessMetrics, database)
                }
                .padding(20)
            }
            .navigationTitle("Body & Vitals")
        } else {
            NoDataView()
        }
    }

    @ViewBuilder
    private func vo2Card(_ database: HealthDatabase) -> some View {
        let series = database.series(.vo2Max)
        if let latest = series.last {
            let age = database.profile.age(on: latest.day)
            let category = ReferenceRanges.vo2MaxCategory(latest.value,
                                                          age: age,
                                                          sex: database.profile.biologicalSex)
            let score = ReferenceRanges.vo2MaxScore(latest.value,
                                                    age: age,
                                                    sex: database.profile.biologicalSex)
            Card("Cardio fitness",
                 subtitle: "VO₂ max is the single best predictor of cardiorespiratory fitness Apple records") {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.decimal(latest.value, fractionDigits: 1))
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                        Text("mL/kg·min").font(.caption).foregroundStyle(.secondary)
                        Text(category)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.color(for: FitnessBand(score: score)))
                        if let age {
                            Text("for a \(age)-year-old")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("as of \(Format.day(latest.day))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(width: 190, alignment: .leading)

                    Chart {
                        ForEach(series.clipped(to: rangeBounds(database)).points) { point in
                            LineMark(x: .value("Day", point.day.localDate()),
                                     y: .value("VO₂ max", point.value))
                            .foregroundStyle(Theme.color(for: .fitness))
                            .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", point.day.localDate()),
                                      y: .value("VO₂ max", point.value))
                            .foregroundStyle(Theme.color(for: .fitness).opacity(0.4))
                            .symbolSize(14)
                        }
                    }
                    .frame(height: 150)
                }
            }
        }
    }

    private func section(_ title: String, _ metrics: [Metric], _ database: HealthDatabase) -> some View {
        let present = metrics.filter { !database.series($0).isEmpty }
        return Group {
            if !present.isEmpty {
                Card(title) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(present, id: \.self) { metric in
                            miniChart(metric, database)
                        }
                    }
                }
            }
        }
    }

    private func miniChart(_ metric: Metric, _ database: HealthDatabase) -> some View {
        let series = database.series(metric, in: rangeBounds(database))
        let smoothed = series.rollingMean(window: 14)
        let trend = model.trend(for: metric)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text(Format.metric(series.last?.value, metric))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            if let trend {
                TrendBadge(trend: trend)
            }
            Chart {
                ForEach(series.points) { point in
                    PointMark(x: .value("Day", point.day.localDate()),
                              y: .value(metric.title, point.value))
                    .foregroundStyle(Theme.color(for: metric.category).opacity(0.18))
                    .symbolSize(8)
                }
                ForEach(smoothed.points) { point in
                    LineMark(x: .value("Day", point.day.localDate()),
                             y: .value(metric.title, point.value))
                    .foregroundStyle(Theme.color(for: metric.category))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: domain(series))
            .frame(height: 110)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func domain(_ series: TimeSeries) -> ClosedRange<Double> {
        let low = series.quantile(0.02) ?? series.minimum?.value ?? 0
        let high = series.quantile(0.98) ?? series.maximum?.value ?? 1
        let padding = max((high - low) * 0.15, 0.001)
        return (low - padding)...(high + padding)
    }

    private func rangeBounds(_ database: HealthDatabase) -> ClosedRange<DayKey> {
        range.range(in: database) ?? (DayKey.today.adding(days: -365)...DayKey.today)
    }
}
