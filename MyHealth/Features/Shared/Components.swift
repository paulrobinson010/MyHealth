import SwiftUI
import Charts
import HealthCore
import HealthUI

/// Small headline number with an optional trend arrow underneath.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var trend: MetricTrend? = nil
    var symbolName: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .foregroundStyle(tint)
                        .font(.caption)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let trend {
                TrendBadge(trend: trend)
            } else if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// "+12% vs previous 28 days", coloured by whether that is good news.
struct TrendBadge: View {
    let trend: MetricTrend
    var showsWindow: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trend.direction.symbolName)
                .font(.caption2.weight(.bold))
            Text(Format.percentChange(trend.changeVsPrevious))
                .font(.caption2.weight(.medium))
            if showsWindow {
                Text("vs prev \(trend.window)d")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Theme.color(for: trend.direction))
        .help(helpText)
    }

    private var helpText: String {
        var parts: [String] = []
        if let current = trend.current {
            parts.append("Last \(trend.window) days: \(Format.metric(current, trend.metric))")
        }
        if let previous = trend.previous {
            parts.append("Previous \(trend.window) days: \(Format.metric(previous, trend.metric))")
        }
        if let year = trend.changeVsYearAgo {
            parts.append("Vs a year ago: \(Format.percentChange(year))")
        }
        return parts.joined(separator: "\n")
    }
}

/// The big fitness index dial.
struct ScoreRing: View {
    let score: Double
    let band: FitnessBand
    var diameter: CGFloat = 180
    var caption: String?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: diameter * 0.09)
            Circle()
                .trim(from: 0, to: max(0.001, score / 100))
                .stroke(
                    AngularGradient(
                        colors: [Theme.color(for: band).opacity(0.65), Theme.color(for: band)],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: diameter * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            VStack(spacing: 2) {
                Text(Format.decimal(score, fractionDigits: 0))
                    .font(.system(size: diameter * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(band.title)
                    .font(.system(size: diameter * 0.09, weight: .medium))
                    .foregroundStyle(Theme.color(for: band))
                if let caption {
                    Text(caption)
                        .font(.system(size: diameter * 0.065))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Fitness index \(Int(score)), \(band.title)")
    }
}

/// Compact line for a metric, no axes — for use inside tiles and table rows.
struct Sparkline: View {
    let points: [TimeSeries.Point]
    var tint: Color = .accentColor
    var showsArea: Bool = true

    var body: some View {
        if points.count < 2 {
            Rectangle().fill(.clear)
        } else {
            Chart {
                ForEach(points) { point in
                    if showsArea {
                        AreaMark(x: .value("Day", point.day.localDate()),
                                 y: .value("Value", point.value))
                        .foregroundStyle(
                            LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom))
                    }
                    LineMark(x: .value("Day", point.day.localDate()),
                             y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .chartLegend(.hidden)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.12, 0.0001)
        return (low - padding)...(high + padding)
    }
}

/// GitHub-style calendar grid: weeks across, days down.
struct CalendarHeatmap: View {
    let cells: [ActivityStats.HeatmapCell]
    let metric: Metric
    var cellSize: CGFloat = 11
    var spacing: CGFloat = 3

    private var weeks: [[ActivityStats.HeatmapCell?]] {
        guard let first = cells.first else { return [] }
        // Pad the first column so rows line up with Monday...Sunday.
        var padded: [ActivityStats.HeatmapCell?] = Array(
            repeating: nil, count: (first.day.weekday + 6) % 7)
        padded.append(contentsOf: cells.map { Optional($0) })
        while padded.count % 7 != 0 { padded.append(nil) }
        return stride(from: 0, to: padded.count, by: 7).map {
            Array(padded[$0..<min($0 + 7, padded.count)])
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { index in
                            let cell = index < week.count ? week[index] : nil
                            RoundedRectangle(cornerRadius: 2)
                                .fill(cell == nil ? Color.clear : Theme.heatColor(cell?.intensity))
                                .frame(width: cellSize, height: cellSize)
                                .help(tooltip(for: cell))
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tooltip(for cell: ActivityStats.HeatmapCell?) -> String {
        guard let cell else { return "" }
        guard let value = cell.value else { return "\(Format.day(cell.day)) — no data" }
        return "\(Format.day(cell.day)) — \(Format.metric(value, metric))"
    }
}

/// The 1M / 3M / 1Y / All control shared by every chart screen.
enum DateRangeOption: String, CaseIterable, Identifiable {
    case month = "1M"
    case quarter = "3M"
    case halfYear = "6M"
    case year = "1Y"
    case twoYears = "2Y"
    case all = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .month: return 30
        case .quarter: return 90
        case .halfYear: return 182
        case .year: return 365
        case .twoYears: return 730
        case .all: return nil
        }
    }

    /// Sensible chart bucket for the span, so a 2-year chart is not 730 bars.
    var bucket: TimeSeries.Bucket {
        switch self {
        case .month, .quarter: return .day
        case .halfYear, .year: return .week
        case .twoYears: return .month
        case .all: return .month
        }
    }

    func range(in database: HealthDatabase) -> ClosedRange<DayKey>? {
        guard let full = database.dateRange else { return nil }
        guard let days else { return full }
        let start = full.upperBound.adding(days: -(days - 1))
        return max(start, full.lowerBound)...full.upperBound
    }
}

struct DateRangePicker: View {
    @Binding var selection: DateRangeOption

    var body: some View {
        Picker("Range", selection: $selection) {
            ForEach(DateRangeOption.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 320)
    }
}

/// Shown on every screen before any data has been loaded.
struct EmptyStateView: View {
    let symbolName: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Grid that reflows tiles to fill the window width.
struct TileGrid<Content: View>: View {
    var minimumWidth: CGFloat = 170
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 12)],
            spacing: 12) {
            content
        }
    }
}
