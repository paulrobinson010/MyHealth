import SwiftUI

enum Theme {
    static let cardCornerRadius: CGFloat = 12
    static let gridSpacing: CGFloat = 16

    static func color(for band: FitnessBand) -> Color {
        switch band {
        case .needsWork: return Color(red: 0.85, green: 0.42, blue: 0.35)
        case .fair: return Color(red: 0.90, green: 0.64, blue: 0.28)
        case .good: return Color(red: 0.42, green: 0.70, blue: 0.42)
        case .strong: return Color(red: 0.24, green: 0.62, blue: 0.78)
        case .elite: return Color(red: 0.45, green: 0.40, blue: 0.86)
        }
    }

    static func color(for category: MetricCategory) -> Color {
        switch category {
        case .activity: return Color(red: 0.36, green: 0.66, blue: 0.44)
        case .heart: return Color(red: 0.83, green: 0.35, blue: 0.42)
        case .body: return Color(red: 0.46, green: 0.52, blue: 0.80)
        case .fitness: return Color(red: 0.30, green: 0.60, blue: 0.78)
        case .mobility: return Color(red: 0.79, green: 0.57, blue: 0.28)
        case .wellbeing: return Color(red: 0.52, green: 0.44, blue: 0.72)
        }
    }

    static func color(for direction: TrendDirection) -> Color {
        switch direction {
        case .improving: return Color(red: 0.24, green: 0.62, blue: 0.38)
        case .declining: return Color(red: 0.80, green: 0.34, blue: 0.32)
        case .steady, .unknown: return .secondary
        }
    }

    /// Ramp used by the calendar heatmap, low to high.
    static func heatColor(_ intensity: Double?) -> Color {
        guard let intensity else { return Color.secondary.opacity(0.08) }
        let clamped = intensity.clamped(to: 0...1)
        return Color(red: 0.32 + 0.10 * clamped,
                     green: 0.55 + 0.24 * clamped,
                     blue: 0.42 - 0.10 * clamped)
        .opacity(0.20 + 0.80 * clamped)
    }
}

/// Standard card chrome so every panel in the app matches.
struct Card<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    var accessory: AnyView? = nil
    @ViewBuilder var content: Content

    init(_ title: String? = nil,
         subtitle: String? = nil,
         accessory: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || subtitle != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title).font(.headline)
                        }
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}
