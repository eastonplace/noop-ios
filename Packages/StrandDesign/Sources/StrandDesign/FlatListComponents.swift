import SwiftUI

// MARK: - Flat list pieces
//
// What a page of flat sections needs besides the section itself (`FlatSection`, `FactStrip`, `HeroValue`): the row
// that sits in a list under an eyebrow, the hairline between two rows, the glyph on its quiet disc, the title row of
// a sheet and its round header buttons, and the calm tile an exercise illustration sits in. They take plain values
// and know nothing about any screen's model.

// MARK: Glyph disc

/// A symbol in a domain colour on a quiet disc of the same colour. The disc follows the text size up to a ceiling, so
/// a very large text size never gives the glyph more room than the words beside it.
public struct GlyphDisc: View {
    private let symbol: String
    private let tint: DomainTint
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = 38

    public init(_ symbol: String, tint: DomainTint = .workout) {
        self.symbol = symbol
        self.tint = tint
    }

    /// The disc's diameter for a scaled 38pt: it grows with the text and stops at 48pt.
    public static func diameter(scaled: CGFloat) -> CGFloat { min(scaled, 48) }

    private var diameter: CGFloat { Self.diameter(scaled: scaledDiameter) }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(tint.accent)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint.accent.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

// MARK: Row pieces

/// The hairline between two rows of a flat list. `leadingInset` starts it under the row's text instead of at the edge.
public struct FlatRowSeparator: View {
    private let leadingInset: CGFloat

    public init(leadingInset: CGFloat = 0) { self.leadingInset = leadingInset }

    public var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

/// The press feedback of a row that is a button: a hair smaller and quieter while the finger is down.
public struct FlatRowPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: Sheet title

/// A small round header button: its symbol on a quiet disc, with a 44pt tap area. The close, settings and add buttons
/// of a sheet's title row.
public struct HeaderChipButton: View {
    private let systemImage: String
    private let accessibilityLabel: LocalizedStringKey
    private let action: () -> Void

    public init(_ systemImage: String, accessibilityLabel: LocalizedStringKey, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) { HeaderChipGlyph(systemImage: systemImage) }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// The disc of a header chip, for a header control that is not a plain button (a menu).
public struct HeaderChipGlyph: View {
    private let systemImage: String

    public init(systemImage: String) { self.systemImage = systemImage }

    public var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 32, height: 32)
            .background(StrandPalette.chipFill, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

/// The title row of a modal sheet's first page: the title in the sheet-title face, then the page's own header
/// buttons. The title wraps before it truncates, and keeps its words whole.
public struct NoopSheetTitleRow<Trailing: View>: View {
    private let title: LocalizedStringKey
    @ViewBuilder private let trailing: () -> Trailing

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                // A long word scales down before it would be broken across lines.
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NoopMetrics.space2)
            trailing()
        }
        .frame(minHeight: 44)
    }
}

public extension NoopSheetTitleRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) { self.init(title) { EmptyView() } }
}

// MARK: Exercise art

/// The calm tile an exercise illustration sits in. The pictures are drawn on white, which on the dark canvas reads as
/// a glaring square; here the picture is inset in a dark mat, dimmed a little and lit from the middle, so it stays
/// legible without being the brightest thing on the page. `art` is the picture (or a placeholder glyph).
public struct ExerciseArtTile<Art: View>: View {
    private let size: CGFloat
    private let art: Art

    public init(size: CGFloat, @ViewBuilder art: () -> Art) {
        self.size = size
        self.art = art()
    }

    /// The mat around the picture: 6% of the tile, never under 2pt.
    public static func mat(for size: CGFloat) -> CGFloat { max(2, (size * 0.06).rounded()) }

    /// The tile's corner radius: a quarter of its side, capped at the card radius.
    public static func radius(for size: CGFloat) -> CGFloat { min(NoopMetrics.radius3, max(6, (size * 0.22).rounded())) }

    public var body: some View {
        let mat = Self.mat(for: size)
        let outer = Self.radius(for: size)
        let inner = max(outer - mat, 4)
        art
            .frame(width: size - mat * 2, height: size - mat * 2)
            // White paper becomes soft grey, and the darkest ink stays dark: legible, not glaring.
            .colorMultiply(Color(white: 0.8))
            .clipShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
            .overlay {
                // A vignette: the picture's edge falls away into the mat, so the white never reads as a hard square.
                RoundedRectangle(cornerRadius: inner, style: .continuous)
                    .fill(RadialGradient(
                        colors: [.clear, StrandPalette.surfaceInset.opacity(0.55)],
                        center: .center, startRadius: size * 0.2, endRadius: size * 0.62))
                    .allowsHitTesting(false)
            }
            .frame(width: size, height: size)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: outer, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: outer, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

// MARK: Choice chips

/// A chip that is one of a set of choices or a switch: the shared `WidgetChip` with a 44pt tap area, filled with the
/// brand ink while `isSelected` and carrying the selected accessibility trait. A titled chip reads its title.
public struct ChoiceChipButton: View {
    private let chip: WidgetChip
    private let label: Text
    private let hint: LocalizedStringKey?
    private let isSelected: Bool
    private let action: () -> Void

    /// A chip whose title is looked up in the app's string table.
    public init(
        title: LocalizedStringKey,
        systemImage: String? = nil,
        isSelected: Bool = false,
        accessibilityHint: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.chip = WidgetChip(appTitle: title, systemImage: systemImage, showsChevron: false, overhangs: false,
                               isSelected: isSelected)
        self.label = Text(title)
        self.hint = accessibilityHint
        self.isSelected = isSelected
        self.action = action
    }

    /// A chip whose title is already text in the person's language (a duration, a number, a name).
    public init(
        verbatimTitle: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        accessibilityLabel: Text? = nil,
        accessibilityHint: LocalizedStringKey? = nil,
        action: @escaping () -> Void
    ) {
        self.chip = WidgetChip(verbatimTitle: verbatimTitle, systemImage: systemImage, showsChevron: false,
                               overhangs: false, isSelected: isSelected)
        self.label = accessibilityLabel ?? Text(verbatim: verbatimTitle)
        self.hint = accessibilityHint
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) { chip.chipHitTarget() }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .modifier(ChoiceChipHint(hint: hint))
    }

    private struct ChoiceChipHint: ViewModifier {
        let hint: LocalizedStringKey?
        @ViewBuilder func body(content: Content) -> some View {
            if let hint { content.accessibilityHint(hint) } else { content }
        }
    }
}

/// A chip that opens a menu: its current choice in the chip, a down chevron and a 44pt tap area. The title is text
/// already in the person's language.
public struct ChipMenu<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let isSelected: Bool
    private let label: LocalizedStringKey
    private let value: String
    @ViewBuilder private let content: () -> Content

    public init(
        verbatimTitle: String,
        systemImage: String? = nil,
        isSelected: Bool = false,
        accessibilityLabel: LocalizedStringKey,
        accessibilityValue: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = verbatimTitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.label = accessibilityLabel
        self.value = accessibilityValue
        self.content = content
    }

    public var body: some View {
        Menu {
            content()
        } label: {
            WidgetChip(verbatimTitle: title, systemImage: systemImage, opensMenu: true, isSelected: isSelected)
                .chipHitTarget()
        }
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: value))
    }
}
