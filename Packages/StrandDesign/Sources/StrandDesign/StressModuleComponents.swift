import Foundation
import SwiftUI

// MARK: - Stress Module (NOOP scope, data-rich tier)
//
// The Today-screen "Today's Stress" module rebuilt for micro-detail. Same information
// contract as production (dot + overline + value badge on one quiet row, state word,
// 24-hour ribbon) — every layer upgraded:
//
//   · the whole module tints by the CURRENT band (StressLoadStyle's calm→moderate→high
//     ramp, the same ramp the new StressView detail chart speaks), never a fixed accent
//   · the status dot breathes a soft halo (Reduce Motion gated)
//   · the ribbon pips carry their hour's LEVEL as height, not just colour-opacity,
//     revealed with a 18 ms stagger; unscored hours stay honest baseline ticks
//   · the peak hour wears a bead cap; the current hour carries a quiet "now" tick
//   · touch-and-drag scrubs the ribbon: the touched hour lifts, the state row morphs
//     into an hour readout, and a selection haptic marks each hour crossed
//   · the card presses with a 0.985 scale (no layout shift), numerals are tabular,
//     and the whole module collapses to one VoiceOver element with a full summary
//
// Fixture-only: state presets in the specimen cover Calibrating / Low / Moderate / High.

// MARK: Stress ramp compatibility
//
// Keep the original public type name for source compatibility, but make every color
// resolve through StressLoadStyle so Today and the Stress detail use one semantic ramp.

public enum StressHeatStyle {
    public static let calm = StressLoadStyle.calm
    public static let moderate = StressLoadStyle.moderate
    public static let elevated = moderate
    public static let high = StressLoadStyle.high

    public static let stops = StressLoadStyle.stops

    public static func color(for level: Double) -> Color {
        StressLoadStyle.color(for: level)
    }

    public static func zoneColor(_ band: Int) -> Color {
        switch band {
        case 0: calm
        case 1: moderate
        default: high
        }
    }
}

/// The calendar context represented by a stress module.
///
/// `.today` preserves the original title, copy, accessibility summary, and current-time
/// marker. Historical cards name their date and never imply that the selected day is now.
public enum StressModuleDateContext: Equatable, Sendable {
    case today
    case historical(date: Date)

    fileprivate var isToday: Bool {
        if case .today = self { return true }
        return false
    }

    fileprivate var title: String {
        switch self {
        case .today:
            return "Today’s Stress"
        case .historical(let date):
            return "Stress · \(date.formatted(.dateTime.month(.abbreviated).day().year()))"
        }
    }

    fileprivate var accessibilitySubject: String {
        switch self {
        case .today:
            return "Today's stress"
        case .historical(let date):
            return "Stress for \(date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))"
        }
    }
}

// MARK: Band vocabulary (words identical to production paperStressState)

public enum StressModuleBand {
    public static func word(_ value: Double?) -> String {
        guard let value else { return "Calibrating" }
        switch value {
        case ..<1: return "Low"
        case ..<2: return "Moderate"
        default: return "High"
        }
    }

    public static func why(_ value: Double?) -> String {
        guard let value else { return "First nights build your baseline." }
        switch value {
        case ..<1: return "Load is sitting under your baseline."
        case ..<2: return "Riding above baseline — normal for a workday."
        default: return "Sustained high load. A breather would land well."
        }
    }

    public static func word(_ value: Double?, mode: StressPresentationMode) -> String {
        switch mode {
        case .baselineCalibration:
            return "Calibrating"
        case .dailyOnly, .intradayOnly, .combined:
            guard let value else { return "Insufficient signal" }
            return word(value)
        case .empty:
            return "No data"
        }
    }

    public static func why(
        _ value: Double?,
        mode: StressPresentationMode,
        baselineBuilding: Bool = false,
        dateContext: StressModuleDateContext = .today
    ) -> String {
        switch mode {
        case .baselineCalibration:
            return "First nights build your baseline."
        case .dailyOnly:
            return dateContext.isToday
                ? "The daily score is ready; today has not supplied enough hourly signal."
                : "The daily score is ready; hourly signal is unavailable for this date."
        case .intradayOnly:
            guard value != nil else {
                return baselineBuilding
                    ? "Same-day signal is present but not yet scorable while your baseline builds."
                    : "Same-day signal is present but not yet scorable."
            }
            return baselineBuilding
                ? "Same-day signal is available while your daily baseline builds."
                : "Same-day signal is available; a daily score has not landed yet."
        case .combined:
            return why(value)
        case .empty:
            return dateContext.isToday
                ? "No stress signal is available for today."
                : "No stress signal is available for this date."
        }
    }

    public static func color(_ value: Double?) -> Color {
        guard let value else { return StrandPalette.textTertiary }
        return StressHeatStyle.color(for: value)
    }

    /// 0 calm · 1 moderate · 2 high — same thresholds the band legend names.
    public static func band(_ value: Double) -> Int {
        if value < 1 { return 0 }
        if value < 2 { return 1 }
        return 2
    }
}

// MARK: - StressModuleCard

public struct StressModuleCard: View {
    /// 24 hour slots, `nil` = no scorable signal that hour (never fabricated).
    let hours: [Double?]
    /// The daily 0–3 value; `nil` = calibrating.
    let value: Double?
    /// Shared data-coverage semantics used by StressView and Today.
    let presentationMode: StressPresentationMode
    /// True only when the caller has proved that historical baseline evidence is absent.
    var baselineBuilding: Bool = false
    /// The hour index the "now" tick sits under (clamped to 0…23).
    var nowHour: Int = 17
    /// The calendar day represented by this module. Defaults to today's original behavior.
    var dateContext: StressModuleDateContext = .today
    var surfaceStyle: ComponentSurfaceStyle = .flat
    var onOpen: () -> Void = {}

    public init(
        hours: [Double?],
        value: Double?,
        nowHour: Int = 17,
        presentationMode: StressPresentationMode,
        baselineBuilding: Bool = false,
        dateContext: StressModuleDateContext = .today,
        surfaceStyle: ComponentSurfaceStyle = .flat,
        onOpen: @escaping () -> Void = {}
    ) {
        self.hours = hours
        self.value = value
        self.presentationMode = presentationMode
        self.baselineBuilding = baselineBuilding
        self.nowHour = nowHour
        self.dateContext = dateContext
        self.surfaceStyle = surfaceStyle
        self.onOpen = onOpen
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    /// Hour under the finger while scrubbing the ribbon, nil when idle.
    @State private var scrubHour: Int? = nil

    public var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                header
                stateRow
                ribbon
                axis
                bandSplit
            }
            .padding(surfaceStyle == .card ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(StressModulePressStyle())
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.05)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens the Stress monitor")
    }

    // MARK: Derived

    private var scored: [(hour: Int, level: Double)] {
        hours.enumerated().compactMap { index, level in level.map { (index, $0) } }
    }

    private var peak: (hour: Int, level: Double)? {
        scored.max(by: { $0.level < $1.level })
    }

    private var scrubSample: (hour: Int, level: Double)? {
        guard let scrubHour else { return nil }
        return hours.indices.contains(scrubHour)
            ? hours[scrubHour].map { (scrubHour, $0) }
            : nil
    }

    /// The value the badge is showing right now: the scrubbed hour while touching, else the day.
    private var displayedValue: Double? { scrubSample?.level ?? value }

    private var accent: Color { StressModuleBand.color(displayedValue) }

    // MARK: Chrome

    /// Paper surface with a whisper of top light — flat, hairline-bound, no glow.
    @ViewBuilder private var cardSurface: some View {
        if surfaceStyle == .card {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
        } else {
            Color.clear
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            StressBreathingDot(color: accent, active: (value ?? 0) >= 2)
            Text(dateContext.title)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            valueBadge
        }
    }

    private var valueBadge: some View {
        HStack(spacing: 4) {
            if scrubHour != nil {
                Image(systemName: "hand.point.up.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            Text(displayedValue.map { String(format: "%.1f", $0) } ?? "–.–")
                .font(StrandFont.captionNumber)
                .monospacedDigit()
                .foregroundStyle(displayedValue == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(accent.opacity(displayedValue == nil ? 0.08 : 0.14), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 0.75))
        .animation(StrandMotion.interactive, value: scrubHour != nil)
    }

    @ViewBuilder
    private var stateRow: some View {
        if let sample = scrubSample {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Hour readout while the finger rides the ribbon.
                Text(Self.hourLabel(sample.hour))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StressHeatStyle.color(for: sample.level))
                Text("· \(StressModuleBand.word(sample.level)) hour")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(StrandMotion.fade, value: scrubHour)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(StressModuleBand.word(value, mode: presentationMode))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(value == nil ? StrandPalette.textSecondary : accent)
                Text(StressModuleBand.why(
                    value,
                    mode: presentationMode,
                    baselineBuilding: baselineBuilding,
                    dateContext: dateContext
                ))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(StrandMotion.fade, value: scrubHour)
        }
    }

    // MARK: Ribbon

    private static let ribbonHeight: CGFloat = 40
    private static let tickHeight: CGFloat = 3

    private var ribbon: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let slot = width / 24
            ZStack(alignment: .bottom) {
                // Baseline the pips grow from — always visible, so an empty day still has structure.
                Rectangle()
                    .fill(StrandPalette.hairlineStrong.opacity(0.8))
                    .frame(height: 1)

                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        pip(hour: hour)
                            .frame(width: slot, alignment: .bottom)
                    }
                }

                // Peak bead — a small crown on the day's highest scored hour.
                if let peak, revealed, scrubHour == nil {
                    Circle()
                        .fill(StressHeatStyle.color(for: peak.level))
                        .frame(width: 4, height: 4)
                        .offset(
                            x: slot * (CGFloat(peak.hour) + 0.5) - width / 2,
                            y: -(pipHeight(peak.level) + 5)
                        )
                        .transition(.opacity)
                }

                // "Now" exists only on the live day; historical dates have no current hour.
                if dateContext.isToday {
                    Triangle()
                        .fill(StrandPalette.textTertiary)
                        .frame(width: 5, height: 3)
                        .offset(x: slot * (CGFloat(min(max(nowHour, 0), 23)) + 0.5) - width / 2, y: 5)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
        }
        .frame(height: Self.ribbonHeight)
        .padding(.top, 6) // headroom for the peak bead
    }

    @ViewBuilder
    private func pip(hour: Int) -> some View {
        let level = hours.indices.contains(hour) ? hours[hour] : nil
        let isScrubbed = scrubHour == hour
        let dimmed = scrubHour != nil && !isScrubbed

        if let level {
            Capsule(style: .continuous)
                .fill(StressHeatStyle.color(for: level))
                .frame(width: 4.5, height: revealed ? pipHeight(level) : Self.tickHeight)
                .scaleEffect(isScrubbed ? 1.18 : 1, anchor: .bottom)
                .opacity(dimmed ? 0.45 : 1)
                .animation(
                    reduceMotion ? nil : StrandMotion.value.delay(revealed ? 0 : Double(hour) * 0.018),
                    value: revealed
                )
                .animation(StrandMotion.interactive, value: scrubHour)
        } else {
            // Unscored hour: an honest baseline tick, never a fabricated bar.
            Capsule(style: .continuous)
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 3, height: Self.tickHeight)
                .opacity(dimmed ? 0.4 : 0.9)
        }
    }

    private func pipHeight(_ level: Double) -> CGFloat {
        Self.tickHeight + 3 + CGFloat(min(max(level / 3, 0), 1)) * (Self.ribbonHeight - Self.tickHeight - 9)
    }

    /// Riding the ribbon reads hours; each hour boundary crossed ticks the selection haptic.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard width > 0 else { return }
                let hour = min(max(Int(drag.location.x / width * 24), 0), 23)
                if hour != scrubHour {
                    scrubHour = hour
                    StrandHaptic.selection.play()
                }
            }
            .onEnded { _ in
                withAnimation(StrandMotion.interactive) { scrubHour = nil }
            }
    }

    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(Array(["12AM", "6AM", "12PM", "6PM", "12AM"].enumerated()), id: \.offset) { index, label in
                Text(label)
                if index < 4 { Spacer(minLength: 0) }
            }
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Band split footer

    @ViewBuilder
    private var bandSplit: some View {
        let counts = bandCounts
        if counts.reduce(0, +) > 0 {
            HStack(spacing: 10) {
                bandKey(count: counts[0], word: "calm", color: StressHeatStyle.calm)
                bandKey(count: counts[1], word: "moderate", color: StressHeatStyle.moderate)
                bandKey(count: counts[2], word: "high", color: StressHeatStyle.high)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            HStack {
                Text(presentationMode == .dailyOnly
                     ? (dateContext.isToday
                        ? "No same-day signal to score yet."
                        : "No hourly signal was recorded for this date.")
                     : presentationMode == .intradayOnly
                        ? "Same-day signal is present but not yet scorable."
                        : "Wear through a few days to unlock the hourly ribbon.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var bandCounts: [Int] {
        var counts = [0, 0, 0]
        for entry in scored { counts[StressModuleBand.band(entry.level)] += 1 }
        return counts
    }

    @ViewBuilder
    private func bandKey(count: Int, word: String, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("\(count)h")
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(word)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: Helpers

    static func hourLabel(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        if normalized == 0 { return "12 AM" }
        if normalized < 12 { return "\(normalized) AM" }
        if normalized == 12 { return "12 PM" }
        return "\(normalized - 12) PM"
    }

    private var accessibilitySummary: String {
        guard let value else {
            return "\(dateContext.accessibilitySubject), \(StressModuleBand.word(nil, mode: presentationMode)). \(StressModuleBand.why(nil, mode: presentationMode, baselineBuilding: baselineBuilding, dateContext: dateContext))"
        }
        var parts = [
            "\(dateContext.accessibilitySubject) \(String(format: "%.1f", value)), \(StressModuleBand.word(value, mode: presentationMode))",
        ]
        if let peak {
            parts.append("peak \(String(format: "%.1f", peak.level)) at \(Self.hourLabel(peak.hour))")
        }
        let counts = bandCounts
        if counts.reduce(0, +) > 0 {
            parts.append("\(counts[0]) hours calm, \(counts[1]) moderate, \(counts[2]) high")
        }
        return parts.joined(separator: ", ")
    }
}

/// Press feedback: pure scale, no layout shift, spring in/out, Reduce Motion aware.
struct StressModulePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

/// The status dot with a soft breathing halo — active (high band) breathes wider.
private struct StressBreathingDot: View {
    let color: Color
    let active: Bool

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.3), lineWidth: 4)
                        .scaleEffect(breathing ? (active ? 1.9 : 1.45) : 0.9)
                        .opacity(breathing ? 0 : 0.8)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: active ? 1.6 : 2.6).repeatForever(autoreverses: false)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
