import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum NoopMetrics {
    public static let cardRadius: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let gap: CGFloat = 18
    public static let sectionGap: CGFloat = 24
    public static let screenPadding: CGFloat = 20
    public static let tileHeight: CGFloat = 96   // Design Reset: tighter metric tile
    // Key Metrics grid: one fixed height every tile snaps to, so a sparkline-and-caption tile and a
    // plain value tile read the same. maxHeight: .infinity can't equalise them inside a LazyVGrid (the
    // grid only offers a cell its content height, so there's nothing for the shorter tile to grow into),
    // so we pin a single height that clears the tallest layout (value + inline sparkline + caption).
    public static let keyMetricTileHeight: CGFloat = 122
    public static let chartHeight: CGFloat = 230
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar

    // MARK: Paper proportion contract (spec 002 C5)
    // Keep the acceptance dimensions here so score, chart, and dashboard primitives
    // cannot quietly drift apart again.
    public static let trioRingDiameter: CGFloat = 72
    public static let trioRingLineWidth: CGFloat = 4.5
    public static let trioRingNumeralSize: CGFloat = 30
    public static let heroRingDiameter: CGFloat = 104
    public static let heroRingLineWidth: CGFloat = 6.5
    public static let heroRingNumeralSize: CGFloat = 48
    public static let liveRunTimerSize: CGFloat = 64
    public static let healthTileIconSize: CGFloat = 16
    public static let healthTileLabelSize: CGFloat = 13
    public static let healthTileValueSize: CGFloat = 24
    public static let healthTileSparklineHeight: CGFloat = 16
    public static let healthTileMinHeight: CGFloat = 68
    public static let stressTimelineHeight: CGFloat = 4
    public static let chartLineWidth: CGFloat = 2.5
    public static let iconCircleDiameter: CGFloat = 34

    // MARK: Standardised spacing scale (the ONE source of truth for margins)
    //
    // A 4pt-based ramp. Reach for these instead of literal numbers so every gap,
    // inset and margin lines up to the same grid. Note `cardPadding` (16) above is
    // the same value as `space4` — kept as a named alias for the existing call sites.
    public static let space1:  CGFloat = 4
    public static let space2:  CGFloat = 8
    public static let space3:  CGFloat = 12
    public static let space4:  CGFloat = 16
    public static let space5:  CGFloat = 20
    public static let space6:  CGFloat = 24
    public static let space8:  CGFloat = 32
    public static let space10: CGFloat = 40
    public static let space12: CGFloat = 48
    public static let space16: CGFloat = 64

    // MARK: Named layout constants — the canonical margins/heights screens compose with.
    /// Horizontal page margin (the gutter on the left/right edge of a screen). Use via `.screenPadding()`.
    public static let screenHPadding: CGFloat = 20
    /// Vertical gap between top-level page sections.
    public static let sectionSpacing: CGFloat = 24
    /// Interior padding inside a card's content (matches `cardPadding`).
    public static let cardInnerPadding: CGFloat = 16
    /// Vertical gap between stacked elements INSIDE a card.
    public static let cardInnerSpacing: CGFloat = 10
    /// Vertical gap between rows in a list-style card.
    public static let rowSpacing: CGFloat = 18
    /// Standard interactive-control height (buttons, fields, segmented controls).
    public static let controlHeight: CGFloat = 56
    public static let rowHeight: CGFloat = 56
    public static let navBarHeight: CGFloat = 76
    public static let radius1: CGFloat = 8
    public static let radius2: CGFloat = 12
    public static let radius3: CGFloat = 16
    public static let radius4: CGFloat = 20
    public static let radius5: CGFloat = 22
    public static let radius6: CGFloat = 28
    public static let radius7: CGFloat = 32
    /// Fully-rounded corner radius — pills, chips, capsule buttons.
    public static let pillRadius: CGFloat = 999
}

// MARK: - Screen padding

public extension View {
    /// Apply the canonical horizontal page gutter (`NoopMetrics.screenHPadding`). The single
    /// source of truth for left/right screen margins — use this instead of a literal padding so
    /// every screen lines up to the same edge.
    func screenPadding() -> some View {
        self.padding(.horizontal, NoopMetrics.screenHPadding)
    }
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: the drag indicator (the touch affordance that says
    /// "swipe to dismiss") plus detents. macOS sheets are free-floating windows and must
    /// NOT receive this, so the helper is iOS-only and call sites stay shared via #if.
    /// `largeFirst == false` opens at .medium with .large reachable by dragging up (short
    /// forms); `true` opens full-height (long scrolls).
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        self
            .presentationDragIndicator(.visible)
            .presentationDetents(largeFirst ? [.large] : [.medium, .large])
    }
}
#endif

// MARK: - Surface

/// The one card surface — now the Bevel frosted card. PUBLIC API is unchanged
/// (padding + content); an optional `tint` was ADDED (defaulted) so callers can opt
/// into a per-domain accent wash without breaking existing call sites.
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    @Environment(\.contentSurfacePresentation) private var contentSurfacePresentation
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = NoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    @ViewBuilder public var body: some View {
        #if os(iOS)
        if contentSurfacePresentation == .flat {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, min(padding, NoopMetrics.space3))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        } else {
            boundedBody
        }
        #else
        boundedBody
        #endif
    }

    private var boundedBody: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome (fill + border + shadow) lives in the background so its animation is
            // scoped to the card surface ONLY. It must never animate the content() subtree, or a
            // chart inside re-animates its line every time the cursor crosses the card. (#104)
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static resting frosted surface — no
    // hover @State, no .onHover tracking, no .animation node. That trims the modifier
    // count on every card, which multiplies across long scrolling lists. macOS adds the
    // hover emphasis border on top (with the #104 animation scoping) unchanged.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1).opacity(hover ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.16), value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

/// A section's header. On iOS, without an `overline` it is the widget-language eyebrow (letter-spaced caps
/// title, optional leading domain symbol, trailing date or status text), so every section reads like a
/// Coach card header. With an `overline`, and on macOS/watchOS, it keeps the established look.
public struct SectionHeader: View {
    let overline: LocalizedStringKey?; let title: LocalizedStringKey; let trailing: String?
    let systemImage: String?; let tint: DomainTint
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil,
                systemImage: String? = nil, tint: DomainTint = .neutral) {
        self.title = title; self.overline = overline; self.trailing = trailing
        self.systemImage = systemImage; self.tint = tint
    }
    public var body: some View {
        #if os(iOS)
        if overline == nil {
            // SectionHeader's trailing value is display-only. Interactive headers must supply
            // their own Button/NavigationLink so link blue never lies about a static status/count.
            SectionEyebrow(title, systemImage: systemImage, tint: tint,
                           trailing: trailing.map { .text($0) } ?? .none)
        } else {
            classic
        }
        #else
        classic
        #endif
    }
    private var classic: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline { Text(overline).strandOverline() }
                Text(title)
                    .font(overline == nil ? StrandFont.sectionOverline : StrandFont.cardTitle)
                    .tracking(overline == nil ? StrandFont.sectionOverlineTracking : 0)
                    .textCase(overline == nil ? .uppercase : nil)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                // SectionHeader's trailing value is display-only. Interactive headers must supply
                // their own Button/NavigationLink so link blue never lies about a static status/count.
                Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

/// A tile value split for the widget metric look: a number reads in the primary ink with its unit smaller and
/// muted ("54" then "bpm"), a missing value is a tertiary dash, and a word ("Calibrating") is a status rather
/// than a measurement, so it reads in the secondary ink. Shared by `StatTile` and `ChartCard`'s header value.
enum StatTileValue {
    enum Ink { case primary, secondary, tertiary }
    struct Parts: Equatable {
        var number: String
        var unit: String?
        var ink: Ink

        var color: Color {
            switch ink {
            case .primary: StrandPalette.textPrimary
            case .secondary: StrandPalette.textSecondary
            case .tertiary: StrandPalette.textTertiary
            }
        }
    }

    private static let missing: Set<String> = ["—", "–", "-", "--"]

    /// "54 bpm" splits into ("54", "bpm"); "58%", "7h 12m" and "12 of 21" stay whole (the %, the compound
    /// duration and the fraction are the value, not a number plus a unit).
    static func parts(_ raw: String) -> Parts {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || missing.contains(value) {
            return Parts(number: value.isEmpty ? WidgetMetrics.missingValue : value, unit: nil, ink: .tertiary)
        }
        guard value.contains(where: \.isNumber) else {
            return Parts(number: value, unit: nil, ink: .secondary)
        }
        if let space = value.firstIndex(of: " ") {
            let head = value[..<space]
            let tail = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
            let isNumber = head.contains(where: \.isNumber) && head.allSatisfy { $0.isNumber || ".,+-−±".contains($0) }
            if isNumber, !tail.isEmpty, tail.count <= 12, !tail.contains(where: \.isNumber) {
                return Parts(number: String(head), unit: tail, ink: .primary)
            }
        }
        return Parts(number: value, unit: nil, ink: .primary)
    }
}

/// The metric tile in the widget language: a secondary micro label (with an optional domain symbol), a large
/// rounded value with its unit muted beside it, an optional trend chip and sparkline, and a tertiary caption.
public struct StatTile<Accessory: View>: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent
    /// An optional domain symbol leading the label, drawn in the tint's colour (the tile's `accent` when no tint
    /// is given). nil = no symbol, which is how every existing tile reads.
    var systemImage: String? = nil
    var tint: DomainTint? = nil
    /// A unit shown muted beside `value`, for a value whose shape the automatic split cannot read ("6:13" with
    /// "/km"). nil (the default) splits a unit off the value text as it always did.
    var unit: String? = nil
    /// An optional trailing accessory laid out INLINE in the header row beside the label (e.g. a small
    /// ⓘ that opens a scoring guide). Inline placement — not a corner overlay — so it can never sit on
    /// top of the value, sparkline or trend chip on a narrow tile (#495). Defaults to nothing.
    @ViewBuilder var accessory: () -> Accessory

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
                systemImage: String? = nil, tint: DomainTint? = nil, unit: String? = nil,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
        self.systemImage = systemImage; self.tint = tint; self.unit = unit
        self.accessory = accessory
    }

    public var body: some View {
        let parts = unit.map { unit in
            StatTileValue.parts(value).ink == .tertiary
                ? StatTileValue.parts(value)
                : StatTileValue.Parts(number: value, unit: unit, ink: .primary)
        } ?? StatTileValue.parts(value)
        // The tile borrows its accent as a faint card wash, so each metric tile reads as
        // part of its colour world while staying legible on the deep blue-black.
        NoopCard(padding: 14, tint: accent) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row: the metric label, and (right-aligned) the optional accessory laid out in
                // flow so it reserves its own space rather than floating over the value below (#495).
                HStack(alignment: .top, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(tint?.accent ?? accent)
                        }
                        Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    accessory()
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.number).font(StrandFont.metricValue).foregroundStyle(parts.color)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let unit = parts.unit {
                            Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    // Trend chip — the delta as a tinted pill with a direction arrow.
                    if let delta { TrendChip(text: delta, color: deltaColor) }
                }
                // Sparkline isn't available on watchOS (it relies on chart-hover helpers); the watch
                // doesn't use StatTile, but guard the reference so the file still compiles there.
                #if !os(watchOS)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline, gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]))
                        .frame(height: 22).padding(.top, 4)
                        .accessibilityHidden(true)
                }
                #endif
                if let caption {
                    Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .padding(.top, 2)
                }
            }
        }
        // A FLOOR, not a fixed height: a sparkline tile's content exceeds the 96pt base and must be
        // allowed to grow rather than clip. maxHeight: .infinity lets a caller that DOES hand this tile a
        // bounded height (e.g. the Key Metrics grid pins every cell to NoopMetrics.keyMetricTileHeight)
        // stretch it to fill; in an unbounded parent it resolves to the content's own height, unchanged.
        // Note: inside a LazyVGrid the cell only offers content height, so equal heights come from the
        // caller pinning a fixed height, not from maxHeight: .infinity alone.
        .frame(minHeight: NoopMetrics.tileHeight, maxHeight: .infinity)
        // One VoiceOver stop per tile (label, value, caption, delta) instead of up
        // to four fragmented stops; the decorative sparkline is hidden above.
        .accessibilityElement(children: .combine)
    }
}

// Backward-compatible convenience: a StatTile with NO accessory (the common case) — every existing
// call site keeps working unchanged, and the type defaults `Accessory` to `EmptyView`.
public extension StatTile where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String, caption: String? = nil,
         accent: Color = StrandPalette.textPrimary, delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
         systemImage: String? = nil, tint: DomainTint? = nil, unit: String? = nil) {
        self.init(label: label, value: value, caption: caption, accent: accent, delta: delta,
                  deltaColor: deltaColor, sparkline: sparkline, sparkColor: sparkColor,
                  systemImage: systemImage, tint: tint, unit: unit,
                  accessory: { EmptyView() })
    }
}

// MARK: - Trend chip — a small tinted delta pill with a direction arrow.

/// A compact trend pill: an up/down/flat arrow + the delta text, tinted to `color`.
/// Inferred direction comes from a leading +/− in the text (else flat). Sits in the
/// corner of a StatTile or beside a metric value.
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        // No sign → a plain magnitude (e.g. a workout's "874 kcal"), not a trend: show NO direction
        // glyph. Previously this fell to "minus", whose leading dash read as a negative ("-874 kcal" — #41).
        return nil
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            // One line, always: a long chip (e.g. a workout's kcal) truncates rather than wraps, so
            // the pill never grows a tile past its floor. Matches Android's unconditional ellipsize (#934).
            Text(text).font(StrandFont.captionNumber).lineLimit(1)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

/// The chart card in the widget language: an eyebrow header (optional domain symbol, tracked caps title, the
/// headline value at the trailing edge with its unit muted), a micro tertiary subtitle, the chart at a fixed
/// height, and an optional footer under a hairline.
public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    var tint: Color? = nil
    /// An optional domain symbol leading the title, drawn in `tint`. nil = title only.
    var systemImage: String? = nil
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight, tint: Color? = nil, systemImage: String? = nil,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.systemImage = systemImage
        self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionEyebrow(title, systemImage: systemImage, tint: tint.map(DomainTint.custom) ?? .neutral,
                                   trailing: trailing.map { .custom(AnyView(ChartCardValue(text: $0))) } ?? .none)
                    if let subtitle {
                        Text(subtitle).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// The header value of a `ChartCard`: bright number, muted unit, a missing value in the tertiary dash.
private struct ChartCardValue: View {
    let text: String
    var body: some View {
        let parts = StatTileValue.parts(text)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.number).font(StrandFont.bodyNumber).foregroundStyle(parts.color)
            if let unit = parts.unit {
                Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).textCase(.uppercase).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    var symbol: String? = nil
    /// Extra trailing inset reserved on the overline + status rows so a caller's
    /// `.overlay(alignment: .topTrailing)` (greeting + state pill) doesn't run over the
    /// card's own title text on a narrow screen (#69). Defaults to 0 — no effect unless set.
    var titleTrailingInset: CGFloat = 0
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil, titleTrailingInset: CGFloat = 0) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint; self.titleTrailingInset = titleTrailingInset
    }
    public init(symbol: String = "sparkles", title: LocalizedStringKey, body: LocalizedStringKey,
                accent: Color = StrandPalette.link) {
        self.category = ""; self.status = title; self.detail = body
        self.statusColor = accent; self.tint = nil; self.symbol = symbol
        self.titleTrailingInset = 0
    }
    public var body: some View {
        // Defaults the card wash to the status colour so the coaching card sits in the
        // same colour world as the score it summarises (e.g. gold for Charge). The
        // insight card reads a touch stronger than a tile: an explicit hue wash
        // (.14 → .04) + a matching .22 hue border on top of the frosted surface.
        let hue = tint ?? statusColor
        // Apple-flat: a plain flat card. Identity comes from the COLOURED status headline alone — no extra
        // hue-gradient wash, no border (so it reads identical to every other card on the page).
        return NoopCard(padding: 18, tint: hue) {
            if let symbol {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 32, height: 32)
                        .background(statusColor.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status).font(StrandFont.cardTitle).foregroundStyle(StrandPalette.textPrimary)
                        Text(detail).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(category).strandOverline()
                        .padding(.trailing, titleTrailingInset)
                    Text(status).font(StrandFont.cardTitle).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, titleTrailingInset)
                    Text(detail).font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

/// How the selected segment of a `SegmentedPillControl` is drawn. Solid ink (the default) is the app-wide selected chrome. A
/// screen with its own single solid control (the live workout journey's Start circle) asks for `quiet`: a 15% tint of the same
/// colour behind words in that colour, so the one solid control stays the only one.
public enum SegmentedPillSelectionStyle: Sendable {
    case solid
    case quiet
}

private struct SegmentedPillSelectionStyleKey: EnvironmentKey {
    static let defaultValue = SegmentedPillSelectionStyle.solid
}

extension EnvironmentValues {
    var segmentedPillSelectionStyle: SegmentedPillSelectionStyle {
        get { self[SegmentedPillSelectionStyleKey.self] }
        set { self[SegmentedPillSelectionStyleKey.self] = newValue }
    }
}

public extension View {
    /// Draws the selected segment of every `SegmentedPillControl` below this view in `style`.
    func segmentedPillSelectionStyle(_ style: SegmentedPillSelectionStyle) -> some View {
        environment(\.segmentedPillSelectionStyle, style)
    }
}

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    /// Per-segment availability (#943): a disabled segment stays visible (so users learn the
    /// option exists) but renders extra-dim and ignores taps; VoiceOver announces it dimmed.
    /// Defaults to everything enabled; ADDED additively, no existing call site touched.
    let isEnabled: (T) -> Bool
    /// Optional per-segment accessibility identifier (for UI automation). nil = none, the default.
    let identifier: ((T) -> String)?
    /// Whether the segments stack into one column at the accessibility text sizes. A caller that already puts the control in a
    /// horizontal `ScrollView` (a pinned header, a row of presets) passes false: stacked, the control would grow tall inside it.
    let stacksAtAccessibilitySizes: Bool
    @Binding var selection: T
    @Namespace private var selectionThumb
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.segmentedPillSelectionStyle) private var selectionStyle
    public init(_ items: [T], selection: Binding<T>, stacksAtAccessibilitySizes: Bool = true,
                label: @escaping (T) -> String) {
        self.init(items, selection: selection, stacksAtAccessibilitySizes: stacksAtAccessibilitySizes,
                  isEnabled: { _ in true }, label: label)
    }
    public init(_ items: [T], selection: Binding<T>, stacksAtAccessibilitySizes: Bool = true,
                isEnabled: @escaping (T) -> Bool, label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.isEnabled = isEnabled; self.label = label
        self.identifier = nil
        self.stacksAtAccessibilitySizes = stacksAtAccessibilitySizes
    }
    /// Same control with a stable accessibility identifier per segment, so a screen that exposes the
    /// segments as tabs keeps its UI-test hooks when it adopts the canonical control.
    public init(_ items: [T], selection: Binding<T>, stacksAtAccessibilitySizes: Bool = true,
                identifier: @escaping (T) -> String, label: @escaping (T) -> String) {
        self.items = items; self._selection = selection; self.isEnabled = { _ in true }; self.label = label
        self.identifier = identifier
        self.stacksAtAccessibilitySizes = stacksAtAccessibilitySizes
    }
    @Environment(\.dynamicTypeSize) private var typeSize

    public var body: some View {
        // Side by side the labels share one line. From the accessibility sizes up they would be cut, so the segments
        // stack, one full-width row each, and a label may take as many lines as it needs. A control inside a sideways
        // scroll view opts out and keeps its single row.
        let stacked = stacksAtAccessibilitySizes && typeSize.isAccessibilitySize
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items, id: \.self) { item in segment(item, stacked: true) }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(items, id: \.self) { item in segment(item, stacked: false) }
                }
            }
        }
        .padding(3)
        // A rounded rectangle whose radius clamps to half its height is the capsule; stacked rows get a firm corner.
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: stacked ? 24 : 1000, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: stacked ? 24 : 1000, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .strandHaptic(.selection, trigger: selection)
    }

    @ViewBuilder private func segment(_ item: T, stacked: Bool) -> some View {
        let sel = item == selection
        let enabled = isEnabled(item)
        Button {
            SegmentedPillSelection.perform(
                current: selection,
                next: item,
                isEnabled: enabled,
                setSelection: { newSelection in
                    withAnimation(reduceMotion ? nil : StrandMotion.press) {
                        selection = newSelection
                    }
                },
                feedback: playSelectionFallback
            )
        } label: {
            Text(label(item))
                .font(StrandFont.captionNumber)
                // Active segment is SELECTION CHROME, so it follows the accent: on dark a
                // Canonical selected chrome is scheme-invariant ink. Disabled segments
                // drop to a fainter tertiary so the lock reads at a glance.
                .foregroundStyle(sel ? (selectionStyle == .quiet ? StrandPalette.ink : StrandPalette.onInk)
                                     : StrandPalette.textTertiary.opacity(enabled ? 1 : 0.35))
                .multilineTextAlignment(.center)
                // Fill the segment height so the selected pill has EQUAL margins to the track
                // on every side. (The old compact pill inside a taller 44pt touch frame left
                // more vertical margin than horizontal — it read as off-centre.)
                // (Stacked rows are only as tall as their label: a greedy height would stretch a pinned header.)
                .frame(minWidth: 26, maxWidth: stacked ? .infinity : nil, maxHeight: stacked ? nil : .infinity)
                .padding(.horizontal, 9)
                .padding(.vertical, stacked ? 10 : 0)
                .background(
                    Group {
                        if sel {
                            Capsule(style: .continuous)
                                .fill(selectionStyle == .quiet ? StrandPalette.ink.opacity(0.15) : StrandPalette.ink)
                                .matchedGeometryEffect(
                                    id: "selected-segment",
                                    in: selectionThumb
                                )
                        }
                    }
                )
                // Side by side, a finger gets 44 pt of height though the segment is drawn 32: the touch shape reaches 6 pt
                // above and below it, which changes nothing in the layout. Stacked rows are 44 pt already and sit 4 pt
                // apart, so they keep their own bounds and neighbouring touch areas never overlap.
                .contentShape(stacked ? AnyShape(Rectangle()) : AnyShape(SegmentTouchShape()))
        }
        .buttonStyle(.plain)
        .modifier(SegmentHeight(stacked: stacked))
        .disabled(!enabled)
        // Announce the active range to VoiceOver and give a non-colour cue.
        .accessibilityAddTraits(sel ? .isSelected : [])
        .modifier(SegmentIdentifier(identifier: identifier?(item)))
    }

    /// 32pt (44pt to the finger) side by side; as tall as the label needs, at least 44pt, when stacked.
    private struct SegmentHeight: ViewModifier {
        let stacked: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if stacked {
                content.frame(minHeight: 44)
            } else {
                content.frame(height: 32)   // segment height; the pill fills it for an even inset
            }
        }
    }

    private func playSelectionFallback() {
        #if os(iOS)
        if #unavailable(iOS 17.0) {
            StrandHaptic.selection.play()
        }
        #elseif os(watchOS)
        StrandHaptic.selection.play()
        #endif
    }
}

/// The touch area of a pill segment: its own width, and 6 pt more above and below it, so a segment drawn 32 pt tall
/// is 44 pt tall to a finger without growing the control.
struct SegmentTouchShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -6))
    }
}

/// Applies a segment's accessibility identifier only when the caller supplied one, so existing call
/// sites keep exactly the accessibility tree they had.
private struct SegmentIdentifier: ViewModifier {
    let identifier: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

enum SegmentedPillSelection {
    static func perform<T: Equatable>(
        current: T,
        next: T,
        isEnabled: Bool,
        setSelection: (T) -> Void,
        feedback: () -> Void
    ) {
        guard isEnabled, current != next else { return }
        setSelection(next)
        feedback()
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(0.5)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .foregroundStyle(StrandPalette.textPrimary)
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.34), lineWidth: 1))
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for whole-number-or-decimal entry on iOS: the decimal-pad
    /// keyboard (handles both integer Avg-HR and decimal calories). No-op on macOS
    /// (hardware keyboard), so the SAME shared view compiles on both. Pair with
    /// `.keyboardDoneToolbar(...)` on the enclosing view to add a Done button (the decimal
    /// pad has no return key).
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a single trailing "Done" button to the software-keyboard accessory bar that
    /// resigns the given focus binding. iOS-only; the keyboard toolbar is hosted by the
    /// keyboard itself, so it works inside a sheet with no NavigationStack. No-op on macOS.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Titanium & Gold) — ADDED additively, no existing API touched.
//
// Three house button styles for primary actions, secondary chrome and ghost/gold
// CTAs. Drop in via `.buttonStyle(.noopPrimary)` etc. on any `Button`. All read off
// the new gold tokens so they match Apple ⇄ Android. Pressed = subtle dim + scale.

/// Primary call-to-action: gold-gradient fill, dark gold-deep ink (700), rounded 13.
public struct NoopPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(StrandFont.body.weight(.bold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(gradient: StrandPalette.goldGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            // A crisp, subtle NEUTRAL elevation — the gold cast-glow read as too much against the
            // clean design, so it's a soft dark lift now, no bloom.
            .shadow(color: .black.opacity(pressed ? 0.08 : 0.16), radius: 6, x: 0, y: 3)
            .opacity(pressed ? 0.9 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: inset well + 1px white-12 border + primary text. Quieter than gold.
public struct NoopSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost / gold: transparent + 1px gold@.3 hairline + gold text. Tertiary CTA.
public struct NoopGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.gold)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.gold.opacity(pressed ? 0.10 : 0)))
            .overlay(shape.strokeBorder(StrandPalette.gold.opacity(0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == NoopPrimaryButtonStyle {
    /// Gold-gradient primary CTA.
    static var noopPrimary: NoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: NoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopGhostButtonStyle {
    /// Transparent gold-outline ghost button.
    static var noopGhost: NoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// ADDED additively — the existing `StatePill` (tone-based, in StatePill.swift) is
// untouched. This is the score-lifecycle chip the new design calls for: SOLID = gold
// fill, BUILDING = blue, CALIBRATING = slate, LIVE = gold dot with a pulsing halo.

public enum ScoreState: Sendable, Equatable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's hue, drawn from the re-pointed palette (gold / blue / slate).
    public var color: Color {
        switch self {
        case .solid:        return StrandPalette.statusPositive // settled / trustworthy — WHOOP green
        case .live:         return StrandPalette.accent          // streaming now — WHOOP blue
        case .building:     return StrandPalette.sleepLight   // #4A90E2 blue
        case .calibrating:  return StrandPalette.textTertiary // #8A94A4 slate
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip, built from the shared state-pill parts so the app has ONE pill: a state-coloured
/// dot, the white overline label, and the 10 / 5pt capsule with a 12% wash and a 28% hairline of the state hue
/// (the `StatePill` chrome that the Coach cards and Today's pills use). LIVE pulses its dot. `text` overrides the
/// default state label (e.g. "Building — 2 of 4").
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        let hue = state.color
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .statePillLabel()
        }
        .statePillChrome(tint: hue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// A small dot with an optional breathing pulse halo (LIVE). Honours Reduce Motion.
/// Local to the score pill so it doesn't disturb StatePill.swift's ConnectionDot.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            // Dark-mode only (#review): AdditiveBloom used to hide this expanding ring on light
            // (content.opacity(0)); now that we drop the offscreen bloom, gate it explicitly so light
            // mode stays ring-free (the resting dot + its shadow carry the live state there).
            if pulsing && scheme == .dark {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every
                    // frame of the repeatForever pulse, a continuous cost while a strap is backfilling
                    // (exactly when this live dot is on screen). The expanding/fading ring reads the
                    // same without it; the resting dot's shadow still carries the "live" glow.
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing && !reduceMotion { animate = true } }
        .animation(pulsing && !reduceMotion ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}
