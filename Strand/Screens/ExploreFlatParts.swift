import SwiftUI
import StrandDesign

// MARK: - Flat parts for the Explore family
//
// The Explore hub, the metric list and a metric's correlations are lists of rows on the flat canvas: a glyph on its
// quiet domain disc, a title over one quiet line, then whatever the row has to say on its right. These are the row,
// its hairline and the tap feedback they share, so the three pages cannot drift apart. They take plain values and
// know nothing about a screen's model.

extension LocalizedStringKey {
    /// A title that is data (a metric name the catalog already localised, a marker name the person typed). The key is
    /// built as an interpolation, so it is "%@" with the text as its argument: the text is never looked up as a
    /// catalog key and never read as markdown. Writing `self.init("\(text)")` would not do this: that literal is
    /// typed as a String, which makes the text itself the key.
    init(dataText: String) { self = "\(dataText)" }
}

/// A text role that, at the accessibility sizes, scales down to fit a long word instead of hyphenating it. SwiftUI
/// hyphenates a word wider than its column ("Durchschnitt-liche") before it scales when the type is a Dynamic Type
/// text style, so at those sizes this sets the same size through `ScaledMetric` (a fixed size that scales with Dynamic
/// Type itself), which scales first, and bounds the lines. Every smaller size keeps `standard`, the plain text style.
/// It is `microLabelFit` for the larger roles a row's title and line use. Set the ink on the `Text` before this.
private struct LongWordFit: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    private let standard: Font
    private let weight: Font.Weight
    private let lines: Int

    init(style: Font.TextStyle, standard: Font, weight: Font.Weight, lines: Int) {
        _size = ScaledMetric(wrappedValue: Self.base(style), relativeTo: style)
        self.standard = standard
        self.weight = weight
        self.lines = lines
    }

    /// The default-size point size of each role in use.
    private static func base(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .title2: 22
        case .body: 17
        case .subheadline: 15
        case .footnote: 13
        default: 17
        }
    }

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content
                .font(.system(size: size, weight: weight, design: .default))
                .lineLimit(lines)
                .minimumScaleFactor(0.5)
        } else {
            content.font(standard)
        }
    }
}

extension View {
    func longWordFit(_ style: Font.TextStyle, standard: Font, weight: Font.Weight, lines: Int) -> some View {
        modifier(LongWordFit(style: style, standard: standard, weight: weight, lines: lines))
    }
}

/// Where a row stacks its parts. From the largest standard text size up a row side by side would cut its words.
enum ExploreRowLayout {
    static func stacks(_ size: DynamicTypeSize) -> Bool { size >= .xxxLarge }
}

/// One row of a flat list: a glyph disc, a title over an optional quiet line, then a trailing view and a chevron.
/// The row is one spoken element, and stacks from `.xxxLarge`.
struct ExploreFlatRow<Trailing: View>: View {
    let symbol: String
    let tint: DomainTint
    let title: Text
    var subtitle: Text? = nil
    /// An optional third line under the subtitle, quieter still (how many days a figure rests on, say).
    var detail: Text? = nil
    var showsChevron = true
    /// What VoiceOver says for the whole row; nil reads the title, the line and the trailing view as they are shown.
    var spoken: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if ExploreRowLayout.stacks(typeSize) { stacked } else { inline }
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(SpokenRow(spoken: spoken))
    }

    private var inline: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            GlyphDisc(symbol, tint: tint)
            texts.layoutPriority(1)
            Spacer(minLength: NoopMetrics.space2)
            trailing().fixedSize(horizontal: true, vertical: false)
            if showsChevron { chevron }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                GlyphDisc(symbol, tint: tint)
                Spacer(minLength: 0)
                if showsChevron { chevron }
            }
            texts
            trailing()
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .foregroundStyle(StrandPalette.textPrimary)
                .longWordFit(.body, standard: StrandFont.body.weight(.semibold), weight: .semibold, lines: 3)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .foregroundStyle(StrandPalette.textSecondary)
                    .longWordFit(.footnote, standard: StrandFont.footnote, weight: .regular, lines: 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                detail
                    .foregroundStyle(StrandPalette.textTertiary)
                    .longWordFit(.footnote, standard: StrandFont.micro, weight: .regular, lines: 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }

    private struct SpokenRow: ViewModifier {
        let spoken: String?
        @ViewBuilder func body(content: Content) -> some View {
            if let spoken {
                content.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: spoken))
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
    }
}

extension ExploreFlatRow where Trailing == EmptyView {
    init(symbol: String, tint: DomainTint, title: Text, subtitle: Text? = nil, detail: Text? = nil,
         showsChevron: Bool = true, spoken: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, detail: detail,
                  showsChevron: showsChevron, spoken: spoken, trailing: { EmptyView() })
    }
}

/// The hairline between two rows, starting under the row's text: after the glyph when the row is side by side, at
/// the edge when it is stacked.
struct ExploreRowSeparator: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 38

    var body: some View {
        FlatRowSeparator(
            leadingInset: ExploreRowLayout.stacks(typeSize) ? 0 : GlyphDisc.diameter(scaled: scaledGlyph) + NoopMetrics.space3)
    }
}

extension FlatSectionSeparator {
    /// The hairline after a list of rows. A row pads its own bottom edge by `NoopMetrics.space3`, so the separator
    /// adds only a hair to reach the page's usual gap.
    static var afterExploreRows: FlatSectionSeparator {
        FlatSectionSeparator(above: FlatSectionRhythm.airAbove - NoopMetrics.space3)
    }

    /// The hairline before a list of rows with no header of their own, whose first row pads its own top edge.
    static var beforeExploreRows: FlatSectionSeparator {
        FlatSectionSeparator(below: FlatSectionRhythm.airBelow - NoopMetrics.space3)
    }
}

extension View {
    /// The press feedback and the selection tick of a row that pushes a screen. The tick is a simultaneous gesture,
    /// so the closure-based NavigationLink it sits on still pushes (a value + destination pairing double-pushed, #38).
    func exploreRowPress() -> some View {
        buttonStyle(FlatRowPressStyle())
        #if os(iOS)
            .simultaneousGesture(TapGesture().onEnded { StrandHaptic.selection.play() })
        #endif
    }
}

/// A message for a page or section with nothing to show yet: a spinner (or a glyph), a title and at most one
/// sentence. Loading reads as a spinner beside one quiet line, so a wait is never headlined like a result.
struct ExploreMessage: View {
    var symbol: String? = nil
    var isLoading = false
    let title: Text
    var message: Text? = nil

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    title
                        .foregroundStyle(StrandPalette.textTertiary)
                        .longWordFit(.subheadline, standard: StrandFont.subhead, weight: .medium, lines: 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let symbol { GlyphDisc(symbol, tint: .neutral) }
                    title
                        .foregroundStyle(StrandPalette.textPrimary)
                        .longWordFit(.title2, standard: StrandFont.title2, weight: .semibold, lines: 3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        message
                            .foregroundStyle(StrandPalette.textSecondary)
                            .longWordFit(.subheadline, standard: StrandFont.subhead, weight: .medium, lines: 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, NoopMetrics.space4)
        .accessibilityElement(children: .combine)
    }
}

/// The right side of a correlation row: the signed r over the strength word. Side by side it trails; a stacked row
/// (from `.xxxLarge`) has no right edge, so it lines both up with the row's text.
struct CorrelationTrailing: View {
    let value: String
    let word: String
    let color: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: ExploreRowLayout.stacks(typeSize) ? .leading : .trailing, spacing: NoopMetrics.space1) {
            Text(verbatim: value)
                .font(.system(.subheadline, design: .default).weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
            ValuePill(word, tint: color)
        }
    }
}

/// The W / M / 3M / 6M / 1Y / ALL control and the window it picks ("Last 30 days"). At the accessibility sizes six chips
/// would stack into a column taller than the chart above them, so one menu chip names the range and changes it. A range
/// `isEnabled` says no to stays visible but dimmed and inert (the Metric Explorer's #943 locking).
struct ExploreRangeControl: View {
    @Binding var selection: ExploreRange
    var isEnabled: (ExploreRange) -> Bool = { _ in true }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            menu
        } else {
            TrendsControlRow(
                leading: { _ in
                    Text(selection.title)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                },
                trailing: { picker }
            )
        }
    }

    /// The canonical segmented pill, announced as one adjustable "Range" control so VoiceOver reads "30 days" instead of
    /// the bare "M" (the same treatment the Trends tab gives it).
    private var picker: some View {
        let ranges = ExploreRange.allCases
        return SegmentedPillControl(ranges, selection: $selection, isEnabled: isEnabled) { $0.label }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Range")
            .accessibilityValue(selection.title)
            .accessibilityAdjustableAction { direction in
                guard let index = ranges.firstIndex(of: selection) else { return }
                switch direction {
                case .increment:
                    if let next = ranges[(index + 1)...].first(where: isEnabled) { selection = next }
                case .decrement:
                    if let previous = ranges[..<index].last(where: isEnabled) { selection = previous }
                default: break
                }
            }
            .accessibilityActions {
                ForEach(ranges.filter(isEnabled)) { option in
                    Button(option.title) { selection = option }
                }
            }
    }

    private var menu: some View {
        ChipMenu(
            verbatimTitle: selection.title,
            accessibilityLabel: "Range",
            accessibilityValue: selection.title
        ) {
            ForEach(ExploreRange.allCases) { option in
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
                .disabled(!isEnabled(option))
            }
        }
    }
}
