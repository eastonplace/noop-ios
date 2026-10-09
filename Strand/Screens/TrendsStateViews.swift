import SwiftUI
import StrandDesign

// MARK: - Trends states in the widget design language
//
// The error banner and the no-history / loading states, composed from the same primitives as the live
// sections: an eyebrow, a hero value, quiet pills and chips. Missing values read "—", never zero.

/// "Trends could not refresh": one deliberate, bounded card in the warning tint with a retry chip.
struct TrendsErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        WidgetCard(
            title: String(localized: "Trends could not refresh"),
            systemImage: "exclamationmark.triangle.fill",
            tint: .custom(StrandPalette.statusWarning)
        ) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRetry) {
                    TrendsChip("Try again", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Try again")
                .accessibilityHint("Reloads Trends")
            }
        }
        .accessibilityIdentifier("trends.error")
    }
}

/// What Trends shows before there is any history to draw: the section shape of the live screen with every
/// figure left as "—" and a flat rail where the chart will be.
struct TrendsEmptyState: View {
    let isLoaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Trends"),
                systemImage: "chart.xyaxis.line",
                tint: .neutral,
                trailing: .pill(isLoaded ? String(localized: "No history") : String(localized: "Loading"), tone: .neutral)
            )
            HeroValue(
                value: WidgetMetrics.missingValue,
                caption: isLoaded ? String(localized: "No days recorded yet") : String(localized: "Reading your history"),
                captionPlacement: .below
            )
            TrendsGhostRail()
            Text(isLoaded
                ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                : "Loading your history…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trends.empty")
    }
}

/// A chart's place before it has data: three faint rails and a flat line, never a fabricated trace.
struct TrendsGhostRail: View {
    var height: CGFloat = 112

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    Rectangle()
                        .fill(StrandPalette.hairline.opacity(0.7))
                        .frame(height: 1)
                }
            }
            Capsule(style: .continuous)
                .fill(StrandPalette.hairlineStrong)
                .frame(height: 2)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
