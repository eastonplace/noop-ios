#if !os(watchOS)
import SwiftUI

// MARK: Live Activity and Dynamic Island
//
// The workout's Lock Screen card and Dynamic Island, in the widget language: a recording eyebrow with its pulse, the
// elapsed time as the hero, the heart rate in its zone's colour, strain and energy as quiet facts, and the wearer's own
// Rest / Steady / Push rail. The timer is `Text(timerInterval:pauseTime:)`, so a paused workout's clock stops on the
// Lock Screen by itself. The Pause / Resume control is supplied by the caller: the widget extension wraps it in a
// `Button(intent:)`, which these shared views, also drawn by the simulator QA gallery, must not know about.

/// What the workout's heart-rate colours and rail are measured against: the wearer's own maximum when the activity carries
/// it, the fixed split otherwise.
private func liveThresholds(maxHR: Double?) -> HRZoneStyle.Thresholds {
    maxHR.map { HRZoneStyle.Thresholds(hrMax: $0) } ?? .default
}

private func liveHeartTint(bpm: Int?, maxHR: Double?) -> Color {
    guard let bpm else { return StrandPalette.textTertiary }
    return HRZoneStyle.color(for: Double(bpm), thresholds: liveThresholds(maxHR: maxHR))
}

private func liveStrainText(_ strain: Double?, building: Bool) -> String {
    if building { return String(localized: "Building", bundle: .module) }
    return strain.map { String(format: "%.1f", $0) } ?? WidgetMetrics.missingValue
}

/// A state pill whose word comes from this package's string table, so it is translated in the widget extension too (which
/// carries no string table of its own).
struct LivePill: View {
    let title: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(title, bundle: .module).statePillLabel().statePillChrome(tint: tint)
    }
}

/// Whether a live-workout indicator (the eyebrow glyph or a status dot) pulses as "recording". One rule for every surface:
/// the in-app header, Today's card, the Lock Screen card and the expanded island. A paused workout is not recording, a
/// pending finish has stopped recording (the Ending pill says so beside it), and a reading that has gone stale is not
/// news from a live strap.
public enum NOOPLiveWorkoutPulse {
    public static func isActive(isPaused: Bool, isEnding: Bool, isStale: Bool = false) -> Bool {
        !isPaused && !isEnding && !isStale
    }
}

/// "Ending": the workout was ended and is saving, or the save failed and is waiting for a retry. Drawn where "Paused" is, so
/// a frozen clock and a Pause button that has gone quiet are explained, on the Lock Screen card and in the expanded island.
public struct NOOPLiveEndingPill: View {
    public init() {}
    public var body: some View { LivePill(title: "Ending", tint: StrandPalette.textSecondary) }
}

/// The elapsed time. Counts up from `startedAt` (the workout's start moved forward by the pauses already over) and
/// stands still at `pausedAt` while a pause is open.
public struct NOOPLiveTimerText: View {
    public let startedAt: Date?
    public let pausedAt: Date?
    public let size: CGFloat
    public let isDimmed: Bool

    public init(startedAt: Date?, pausedAt: Date? = nil, size: CGFloat, isDimmed: Bool = false) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.size = size
        self.isDimmed = isDimmed
    }

    public var body: some View {
        Group {
            if let startedAt {
                Text(timerInterval: startedAt...Date.distantFuture,
                     pauseTime: pausedAt.map { max($0, startedAt) },
                     countsDown: false)
            } else {
                Text(verbatim: "—:—").foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .font(StrandFont.number(size, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .opacity(isDimmed ? 0.45 : 1)
    }
}

/// The face of the Pause / Resume button, for the caller to put inside a `Button(intent:)`.
public struct NOOPLivePauseButtonLabel: View {
    public let isPaused: Bool
    /// `compact` is the icon-only face for the Dynamic Island's crowded regions.
    public let isCompact: Bool

    public init(isPaused: Bool, isCompact: Bool = false) {
        self.isPaused = isPaused
        self.isCompact = isCompact
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: isCompact ? 14 : 12, weight: .bold))
            if !isCompact {
                Text(isPaused ? "Resume" : "Pause", bundle: .module)
                    .font(.system(size: 14, weight: .bold))
            }
        }
        .foregroundStyle(StrandPalette.onInk)
        .padding(.horizontal, isCompact ? 14 : 16)
        .frame(height: isCompact ? 34 : 36)
        .background(Capsule(style: .continuous).fill(StrandPalette.ink))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isPaused ? "Resume workout" : "Pause workout", bundle: .module))
    }
}

/// The Lock Screen and banner card.
public struct NOOPWorkoutLiveActivityView<Control: View>: View {
    public let title: String
    public let startedAt: Date?
    public let pausedAt: Date?
    /// Set while the workout is being ended: the clock stops here, with no Paused pill, because the workout is not paused,
    /// it is finished and saving.
    public let frozenAt: Date?
    public let bpm: Int?
    public let strain: Double?
    public let strainBuilding: Bool
    public let calories: Int?
    public let hrSpark: [Int]?
    public let maxHR: Double?
    /// ActivityKit's own staleness: the app has not updated this activity for a while.
    public let isStale: Bool
    /// False while the strap is not connected: the reading is then the last one taken, not a live one.
    public let heartRateIsLive: Bool
    /// The workout was ended and is saving (or waits for a retry): the eyebrow says "Ending".
    public let isEnding: Bool
    private let control: Control

    public init(title: String, startedAt: Date?, pausedAt: Date? = nil, frozenAt: Date? = nil, bpm: Int?, strain: Double?,
                strainBuilding: Bool, calories: Int?, hrSpark: [Int]?, maxHR: Double? = nil, isStale: Bool = false,
                heartRateIsLive: Bool = true, isEnding: Bool = false, @ViewBuilder control: () -> Control) {
        self.isEnding = isEnding
        self.title = title
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.frozenAt = frozenAt
        self.bpm = bpm
        self.strain = strain
        self.strainBuilding = strainBuilding
        self.calories = calories
        self.hrSpark = hrSpark
        self.maxHR = maxHR
        self.isStale = isStale
        self.heartRateIsLive = heartRateIsLive
        self.control = control()
    }

    private var isPaused: Bool { pausedAt != nil }
    private var tint: Color { liveHeartTint(bpm: bpm, maxHR: maxHR) }
    /// One rule on every surface: a heart rate that is not live (paused, not updating, strap not connected) is the last
    /// reading, shown quieter. It is "—" only when there has never been one.
    private var heartIsDimmed: Bool { isPaused || isStale || !heartRateIsLive }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow
            HStack(alignment: .center, spacing: 12) {
                NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt ?? frozenAt, size: 38, isDimmed: isPaused || isStale)
                if let hrSpark, hrSpark.count > 1 {
                    Sparkline(values: hrSpark.map(Double.init), gradient: Gradient(colors: [tint.opacity(0.4), tint]),
                              lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                        .frame(height: 22).frame(maxWidth: .infinity)
                        .opacity(heartIsDimmed ? 0.4 : 1)
                        .accessibilityHidden(true)
                } else {
                    Spacer(minLength: 0)
                }
                heartReading
            }
            HStack(alignment: .center, spacing: 14) {
                fact(label: Text("Strain", bundle: .module), value: liveStrainText(strain, building: strainBuilding), tint: StrandPalette.strainAccent)
                fact(label: Text(verbatim: "kcal"), value: calories.map(String.init) ?? WidgetMetrics.missingValue, tint: StrandPalette.textPrimary)
                Spacer(minLength: 6)
                control
            }
            LiveZoneRail(bpm: bpm, thresholds: liveThresholds(maxHR: maxHR), isDimmed: heartIsDimmed, style: .bar)
        }
        .padding(14)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: summary))
    }

    private var eyebrow: some View {
        HStack(spacing: 8) {
            EyebrowPulseIcon(systemName: isPaused ? "pause.fill" : "waveform.path.ecg",
                             color: isPaused ? StrandPalette.statusWarning : StrandPalette.liveRed,
                             pulses: NOOPLiveWorkoutPulse.isActive(isPaused: isPaused, isEnding: isEnding, isStale: isStale))
            Text(verbatim: title).textCase(.uppercase)
                .font(StrandFont.overline).tracking(1.2)
                .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            if isEnding {
                NOOPLiveEndingPill()
            } else if isPaused {
                LivePill(title: "Paused", tint: StrandPalette.statusWarning)
            } else if isStale {
                LivePill(title: "Not updating", tint: StrandPalette.textSecondary)
            }
        }
    }

    private var heartReading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "heart.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: bpm.map(String.init) ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(30, weight: .bold)).monospacedDigit()
                .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text("bpm", bundle: .module).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        // The reading is never what gives way: the trace beside it shrinks first.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .opacity(heartIsDimmed ? 0.6 : 1)
    }

    private func fact(label: Text, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label.textCase(.uppercase).font(.system(size: 9, weight: .bold)).tracking(0.8)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: value).font(StrandFont.number(16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : tint)
        }
    }

    private var summary: String {
        let state = isEnding ? "ending" : (isPaused ? "paused" : (isStale ? "not updating" : "recording"))
        return "\(title), \(state), heart rate \(bpm.map(String.init) ?? "unavailable"), strain \(liveStrainText(strain, building: strainBuilding))"
    }
}

public extension NOOPWorkoutLiveActivityView where Control == EmptyView {
    init(title: String, startedAt: Date?, pausedAt: Date? = nil, frozenAt: Date? = nil, bpm: Int?, strain: Double?,
         strainBuilding: Bool, calories: Int?, hrSpark: [Int]?, maxHR: Double? = nil, isStale: Bool = false,
         heartRateIsLive: Bool = true, isEnding: Bool = false) {
        self.init(title: title, startedAt: startedAt, pausedAt: pausedAt, frozenAt: frozenAt, bpm: bpm, strain: strain,
                  strainBuilding: strainBuilding, calories: calories, hrSpark: hrSpark, maxHR: maxHR,
                  isStale: isStale, heartRateIsLive: heartRateIsLive, isEnding: isEnding) { EmptyView() }
    }
}

/// Compact leading: the heart in its zone's colour and the reading. A paused workout shows the pause glyph instead, and a
/// reading that is no longer live (paused, stale, strap not bonded) is dimmed like the other surfaces dim it: the heart
/// and the digits together, as the Lock Screen and the expanded island dim theirs.
public struct NOOPDynamicIslandHeartRateView: View {
    public let bpm: Int?
    public let maxHR: Double?
    public let isPaused: Bool
    public let isDimmed: Bool
    public init(bpm: Int?, maxHR: Double? = nil, isPaused: Bool = false, isDimmed: Bool = false) {
        self.bpm = bpm
        self.maxHR = maxHR
        self.isPaused = isPaused
        self.isDimmed = isDimmed
    }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isPaused ? "pause.fill" : "heart.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isPaused ? StrandPalette.statusWarning : liveHeartTint(bpm: bpm, maxHR: maxHR))
                // The pause glyph is the state itself and keeps its strength; a heart is a reading, and a stale one is quiet.
                .opacity(isDimmed && !isPaused ? 0.6 : 1)
            Text(verbatim: bpm.map(String.init) ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(13, weight: .bold)).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .opacity(isDimmed ? 0.6 : 1)
        }
    }
}

/// Compact trailing: the elapsed time, stopped and dimmed while paused.
public struct NOOPDynamicIslandTimerView: View {
    public let startedAt: Date?
    public let pausedAt: Date?
    /// Set while the workout is being ended: the clock stops here (not dimmed, it is not a pause).
    public let frozenAt: Date?
    public init(startedAt: Date?, pausedAt: Date? = nil, frozenAt: Date? = nil) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.frozenAt = frozenAt
    }
    public var body: some View {
        NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt ?? frozenAt, size: 13, isDimmed: pausedAt != nil)
            .frame(maxWidth: 56, alignment: .trailing)
    }
}

public struct NOOPDynamicIslandStrainView: View {
    public let strain: Double?
    public let building: Bool
    public init(strain: Double?, building: Bool) { self.strain = strain; self.building = building }
    public var body: some View {
        Text(verbatim: liveStrainText(strain, building: building))
            .font(StrandFont.number(13, weight: .bold)).monospacedDigit()
            .foregroundStyle(StrandPalette.strainAccent).lineLimit(1).minimumScaleFactor(0.65)
    }
}

/// Minimal: one glyph, the heart in its zone's colour, or the pause glyph while paused. A heart whose reading is no longer
/// live (the strap not connected, or gone quiet) is dimmed like the reading is on every other surface.
public struct NOOPDynamicIslandMinimalView: View {
    public let bpm: Int?
    public let maxHR: Double?
    public let isPaused: Bool
    public let isDimmed: Bool
    public init(bpm: Int?, maxHR: Double? = nil, isPaused: Bool = false, isDimmed: Bool = false) {
        self.bpm = bpm
        self.maxHR = maxHR
        self.isPaused = isPaused
        self.isDimmed = isDimmed
    }
    public var body: some View {
        Image(systemName: isPaused ? "pause.fill" : "heart.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isPaused ? StrandPalette.statusWarning : liveHeartTint(bpm: bpm, maxHR: maxHR))
            .opacity(isDimmed && !isPaused ? 0.6 : 1)
    }
}

/// Expanded leading: the sport as an eyebrow over the elapsed time.
public struct NOOPDynamicIslandIdentityView: View {
    public let sport: String
    public let startedAt: Date?
    public let pausedAt: Date?
    /// Set while the workout is being ended: the clock stops here.
    public let frozenAt: Date?
    /// The finish is pending: the eyebrow stops pulsing, as the card's and the in-app header's do, so nothing here
    /// signals a live recording next to the Ending pill.
    public let isEnding: Bool
    public init(sport: String, startedAt: Date?, pausedAt: Date? = nil, frozenAt: Date? = nil, isEnding: Bool = false) {
        self.sport = sport
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.frozenAt = frozenAt
        self.isEnding = isEnding
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                EyebrowPulseIcon(systemName: pausedAt == nil ? "waveform.path.ecg" : "pause.fill",
                                 color: pausedAt == nil ? StrandPalette.liveRed : StrandPalette.statusWarning,
                                 pulses: NOOPLiveWorkoutPulse.isActive(isPaused: pausedAt != nil, isEnding: isEnding))
                Text(verbatim: sport).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(1.0)
                    .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt ?? frozenAt, size: 26, isDimmed: pausedAt != nil)
        }
    }
}

/// Expanded trailing: the reading in its zone's colour over strain.
public struct NOOPDynamicIslandVitalsView: View {
    public let bpm: Int?
    public let strain: Double?
    public let building: Bool
    public let maxHR: Double?
    public let isDimmed: Bool
    public init(bpm: Int?, strain: Double?, building: Bool, maxHR: Double? = nil, isDimmed: Bool = false) {
        self.bpm = bpm
        self.strain = strain
        self.building = building
        self.maxHR = maxHR
        self.isDimmed = isDimmed
    }
    public var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "heart.fill").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(liveHeartTint(bpm: bpm, maxHR: maxHR)).accessibilityHidden(true)
                Text(verbatim: bpm.map(String.init) ?? WidgetMetrics.missingValue)
                    .font(StrandFont.number(26, weight: .bold)).monospacedDigit()
                    .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            }
            HStack(spacing: 4) {
                Text("Strain", bundle: .module).textCase(.uppercase)
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: liveStrainText(strain, building: building))
                    .font(StrandFont.number(13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(StrandPalette.strainAccent).lineLimit(1)
            }
        }
        .opacity(isDimmed ? 0.6 : 1)
    }
}

public struct NOOPZoneSplitView: View {
    public let seconds: [Int]?
    public init(seconds: [Int]?) { self.seconds = seconds }

    public var body: some View {
        GeometryReader { proxy in
            let values = normalized
            let total = max(values.reduce(0, +), 1)
            let colors = [StrandPalette.accent, StrandPalette.statusPositive,
                          StrandPalette.statusWarning, StrandPalette.stressAccent, StrandPalette.liveRed]
            HStack(spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(colors[index].opacity(value > 0 ? 1 : 0.2))
                        .frame(width: max(3, proxy.size.width * CGFloat(value) / CGFloat(total) - 2))
                }
            }
        }
        .frame(height: 7)
        .accessibilityLabel("Workout heart rate zone distribution")
    }

    private var normalized: [Int] {
        let input = Array((seconds ?? []).prefix(5))
        return input + Array(repeating: 0, count: max(0, 5 - input.count))
    }
}
#endif
