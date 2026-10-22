import SwiftUI

/// A bare ⓘ: the `info.circle` symbol in the tertiary ink with no capsule, stroke, material or glass behind it.
/// The tap area is 44×44 (`contentShape` over a 44pt frame) while the layout footprint stays the glyph's own size, so
/// it sits in a header row without making the row taller or pushing its neighbours. It is a plain-style button, so
/// inside a `NavigationLink` card a tap on it opens the explainer and does not follow the link.
public struct InfoGlyphButton: View {
    private let accessibilityLabel: LocalizedStringKey
    private let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var glyphSize: CGFloat = 16

    private static let hitTarget: CGFloat = 44

    public init(accessibilityLabel: LocalizedStringKey = "More info", action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        let footprint = glyphSize + 4
        let overhang = (Self.hitTarget - footprint) / 2
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: Self.hitTarget, height: Self.hitTarget)
                .contentShape(Rectangle())
                // The frame gives the 44pt tap area; the negative padding hands the extra back to layout.
                .padding(-overhang)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
