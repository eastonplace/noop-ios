import SwiftUI

/// The quiet partner of `PrimaryPillButtonStyle`: the same size and shape, a chip wash and a hairline in place of the
/// brand ink, so a page can offer a second action beside its one primary without competing with it. The tap area
/// reaches 44pt without growing the layout; disabled, the label drops to the tertiary ink.
public struct SecondaryPillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(isEnabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, 10)
            .background(StrandPalette.chipFill, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
    }
}
