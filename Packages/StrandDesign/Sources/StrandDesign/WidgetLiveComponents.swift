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
        decimal ? String(format: "%.1f", value) : String(Int(value.rounded()))
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

public struct NOOPWorkoutLiveActivityView: View {
    public let title: String
    public let startedAt: Date?
    public let bpm: Int?
    public let strain: Double?
    public let strainBuilding: Bool
    public let calories: Int?
    public let hrSpark: [Int]?

    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, startedAt: Date?, bpm: Int?, strain: Double?, strainBuilding: Bool,
                calories: Int?, hrSpark: [Int]?) {
        self.title = title
        self.startedAt = startedAt
        self.bpm = bpm
        self.strain = strain
        self.strainBuilding = strainBuilding
        self.calories = calories
        self.hrSpark = hrSpark
    }

    public var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(StrandPalette.strainAccent)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(StrandPalette.strainAccent.opacity(0.22)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(0.8).foregroundStyle(.white)
                    Text("LIVE · NOOP").font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                if let startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                } else {
                    Text("—:—").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(hrTint).frame(width: 8, height: 8)
                        if bpm != nil && !reduceMotion {
                            Circle().stroke(hrTint.opacity(0.4), lineWidth: 3)
                                .scaleEffect(pulsing ? 2.2 : 1).opacity(pulsing ? 0 : 0.9)
                        }
                    }
                    Text(bpm.map(String.init) ?? "—")
                        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                    Text("BPM").font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
                if let hrSpark, hrSpark.count > 1 {
                    Sparkline(values: hrSpark.map(Double.init), gradient: Gradient(colors: [hrTint.opacity(0.4), hrTint]),
                              lineWidth: 1.8, showsArea: false, showsHead: false, showsHover: false)
                        .frame(height: 24).accessibilityHidden(true)
                } else { Spacer(minLength: 0) }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(strainLabel).font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(StrandPalette.strainAccent)
                    Text(calories.map { "\($0) CAL" } ?? "CAL —")
                        .font(.system(size: 8, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .background(Color.black)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) { pulsing = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) live, heart rate \(bpm.map(String.init) ?? "unavailable"), strain \(strainLabel)")
    }

    private var hrTint: Color { bpm.map { HRZoneStyle.color(for: Double($0)) } ?? Color.white.opacity(0.35) }
    private var strainLabel: String {
        if strainBuilding { return "Building" }
        return strain.map { "+\(String(format: "%.1f", $0))" } ?? "—"
    }
}

public struct NOOPDynamicIslandHeartRateView: View {
    public let bpm: Int?
    public init(bpm: Int?) { self.bpm = bpm }
    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
            Text(bpm.map(String.init) ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        }
    }
    private var tint: Color { bpm.map { HRZoneStyle.color(for: Double($0)) } ?? Color.white.opacity(0.5) }
}

public struct NOOPDynamicIslandStrainView: View {
    public let strain: Double?
    public let building: Bool
    public init(strain: Double?, building: Bool) { self.strain = strain; self.building = building }
    public var body: some View {
        Text(building ? "Building" : strain.map { "+\(String(format: "%.1f", $0))" } ?? "—")
            .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(StrandPalette.strainAccent).lineLimit(1).minimumScaleFactor(0.65)
    }
}

public struct NOOPDynamicIslandIdentityView: View {
    public let sport: String
    public let startedAt: Date?
    public init(sport: String, startedAt: Date?) { self.sport = sport; self.startedAt = startedAt }
    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sport.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8).foregroundStyle(.white).lineLimit(1)
            if let startedAt {
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            } else {
                Text("—:—").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

public struct NOOPDynamicIslandVitalsView: View {
    public let bpm: Int?
    public let strain: Double?
    public let building: Bool
    public init(bpm: Int?, strain: Double?, building: Bool) {
        self.bpm = bpm; self.strain = strain; self.building = building
    }
    public var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(hrTint)
                Text(bpm.map(String.init) ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            }
            Text(building ? "BUILDING STRAIN" : strain.map { "+\(String(format: "%.1f", $0)) STRAIN" } ?? "STRAIN —")
                .font(.system(size: 8, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(StrandPalette.strainAccent).lineLimit(1)
        }
    }
    private var hrTint: Color { bpm.map { HRZoneStyle.color(for: Double($0)) } ?? Color.white.opacity(0.5) }
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
