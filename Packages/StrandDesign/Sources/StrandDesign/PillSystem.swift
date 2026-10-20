import SwiftUI

// MARK: - One pill system (L4 core)
//
// Four shapes, all neutral: the pill (`neutralPillChrome` / `statePillChrome`, in StatePill.swift), the chip, the main
// button and the tag. Colour lives in a dot or an icon, never in the shape. Mint survives only on the + button and the
// fan primaries, recording-now indicators and native toggles.

// MARK: Tag

enum TagMetrics {
    /// Tag corner radius (not a capsule: a tag is a label, a pill is a state).
    static let cornerRadius: CGFloat = 6
    /// Minimum tag height; scales with Dynamic Type.
    static let minHeight: CGFloat = 20
    static let horizontalPadding: CGFloat = 7
    static let tracking: CGFloat = 0.6
    static let fontSize: CGFloat = 11
}

/// A tag: `tagFill` (the inset surface), radius 6, at least 20pt tall, an 11pt-equivalent bold label with 0.6 tracking,
/// and an optional leading icon in its own colour (the PR star is `signalYellow`; Superset takes a link icon). The label
/// is neutral ink; colour is only ever the icon.
public struct PillTag: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let iconTint: Color

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var fontSize: CGFloat = TagMetrics.fontSize
    @ScaledMetric(relativeTo: .caption2) private var minHeight: CGFloat = TagMetrics.minHeight

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, iconTint: Color = StrandPalette.textSecondary) {
        self.title = title
        self.systemImage = systemImage
        self.iconTint = iconTint
    }

    public var body: some View {
        let wraps = typeSize.isAccessibilitySize
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(StrandFont.sized(fontSize, weight: .bold))
                    .foregroundStyle(iconTint)
                    .accessibilityHidden(true)
            }
            Text(title)
                .textCase(.uppercase)
                .font(StrandFont.sized(fontSize, weight: .bold))
                .tracking(TagMetrics.tracking)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(wraps ? 3 : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
        }
        .padding(.horizontal, TagMetrics.horizontalPadding)
        .padding(.vertical, wraps ? 3 : 0)
        .frame(minHeight: minHeight)
        .background(StrandPalette.tagFill, in: RoundedRectangle(cornerRadius: TagMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chip

enum ChoiceChipMetrics {
    /// The drawn height of a choice chip.
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 14
    static let fontSize: CGFloat = 14
    /// A finger always gets at least this much.
    static let hitTarget: CGFloat = 44
}

/// How a chip looks, resolved from its state. Kept apart from the view so the rule is testable.
struct ChoiceChipAppearance: Equatable {
    let fill: Color
    let stroke: Color
    let label: Color

    /// - Unselected: clear, a 1pt `hairlineStrong` edge, `textSecondary` label.
    /// - Selected: solid `solidFill` (#F2F4F5) with a dark label.
    /// - Selected on a metric page (`tint` given): the page's metric colour softly (an 18% wash, the label lightened), the
    ///   same resolution the range control uses, so a chip and the range tabs beside it read as one family.
    static func resolve(isSelected: Bool, tint: Color?) -> ChoiceChipAppearance {
        guard isSelected else {
            return ChoiceChipAppearance(fill: .clear, stroke: StrandPalette.hairlineStrong, label: StrandPalette.textSecondary)
        }
        if let tint, tint != StrandPalette.textTertiary, tint != StrandPalette.textSecondary {
            let softly = SegmentedPillSelectionAppearance.resolve(tint: tint, style: .solid)
            return ChoiceChipAppearance(fill: softly.fill, stroke: .clear, label: softly.label)
        }
        return ChoiceChipAppearance(fill: StrandPalette.solidFill, stroke: StrandPalette.solidFill, label: StrandPalette.onLightFill)
    }
}

/// A choice chip: 34pt high (scales with Dynamic Type), hairline when unselected, solid light with a dark label when
/// selected. On a metric page, pass the page's tint (or set `segmentedPillTint` once above a row of them) and the selected
/// chip takes the metric colour softly, like the range control. Draws only; wrap it in a `Button` (or use
/// `ChoiceChipButton`) and call `chipHitTarget()` for the 44pt tap area.
public struct ChoiceChip: View {
    private let title: LocalizedStringKey?
    private let verbatimTitle: String?
    private let systemImage: String?
    private let isSelected: Bool
    private let tint: Color?

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.segmentedPillTint) private var environmentTint
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = ChoiceChipMetrics.fontSize
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = ChoiceChipMetrics.height

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, isSelected: Bool = false, tint: Color? = nil) {
        self.title = title
        self.verbatimTitle = nil
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tint = tint
    }

    /// A chip whose title is already text in the person's language (a sport, a source), never looked up.
    public init(verbatimTitle: String, systemImage: String? = nil, isSelected: Bool = false, tint: Color? = nil) {
        self.title = nil
        self.verbatimTitle = verbatimTitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tint = tint
    }

    public var body: some View {
        let appearance = ChoiceChipAppearance.resolve(isSelected: isSelected, tint: tint ?? environmentTint)
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(StrandFont.sized(fontSize - 2, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if let verbatimTitle {
                Text(verbatim: verbatimTitle).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            } else if let title {
                Text(title).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
        }
        .font(StrandFont.sized(fontSize, weight: isSelected ? .bold : .semibold))
        .foregroundStyle(appearance.label)
        .padding(.horizontal, ChoiceChipMetrics.horizontalPadding)
        .padding(.vertical, typeSize.isAccessibilitySize ? 6 : 0)
        .frame(minHeight: height)
        .background(Capsule(style: .continuous).fill(appearance.fill))
        .overlay(Capsule(style: .continuous).stroke(appearance.stroke, lineWidth: 1))
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
    }
}

// MARK: Main buttons

/// The ink on the main buttons. Primary: `solidFill` with a dark label, 50pt. Secondary: clear with a `hairlineStrong`
/// edge and a `textPrimary` label. One table, so the three button front doors (`NoopButton`, `PrimaryPillButtonStyle`,
/// `SecondaryPillButtonStyle`) cannot drift apart.
enum MainButtonInk {
    static let primaryFill = StrandPalette.solidFill
    static let primaryLabel = StrandPalette.onLightFill
    static let secondaryStroke = StrandPalette.hairlineStrong
    static let secondaryLabel = StrandPalette.textPrimary
    /// The main button's height.
    static let height: CGFloat = 50
}

#if DEBUG
#Preview("Pill system") {
    VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 8) {
            StatePill("Active · Live", tone: .positive)
            StatePill("NOOP V2", tone: .neutral)
            StatePill("Moderate", tone: .warning)
        }
        HStack(spacing: 8) {
            ChoiceChip("All", isSelected: true)
            ChoiceChip("Running")
            ChoiceChip("Strength")
            ChoiceChip("6W", isSelected: true, tint: StrandPalette.strainAccent)
        }
        HStack(spacing: 8) {
            NoopButton("Start workout", kind: .primary) {}
            NoopButton("Later", kind: .secondary) {}
        }
        HStack(spacing: 8) {
            PillTag("PR", systemImage: "star.fill", iconTint: StrandPalette.signalYellow)
            PillTag("Superset", systemImage: "link")
        }
    }
    .padding(24)
    .frame(width: 420, height: 320)
    .background(StrandPalette.canvas)
    .preferredColorScheme(.dark)
}
#endif
