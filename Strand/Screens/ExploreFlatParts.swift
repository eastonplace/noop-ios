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
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                subtitle
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
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
    init(symbol: String, tint: DomainTint, title: Text, subtitle: Text? = nil, showsChevron: Bool = true,
         spoken: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, showsChevron: showsChevron,
                  spoken: spoken, trailing: { EmptyView() })
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
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    if let symbol { GlyphDisc(symbol, tint: .neutral) }
                    title
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        message
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
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
