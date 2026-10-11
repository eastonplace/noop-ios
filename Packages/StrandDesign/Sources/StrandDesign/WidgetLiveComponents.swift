#if !os(watchOS)
import SwiftUI

// MARK: - Component 41 production surfaces

/// The component-41 battery treatment shared by the production widget extension and
/// the DEBUG visual-QA gallery. Values stay optional so an unavailable battery never
/// turns into a fabricated zero.
public struct NOOPWidgetBatteryChip: View {
    public let percentage: Int?

    public init(percentage: Int?) { self.percentage = percentage }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbol)
                .font(.system(size: 8, weight: .bold))
            Text(percentage.map { "\($0)%" } ?? "—")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percentage.map { "Strap battery \($0) percent" } ?? "Strap battery unavailable")
    }

    private var batterySymbol: String {
        guard let percentage else { return "battery.0" }
        switch percentage {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.50"
        case 1...: return "battery.25"
        default: return "battery.0"
        }
    }

    private var tint: Color {
        guard let percentage else { return StrandPalette.textTertiary }
        return percentage <= 20 ? StrandPalette.statusWarning : StrandPalette.textTertiary
    }
}

public struct NOOPRecoverySmallWidgetView: View {
    public let recovery: Int?
    public let delta: Int?
    public let sleepMinutes: Int?
    public let batteryPercentage: Int?

    public init(recovery: Int?, delta: Int?, sleepMinutes: Int?, batteryPercentage: Int?) {
        self.recovery = recovery
        self.delta = delta
        self.sleepMinutes = sleepMinutes
        self.batteryPercentage = batteryPercentage
    }

    private static let sweep: Double = 240 / 360

    public var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("RECOVERY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Circle().fill(accent).frame(width: 6, height: 6)
            }
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height)
                let stroke = min(max(diameter * 0.075, 6), 9)
                let scoreSize = min(max(diameter * 0.28, 25), 34)

                ZStack {
                    Circle()
                        .trim(from: 0, to: Self.sweep)
                        .stroke(StrandPalette.surfaceInset,
                                style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        .rotationEffect(.degrees(150))
                    if let recovery {
                        Circle()
                            .trim(from: 0, to: Self.sweep * min(max(Double(recovery) / 100, 0), 1))
                            .stroke(accent, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                            .rotationEffect(.degrees(150))
                    }
                    VStack(spacing: 1) {
                        Text(recovery.map(String.init) ?? "—")
                            .font(StrandFont.number(scoreSize, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(recovery == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        Text(deltaLine)
                            .font(.system(size: max(8, diameter * 0.075), weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(deltaTint)
                    }
                }
                .frame(width: diameter, height: diameter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text(sleepLine)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                NOOPWidgetBatteryChip(percentage: batteryPercentage)
            }
        }
        // WidgetKit already applies family-aware content margins. A second 13 pt
        // inset made the small widget look like a tiny card floating inside the
        // container. Fill the system-provided content rect instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accent: Color {
        recovery.map { RecoveryBands.color(for: Double($0)) } ?? StrandPalette.textTertiary
    }

    private var deltaLine: String {
        guard let delta else { return "No comparison" }
        return delta >= 0 ? "▲ \(delta) vs yest" : "▼ \(abs(delta)) vs yest"
    }

    private var deltaTint: Color {
        guard let delta else { return StrandPalette.textTertiary }
        return delta >= 0 ? StrandPalette.statusPositive : StrandPalette.metricRose
    }

    private var sleepLine: String {
        guard let sleepMinutes else { return "Sleep unavailable" }
        return "\(sleepMinutes / 60):\(String(format: "%02d", sleepMinutes % 60)) slept"
    }

    private var accessibilitySummary: String {
        let score = recovery.map(String.init) ?? "unavailable"
        let battery = batteryPercentage.map { "\($0) percent" } ?? "unavailable"
        return "Recovery \(score), \(deltaLine), \(sleepLine), battery \(battery)"
    }
}

public struct NOOPPillarsMediumWidgetView: View {
    public let recovery: Int?
    public let strain: Double?
    public let sleep: Int?
    public let stressHours: [Double?]?
    public let batteryPercentage: Int?
    public let hrv: Int?
    public let restingHeartRate: Int?
    public let steps: Int?

    public init(recovery: Int?, strain: Double?, sleep: Int?, stressHours: [Double?]?,
                batteryPercentage: Int?, hrv: Int?, restingHeartRate: Int?, steps: Int?) {
        self.recovery = recovery
        self.strain = strain
        self.sleep = sleep
        self.stressHours = stressHours
        self.batteryPercentage = batteryPercentage
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.steps = steps
    }

    public var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("TODAY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                NOOPWidgetBatteryChip(percentage: batteryPercentage)
                Text("NOOP")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            HStack(spacing: 8) {
                pillar("Recovery", value: recovery.map(String.init),
                       fraction: recovery.map { Double($0) / 100 },
                       accent: recovery.map { RecoveryBands.color(for: Double($0)) } ?? StrandPalette.textTertiary)
                pillar("Strain", value: strain.map { String(format: "%.1f", $0) },
                       fraction: strain.map { $0 / 21 }, accent: StrandPalette.strainAccent)
                pillar("Sleep", value: sleep.map(String.init),
                       fraction: sleep.map { Double($0) / 100 }, accent: StrandPalette.sleepAccent)
            }
            .frame(maxHeight: .infinity)
            NOOPWidgetStressStrip(values: stressHours)
            Text(statsLine)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today, \(statsLine)")
    }

    private var statsLine: String {
        let hrvText = hrv.map { "\($0) ms HRV" } ?? "HRV —"
        let rhrText = restingHeartRate.map { "\($0) RHR" } ?? "RHR —"
        let stepText = steps.map { "\($0.formatted()) steps" } ?? "steps —"
        return "\(hrvText) · \(rhrText) · \(stepText)"
    }

    private func pillar(_ label: String, value: String?, fraction: Double?, accent: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 240 / 360)
                    .stroke(StrandPalette.surfaceInset,
                            style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                    .rotationEffect(.degrees(150))
                if let fraction {
                    Circle()
                        .trim(from: 0, to: (240 / 360) * min(max(fraction, 0), 1))
                        .stroke(accent, style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                        .rotationEffect(.degrees(150))
                }
                Text(value ?? "—")
                    .font(StrandFont.number(15, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 38)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .offset(y: 2)
            }
            .frame(width: 52, height: 52)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

public struct NOOPTodayLargeWidgetView: View {
    public let date: Date
    public let recovery: Int?
    public let strain: Double?
    public let sleep: Int?
    public let bpm: Int?
    public let hrSpark: [Int]?
    public let stressHours: [Double?]?
    public let stressSummary: String?
    public let batteryPercentage: Int?
    public let hrv: Int?
    public let restingHeartRate: Int?
    public let steps: Int?
    public let calories: Int?

    public init(date: Date, recovery: Int?, strain: Double?, sleep: Int?, bpm: Int?,
                hrSpark: [Int]?, stressHours: [Double?]?, stressSummary: String?,
                batteryPercentage: Int?, hrv: Int?, restingHeartRate: Int?, steps: Int?, calories: Int?) {
        self.date = date
        self.recovery = recovery
        self.strain = strain
        self.sleep = sleep
        self.bpm = bpm
        self.hrSpark = hrSpark
        self.stressHours = stressHours
        self.stressSummary = stressSummary
        self.batteryPercentage = batteryPercentage
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.steps = steps
        self.calories = calories
    }

    public var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("TODAY")
                    .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1)
                Text("· \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                NOOPWidgetBatteryChip(percentage: batteryPercentage)
                Text("NOOP").font(.system(size: 8, weight: .bold, design: .rounded)).tracking(2.4)
            }
            .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 8) {
                largePillar("Recovery", value: recovery.map(String.init),
                            fraction: recovery.map { Double($0) / 100 },
                            accent: recovery.map { RecoveryBands.color(for: Double($0)) } ?? StrandPalette.textTertiary)
                largePillar("Strain", value: strain.map { String(format: "%.1f", $0) },
                            fraction: strain.map { $0 / 21 }, accent: StrandPalette.strainAccent)
                largePillar("Sleep", value: sleep.map(String.init),
                            fraction: sleep.map { Double($0) / 100 }, accent: StrandPalette.sleepAccent)
            }
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(bpm == nil ? StrandPalette.textTertiary : StrandPalette.liveRed)
                        .frame(width: 5, height: 5)
                    Text(bpm == nil ? "LAST" : "LIVE")
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.liveRed)
                }
                Text(bpm.map(String.init) ?? "—")
                    .font(StrandFont.number(19, weight: .bold)).monospacedDigit()
                    .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("BPM").font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textTertiary)
                if let hrSpark, hrSpark.count > 1 {
                    Sparkline(values: hrSpark.map(Double.init),
                              gradient: Gradient(colors: [hrTint.opacity(0.45), hrTint]),
                              lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                        .frame(height: 20)
                        .accessibilityHidden(true)
                } else {
                    Spacer(minLength: 0)
                    Text("Trace unavailable")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(spacing: 6) {
                vitalCell(label: "HRV", value: hrv.map { "\($0) ms" })
                vitalCell(label: "RHR", value: restingHeartRate.map(String.init))
                vitalCell(label: "Steps", value: steps.map(Self.compactNumber))
                vitalCell(label: "Cal", value: calories.map { $0.formatted() })
            }
            VStack(spacing: 4) {
                NOOPWidgetStressStrip(values: stressHours)
                Text(stressSummary.map { "Stress · \($0)" } ?? "Stress unavailable")
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today widget. Recovery \(recovery.map(String.init) ?? "unavailable"), strain \(strain.map { String(format: "%.1f", $0) } ?? "unavailable"), sleep \(sleep.map(String.init) ?? "unavailable")")
    }

    private var hrTint: Color { bpm.map { HRZoneStyle.color(for: Double($0)) } ?? StrandPalette.textTertiary }

    private func largePillar(_ label: String, value: String?, fraction: Double?, accent: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0, to: 240 / 360)
                    .stroke(StrandPalette.surfaceInset, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(150))
                if let fraction {
                    Circle().trim(from: 0, to: (240 / 360) * min(max(fraction, 0), 1))
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(150))
                }
                Text(value ?? "—").font(StrandFont.number(17, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 44)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .offset(y: 2)
            }
            .frame(width: 60, height: 60)
            Text(label.uppercased()).font(.system(size: 8, weight: .semibold, design: .rounded))
                .tracking(0.6).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func vitalCell(label: String, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "—").font(StrandFont.number(13, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(label.uppercased()).font(.system(size: 7.5, weight: .semibold, design: .rounded))
                .tracking(0.5).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StrandPalette.surfaceInset))
    }

    private static func compactNumber(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : String(value)
    }
}

public struct NOOPWidgetStressStrip: View {
    public let values: [Double?]?
    public init(values: [Double?]?) { self.values = values }

    public var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<24, id: \.self) { hour in
                let value = values.flatMap { $0.indices.contains(hour) ? $0[hour] : nil }
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(value.map(StressHeatStyle.color(for:)) ?? StrandPalette.surfaceInset)
                    .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Lock Screen accessories

public struct NOOPAccessoryCircularGaugeView: View {
    public let value: Double?
    public let maximum: Double
    public let accent: Color
    public let accessibilityName: String
    public let decimal: Bool

    public init(value: Double?, maximum: Double, accent: Color, accessibilityName: String,
                decimal: Bool = false) {
        self.value = value
        self.maximum = maximum
        self.accent = accent
        self.accessibilityName = accessibilityName
        self.decimal = decimal
    }

    public var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 240 / 360)
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(150))
            if let value {
                Circle().trim(from: 0, to: (240 / 360) * min(max(value / maximum, 0), 1))
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(150))
            }
            Text(value.map(format) ?? "—")
                .font(.system(size: decimal ? 14 : 16, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(.primary).offset(y: 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityName) \(value.map(format) ?? "unavailable")")
    }

    private func format(_ value: Double) -> String {
        decimal ? ComponentValueFormat.oneDecimal(value) : ComponentValueFormat.rounded(value)
    }
}

public struct NOOPAccessoryRectangularView: View {
    public let recovery: Int?
    public let strain: Double?
    public let hrv: Int?
    public let hrvSpark: [Int]?

    public init(recovery: Int?, strain: Double?, hrv: Int?, hrvSpark: [Int]?) {
        self.recovery = recovery
        self.strain = strain
        self.hrv = hrv
        self.hrvSpark = hrvSpark
    }

    public var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("RECOVERY · STRAIN")
                    .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(0.7)
                    .foregroundStyle(.primary.opacity(0.6))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(recovery.map { "\($0)%" } ?? "—")
                    Text(strain.map { String(format: "%.1f", $0) } ?? "—")
                }
                .font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                Text(hrv.map { "\($0) ms HRV" } ?? "HRV unavailable")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.6))
            }
            Spacer(minLength: 2)
            if let hrvSpark, hrvSpark.count > 1 {
                Sparkline(values: hrvSpark.map(Double.init), gradient: Gradient(colors: [.primary.opacity(0.5), .primary]),
                          lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                    .frame(width: 48, height: 26).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recovery \(recovery.map(String.init) ?? "unavailable"), strain \(strain.map { String(format: "%.1f", $0) } ?? "unavailable"), HRV \(hrv.map(String.init) ?? "unavailable")")
    }
}

public struct NOOPAccessoryInlineView: View {
    public let recovery: Int?
    public let strain: Double?
    public init(recovery: Int?, strain: Double?) { self.recovery = recovery; self.strain = strain }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold))
            Text("Recovery \(recovery.map(String.init) ?? "—") · Strain \(strain.map { String(format: "%.1f", $0) } ?? "—")")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

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
    public let bpm: Int?
    public let strain: Double?
    public let strainBuilding: Bool
    public let calories: Int?
    public let hrSpark: [Int]?
    public let maxHR: Double?
    /// ActivityKit's own staleness: the app has not updated this activity for a while.
    public let isStale: Bool
    private let control: Control

    public init(title: String, startedAt: Date?, pausedAt: Date? = nil, bpm: Int?, strain: Double?,
                strainBuilding: Bool, calories: Int?, hrSpark: [Int]?, maxHR: Double? = nil, isStale: Bool = false,
                @ViewBuilder control: () -> Control) {
        self.title = title
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.bpm = bpm
        self.strain = strain
        self.strainBuilding = strainBuilding
        self.calories = calories
        self.hrSpark = hrSpark
        self.maxHR = maxHR
        self.isStale = isStale
        self.control = control()
    }

    private var isPaused: Bool { pausedAt != nil }
    private var tint: Color { liveHeartTint(bpm: bpm, maxHR: maxHR) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow
            HStack(alignment: .center, spacing: 12) {
                NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt, size: 38, isDimmed: isPaused || isStale)
                if let hrSpark, hrSpark.count > 1 {
                    Sparkline(values: hrSpark.map(Double.init), gradient: Gradient(colors: [tint.opacity(0.4), tint]),
                              lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                        .frame(height: 22).frame(maxWidth: .infinity)
                        .opacity(isPaused || isStale ? 0.4 : 1)
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
            LiveZoneRail(bpm: bpm, thresholds: liveThresholds(maxHR: maxHR), isDimmed: isPaused || isStale, style: .bar)
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
                             pulses: !isPaused && !isStale)
            Text(verbatim: title).textCase(.uppercase)
                .font(StrandFont.overline).tracking(1.2)
                .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            Spacer(minLength: 8)
            if isPaused {
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
        .opacity(isPaused || isStale ? 0.6 : 1)
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
        let state = isPaused ? "paused" : (isStale ? "not updating" : "recording")
        return "\(title), \(state), heart rate \(bpm.map(String.init) ?? "unavailable"), strain \(liveStrainText(strain, building: strainBuilding))"
    }
}

public extension NOOPWorkoutLiveActivityView where Control == EmptyView {
    init(title: String, startedAt: Date?, pausedAt: Date? = nil, bpm: Int?, strain: Double?, strainBuilding: Bool,
         calories: Int?, hrSpark: [Int]?, maxHR: Double? = nil, isStale: Bool = false) {
        self.init(title: title, startedAt: startedAt, pausedAt: pausedAt, bpm: bpm, strain: strain,
                  strainBuilding: strainBuilding, calories: calories, hrSpark: hrSpark, maxHR: maxHR,
                  isStale: isStale) { EmptyView() }
    }
}

/// Compact leading: the heart in its zone's colour and the reading. A paused workout shows the pause glyph instead.
public struct NOOPDynamicIslandHeartRateView: View {
    public let bpm: Int?
    public let maxHR: Double?
    public let isPaused: Bool
    public init(bpm: Int?, maxHR: Double? = nil, isPaused: Bool = false) {
        self.bpm = bpm
        self.maxHR = maxHR
        self.isPaused = isPaused
    }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isPaused ? "pause.fill" : "heart.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isPaused ? StrandPalette.statusWarning : liveHeartTint(bpm: bpm, maxHR: maxHR))
            Text(verbatim: bpm.map(String.init) ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(13, weight: .bold)).monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

/// Compact trailing: the elapsed time, stopped and dimmed while paused.
public struct NOOPDynamicIslandTimerView: View {
    public let startedAt: Date?
    public let pausedAt: Date?
    public init(startedAt: Date?, pausedAt: Date? = nil) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
    }
    public var body: some View {
        NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt, size: 13, isDimmed: pausedAt != nil)
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

/// Minimal: one glyph, the heart in its zone's colour, or the pause glyph while paused.
public struct NOOPDynamicIslandMinimalView: View {
    public let bpm: Int?
    public let maxHR: Double?
    public let isPaused: Bool
    public init(bpm: Int?, maxHR: Double? = nil, isPaused: Bool = false) {
        self.bpm = bpm
        self.maxHR = maxHR
        self.isPaused = isPaused
    }
    public var body: some View {
        Image(systemName: isPaused ? "pause.fill" : "heart.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isPaused ? StrandPalette.statusWarning : liveHeartTint(bpm: bpm, maxHR: maxHR))
    }
}

/// Expanded leading: the sport as an eyebrow over the elapsed time.
public struct NOOPDynamicIslandIdentityView: View {
    public let sport: String
    public let startedAt: Date?
    public let pausedAt: Date?
    public init(sport: String, startedAt: Date?, pausedAt: Date? = nil) {
        self.sport = sport
        self.startedAt = startedAt
        self.pausedAt = pausedAt
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                EyebrowPulseIcon(systemName: pausedAt == nil ? "waveform.path.ecg" : "pause.fill",
                                 color: pausedAt == nil ? StrandPalette.liveRed : StrandPalette.statusWarning,
                                 pulses: pausedAt == nil)
                Text(verbatim: sport).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(1.0)
                    .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            NOOPLiveTimerText(startedAt: startedAt, pausedAt: pausedAt, size: 26, isDimmed: pausedAt != nil)
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
