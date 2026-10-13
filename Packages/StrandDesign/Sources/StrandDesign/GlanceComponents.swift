import SwiftUI

// MARK: - Glance metrics
//
// The big capsule button the earlier glance screens used. The live workout journey now draws its numerals and controls with
// `LiveNumeral` and the circles in `LiveControls`.

/// How far a frozen number steps back, and a reading whose source has gone quiet.
public enum GlanceMetricLayout {
    /// A reading whose source has gone quiet keeps its last number, quieter.
    public static let staleOpacity: Double = 0.6
}

// MARK: - The big buttons

/// The workout screen's big action: a full-width capsule at least 88 pt tall, pressed mid-stride with a wet thumb.
/// `.primary` is the brand ink with a dark label; `.secondary` is the quiet chip. A disabled button steps back to the chip
/// with a tertiary label. The label is 22 pt semibold and wraps (the capsule grows with it) at the accessibility sizes.
public struct GlanceActionButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary }

    /// The capsule's least height. Fixed: it is a touch target, not text.
    public static let minimumHeight: CGFloat = 88

    private let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title2) private var labelSize: CGFloat = 22

    public init(_ kind: Kind = .primary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: labelSize, weight: .semibold))
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, NoopMetrics.space5)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, minHeight: Self.minimumHeight)
            .background(Capsule(style: .continuous).fill(fill))
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
    }

    private var fill: Color {
        guard isEnabled else { return StrandPalette.chipFill }
        return kind == .primary ? StrandPalette.ink : StrandPalette.chipFill
    }

    private var foreground: Color {
        guard isEnabled else { return StrandPalette.textTertiary }
        return kind == .primary ? StrandPalette.onInk : StrandPalette.textPrimary
    }
}
