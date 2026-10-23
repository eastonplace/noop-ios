import SwiftUI
import StrandDesign
import StrandAnalytics

/// One insight as a flat row: the sentence, optionally a two-bar with/without comparison, then a
/// quiet line with where it came from, how many days it rests on and how sure NOOP is.
struct InsightRowView: View {
    let row: InsightRow
    var showsComparison = true

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(row.sentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if showsComparison {
                InsightComparisonBars(row: row)
                    .padding(.top, 2)
            }
            meta
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(row.source.label)
            if showsComparison {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(row.countsText)
            }
            Text(verbatim: "·").accessibilityHidden(true)
            Circle()
                .fill(confidenceColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(row.confidenceWord)
                .foregroundStyle(StrandPalette.textSecondary)
                .fontWeight(.semibold)
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var confidenceColor: Color {
        switch row.effect.confidence {
        case .solid: return StrandPalette.statusPositive
        case .building: return StrandPalette.statusWarning
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    private var accessibilityText: String {
        String(localized: "\(row.sentence) \(row.withLabel): \(row.outcome.format(row.effect.effect.meanWith)). \(row.withoutLabel): \(row.outcome.format(row.effect.effect.meanWithout)). \(row.source.label), \(row.countsText), \(row.confidenceWord).")
    }
}

/// Two thin bars, the factor's side tinted by whether it lined up with a better or worse outcome
/// and the other side neutral, each with its average.
struct InsightComparisonBars: View {
    let row: InsightRow

    var body: some View {
        let e = row.effect.effect
        let scale = barScale(e)
        VStack(spacing: 6) {
            bar(label: row.withLabel, value: e.meanWith, fraction: e.meanWith / scale,
                tint: row.movedGood ? StrandPalette.statusPositive : StrandPalette.destructive)
            bar(label: row.withoutLabel, value: e.meanWithout, fraction: e.meanWithout / scale,
                tint: StrandPalette.textTertiary.opacity(0.7))
        }
        .accessibilityHidden(true)
    }

    /// Scores share a 0–100 axis; HRV and resting heart rate scale to the larger side.
    private func barScale(_ e: BehaviorEffect) -> Double {
        switch row.outcome {
        case .recovery, .sleep: return 100
        case .hrv, .rhr: return max(1, max(e.meanWith, e.meanWithout) * 1.15)
        }
    }

    private func bar(label: String, value: Double, fraction: Double, tint: Color) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(StrandPalette.hairline)
                    Rectangle().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            Text(row.outcome.format(value))
                .font(StrandFont.captionNumber.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }
}

/// The plain row that opens another page: a glyph with no disc behind it, a title, an optional
/// quiet line and a chevron.
struct InsightsLinkRow: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
}
