import SwiftUI
import os

// MARK: - Flat page sections
//
// Today, Trends, Sleep, Coach and Workouts are pages of flat sections on the canvas: a `SectionEyebrow` header (a
// symbol in the domain colour and a tracked caps title) over free-form content, one hairline between neighbours, values
// bright with their units muted. The widget primitives cover the header, the hero value and the stat footer; these are
// the pieces every such page also needs and used to carry a private copy of: the section itself, the separator and its
// air, a labelled fact strip, a value with a muted unit, a chip and the primary pill. They take plain values and know
// nothing about any screen's model.

// MARK: Page rhythm

public enum FlatSectionRhythm {
    /// Layout air above the hairline between two flat sections, in points.
    ///
    /// The air is not the visible gap: a section's ink does not end where its layout does (a text line keeps its
    /// descender room, a footer chip's capsule hangs below its row, a header pill's outline sits above its caps).
    /// These defaults give a visible gap of about 12.5pt, the gap Today draws, between a text-ended section and an
    /// eyebrow-headed one. A page whose sections end or begin with other ink passes its own pair, as Today, Sleep
    /// and Coach each do (`gaps.py` against a capture is how the pair is checked).
    public static let airAbove: CGFloat = 12.5
    /// Layout air below the hairline, in points.
    public static let airBelow: CGFloat = 12.5
    /// Air either side of the hairline between two rows of tiles.
    public static let rowAir: CGFloat = 12
}

/// The one hairline between two flat sections. It is Today's own separator, so weight and colour cannot drift.
public struct FlatSectionSeparator: View {
    private let above: CGFloat
    private let below: CGFloat

    public init(above: CGFloat = FlatSectionRhythm.airAbove, below: CGFloat = FlatSectionRhythm.airBelow) {
        self.above = above
        self.below = below
    }

    public var body: some View {
        TodaySectionSeparator(above: above, below: below)
    }
}

// MARK: Section

/// A flat section: an eyebrow header over free-form content, spaced like the widget cards' interiors. Titles are
/// looked up in the app's string table.
public struct FlatSection<Content: View>: View {
    private let eyebrow: SectionEyebrow
    private let spacing: CGFloat
    private let content: () -> Content

    /// `contentSpacing` is the space between the eyebrow and what follows it. A section whose content brings its own
    /// top padding (a list of rows) passes less, so the first row sits where any other content would.
    public init(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: DomainTint = .neutral,
        trailing: EyebrowTrailing = .none,
        contentSpacing: CGFloat = WidgetMetrics.contentSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrow = SectionEyebrow(title, systemImage: systemImage, tint: tint, trailing: trailing)
        self.spacing = contentSpacing
        self.content = content
    }

    /// A title that is data (a weekday, a category name), shown as written.
    public init(
        verbatim title: String,
        systemImage: String,
        tint: DomainTint = .neutral,
        trailing: EyebrowTrailing = .none,
        contentSpacing: CGFloat = WidgetMetrics.contentSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.eyebrow = SectionEyebrow(title: title, systemImage: systemImage, tint: tint, trailing: trailing)
        self.spacing = contentSpacing
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            eyebrow
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Values with muted units

public enum ValueUnitSplit {
    /// "55 bpm" -> ("55", "bpm"), "7:00 AM" -> ("7:00", "AM"), "7:00 a. m." -> ("7:00", "a. m."). A compound like
    /// "6h 49m" or "12 of 21" stays whole: the tail of a unit has no digit in it. A clock's day period is matched
    /// against the locale's own AM/PM symbols (which can be several tokens), never guessed from "the last word";
    /// a 24-hour clock has none, so it shows no unit.
    public static func parts(_ raw: String, locale: Locale = .autoupdatingCurrent) -> (number: String, unit: String?) {
        let value = normalizingSpaces(raw)
        for symbol in dayPeriodSymbols(for: locale) where value.hasSuffix(symbol) {
            let head = String(value.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
            if head.contains(where: \.isNumber) { return (head, symbol) }
        }
        guard let split = value.lastIndex(of: " ") else { return (value, nil) }
        let head = value[..<split].trimmingCharacters(in: .whitespaces)
        let tail = value[value.index(after: split)...].trimmingCharacters(in: .whitespaces)
        guard head.contains(where: \.isNumber), !tail.isEmpty, tail.count <= 4,
              !tail.contains(where: \.isNumber) else { return (value, nil) }
        return (head, tail)
    }

    /// The locale's AM and PM symbols with every kind of space folded to a plain one, longest first.
    public static func dayPeriodSymbols(for locale: Locale) -> [String] {
        let key = locale.identifier
        if let hit = symbolCache.withLock({ $0[key] }) { return hit }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = [formatter.amSymbol, formatter.pmSymbol]
            .compactMap { $0 }
            .map(normalizingSpaces)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        symbolCache.withLock { $0[key] = symbols }
        return symbols
    }

    private static let symbolCache = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    private static func normalizingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A bright value with its unit small and muted beside it; a missing value is a tertiary dash. A unit passed
/// explicitly is shown as given; otherwise it is split off the value ("55 bpm").
public struct UnitValueText: View {
    private let value: String
    private let unit: LocalizedStringKey?
    private let size: CGFloat
    private let weight: Font.Weight

    public init(value: String, unit: LocalizedStringKey? = nil, size: CGFloat = WidgetMetrics.statValueSize,
                weight: Font.Weight = .semibold) {
        self.value = value
        self.unit = unit
        self.size = size
        self.weight = weight
    }

    public var body: some View {
        let missing = value == WidgetMetrics.missingValue
        let parts = unit == nil ? ValueUnitSplit.parts(value) : (number: value, unit: nil as String?)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.number)
                .font(StrandFont.number(size, weight: weight))
                .foregroundStyle(missing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                // "Unavailable" at tile size in a half-width column shrinks instead of truncating.
                .minimumScaleFactor(0.6)
            if !missing {
                // A unit shrinks to fit its row rather than being cut ("/k…") when a big value shares a narrow one.
                if let unit {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else if let split = parts.unit {
                    Text(split).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
    }
}

// MARK: Fact strip

/// Label-over-value columns with hairline dividers, the shape of `StatFooter(.prominent)` with the unit muted.
/// Equal columns, labels on one line, values on one baseline; steps down in size and then stacks as rows before
/// anything truncates.
public struct FactStrip: View {
    /// How a fact's label is drawn.
    public enum LabelStyle: Sendable {
        /// A sentence-case caption: "Strain".
        case caption
        /// The caps eyebrow every glance screen names a number with, a size down: "STRAIN".
        case eyebrow
    }

    public struct Fact {
        public let label: LocalizedStringKey
        public let value: String
        /// The unit of a bare number ("min"); nil splits one off the value instead ("55 bpm").
        public let unit: LocalizedStringKey?
        /// What VoiceOver reads for the value when the text on screen would be misread ("1h 5m" is read as "1 h 5
        /// metres"). nil reads the label and the value as they are shown.
        public let spokenValue: String?

        public init(_ label: LocalizedStringKey, value: String, unit: LocalizedStringKey? = nil,
                    spokenValue: String? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
            self.spokenValue = spokenValue
        }
    }

    /// One fact as one spoken element: label then value, or the label and the caller's spoken value.
    private struct SpokenFact: ViewModifier {
        let fact: Fact
        @ViewBuilder func body(content: Content) -> some View {
            if let spoken = fact.spokenValue {
                content.accessibilityElement(children: .ignore)
                    .accessibilityLabel(fact.label)
                    .accessibilityValue(Text(verbatim: spoken))
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
    }

    /// A caps eyebrow in the glance numerals' own style, a size down so the labels stay under the numbers' own. A fixed,
    /// scaled size, so a long word wraps or shrinks and is never hyphenated.
    private struct EyebrowLabel: ViewModifier {
        @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 10
        @Environment(\.dynamicTypeSize) private var typeSize

        func body(content: Content) -> some View {
            content
                .font(.system(size: size, weight: .bold, design: .default))
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.5)
        }
    }

    private let facts: [Fact]
    private let labelStyle: LabelStyle
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = WidgetMetrics.statValueSize
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(facts: [Fact], labelStyle: LabelStyle = .caption) {
        self.facts = facts
        self.labelStyle = labelStyle
    }

    @ViewBuilder private func columnLabel(_ fact: Fact) -> some View {
        switch labelStyle {
        case .caption: Text(fact.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
        case .eyebrow: Text(fact.label).modifier(EyebrowLabel())
        }
    }

    @ViewBuilder private func rowLabel(_ fact: Fact) -> some View {
        switch labelStyle {
        case .caption: Text(fact.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        case .eyebrow: Text(fact.label).modifier(EyebrowLabel())
        }
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                columns(size: valueSize)
                columns(size: valueSize * 0.85)
                columns(size: valueSize * 0.72)
                stacked
            }
        }
    }

    private func columns(size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    columnLabel(fact)
                    UnitValueText(value: fact.value, unit: fact.unit, size: size)
                        // One-line sizes report their full width, so ViewThatFits moves to the next size
                        // rather than truncating one column.
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                .padding(.trailing, index == facts.count - 1 ? 0 : NoopMetrics.space3)
                .modifier(SpokenFact(fact: fact))
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    rowLabel(fact)
                    Spacer(minLength: NoopMetrics.space2)
                    UnitValueText(value: fact.value, unit: fact.unit, size: valueSize)
                }
                .modifier(SpokenFact(fact: fact))
            }
        }
    }
}

// MARK: Chips

/// A small action: the shared `WidgetChip` with a 44pt tap area, an optional title and symbol. Its title is looked
/// up in the app's string table.
public struct WidgetChipButton: View {
    private let title: LocalizedStringKey?
    private let systemImage: String?
    private let showsChevron: Bool
    private let accessibilityLabel: LocalizedStringKey
    private let accessibilityHint: LocalizedStringKey?
    private let action: () -> Void

    public init(
        title: LocalizedStringKey? = nil,
        systemImage: String? = nil,
        showsChevron: Bool = false,
        accessibilityLabel: LocalizedStringKey,
        accessibilityHint: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.showsChevron = showsChevron
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            chip.chipHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .modifier(OptionalHint(hint: accessibilityHint))
    }

    @ViewBuilder private var chip: some View {
        if let title {
            WidgetChip(appTitle: title, systemImage: systemImage, showsChevron: showsChevron, overhangs: false)
        } else {
            WidgetChip(systemImage: systemImage, showsChevron: showsChevron, overhangs: false)
        }
    }

    private struct OptionalHint: ViewModifier {
        let hint: LocalizedStringKey?
        @ViewBuilder func body(content: Content) -> some View {
            if let hint { content.accessibilityHint(hint) } else { content }
        }
    }
}

/// Chips side by side, dropping to a column when they no longer fit.
public struct ChipRow<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        // A chip is about 19pt tall, so it needs 13pt above and below to reach 44pt. Side by side the chips are 8pt
        // apart, so each reaches 4pt sideways (and 13pt up and down); stacked they are 26pt apart, so each reaches the
        // full 13pt up and down and neighbouring areas meet without overlapping.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) { content() }
                .environment(\.chipHitInsets, ChipHitInsets(horizontal: NoopMetrics.space2 / 2, vertical: 13))
            VStack(alignment: .leading, spacing: 26) { content() }
                .environment(\.chipHitInsets, ChipHitInsets(horizontal: 13, vertical: 13))
        }
    }
}

// MARK: Primary pill

/// The primary action: Today's Start pill (solid light capsule, dark label) scaled up modestly for a page whose one
/// job is this action. The tap area reaches 44pt without growing the layout. Disabled it is the standard quiet
/// look (the chip wash behind a tertiary label), never a dimmed accent, so it cannot be mistaken for a rendering
/// fault.
public struct PrimaryPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let looksUnavailable: Bool

    /// - Parameter looksUnavailable: Draws the standard disabled look while the button stays tappable. For an action that
    ///   must stay pressable so it can say what is missing (a form that cannot be saved yet).
    public init(looksUnavailable: Bool = false) { self.looksUnavailable = looksUnavailable }

    public func makeBody(configuration: Configuration) -> some View {
        let drawnEnabled = isEnabled && !looksUnavailable
        return configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(drawnEnabled ? MainButtonInk.primaryLabel : StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, 10)
            .background(drawnEnabled ? MainButtonInk.primaryFill : StrandPalette.chipFill, in: Capsule(style: .continuous))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
    }
}
