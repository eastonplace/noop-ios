import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Insight rows
//
// Built in the Heads-Up detail page's language: a bare SF Symbol, a semibold title, a footnote line with the
// numbers, a trailing signed change and one thin rail. Helps read in the accent, hurts in the warning amber.

enum InsightInk {
    static func tint(_ row: InsightRow) -> Color {
        row.movedGood ? StrandPalette.accent : StrandPalette.statusWarning
    }
}

/// One finding on the Insights page: icon, factor name, "62% vs 54% · 87 vs 33 nights · Solid", the signed change,
/// then a rail with the with and without averages as two dots on the section's shared scale.
struct InsightFindingRow: View {
    let row: InsightRow
    /// The value range the section's rails share, so rows in one section compare by eye.
    let scale: ClosedRange<Double>

    static let iconColumn: CGFloat = 24

    var body: some View {
        let ink = InsightInk.tint(row)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: row.symbol)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: Self.iconColumn, height: 22, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.rowTitle)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: row.detailLine)
                        .font(StrandFont.footnote)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(verbatim: row.deltaText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            InsightRail(with: row.effect.effect.meanWith, without: row.effect.effect.meanWithout,
                        scale: scale, ink: ink)
                .padding(.leading, Self.iconColumn + NoopMetrics.space3)
        }
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.sentence) \(row.countsText), \(row.confidenceWord)."))
    }
}

/// A thin rail with two dots: the factor's average in its ink, the other side's in grey, and the stretch
/// between them drawn a shade stronger.
struct InsightRail: View {
    let with: Double
    let without: Double
    let scale: ClosedRange<Double>
    let ink: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(0.0001, scale.upperBound - scale.lowerBound)
            let x: (Double) -> CGFloat = { v in
                CGFloat(min(1, max(0, (v - scale.lowerBound) / span))) * width
            }
            let a = x(with), b = x(without)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.hairline)
                    .frame(height: 4)
                Capsule(style: .continuous).fill(StrandPalette.hairlineStrong)
                    .frame(width: abs(a - b), height: 4)
                    .offset(x: min(a, b))
                dot(StrandPalette.textTertiary).offset(x: min(max(0, b - 4), max(0, width - 8)))
                dot(ink).offset(x: min(max(0, a - 4), max(0, width - 8)))
            }
            .frame(width: width, height: 8)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(StrandPalette.appCanvas, lineWidth: 1.5))
    }
}

/// The compact Trends row: icon, factor name and the signed change with its outcome ("+8 pts recovery").
struct InsightCompactRow: View {
    let row: InsightRow

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: row.symbol)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: InsightFindingRow.iconColumn, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: row.rowTitle)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: NoopMetrics.space2)
            Text(verbatim: row.deltaWithOutcome)
                .font(StrandFont.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(InsightInk.tint(row))
                .lineLimit(1)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.sentence))
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
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: InsightFindingRow.iconColumn, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
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
