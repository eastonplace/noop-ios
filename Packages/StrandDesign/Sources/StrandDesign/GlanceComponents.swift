import SwiftUI

// MARK: - Glance metrics
//
// The workout screen is read in under a second, at arm's length, in motion. One big number for the thing the wearer
// came to see, a row of smaller ones for the rest, and nothing that moves. These are those numerals and the two big
// buttons under them.

/// The sizes of a glance numeral, worked out from plain values so they are tested without a view.
public enum GlanceMetricLayout {
    /// The size of every secondary numeral.
    public static let secondaryPointSize: CGFloat = 56

    /// The focus numeral's size for the number of characters it has to show: the shorter it is, the bigger it can be, and
    /// a number that grows ("9.99" to "10.00" km, "59:59" to "1:00:00") steps down instead of overflowing its line.
    public static func focusPointSize(characterCount: Int) -> CGFloat {
        switch characterCount {
        case ...4: 132
        case 5: 116
        case 6: 100
        default: 80
        }
    }
}

/// One metric, drawn to be read at a glance: a caps eyebrow that names it (with its unit), the numeral, and an optional
/// micro line.
///
/// The numeral is a fixed size that does not scale with Dynamic Type (it is already larger than the largest accessibility
/// text); the eyebrow and the micro line scale and wrap. A value that is not known reads "—" in the tertiary ink, never 0.
public struct GlanceMetricView: View {
    public enum Size: Sendable {
        /// The one big number.
        case focus
        /// One of the row beneath it.
        case secondary
    }

    /// How current the number is. A reading whose source has gone quiet keeps its last number, quieter.
    public enum State: Sendable {
        case live
        /// The source has gone quiet; the last number steps back (and the micro line should say so).
        case stale
        /// There is no number yet.
        case missing
        /// The workout is paused: the number is frozen.
        case paused

        var opacity: Double {
            switch self {
            case .live, .missing: 1
            case .stale: 0.6
            case .paused: 0.4
            }
        }
    }

    private let eyebrow: String
    private let value: String
    private let size: Size
    private let state: State
    private let micro: String?
    private let spokenLabel: String?
    private let spokenValue: String?

    /// - Parameters:
    ///   - eyebrow: What the number is, with its unit ("Distance · km"); drawn in capitals.
    ///   - value: The number as shown, or `WidgetMetrics.missingValue` while there is none.
    ///   - micro: A line under the number ("avg 6:13", "no signal").
    ///   - spokenLabel / spokenValue: What VoiceOver reads, when the drawn text is not enough ("Distance" / "5.49 kilometres").
    public init(eyebrow: String, value: String, size: Size = .focus, state: State = .live, micro: String? = nil,
                spokenLabel: String? = nil, spokenValue: String? = nil) {
        self.eyebrow = eyebrow
        self.value = value
        self.size = size
        self.state = state
        self.micro = micro
        self.spokenLabel = spokenLabel
        self.spokenValue = spokenValue
    }

    private var isMissing: Bool { state == .missing || value == WidgetMetrics.missingValue }

    private var pointSize: CGFloat {
        switch size {
        case .focus: GlanceMetricLayout.focusPointSize(characterCount: value.count)
        case .secondary: GlanceMetricLayout.secondaryPointSize
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(verbatim: eyebrow)
                .strandOverlineFitted()
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: value)
                .font(StrandFont.number(pointSize, weight: .bold))
                .foregroundStyle(isMissing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let micro {
                Text(verbatim: micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .microLabelFit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(state.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel ?? eyebrow))
        .accessibilityValue(Text(verbatim: spokenValue ?? [isMissing ? nil : value, micro].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.updatesFrequently)
    }
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
