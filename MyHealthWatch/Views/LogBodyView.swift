import SwiftUI
import HealthCore

/// Weight and waist, entered with the Digital Crown.
///
/// Waist matters here because weight alone cannot tell the difference between
/// losing fat and losing muscle — the Mac correlates the two and says which is
/// happening.
struct LogBodyView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var massKg = 80.0
    @State private var waistCm = 90.0
    @State private var editing: Field = .mass

    enum Field { case mass, waist }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                dial(title: "Weight",
                     value: String(format: "%.1f", massKg),
                     unit: "kg",
                     isActive: editing == .mass)
                .focusable(editing == .mass)
                .digitalCrownRotation($massKg, from: 30, through: 250, by: 0.1,
                                      sensitivity: .medium)
                .onTapGesture { editing = .mass }

                dial(title: "Waist",
                     value: String(format: "%.0f", waistCm),
                     unit: "cm",
                     isActive: editing == .waist)
                .focusable(editing == .waist)
                .digitalCrownRotation($waistCm, from: 50, through: 180, by: 0.5,
                                      sensitivity: .medium)
                .onTapGesture { editing = .waist }

                Button("Save both") {
                    Task { await model.logBody(massKg: massKg, waistCm: waistCm) }
                }
                .buttonStyle(.borderedProminent)

                Button("Weight only") {
                    Task { await model.logBody(massKg: massKg, waistCm: nil) }
                }
                .font(.caption2)
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Body")
        .overlay(alignment: .bottom) { ConfirmationBar() }
    }

    private func dial(title: String, value: String, unit: String, isActive: Bool) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isActive ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}
