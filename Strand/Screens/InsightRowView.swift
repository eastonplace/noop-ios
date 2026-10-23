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
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: InsightRow
    /// The value range the section's rails share, so rows in one section compare by eye.
    let scale: ClosedRange<Double>

    static let iconColumn: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        InsightRowIcon(symbol: row.symbol)
                        title
                    }
                    detail
                    delta
                }
            } else {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    InsightRowIcon(symbol: row.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        detail
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    delta.lineLimit(1)
                }
            }
            InsightRail(with: row.effect.effect.meanWith, without: row.effect.effect.meanWithout,
                        scale: scale, ink: InsightInk.tint(row))
                .padding(.leading, typeSize.isAccessibilitySize ? 0 : Self.iconColumn + NoopMetrics.space3)
        }
        .padding(.vertical, NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.sentence) \(row.countsText), \(row.confidenceWord)."))
    }

    private var title: some View {
        Text(verbatim: row.rowTitle)
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detail: some View {
        Text(verbatim: row.detailLine)
            .font(StrandFont.footnote)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var delta: some View {
        Text(verbatim: row.deltaText)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(InsightInk.tint(row))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Decorative glyphs retain their own reserved geometry as the adjacent text grows.
/// They are hidden from VoiceOver; the complete meaning stays in the row's text/label.
struct InsightRowIcon: View {
    let symbol: String
    var compact = false
    var tint: Color = StrandPalette.textSecondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: InsightFindingRow.iconColumn, height: 22, alignment: .leading)
            .accessibilityHidden(true)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: InsightRow

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        InsightRowIcon(symbol: row.symbol, compact: true)
                        title.fixedSize(horizontal: false, vertical: true)
                    }
                    delta.fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, NoopMetrics.space1)
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    InsightRowIcon(symbol: row.symbol, compact: true)
                    title.lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: NoopMetrics.space2)
                    delta.lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.sentence))
    }

    private var title: some View {
        Text(verbatim: row.rowTitle)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
    }

    private var delta: some View {
        Text(verbatim: row.deltaWithOutcome)
            .font(StrandFont.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(InsightInk.tint(row))
    }
}

/// The plain row that opens another page: a glyph with no disc behind it, a title, an optional
/// quiet line and a chevron.
struct InsightsLinkRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let symbol: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: NoopMetrics.space3) {
            InsightRowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Expanded no-difference factors use a separate count line at accessibility text sizes.
struct InsightUnclearFactorRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let factor: UnclearFactor

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        icon
                        title
                    }
                    checked
                }
                .padding(.vertical, NoopMetrics.space1)
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    icon
                    title
                    Spacer(minLength: NoopMetrics.space2)
                    checked
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        InsightRowIcon(symbol: InsightWords.symbol(factor.source), compact: true, tint: StrandPalette.textTertiary)
    }

    private var title: some View {
        Text(verbatim: factor.name)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var checked: some View {
        Text(verbatim: factor.checkedText)
            .font(StrandFont.footnote)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
