import SwiftUI
import Charts

/// The "how fit am I, and how does that compare with every other stretch of my
/// life" screen: the index over time, what is driving it, and a leaderboard of
/// your own months, quarters and years.
struct FitnessRankView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bucket: TimeSeries.Bucket = .month
    @State private var range: DateRangeOption = .all

    var body: some View {
        if model.analytics.fitnessScores.isEmpty {
            if model.database == nil {
                NoDataView()
            } else {
                EmptyStateView(
                    symbolName: "trophy",
                    title: "Not enough data to score fitness",
                    message: "The fitness index needs at least a few weeks of activity, heart or workout data in a row. Import a longer history, or check that the metrics it uses are being recorded.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gridSpacing) {
                    scoreOverTime
                    componentBreakdown
                    leaderboard
                    methodology
                }
                .padding(20)
            }
            .navigationTitle("Fitness Rank")
        }
    }

    // MARK: - Index over time

    private var scoreOverTime: some View {
        Card("Fitness index over time",
             subtitle: "A 0–100 rollup of the trailing 28 days, scored against reference ranges for your age and sex",
             accessory: AnyView(DateRangePicker(selection: $range))) {
            let scores = visibleScores
            Chart {
                ForEach(scores) { score in
                    AreaMark(x: .value("Day", score.day.localDate()),
                             y: .value("Index", score.value))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.accentColor.opacity(0.28),
                                                Color.accentColor.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", score.day.localDate()),
                             y: .value("Index", score.value))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                }
                if let best = model.analytics.standing?.allTimeBest,
                   scores.contains(where: { $0.day == best.day }) {
                    PointMark(x: .value("Day", best.day.localDate()),
                              y: .value("Index", best.value))
                    .foregroundStyle(Theme.color(for: best.band))
                    .symbolSize(70)
                    .annotation(position: .top) {
                        Text("Best").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(bandRules) { rule in
                    RuleMark(y: .value("Band", rule.value))
                        .foregroundStyle(Color.secondary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(rule.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 260)

            if let standing = model.analytics.standing {
                HStack(spacing: 20) {
                    summaryPill("Now", Format.decimal(standing.current.value, fractionDigits: 1),
                                Theme.color(for: standing.current.band))
                    summaryPill("All-time percentile",
                                "\(Int((standing.percentileAllTime * 100).rounded()))",
                                .secondary)
                    summaryPill("Last-year percentile",
                                "\(Int((standing.percentileLastYear * 100).rounded()))",
                                .secondary)
                    if let best = standing.allTimeBest {
                        summaryPill("Best ever",
                                    "\(Format.decimal(best.value, fractionDigits: 1)) · \(Format.day(best.day, style: .short))",
                                    Theme.color(for: best.band))
                    }
                    Spacer()
                }
            }
        }
    }

    private struct BandRule: Identifiable {
        var id: Double { value }
        let value: Double
        let label: String
    }

    private var bandRules: [BandRule] {
        [BandRule(value: 35, label: "Fair"), BandRule(value: 52, label: "Good"),
         BandRule(value: 70, label: "Strong"), BandRule(value: 85, label: "Elite")]
    }

    private func summaryPill(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).foregroundStyle(tint)
        }
    }

    // MARK: - Components

    private var componentBreakdown: some View {
        Card("What is driving the score",
             subtitle: "Average over the last 90 days. Weights are rebalanced across whatever data you actually have.") {
            let components = model.analytics.componentAverages
            if components.isEmpty {
                Text("No component data available.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(components) { component in
                        componentRow(component)
                    }
                }
            }
        }
    }

    private func componentRow(_ component: FitnessComponent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: component.kind.symbolName)
                .frame(width: 22)
                .foregroundStyle(Theme.color(for: FitnessBand(score: component.score)))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(component.kind.title).font(.callout.weight(.medium))
                    Text("· \(Int((component.weight * 100).rounded()))% of index")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.decimal(component.score, fractionDigits: 0))
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(Theme.color(for: FitnessBand(score: component.score)))
                            .frame(width: proxy.size.width * (component.score / 100))
                    }
                }
                .frame(height: 7)
                if let detail = component.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .help(component.kind.explanation)
    }

    // MARK: - Leaderboard

    private var leaderboard: some View {
        Card("Your periods, ranked",
             subtitle: "Every \(bucket.title.lowercased()) of your history, best first",
             accessory: AnyView(
                Picker("Period", selection: $bucket) {
                    Text("Months").tag(TimeSeries.Bucket.month)
                    Text("Quarters").tag(TimeSeries.Bucket.quarter)
                    Text("Years").tag(TimeSeries.Bucket.year)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260))) {

            let periods = rankedPeriods
            if periods.isEmpty {
                Text("Not enough complete \(bucket.title.lowercased())s yet.")
                    .foregroundStyle(.secondary)
            } else {
                Table(periods.sorted { $0.rank < $1.rank }) {
                    TableColumn("Rank") { period in
                        HStack(spacing: 6) {
                            if period.rank <= 3 {
                                Image(systemName: "trophy.fill")
                                    .foregroundStyle(medalColor(period.rank))
                                    .font(.caption)
                            }
                            Text(Format.ordinal(period.rank))
                                .monospacedDigit()
                        }
                    }
                    .width(70)

                    TableColumn(bucket.title, value: \.label)

                    TableColumn("Index") { period in
                        HStack(spacing: 8) {
                            Text(Format.decimal(period.averageScore, fractionDigits: 1))
                                .monospacedDigit()
                                .foregroundStyle(Theme.color(for: period.band))
                            Text(period.band.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(140)

                    TableColumn("Change") { period in
                        Text(Format.signed(period.changeFromPrevious, fractionDigits: 1))
                            .monospacedDigit()
                            .foregroundStyle(changeColor(period.changeFromPrevious))
                    }
                    .width(80)

                    TableColumn("Percentile") { period in
                        Text("\(Int((period.percentile * 100).rounded()))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(80)

                    TableColumn("Days") { period in
                        Text("\(period.days)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(60)
                }
                .frame(minHeight: 260, maxHeight: 460)

                Chart(periods) { period in
                    BarMark(x: .value(bucket.title, period.label),
                            y: .value("Index", period.averageScore))
                    .foregroundStyle(Theme.color(for: period.band))
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(.caption2)
                        AxisTick()
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(height: 170)
            }
        }
    }

    private func medalColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.85, green: 0.68, blue: 0.22)
        case 2: return Color(red: 0.68, green: 0.70, blue: 0.72)
        default: return Color(red: 0.72, green: 0.51, blue: 0.33)
        }
    }

    private func changeColor(_ delta: Double?) -> Color {
        guard let delta, abs(delta) > 0.4 else { return .secondary }
        return delta > 0 ? Theme.color(for: .improving) : Theme.color(for: .declining)
    }

    // MARK: - Methodology

    private var methodology: some View {
        Card("How the index is calculated") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(FitnessComponent.Kind.allCases, id: \.self) { kind in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(Int(kind.baseWeightPercent))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.title).font(.caption.weight(.medium))
                            Text(kind.explanation).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                Text("Weights are the starting point. If a component has no data — no VO₂ max readings, say — its weight is redistributed across the rest, so the index stays comparable rather than silently dropping to zero. Reference ranges come from published population fitness categories and are there to make your own trajectory legible; they are not a medical assessment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Data

    private var visibleScores: [FitnessScore] {
        let scores = model.analytics.fitnessScores
        guard let days = range.days, let last = scores.last?.day else { return scores }
        let cutoff = last.adding(days: -days)
        return scores.filter { $0.day >= cutoff }
    }

    private var rankedPeriods: [RankedPeriod] {
        switch bucket {
        case .quarter: return model.analytics.quarters
        case .year: return model.analytics.years
        default: return model.analytics.months
        }
    }
}

extension FitnessComponent.Kind {
    var baseWeightPercent: Double { baseWeight * 100 }
}
