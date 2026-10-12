import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - The live workout language
//
// Direction A, "Apple Workout, refined": pure black, SF Pro Rounded numerals in two sizes only (the focus figure and the
// secondaries), each in its own colour with its unit riding beside it on the baseline, no eyebrows over numbers and no
// hairlines. Everything the live workout journey draws about numbers, controls and zones comes from here, so the screens
// read as one product.

/// The colours the live workout screens use, all drawn from the app's own tokens. The few greys are solid (a paused metric
/// is a different colour, not a faded one), so they are made from white at a fixed level instead of from opacity.
public enum LivePalette {
    /// The canvas of the live screens: true black.
    public static let canvas = Color.black

    // Metrics: the same colour for the same metric on every page.
    public static let time = StrandPalette.ink
    public static let distance = StrandPalette.textPrimary
    public static let pace = StrandPalette.textPrimary
    public static let strain = StrandPalette.strainAccent
    public static let calories = StrandPalette.metricAmber

    /// What is wrong: the paused header, a notice, a failing signal glyph.
    public static let amber = StrandPalette.statusWarning
    public static let mint = StrandPalette.ink
    public static let red = StrandPalette.liveRed

    // Surfaces and greys.
    /// A dark circle or capsule on the black canvas.
    public static let fill = Color.white.opacity(0.11)
    /// Secondary text, unit blocks of white metrics, the labels of quiet controls.
    public static let secondaryText = Color(white: 0.56)
    /// The label of a quiet action that is not data (Discard Workout): lighter than the secondary text, below the figures.
    public static let quietAction = Color(white: 0.72)
    /// A metric of a paused workout: flat grey, and a darker one for its unit.
    public static let frozenNumeral = Color(white: 0.37)
    public static let frozenUnit = Color(white: 0.25)
    /// A figure with no reading yet.
    public static let missing = Color(white: 0.39)
    /// The unlit track of a bar.
    public static let track = Color(white: 0.165)
    /// The ring around a control that is held.
    public static func ring(_ color: Color) -> Color { color.opacity(0.26) }

    /// The colour of a zone's name and figures: the app's zone colours.
    public static func zone(_ zone: Int) -> Color { HRZoneStyle.zoneColor(zone) }
}

/// The two numeral sizes of the live screens and the geometry that follows from them, as plain numbers so the page layout is
/// worked out (and tested) without a view. Design units are points on a 402 pt wide, 874 pt tall screen.
public enum LiveNumeralMetrics {
    public static let focusPointSize: CGFloat = 160
    public static let secondaryPointSize: CGFloat = 76

    /// A secondary's unit block: 15 pt, 17 pt line. The focus figure's: 19 pt, 20 pt line.
    public static let secondaryUnitSize: CGFloat = 15
    public static let focusUnitSize: CGFloat = 19
    /// The largest a unit grows to, as a share of its numeral: a value is never smaller than its unit.
    public static let unitShareOfNumeral: CGFloat = 0.3

    /// Gaps between the figures, measured from the foot of one set of digits to the top of the next.
    public static let focusGap: CGFloat = 50
    public static let secondaryGap: CGFloat = 37
    /// The band under the header that a notice pill drops into; the figures never move for it.
    public static let noticeBand: CGFloat = 48
    /// The least the figures are scaled to before the page scrolls.
    public static let minimumScale: CGFloat = 0.42

    /// The live numeral face: SF Pro Rounded, semibold, tabular digits, at a fixed `size` (it does not follow Dynamic Type: the
    /// page scales its figures to fit instead).
    public static func numeralFont(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// The height of a digit in the numeral face at `size`.
    public static func digitHeight(_ size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        return roundedFont(size).capHeight
        #else
        return size * 0.705
        #endif
    }

    /// How far below the top of its line the baseline is, so a line can be cropped to the digits.
    public static func ascender(_ size: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        return roundedFont(size).ascender
        #else
        return size * 0.97
        #endif
    }

    #if canImport(UIKit)
    private static func roundedFont(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
    #endif

    /// The height of the stack of figures at scale 1: one focus figure, `rows` secondaries under it.
    public static func stackHeight(rows: Int, hasFocus: Bool = true) -> CGFloat {
        var total: CGFloat = 0
        if hasFocus {
            total += digitHeight(focusPointSize)
            if rows > 0 { total += focusGap }
        }
        total += CGFloat(rows) * digitHeight(secondaryPointSize) + CGFloat(max(0, rows - 1)) * secondaryGap
        return total
    }

    /// How a page of natural height `natural` sits in a region `region` tall: the figures are scaled down (never up) to fit
    /// under the notice band, and any room left over goes 40% above them and 60% below. `scrolls` is true when even the
    /// smallest scale does not fit and the page has to scroll.
    public static func fit(natural: CGFloat, region: CGFloat, band: CGFloat = noticeBand) -> PageFit {
        let usable = max(0, region - band)
        guard natural > 0 else { return PageFit(scale: 1, top: band, scrolls: false) }
        let wanted = usable / natural
        let scale = min(1, max(minimumScale, wanted))
        let free = max(0, usable - natural * scale)
        return PageFit(scale: scale, top: band + free * 0.4, scrolls: wanted < minimumScale)
    }

    /// The width of `text` set as a live numeral at `pointSize` with `tracking`, so a figure that is wider than its line
    /// is scaled by an exact factor (never by the text's own shrinking, which would move its digits off the baseline).
    public static func numeralWidth(_ text: String, pointSize: CGFloat, tracking: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        // The last character carries no tracking (it would shorten the line and clip the glyph's right edge), as drawn.
        let font = tabularRoundedFont(pointSize)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font])
        if text.count > 1 { attributed.addAttribute(.kern, value: tracking, range: NSRange(location: 0, length: (text as NSString).length - 1)) }
        return attributed.size().width
        #else
        return CGFloat(text.count) * pointSize * 0.6 + CGFloat(max(0, text.count - 1)) * tracking
        #endif
    }

    /// The width of a unit line set in capitals at `pointSize`.
    public static func unitWidth(_ text: String, pointSize: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        return (text.uppercased() as NSString).size(withAttributes: [.font: font, .kern: pointSize * 0.045]).width
        #else
        return CGFloat(text.count) * pointSize * 0.68
        #endif
    }

    #if canImport(UIKit)
    private static func tabularRoundedFont(_ size: CGFloat) -> UIFont {
        let base = roundedFont(size)
        let descriptor = base.fontDescriptor.addingAttributes([
            .featureSettings: [[UIFontDescriptor.FeatureKey.type: 6, UIFontDescriptor.FeatureKey.selector: 0]],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }
    #endif

    public struct PageFit: Equatable, Sendable {
        public let scale: CGFloat
        /// The space above the first figure, the notice band included.
        public let top: CGFloat
        public let scrolls: Bool
    }
}

// MARK: - A numeral

/// One metric: a single rounded figure in its colour with its unit block beside it on the baseline. The figure is a fixed size
/// (it does not grow with Dynamic Type; at the accessibility sizes the page scales every figure down together to fit), and
/// the unit and micro text are capped at a share of it so a value is never smaller than what labels it.
public struct LiveNumeral: View {
    public enum Size: Sendable { case focus, secondary }

    /// How current the figure is.
    public enum State: Sendable {
        case live
        /// The source has gone quiet: the last figure steps back.
        case stale
        /// No figure yet.
        case missing
        /// The workout is paused: a flat grey, so it is plain that nothing is live.
        case paused
    }

    private let value: String
    private let unit: [String]
    private let micro: String?
    private let size: Size
    private let color: Color
    private let unitColor: Color?
    private let state: State
    private let scale: CGFloat
    private let spokenLabel: String?
    private let spokenValue: String?

    @ScaledMetric(relativeTo: .caption) private var secondaryUnit: CGFloat = LiveNumeralMetrics.secondaryUnitSize
    @ScaledMetric(relativeTo: .caption) private var focusUnit: CGFloat = LiveNumeralMetrics.focusUnitSize

    /// - Parameters:
    ///   - value: The figure as drawn ("5.49", "34:59"), or `WidgetMetrics.missingValue` while there is none.
    ///   - unit: The unit block's lines, set in capitals beside the figure ("AVG", "/KM"); empty for a figure that needs none.
    ///   - micro: A short line in the unit block ("no signal", "scores in 4:38").
    ///   - color: The figure's colour; the unit block takes it too unless `unitColor` says otherwise.
    ///   - scale: The page's scale, 1 at the reference size.
    public init(_ value: String, unit: [String] = [], micro: String? = nil, size: Size, color: Color,
                unitColor: Color? = nil, state: State = .live, scale: CGFloat = 1,
                spokenLabel: String? = nil, spokenValue: String? = nil) {
        self.value = value
        self.unit = unit
        self.micro = micro
        self.size = size
        self.color = color
        self.unitColor = unitColor
        self.state = state
        self.scale = scale
        self.spokenLabel = spokenLabel
        self.spokenValue = spokenValue
    }

    private var pointSize: CGFloat {
        (size == .focus ? LiveNumeralMetrics.focusPointSize : LiveNumeralMetrics.secondaryPointSize) * scale
    }

    /// The unit's size: its own, scaled with the text size, but never more than a share of the figure.
    private var unitPointSize: CGFloat {
        let wanted = size == .focus ? focusUnit : secondaryUnit
        let designBase = size == .focus ? LiveNumeralMetrics.focusUnitSize : LiveNumeralMetrics.secondaryUnitSize
        return min(max(wanted, designBase * scale), pointSize * LiveNumeralMetrics.unitShareOfNumeral)
    }

    private var isMissing: Bool { state == .missing || value == WidgetMetrics.missingValue }

    private var numeralColor: Color {
        switch state {
        case .paused: LivePalette.frozenNumeral
        case .missing: LivePalette.missing
        default: isMissing ? LivePalette.missing : color
        }
    }

    private var unitTint: Color {
        state == .paused ? LivePalette.frozenUnit : (unitColor ?? color)
    }

    private func tracking(_ points: CGFloat) -> CGFloat { points * (size == .focus ? -0.04 : -0.022) }

    /// The width the unit block takes, at most 45% of the line, so the figure keeps most of it.
    private func unitBlockWidth(unitSize: CGFloat, limit: CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        for line in unit { widest = max(widest, LiveNumeralMetrics.unitWidth(line, pointSize: unitSize)) }
        if let micro { widest = max(widest, LiveNumeralMetrics.unitWidth(micro, pointSize: unitSize * 0.85) * 0.9) }
        return min(widest * 1.03, limit)
    }

    private var hasUnit: Bool { !unit.isEmpty || micro != nil }

    /// What is drawn: a figure that is not known yet is a short en dash, not the em dash the text rows use (at this size that
    /// would be a bar a third of the line long).
    private var displayValue: String { isMissing ? "\u{2013}" : value }

    public var body: some View {
        let nominal = LiveNumeralMetrics.digitHeight(pointSize)
        GeometryReader { proxy in
            let u = unitPointSize
            let gap = 9 * max(scale, 0.7)
            let unitWidth = hasUnit ? unitBlockWidth(unitSize: u, limit: proxy.size.width * 0.45) : 0
            let room = max(1, proxy.size.width - (hasUnit ? unitWidth + gap : 0))
            let shown = displayValue
            let natural = LiveNumeralMetrics.numeralWidth(shown, pointSize: pointSize, tracking: tracking(pointSize)) * 1.01
            // A figure wider than its line is scaled as a whole, so its digits stay on the baseline the gaps are measured from.
            let k = natural > room ? max(0.4, room / natural) : 1
            let drawn = pointSize * k
            let digits = LiveNumeralMetrics.digitHeight(drawn)
            let lift = LiveNumeralMetrics.ascender(drawn) - digits
            HStack(alignment: .lastTextBaseline, spacing: gap) {
                // The tightening applies between the figures, not after the last one: tracking after it would shorten the
                // text's frame and the last glyph's edge would be cut off.
                (Text(verbatim: String(shown.dropLast())).tracking(tracking(drawn)) + Text(verbatim: String(shown.suffix(1))))
                    .font(LiveNumeralMetrics.numeralFont(drawn))
                    .foregroundStyle(numeralColor)
                    .lineLimit(1)
                    .fixedSize()
                if hasUnit { unitBlock(size: u, width: unitWidth) }
            }
            // Cropped to the digits, so the gaps between figures are the gaps between ink.
            .frame(height: digits, alignment: .top)
            .offset(y: -lift)
            .frame(width: proxy.size.width, height: nominal, alignment: .bottomLeading)
        }
        .frame(height: nominal)
        .opacity(state == .stale ? GlanceMetricLayout.staleOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel ?? unit.joined(separator: " ")))
        .accessibilityValue(Text(verbatim: spokenValue ?? [isMissing ? nil : value, micro].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func unitBlock(size u: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(unit.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.system(size: u, weight: .semibold))
                    .tracking(u * 0.045)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(unitTint)
            }
            if let micro {
                Text(verbatim: micro)
                    .font(.system(size: u * 0.85, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(state == .paused ? LivePalette.frozenUnit : LivePalette.secondaryText)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - A line of small print

public extension View {
    /// The live screens' small text at a fixed design size that scales with Dynamic Type up to `maxSize`, and then wraps to
    /// `lines` and shrinks rather than hyphenating a word or growing past its place. Set the colour on the `Text` first.
    func liveText(_ size: CGFloat, weight: Font.Weight = .medium, maxSize: CGFloat? = nil, lines: Int = 1,
                  relativeTo style: Font.TextStyle = .caption) -> some View {
        modifier(LiveTextFit(base: size, weight: weight, maxSize: maxSize, lines: lines, style: style))
    }
}

private struct LiveTextFit: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let weight: Font.Weight
    private let maxSize: CGFloat?
    private let lines: Int

    init(base: CGFloat, weight: Font.Weight, maxSize: CGFloat?, lines: Int, style: Font.TextStyle) {
        _scaled = ScaledMetric(wrappedValue: base, relativeTo: style)
        self.weight = weight
        self.maxSize = maxSize
        self.lines = lines
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: maxSize.map { min(scaled, $0) } ?? scaled, weight: weight))
            .lineLimit(lines)
            .minimumScaleFactor(0.5)
    }
}
