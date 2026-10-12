import SwiftUI

/// A compact label/value readout promoted from the NOOP design lab.
public struct ValueToken: View {
    private let label: LocalizedStringKey
    private let value: String
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        _ label: LocalizedStringKey,
        value: String,
        tint: Color = StrandPalette.textPrimary
    ) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .textCase(.uppercase)
                .font(StrandFont.micro.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)

            numericValue
                .font(StrandFont.captionNumber.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        // A fixed 42pt box at every size short of the accessibility sizes, exactly as it always was. At those sizes the
        // label and value stack taller than 42pt, so the box is a floor: it grows with the text instead of letting one
        // token's text spill over the token below it.
        .modifier(TokenHeight(growsWithText: typeSize.isAccessibilitySize))
        .background(
            StrandPalette.surfaceInset.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(label)), \(value)"))
    }

    @ViewBuilder
    private var numericValue: some View {
        if reduceMotion {
            Text(value).monospacedDigit()
        } else if #available(iOS 17.0, macOS 14.0, watchOS 10.0, *) {
            Text(value)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(StrandMotion.value, value: value)
        } else {
            Text(value)
                .monospacedDigit()
                .contentTransition(.opacity)
                .animation(.easeOut(duration: StrandMotion.durationFast), value: value)
        }
    }

    private struct TokenHeight: ViewModifier {
        let growsWithText: Bool

        @ViewBuilder func body(content: Content) -> some View {
            if growsWithText {
                content.padding(.vertical, 6).frame(minHeight: 42)
            } else {
                content.frame(height: 42)
            }
        }
    }

    static func accessibilityLabel(label: String, value: String) -> String {
        String(localized: "\(label), \(value)", bundle: .module)
    }
}

#if DEBUG
#Preview("ValueToken") {
    HStack {
        ValueToken("Delta", value: "+8%", tint: StrandPalette.statusPositive)
        ValueToken("Source", value: "LIVE")
    }
    .padding()
    .background(StrandPalette.canvas)
}
#endif
