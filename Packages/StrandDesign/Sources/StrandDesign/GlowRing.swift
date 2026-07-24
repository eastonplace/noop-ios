import SwiftUI

// MARK: - ScoreRing — Paper score primitive

/// The one Paper score ring used by daily pillars, detail heroes, and live metrics.
/// It is deliberately flat: a solid rounded-cap arc over an inset track, with no
/// gradient, bevel, inner disc, endpoint bead, or glow.
public struct ScoreRing: View {
    public var value: Double
    public var range: ClosedRange<Double>
    public var accent: Color
    public var size: CGFloat
    public var lineWidth: CGFloat
    public var format: (Double) -> String
    public var centerCaption: String?
    public var showsValue: Bool

    public init(
        value: Double,
        range: ClosedRange<Double>,
        accent: Color,
        size: CGFloat,
        lineWidth: CGFloat? = nil,
        format: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) },
        centerCaption: String? = nil,
        showsValue: Bool = true
    ) {
        self.value = value
        self.range = range
        self.accent = accent
        self.size = size
        self.lineWidth = lineWidth ?? (size <= NoopMetrics.trioRingDiameter
            ? NoopMetrics.trioRingLineWidth : NoopMetrics.heroRingLineWidth)
        self.format = format
        self.centerCaption = centerCaption
        self.showsValue = showsValue
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedProgress: CGFloat = 0

    private var targetProgress: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    private var scoreFont: Font {
        if size <= 72 { return StrandFont.ringScoreSmall }
        if size <= 110 { return StrandFont.ringScoreLarge }
        return StrandFont.rounded(size * 0.36, weight: .bold)
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.10),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, animatedProgress))
                .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if showsValue {
                VStack(spacing: 0) {
                    Text(format(value))
                        .font(scoreFont)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if let centerCaption {
                        Text(centerCaption)
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, lineWidth + 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(format(value)))
        .accessibilityValue(Text("\(ComponentValueFormat.rounded(Double(targetProgress) * 100)) percent"))
        .onAppear { animate(to: targetProgress) }
        .onChangeCompat(of: value) { _ in animate(to: targetProgress) }
    }

    private func animate(to progress: CGFloat) {
        if reduceMotion {
            animatedProgress = progress
        } else {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)) {
                animatedProgress = progress
            }
        }
    }
}

// MARK: - GlowRing — crisp WHOOP-style score ring
//
// Quality here is CRISPNESS, not blur. A clean solid arc with rounded caps over a clearly-visible
// full-circle track (so the ring reads as "X% of a circle"), a bold centred number that counts up, and
// only a TIGHT, low-opacity glow hugging the arc (additive on dark, hidden on light) — never a wide
// fuzzy bloom. The arc springs in from 12 o'clock and re-animates when the value changes (day nav).
// Theme-aware (number + track follow light/dark). Motion gated on Reduce Motion; macOS-13 / iOS-17 safe.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre — rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (solid, saturated — the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    /// The centre-number font for a ring of the given diameter — the house numeral at `diameter * 0.36`,
    /// bold. Exposed so an EMPTY / carried / "No data" ring (which doesn't draw a `GlowRing`) can render
    /// its centre text in the EXACT same size + weight as a filled ring, keeping the hero trio's three
    /// centre read-outs visually consistent regardless of state.
    public static func centerFont(diameter: CGFloat) -> Font {
        diameter <= 72 ? StrandFont.ringScoreSmall : StrandFont.ringScoreLarge
    }

    private var inferredUpperBound: Double {
        guard fraction > 0.0001 else { return max(abs(value), 1) }
        return max(abs(value / fraction), 1)
    }

    public var body: some View {
        ScoreRing(
            value: value,
            range: 0...inferredUpperBound,
            accent: color,
            size: diameter,
            lineWidth: lineWidth,
            format: format
        )
    }
}
