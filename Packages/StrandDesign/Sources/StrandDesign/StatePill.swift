import SwiftUI

// MARK: - StatePill (§9.4 chrome) & ConnectionDot (sidebar status footer)
//
// Small status chips used in chrome: a rounded pill with an optional leading dot
// and a tinted label. Tones map to the status palette (positive/warning/critical)
// plus neutral and accent. The ConnectionDot is a tiny pulsing presence indicator
// used in the strap-status footer / menu-bar.

public enum StrandTone: Sendable {
    case neutral
    case accent
    case positive
    case warning
    case critical

    public var color: Color {
        switch self {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }
}

public struct StatePill: View {

    public var title: LocalizedStringKey
    public var tone: StrandTone
    public var showsDot: Bool
    /// Pulse the leading dot (e.g. "live" / "syncing").
    public var pulsing: Bool

    public init(_ title: LocalizedStringKey, tone: StrandTone = .neutral, showsDot: Bool = true, pulsing: Bool = false) {
        self.title = title
        self.tone = tone
        self.showsDot = showsDot
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                if pulsing {
                    MicroStatusDot(color: tone.color, isActive: true, diameter: 7)
                } else {
                    ConnectionDot(tone: tone, pulsing: false, size: 7)
                }
            }
            Text(title)
                .statePillLabel()
        }
        .neutralPillChrome()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - Shared pill metrics

extension View {
    /// The state pill's type: 13pt semibold, no tracking, white ink (the approved pill board's `.pill`). White, never
    /// the tone, so a red or amber pill still reads as a quiet label on a neutral chip.
    ///
    /// The 13pt scales with Dynamic Type (`.footnote`). At the accessibility sizes a word wider than the pill scales
    /// down instead of hyphenating ("Rest-ing") and a label wraps between words, `lines` at most. At every smaller size
    /// there is no line limit of its own.
    func statePillLabel(lines: Int = 2) -> some View {
        modifier(StatePillLabelFit(lines: lines))
    }

    /// The neutral pill: 26pt tall at least (10pt side padding) on the `pillFill` wash with a 1pt `pillStroke` edge.
    /// Colour is never in the pill; a pill that carries a state brings its own 7pt dot (`StatePill`, `ScoreStatePill`)
    /// or uses `statePillChrome`.
    public func neutralPillChrome() -> some View {
        self.padding(.horizontal, StatePillMetrics.horizontalPadding)
            .padding(.vertical, StatePillMetrics.verticalPadding)
            .frame(minHeight: StatePillMetrics.minHeight)
            .background(Capsule(style: .continuous).fill(StrandPalette.pillFill))
            .overlay(Capsule(style: .continuous).stroke(StrandPalette.pillStroke, lineWidth: 1))
    }

    /// The state pill's chip: a leading 7pt dot in `tint` and then the neutral chrome. `StatePill` and every pill that
    /// must match it (Live HR zone, Stress value) share this one definition. The tint is the dot only, so a red or amber
    /// state is told apart by its dot and its word, never by a coloured pill.
    public func statePillChrome(tint: Color) -> some View {
        HStack(spacing: StatePillMetrics.dotSpacing) {
            PillToneDot(color: tint)
            self
        }
        .neutralPillChrome()
    }
}

/// The 7pt tone dot at the leading edge of a pill. Scales a little with Dynamic Type and is hidden from VoiceOver (the
/// pill's word carries the state).
struct PillToneDot: View {
    let color: Color
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = StatePillMetrics.dotDiameter

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }
}

private struct StatePillLabelFit: ViewModifier {
    let lines: Int
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = StatePillMetrics.labelSize
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content
                .font(.system(size: size, weight: .semibold, design: .default))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(lines)
                .minimumScaleFactor(0.5)
        } else {
            content
                .font(.system(size: size, weight: .semibold, design: .default))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

enum StatePillMetrics {
    /// The pill's label: 13pt semibold (scaled with Dynamic Type from `.footnote`).
    static let labelSize: CGFloat = 13
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 5
    /// The pill board's 26pt height; a label taller than that (larger text) grows the pill past it.
    static let minHeight: CGFloat = 26
    static let dotDiameter: CGFloat = 7
    static let dotSpacing: CGFloat = 6
}

// MARK: - ConnectionDot

/// A tiny status dot with an optional breathing pulse halo. Used for connection
/// state, live indicators, and inside StatePill.
public struct ConnectionDot: View {

    public var tone: StrandTone
    public var pulsing: Bool
    public var size: CGFloat

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    public init(tone: StrandTone = .positive, pulsing: Bool = false, size: CGFloat = 9) {
        self.tone = tone
        self.pulsing = pulsing
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Dark-mode only (#review): AdditiveBloom used to hide this expanding ring on light
            // (content.opacity(0)); now that we drop the offscreen bloom, gate it explicitly so light
            // mode stays ring-free (the resting dot + its shadow carry the live state there).
            if pulsing && scheme == .dark {
                Circle()
                    .fill(tone.color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every
                    // frame of the repeatForever pulse, a continuous cost while a strap is backfilling
                    // (exactly when this live dot is on screen). The expanding/fading ring reads the
                    // same without it; the resting dot's shadow still carries the "live" glow.
            }
            Circle()
                .fill(tone.color)
                .frame(width: size, height: size)
                .shadow(color: tone.color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        // Honour Reduce Motion: don't kick off the looping pulse (settles at the
        // resting dot) and never attach the repeatForever breathe animation.
        .onAppear { if pulsing && !reduceMotion { animate = true } }
        .animation(pulsing && !reduceMotion ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("StatePill / ConnectionDot") {
    VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
            StatePill("Connected", tone: .positive)
            StatePill("Syncing", tone: .accent, pulsing: true)
            StatePill("Battery 14%", tone: .warning)
            StatePill("Disconnected", tone: .critical)
            StatePill("Idle", tone: .neutral, showsDot: false)
        }
        HStack(spacing: 16) {
            ConnectionDot(tone: .positive)
            ConnectionDot(tone: .accent, pulsing: true)
            ConnectionDot(tone: .warning)
            ConnectionDot(tone: .critical, pulsing: true)
        }
        // mimic the sidebar strap-status footer chip
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whoop 4.0").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("87% · streaming").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ConnectionDot(tone: .positive, pulsing: true)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .frame(width: 300)
    }
    .padding(28)
    .frame(width: 560, height: 280)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
