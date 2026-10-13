import SwiftUI

// MARK: - Eyebrow

/// What sits at the trailing edge of a section eyebrow.
public enum EyebrowTrailing {
    case none
    /// Secondary text, usually the record's date.
    case text(String)
    /// A status pill (no leading dot). The title is looked up in the app's string table, like `StatePill`'s.
    case pill(LocalizedStringKey, tone: StrandTone)
    /// A status pill followed by secondary text (for example "Stale" then a date).
    case pillAndText(LocalizedStringKey, tone: StrandTone, text: String)
    /// Any view you need.
    case custom(AnyView)

    /// The record-date treatment: the record's actual date, plus a "Stale" pill when the newest record
    /// is older than the window that was read. Either may be absent.
    public static func record(date: String?, isStale: Bool) -> EyebrowTrailing {
        switch (isStale, date) {
        case (true, let date?): return .pillAndText("Stale", tone: .warning, text: date)
        case (true, nil): return .pill("Stale", tone: .warning)
        case (false, let date?): return .text(date)
        case (false, nil): return .none
        }
    }
}

/// The header of a section or card: a leading symbol in the domain colour, a letter-spaced caps title,
/// and a trailing date, pill or view. Works on the flat canvas and inside a `WidgetCard` alike.
public struct SectionEyebrow: View {
    private let titleText: Text
    public var systemImage: String?
    public var tint: DomainTint
    public var trailing: EyebrowTrailing
    /// A trailing chevron, for a header that is itself a tap target.
    public var showsChevron: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        title: String,
        systemImage: String? = nil,
        tint: DomainTint = .neutral,
        trailing: EyebrowTrailing = .none,
        showsChevron: Bool = false
    ) {
        self.titleText = Text(verbatim: title)
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.showsChevron = showsChevron
    }

    /// Localized-title form, for call sites that already pass a `LocalizedStringKey` (such as `SectionHeader`).
    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tint: DomainTint = .neutral,
        trailing: EyebrowTrailing = .none,
        showsChevron: Bool = false
    ) {
        self.titleText = Text(title)
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.showsChevron = showsChevron
    }

    /// One row at ordinary sizes. The title wraps to a second line before it truncates (a long German title with a
    /// date beside it) and the trailing date or pill keeps its full width, so a record's date is never the thing
    /// that gives way. At accessibility sizes the trailing item drops under the title so both wrap freely.
    /// A title that fits on one line lays out exactly as it always did. A word wider than the row scales the title down
    /// (down to half) instead of hyphenating it, at every size (`strandOverlineFitted`).
    public var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(spacing: NoopMetrics.space2) {
                    leadingSymbol
                    titleText.strandOverlineFitted().lineLimit(3).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: NoopMetrics.space2)
                    chevron
                }
                if hasTrailing {
                    HStack(spacing: NoopMetrics.space2) { trailingView }
                }
            }
        } else {
            HStack(spacing: NoopMetrics.space2) {
                leadingSymbol
                titleText.strandOverlineFitted().lineLimit(2).layoutPriority(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: NoopMetrics.space2)
                trailingView
                chevron
            }
        }
    }

    private var hasTrailing: Bool {
        if case .none = trailing { return false }
        return true
    }

    @ViewBuilder private var leadingSymbol: some View {
        if let systemImage {
            Image(systemName: systemImage).font(StrandFont.caption).foregroundStyle(tint.accent)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .text(let text):
            trailingText(text)
        case .pill(let title, let tone):
            pill(title, tone: tone)
        case .pillAndText(let title, let tone, let text):
            pill(title, tone: tone)
            trailingText(text)
        case .custom(let view):
            view
        }
    }

    /// The pill keeps its natural size (it is one short word) and wins the width over the title. At accessibility
    /// sizes it sits under the title and may be a long translated phrase ("Creazione in corso", "Calibration en
    /// cours") at a type size that makes it wider than the row, so only its height is fixed there: the label wraps
    /// and scales as `StatePill` does at those sizes instead of running past the gutter.
    private func pill(_ title: LocalizedStringKey, tone: StrandTone) -> some View {
        StatePill(title, tone: tone, showsDot: false)
            .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
            .layoutPriority(2)
    }

    /// One line at ordinary sizes, wins the width over the title; wraps at accessibility sizes.
    private func trailingText(_ text: String) -> some View {
        Text(text).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            // Under the title at accessibility sizes the text is left-aligned with it; beside the title it is
            // right-aligned. (Right-aligned lines in a left-hugging box read as centred.)
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            .layoutPriority(2)
    }
}

// MARK: - Hero value

/// A huge rounded numeral with a small unit and an optional caption. A value of "—" reads in the
/// tertiary ink, never as zero.
public struct HeroValue: View {
    public enum CaptionPlacement: Sendable {
        /// Right-aligned on the value's baseline.
        case trailing
        /// Under the value.
        case below
    }

    private let value: String
    private let unit: String?
    private let caption: String?
    private let captionPlacement: CaptionPlacement
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = WidgetMetrics.heroValueSize

    public init(
        value: String,
        unit: String? = nil,
        caption: String? = nil,
        captionPlacement: CaptionPlacement = .trailing,
        size: CGFloat = WidgetMetrics.heroValueSize
    ) {
        self.value = value
        self.unit = unit
        self.caption = caption
        self.captionPlacement = captionPlacement
        _size = ScaledMetric(wrappedValue: size, relativeTo: .title)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(StrandFont.number(size, weight: .bold))
                    .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let unit {
                    Text(unit).foregroundStyle(StrandPalette.textTertiary).captionLabelFit(lines: 1)
                }
                if let caption, captionPlacement == .trailing {
                    Spacer(minLength: NoopMetrics.space2)
                    Text(caption).foregroundStyle(StrandPalette.textTertiary).microLabelFit()
                }
            }
            if let caption, captionPlacement == .below {
                Text(caption).foregroundStyle(StrandPalette.textTertiary).microLabelFit()
            }
        }
    }
}

// MARK: - Metric row

/// Icon, label and a right-aligned tabular value. Missing values read "—" in the tertiary ink and drop
/// their unit.
public struct MetricValueRow: View {
    private let systemImage: String
    private let label: String
    private let value: String
    private let unit: String?
    private let tint: DomainTint

    public init(systemImage: String, label: String, value: String, unit: String? = nil, tint: DomainTint = .neutral) {
        self.systemImage = systemImage
        self.label = label
        self.value = value
        self.unit = unit
        self.tint = tint
    }

    public var body: some View {
        let missing = value == WidgetMetrics.missingValue
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: systemImage).font(StrandFont.caption).foregroundStyle(tint.accent)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            // One line at every size short of the accessibility sizes, where the label may take a second.
            Text(label).foregroundStyle(StrandPalette.textSecondary)
                .captionLabelFit(lines: 2, standardLines: 1)
            Spacer(minLength: NoopMetrics.space1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(StrandFont.bodyNumber)
                    .foregroundStyle(missing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                if let unit, !missing {
                    Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .lineLimit(1)
        }
    }
}

// MARK: - Stat footer

/// Label-over-value columns: the Low / Average / High footer under a chart, or a three-column fact strip.
public struct StatFooter: View {
    public enum Style: Sendable {
        /// Body-sized values in equal columns (a chart footer).
        case compact
        /// Large values with hairline dividers; steps down in size, then wraps, before truncating.
        case prominent
    }

    private let items: [(label: String, value: String)]
    private let style: Style
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = WidgetMetrics.statValueSize
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(items: [(label: String, value: String)], style: Style = .compact) {
        self.items = items
        self.style = style
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            columnsBody
        }
    }

    /// At the accessibility sizes three columns are too narrow for a label and its value, and a wrapped label in one
    /// column pushes its value out of line with the next. Each fact gets a full-width row of its own instead, label over
    /// value, in the order the columns had.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).foregroundStyle(StrandPalette.textTertiary).microLabelFit()
                    Text(item.value)
                        .font(StrandFont.number(style == .prominent ? valueSize * 0.7 : valueSize * 0.5, weight: .semibold))
                        .foregroundStyle(item.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var columnsBody: some View {
        switch style {
        case .compact:
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.label).foregroundStyle(StrandPalette.textTertiary).microLabelFit()
                        Text(item.value).font(StrandFont.bodyNumber)
                            .foregroundStyle(item.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .prominent:
            // One shared value size for every column: the largest that fits on one line, else a smaller
            // shared size that may wrap to two lines. Columns never shrink independently.
            ViewThatFits(in: .horizontal) {
                columns(size: valueSize, lines: 1)
                columns(size: valueSize * 0.85, lines: 1)
                columns(size: valueSize * 0.7, lines: 2)
            }
        }
    }

    private func columns(size: CGFloat, lines: Int) -> some View {
        let shown = Array(items.prefix(3))
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 34)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label).foregroundStyle(StrandPalette.textTertiary).microLabelFit(lines: 1, standardLines: 1)
                    Text(item.value)
                        .font(StrandFont.number(size, weight: .semibold))
                        .foregroundStyle(item.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        .lineLimit(lines)
                        // One-line sizes report their full width, so ViewThatFits moves to the next
                        // shared size instead of truncating a single column.
                        .fixedSize(horizontal: lines == 1, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                .padding(.trailing, index == shown.count - 1 ? 0 : NoopMetrics.space3)
            }
        }
    }
}

// MARK: - Gauge layout

/// A gauge beside its metric rows. Falls back to stacked at accessibility text sizes so nothing truncates.
public struct GaugeLayout<Gauge: View, Rows: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder private let gauge: () -> Gauge
    @ViewBuilder private let rows: () -> Rows

    public init(@ViewBuilder gauge: @escaping () -> Gauge, @ViewBuilder rows: @escaping () -> Rows) {
        self.gauge = gauge
        self.rows = rows
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                gauge()
                rows()
            }
        } else {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                gauge()
                VStack(alignment: .leading, spacing: NoopMetrics.space3) { rows() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
