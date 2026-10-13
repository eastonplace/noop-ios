#if !os(watchOS)
import SwiftUI

// MARK: - Home and Lock Screen widgets, in the widget language
//
// A domain-tinted surface (`NOOPWidgetBackground`), a caps eyebrow with the domain's symbol (`SectionEyebrow`), numbers in
// the number face, and the same Rest / Steady / Push colours the app uses, drawn against the wearer's own maximum heart
// rate when the app has shared one. Every word comes from this package's string table (`bundle: .module`), so the widget
// extension, which carries no table of its own, still speaks the wearer's language.

/// A word or phrase from this package's string table.
private func words(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }

/// The words the widget extension needs for accessibility names that it passes in as plain strings.
public enum NOOPWidgetLabel {
    public static var recovery: String { words("Recovery") }
    public static var strain: String { words("Strain") }
}

/// The surface every Home Screen widget draws on: the graphite card with the domain's quiet wash in its top-leading corner.
public struct NOOPWidgetBackground: View {
    private let tint: DomainTint
    public init(_ tint: DomainTint = .neutral) { self.tint = tint }

    public var body: some View {
        ZStack {
            tint.surfaceGradient
            if let wash = tint.washGradient { wash }
        }
    }
}

/// The 240° arc the Today dials use: the unfilled part is the accent at a whisper.
private struct WidgetArc: View {
    let fraction: Double?
    let accent: Color
    let lineWidth: CGFloat

    private static let sweep: Double = 240 / 360

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: Self.sweep)
                .stroke(fraction == nil ? StrandPalette.textTertiary.opacity(0.2) : accent.opacity(0.16),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(150))
            if let fraction {
                Circle().trim(from: 0, to: Self.sweep * min(max(fraction, 0), 1))
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(150))
            }
        }
    }
}

private func recoveryTint(_ recovery: Int?) -> Color {
    recovery.map { RecoveryBands.color(for: Double($0)) } ?? StrandPalette.textTertiary
}

private func strainText(_ strain: Double?) -> String? {
    strain.map { ComponentValueFormat.oneDecimal($0) }
}

public struct NOOPWidgetBatteryChip: View {
    public let percentage: Int?

    public init(percentage: Int?) { self.percentage = percentage }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbol)
                .font(.system(size: 10, weight: .semibold))
            Text(verbatim: percentage.map { "\($0)%" } ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var spoken: String {
        percentage.map { words("Strap battery \($0) percent") } ?? words("Strap battery unavailable")
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

// MARK: Small

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

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionEyebrow(title: words("Recovery"), systemImage: "heart.circle.fill",
                           tint: .recovery(score: recovery.map(Double.init)))
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height)
                let stroke = min(max(diameter * 0.085, 7), 10)
                ZStack {
                    WidgetArc(fraction: recovery.map { Double($0) / 100 }, accent: accent, lineWidth: stroke)
                    VStack(spacing: 1) {
                        Text(verbatim: recovery.map(String.init) ?? WidgetMetrics.missingValue)
                            .font(StrandFont.number(min(max(diameter * 0.36, 26), 40), weight: .bold))
                            .foregroundStyle(recovery == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(verbatim: deltaChip)
                            .font(StrandFont.number(11, weight: .semibold))
                            .foregroundStyle(deltaTint)
                    }
                    .frame(width: diameter * 0.62)
                    .offset(y: -2)
                }
                .frame(width: diameter, height: diameter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 4) {
                Text(verbatim: sleepLine)
                    .font(StrandFont.micro).monospacedDigit()
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                NOOPWidgetBatteryChip(percentage: batteryPercentage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var accent: Color { recoveryTint(recovery) }

    /// "▲ 6" or "▼ 2": the change from yesterday. Blank when there is nothing to compare with.
    private var deltaChip: String {
        guard let delta else { return " " }
        return delta >= 0 ? "▲ \(delta)" : "▼ \(abs(delta))"
    }

    private var deltaTint: Color {
        guard let delta else { return StrandPalette.textTertiary }
        return delta >= 0 ? StrandPalette.statusPositive : StrandPalette.metricRose
    }

    private var sleepLine: String {
        guard let sleepMinutes else { return words("No sleep yet") }
        return words("\(String(format: "%d:%02d", sleepMinutes / 60, sleepMinutes % 60)) slept")
    }

    private var spokenDelta: String {
        guard let delta else { return words("No comparison yet") }
        return delta >= 0 ? words("Up \(delta) from yesterday") : words("Down \(abs(delta)) from yesterday")
    }

    private var spoken: String {
        let score = recovery.map(String.init) ?? words("No reading")
        let battery = batteryPercentage.map { words("Strap battery \($0) percent") } ?? words("Strap battery unavailable")
        return [ "\(words("Recovery")) \(score)", spokenDelta, sleepLine, battery ].joined(separator: ", ")
    }
}

// MARK: Medium

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
        VStack(alignment: .leading, spacing: 7) {
            SectionEyebrow(title: words("Today"), systemImage: "sun.max.fill", tint: .accent,
                           trailing: .custom(AnyView(NOOPWidgetBatteryChip(percentage: batteryPercentage))))
            HStack(spacing: 8) {
                pillar(words("Recovery"), value: recovery.map(String.init),
                       fraction: recovery.map { Double($0) / 100 }, accent: recoveryTint(recovery))
                pillar(words("Strain"), value: strainText(strain),
                       fraction: strain.map { $0 / 21 }, accent: StrandPalette.strainAccent)
                pillar(words("Sleep"), value: sleep.map(String.init),
                       fraction: sleep.map { Double($0) / 100 }, accent: StrandPalette.sleepAccent)
            }
            .frame(maxHeight: .infinity)
            NOOPWidgetStressStrip(values: stressHours)
            HStack(spacing: 10) {
                fact(hrv.map(String.init), unit: "ms", label: words("HRV"))
                fact(restingHeartRate.map(String.init), unit: nil, label: "RHR")
                fact(steps.map(WidgetFormat.compact), unit: nil, label: words("Steps"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private func pillar(_ label: String, value: String?, fraction: Double?, accent: Color) -> some View {
        VStack(spacing: 3) {
            ZStack {
                WidgetArc(fraction: fraction, accent: accent, lineWidth: 6)
                Text(verbatim: value ?? WidgetMetrics.missingValue)
                    .font(StrandFont.number(16, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: 38)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .offset(y: 2)
            }
            .frame(width: 50, height: 50)
            Text(verbatim: label).textCase(.uppercase)
                .font(StrandFont.micro).tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func fact(_ value: String?, unit: String?, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: factText(value, unit: unit))
                .font(StrandFont.number(12, weight: .semibold))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(verbatim: label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func factText(_ value: String?, unit: String?) -> String {
        guard let value else { return WidgetMetrics.missingValue }
        guard let unit else { return value }
        return "\(value) \(unit)"
    }

    private var spoken: String {
        let none = words("No reading")
        return [
            words("Today"),
            "\(words("Recovery")) \(recovery.map(String.init) ?? none)",
            "\(words("Strain")) \(strainText(strain) ?? none)",
            "\(words("Sleep")) \(sleep.map(String.init) ?? none)",
            hrv.map { words("HRV \($0) ms") } ?? words("No HRV yet"),
            "RHR \(restingHeartRate.map(String.init) ?? none)",
            "\(words("Steps")) \(steps.map { $0.formatted() } ?? none)",
        ].joined(separator: ", ")
    }
}

// MARK: Large

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
    /// The wearer's maximum heart rate, from the app; nil draws the fixed 60 / 110 split.
    public let maxHR: Double?

    public init(date: Date, recovery: Int?, strain: Double?, sleep: Int?, bpm: Int?,
                hrSpark: [Int]?, stressHours: [Double?]?, stressSummary: String?,
                batteryPercentage: Int?, hrv: Int?, restingHeartRate: Int?, steps: Int?, calories: Int?,
                maxHR: Double? = nil) {
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
        self.maxHR = maxHR
    }

    private var thresholds: HRZoneStyle.Thresholds {
        maxHR.map { HRZoneStyle.Thresholds(hrMax: $0) } ?? .default
    }

    private var hrTint: Color {
        bpm.map { HRZoneStyle.color(for: Double($0), thresholds: thresholds) } ?? StrandPalette.textTertiary
    }

    /// The zone's name and its own colour (the chip is a label, so it takes the zone's colour, not the ramp's).
    private var zone: (name: String, tint: Color)? {
        guard let bpm else { return nil }
        switch thresholds.zone(for: Double(bpm)) {
        case 0: return (words("Rest"), HRZoneStyle.rest)
        case 1: return (words("Steady"), HRZoneStyle.steady)
        default: return (words("Push"), HRZoneStyle.push)
        }
    }

    public var body: some View {
        // Whatever height the family offers is shared between the sections, so the widget fills its frame.
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(
                title: words("Today"), systemImage: "sun.max.fill", tint: .accent,
                trailing: .custom(AnyView(
                    HStack(spacing: 8) {
                        Text(verbatim: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                        NOOPWidgetBatteryChip(percentage: batteryPercentage)
                    })))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                largePillar(words("Recovery"), value: recovery.map(String.init),
                            fraction: recovery.map { Double($0) / 100 }, accent: recoveryTint(recovery))
                largePillar(words("Strain"), value: strainText(strain),
                            fraction: strain.map { $0 / 21 }, accent: StrandPalette.strainAccent)
                largePillar(words("Sleep"), value: sleep.map(String.init),
                            fraction: sleep.map { Double($0) / 100 }, accent: StrandPalette.sleepAccent)
            }
            Spacer(minLength: 8)
            Divider().overlay(StrandPalette.hairline)
            Spacer(minLength: 8)
            heartRow
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                vitalCell(label: words("HRV"), value: hrv.map { "\($0) ms" })
                vitalCell(label: "RHR", value: restingHeartRate.map(String.init))
                vitalCell(label: words("Steps"), value: steps.map(WidgetFormat.compact))
                vitalCell(label: words("Calories"), value: calories.map { $0.formatted() })
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 5) {
                NOOPWidgetStressStrip(values: stressHours)
                Text(verbatim: stressSummary.map { words("Stress · \($0)") } ?? words("No stress data yet"))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var heartRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(bpm == nil ? StrandPalette.textTertiary : StrandPalette.liveRed)
                    .frame(width: 6, height: 6)
                Text(verbatim: bpm == nil ? words("Last") : words("Live")).textCase(.uppercase)
                    .font(StrandFont.overline).tracking(0.8)
                    .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.liveRed)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: bpm.map(String.init) ?? WidgetMetrics.missingValue)
                    .font(StrandFont.number(22, weight: .bold))
                    .foregroundStyle(bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("bpm", bundle: .module).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            .fixedSize()
            if let zone {
                Text(verbatim: zone.name).statePillLabel().statePillChrome(tint: zone.tint).fixedSize()
            }
            if let hrSpark, hrSpark.count > 1 {
                Sparkline(values: hrSpark.map(Double.init),
                          gradient: Gradient(colors: [hrTint.opacity(0.45), hrTint]),
                          lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                    .frame(height: 22)
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 0)
                Text(verbatim: words("No trace yet"))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private func largePillar(_ label: String, value: String?, fraction: Double?, accent: Color) -> some View {
        VStack(spacing: 4) {
            ZStack {
                WidgetArc(fraction: fraction, accent: accent, lineWidth: 7)
                Text(verbatim: value ?? WidgetMetrics.missingValue)
                    .font(StrandFont.number(19, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 44)
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .offset(y: 2)
            }
            .frame(width: 62, height: 62)
            Text(verbatim: label).textCase(.uppercase)
                .font(StrandFont.micro).tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func vitalCell(label: String, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: value ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(14, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Text(verbatim: label).textCase(.uppercase)
                .font(StrandFont.micro).tracking(0.4)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StrandPalette.surfaceInset))
    }

    private var spoken: String {
        let none = words("No reading")
        return [
            words("Today"),
            "\(words("Recovery")) \(recovery.map(String.init) ?? none)",
            "\(words("Strain")) \(strainText(strain) ?? none)",
            "\(words("Sleep")) \(sleep.map(String.init) ?? none)",
            "\(words("Heart rate")) \(bpm.map(String.init) ?? none)\(zone.map { ", \($0.name)" } ?? "")",
        ].joined(separator: ", ")
    }
}

/// Number formats the widgets share.
enum WidgetFormat {
    /// 842 stays "842"; 11 204 reads "11.2k".
    static func compact(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : String(value)
    }
}

// MARK: Stress

public struct NOOPWidgetStressStrip: View {
    public let values: [Double?]?
    public init(values: [Double?]?) { self.values = values }

    public var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<24, id: \.self) { hour in
                let value = values.flatMap { $0.indices.contains(hour) ? $0[hour] : nil }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(value.map(StressHeatStyle.color(for:)) ?? StrandPalette.textTertiary.opacity(0.18))
                    .frame(maxWidth: .infinity, minHeight: 6, maxHeight: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Stress widget's face (small and medium): today's pattern in words, the hourly strip, and when it was last updated.
public struct NOOPStressWidgetContent: View {
    public let summary: String?
    public let hours: [Double?]?
    public let hasData: Bool
    public let updated: Date

    public init(summary: String?, hours: [Double?]?, hasData: Bool, updated: Date) {
        self.summary = summary
        self.hours = hours
        self.hasData = hasData
        self.updated = updated
    }

    /// A summary like "Moderate · easing" breaks after its dot, not before it, when it has to wrap.
    private var headline: String {
        guard hasData else { return words("No recent data") }
        return (summary ?? words("Today's pattern")).replacingOccurrences(of: " · ", with: "\u{00A0}· ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(title: words("Stress"), systemImage: "waveform.path", tint: .stress)
            Spacer(minLength: 0)
            Text(verbatim: headline)
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.8)
            NOOPWidgetStressStrip(values: hours)
            if hasData {
                Text(updated, style: .time).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text(verbatim: words("Open NOOP to refresh"))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
            Text(verbatim: value.map(format) ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(decimal ? 15 : 17, weight: .bold))
                .foregroundStyle(.primary).offset(y: 1.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(accessibilityName) \(value.map(format) ?? words("No reading"))"))
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
                Text(verbatim: words("Recovery · Strain")).textCase(.uppercase)
                    .font(.system(size: 9, weight: .bold)).tracking(0.7)
                    .foregroundStyle(.primary.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: recovery.map { "\($0)%" } ?? WidgetMetrics.missingValue)
                    Text(verbatim: strainText(strain) ?? WidgetMetrics.missingValue)
                }
                .font(StrandFont.number(19, weight: .bold))
                Text(verbatim: hrv.map { words("HRV \($0) ms") } ?? words("No HRV yet"))
                    .font(StrandFont.number(10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6)).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 2)
            if let hrvSpark, hrvSpark.count > 1 {
                Sparkline(values: hrvSpark.map(Double.init), gradient: Gradient(colors: [.primary.opacity(0.5), .primary]),
                          lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
                    .frame(width: 48, height: 26).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var spoken: String {
        let none = words("No reading")
        return [
            "\(words("Recovery")) \(recovery.map(String.init) ?? none)",
            "\(words("Strain")) \(strainText(strain) ?? none)",
            hrv.map { words("HRV \($0) ms") } ?? words("No HRV yet"),
        ].joined(separator: ", ")
    }
}

public struct NOOPAccessoryInlineView: View {
    public let recovery: Int?
    public let strain: Double?
    public init(recovery: Int?, strain: Double?) { self.recovery = recovery; self.strain = strain }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold))
            Text(verbatim: words("Recovery \(recovery.map(String.init) ?? WidgetMetrics.missingValue) · Strain \(strainText(strain) ?? WidgetMetrics.missingValue)"))
                .font(StrandFont.number(13, weight: .semibold))
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
