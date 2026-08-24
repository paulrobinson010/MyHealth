import SwiftUI
import Charts
import HealthCore

/// Everything that answers "is what I am doing working?", on one screen.
///
/// Fitness, weight and waist are plotted on a shared time axis rather than
/// squeezed onto shared scales. A dual-axis chart can make any two lines look
/// related by choosing the ranges flatteringly; stacked panels cannot, and the
/// honest correlation is stated in numbers underneath.
public struct BodyAndFitnessView: View {

    /// Everything the view needs, assembled by whichever app is showing it.
    public struct Model: Sendable {
        public var fitnessScores: [FitnessScore]
        public var weight: TimeSeries
        public var waist: TimeSeries
        public var intervals: [ReconciledInterval]
        public var fitnessVsWeight: Correlation?
        public var fitnessVsWaist: Correlation?
        public var summary: IntervalReconciler.Summary?

        public init(fitnessScores: [FitnessScore] = [],
                    weight: TimeSeries = TimeSeries(metric: .bodyMass, points: []),
                    waist: TimeSeries = TimeSeries(metric: .waistCircumference, points: []),
                    intervals: [ReconciledInterval] = [],
                    fitnessVsWeight: Correlation? = nil,
                    fitnessVsWaist: Correlation? = nil,
                    summary: IntervalReconciler.Summary? = nil) {
            self.fitnessScores = fitnessScores
            self.weight = weight
            self.waist = waist
            self.intervals = intervals
            self.fitnessVsWeight = fitnessVsWeight
            self.fitnessVsWaist = fitnessVsWaist
            self.summary = summary
        }

        public var isEmpty: Bool { fitnessScores.isEmpty && weight.isEmpty }

        /// Builds the whole model from a database. One call, so every platform
        /// shows exactly the same thing.
        public static func build(database: HealthDatabase,
                                 scores: [FitnessScore],
                                 range: ClosedRange<DayKey>?,
                                 policy: UnloggedDayPolicy = .reconcile) -> Model {
            let clipped = range.map { bounds in
                scores.filter { bounds.contains($0.day) }
            } ?? scores

            // The index is a trailing-window figure, so it needs to be paired
            // with the body metrics day by day to correlate honestly.
            var withIndex = database
            var byOrdinal: [Int: DailySummary] = [:]
            for day in database.days { byOrdinal[day.day.ordinal] = day }
            for score in scores {
                var summary = byOrdinal[score.day.ordinal]
                    ?? DailySummary(day: score.day)
                summary.values[.fitnessIndex] = score.value
                byOrdinal[score.day.ordinal] = summary
            }
            withIndex.days = byOrdinal.values.sorted { $0.day < $1.day }

            return Model(
                fitnessScores: clipped,
                weight: database.series(.bodyMass, in: range).rollingMean(window: 7),
                waist: database.series(.waistCircumference, in: range).rollingMean(window: 14),
                intervals: IntervalReconciler.intervals(database: database, range: range),
                fitnessVsWeight: CorrelationAnalysis.correlate(.fitnessIndex, with: .bodyMass,
                                                              in: withIndex, range: range),
                fitnessVsWaist: CorrelationAnalysis.correlate(.fitnessIndex, with: .waistCircumference,
                                                              in: withIndex, range: range),
                summary: IntervalReconciler.summarise(for: database, range: range, policy: policy))
        }
    }

    private let model: Model
    private let compact: Bool

    public init(model: Model, compact: Bool = false) {
        self.model = model
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.gridSpacing) {
            if model.isEmpty {
                Text("Not enough data yet. Fitness needs a few weeks of activity, and the body panel needs weigh-ins.")
                    .foregroundStyle(.secondary)
            } else {
                verdict
                fitnessChart
                bodyChart
                if !model.intervals.isEmpty { deficitChart }
                relationship
            }
        }
    }

    // MARK: - Verdict

    /// The sentence people actually want, before any chart.
    private var verdict: some View {
        Card {
            Text(verdictText)
                .font(compact ? .callout : .title3)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = model.summary, let measured = summary.measuredDailyDeficit {
                HStack(spacing: 22) {
                    figure("Measured deficit",
                           String(format: "%.0f kcal/day", abs(measured)),
                           measured >= 0 ? Theme.color(for: .improving) : Theme.color(for: .declining))
                    if let implied = summary.impliedUnloggedDailyIntake {
                        figure("Unlogged days averaged",
                               String(format: "%.0f kcal", implied), .secondary)
                    }
                    if let gap = summary.underLoggingPerDay, abs(gap) > 100 {
                        figure("Under-logged by",
                               String(format: "%.0f kcal/day", abs(gap)), .orange)
                    }
                }
            }
        }
    }

    private var verdictText: String {
        let indexChange = change(in: model.fitnessScores.map(\.value))
        let weightChange = change(in: model.weight.values)
        let waistChange = change(in: model.waist.values)

        var clauses: [String] = []
        if let indexChange, abs(indexChange) >= 2 {
            clauses.append("your fitness index \(indexChange > 0 ? "rose" : "fell") \(Format.decimal(abs(indexChange), fractionDigits: 0)) points")
        }
        if let weightChange, abs(weightChange) >= 0.5 {
            clauses.append("you \(weightChange < 0 ? "lost" : "gained") \(Format.decimal(abs(weightChange), fractionDigits: 1)) kg")
        }
        if let waistChange, abs(waistChange) >= 0.5 {
            clauses.append("your waist \(waistChange < 0 ? "came down" : "went up") \(Format.decimal(abs(waistChange), fractionDigits: 1)) cm")
        }

        guard !clauses.isEmpty else {
            return "Nothing has moved much over this period."
        }

        // The interesting case: fitness up while weight holds. The scale is not
        // the whole story and saying so plainly is the point of this screen.
        if let indexChange, let weightChange, indexChange >= 3, abs(weightChange) < 1,
           let waistChange, waistChange <= -1 {
            return "Over this period " + list(clauses)
                + ". Holding weight while the waist comes down and fitness rises is recomposition — the scale simply cannot see it."
        }
        return "Over this period " + list(clauses) + "."
    }

    // MARK: - Charts

    private var fitnessChart: some View {
        Card("Fitness index", subtitle: "A 0–100 rollup of the trailing 28 days") {
            Chart(model.fitnessScores) { score in
                AreaMark(x: .value("Day", score.day.localDate()),
                         y: .value("Index", score.value))
                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.28),
                                                         Color.accentColor.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", score.day.localDate()),
                         y: .value("Index", score.value))
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
            }
            .chartXScale(domain: sharedDomain)
            .chartYScale(domain: 0...100)
            .frame(height: compact ? 130 : 190)
        }
    }

    private var bodyChart: some View {
        Card("Weight and waist", subtitle: "Both smoothed — day-to-day weight is mostly water") {
            Chart {
                ForEach(model.weight.points) { point in
                    LineMark(x: .value("Day", point.day.localDate()),
                             y: .value("Weight", point.value),
                             series: .value("Series", "Weight"))
                    .foregroundStyle(Theme.color(for: .body))
                    .interpolationMethod(.monotone)
                }
                ForEach(model.waist.points) { point in
                    LineMark(x: .value("Day", point.day.localDate()),
                             y: .value("Waist", point.value),
                             series: .value("Series", "Waist"))
                    .foregroundStyle(Theme.color(for: .mobility))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: sharedDomain)
            .chartYScale(domain: bodyDomain)
            .frame(height: compact ? 130 : 190)

            HStack(spacing: 14) {
                swatch(Theme.color(for: .body), "Weight (kg)")
                if !model.waist.isEmpty {
                    swatch(Theme.color(for: .mobility), "Waist (cm)")
                } else {
                    Text("No waist measurements — the one thing that can tell fat loss from muscle loss.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var deficitChart: some View {
        Card("Measured deficit, between weigh-ins",
             subtitle: "From the scale, not the food diary — the diary only says where it came from") {
            Chart(model.intervals.filter { $0.plausibility != .unusable }) { interval in
                BarMark(x: .value("From", interval.start.day.localDate()),
                        y: .value("Deficit", interval.measuredDailyDeficit))
                .foregroundStyle(interval.measuredDailyDeficit >= 0
                                 ? Theme.color(for: .improving)
                                 : Theme.color(for: .declining))
                .cornerRadius(3)
            }
            .chartXScale(domain: sharedDomain)
            .frame(height: compact ? 100 : 140)
        }
    }

    // MARK: - Relationship

    private var relationship: some View {
        Card("Do they move together?") {
            VStack(alignment: .leading, spacing: 10) {
                correlationRow("Fitness and weight", model.fitnessVsWeight,
                               expected: "Fitness usually rises as weight comes down.")
                correlationRow("Fitness and waist", model.fitnessVsWaist,
                               expected: "Waist tracks fat more closely than weight does.")
                Text("Correlation is not cause. Both can move together because of a third thing — a training block, an illness, a holiday — and a strong number here is a prompt to look, not a conclusion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func correlationRow(_ title: String,
                                _ correlation: Correlation?,
                                expected: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.callout.weight(.medium)).frame(width: 160, alignment: .leading)
            if let correlation, correlation.isNoteworthy {
                Text("r = \(Format.decimal(correlation.r, fractionDigits: 2)) · \(correlation.strength)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(correlation.r < 0 ? Theme.color(for: .improving) : .secondary)
                Text("over \(correlation.count) days")
                    .font(.caption).foregroundStyle(.secondary)
            } else if correlation != nil {
                Text("no clear relationship yet").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(expected).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func figure(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
        }
    }

    private func swatch(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(colour).frame(width: 14, height: 3)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// All three panels share one x range, so they can be read against each
    /// other without any mental adjustment.
    private var sharedDomain: ClosedRange<Date> {
        var days: [DayKey] = model.fitnessScores.map(\.day)
        days += model.weight.points.map(\.day)
        days += model.waist.points.map(\.day)
        guard let first = days.min(), let last = days.max(), first < last else {
            let now = Date()
            return now.addingTimeInterval(-30 * 86_400)...now
        }
        return first.localDate()...last.localDate()
    }

    private var bodyDomain: ClosedRange<Double> {
        let values = model.weight.values + model.waist.values
        guard let low = values.min(), let high = values.max(), high > low else { return 0...100 }
        let padding = (high - low) * 0.12
        return (low - padding)...(high + padding)
    }

    private func change(in values: [Double]) -> Double? {
        guard let first = values.first, let last = values.last, values.count >= 2 else { return nil }
        return last - first
    }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
