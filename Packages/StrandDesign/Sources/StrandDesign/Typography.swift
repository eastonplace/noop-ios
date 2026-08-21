import SwiftUI

// MARK: - Strand typography
//
// WHOOP specifies Proxima Nova for words and DINPro for numbers. Noop uses the native Apple
// sans-serif fallback allowed by the brand guide. Native system fonts avoid custom-font lookup
// failures, preserve Dynamic Type, and keep every screen on one text scale. Numeric roles use
// tabular digits so live values do not change width.

public enum StrandFont {

    // MARK: Fixed numeric roles

    private static func fixed(_ size: CGFloat, weight: Font.Weight) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }

    /// Large score number used inside fixed-size rings and hero layouts.
    public static func display(_ size: CGFloat = 72) -> Font {
        fixed(size, weight: .bold).monospacedDigit()
    }

    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// Shared fixed-size numeric style for gauges, tiles, and timers.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        fixed(size, weight: weight).monospacedDigit()
    }

    // MARK: Dynamic Type roles

    public static let largeTitle = Font.system(.largeTitle, design: .default).weight(.bold)
    public static let title1 = Font.system(.title, design: .default).weight(.bold)
    public static let title2 = Font.system(.title2, design: .default).weight(.semibold)
    public static let headline = Font.system(.headline, design: .default).weight(.bold)
    public static let body = Font.system(.body, design: .default).weight(.medium)
    public static let subhead = Font.system(.subheadline, design: .default).weight(.medium)
    public static let caption = Font.system(.caption, design: .default).weight(.medium)
    public static let footnote = Font.system(.footnote, design: .default).weight(.regular)
    public static let overline = Font.system(.caption2, design: .default).weight(.bold)

    /// A compact overline for constrained UI. Fixed containers can choose the size while the main
    /// semantic text roles continue to use Dynamic Type.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        fixed(size, weight: .bold)
    }

    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants

    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        fixed(size, weight: weight).monospacedDigit()
    }

    public static let bodyNumber = Font.system(.body, design: .default)
        .weight(.semibold)
        .monospacedDigit()

    public static let captionNumber = Font.system(.caption, design: .default)
        .weight(.semibold)
        .monospacedDigit()

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Shared application roles

    public static let wordmark = Font.system(.caption, design: .default).weight(.bold)
    public static let screenOverline = Font.system(.caption2, design: .default).weight(.bold)
    public static let sectionOverline = Font.system(.caption2, design: .default).weight(.bold)
    public static let ringScoreSmall = fixed(30, weight: .bold).monospacedDigit()
    public static let ringScoreLarge = fixed(48, weight: .bold).monospacedDigit()
    public static let timer = fixed(64, weight: .bold).monospacedDigit()
    public static let metricValue = fixed(28, weight: .bold).monospacedDigit()
    public static let statValue = fixed(32, weight: .bold).monospacedDigit()
    public static let cardTitle = Font.system(.headline, design: .default).weight(.bold)
    public static let micro = Font.system(.caption2, design: .default).weight(.medium)

    public static let wordmarkTracking: CGFloat = 4
    public static let screenOverlineTracking: CGFloat = 1.5
    public static let sectionOverlineTracking: CGFloat = 1.4
    public static let timerTracking: CGFloat = -1
    public static let overlineTracking = sectionOverlineTracking
}

// MARK: - Text helpers

public extension Text {
    /// WHOOP-style section label: bold, uppercase, and tracked.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("88")
                .font(StrandFont.display(72))
                .tracking(StrandFont.displayTracking(72))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Bold")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Medium — one continuous type system across the app.")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Caption")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1")
                .font(StrandFont.mono)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
