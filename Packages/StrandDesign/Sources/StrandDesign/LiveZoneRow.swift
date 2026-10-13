import SwiftUI

// MARK: - The zone row
//
// The heart page's one zone display, and the only place time in each zone is told: three short bars with the zone the heart is in
// lit, and under each bar its name, where it starts and the minutes spent in it. It replaces a slider-like rail with a knob
// and a separate bar of times.

/// The wearer's three zones with the current one lit and the time spent in each. Three columns while they fit; one row per
/// zone when the screen is narrow, a long word is wide or the text is at an accessibility size.
public struct LiveZoneRow: View {
    private let seconds: [Int]
    private let thresholds: HRZoneStyle.Thresholds
    private let currentZone: Int?
    private let isPaused: Bool
    private let scale: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var scaledName: CGFloat = 15
    @ScaledMetric(relativeTo: .caption) private var scaledRange: CGFloat = 13

    /// - Parameters:
    ///   - seconds: Time in rest, steady and push.
    ///   - currentZone: The zone the heart is in now; nil while there is no reading.
    ///   - isPaused: A paused workout: everything is flat grey.
    ///   - scale: The page's scale.
    public init(seconds: [Int], thresholds: HRZoneStyle.Thresholds, currentZone: Int?, isPaused: Bool = false,
                scale: CGFloat = 1) {
        self.seconds = (0..<3).map { $0 < seconds.count ? max(0, seconds[$0]) : 0 }
        self.thresholds = thresholds
        self.currentZone = currentZone
        self.isPaused = isPaused
        self.scale = scale
    }

    // MARK: Text

    public nonisolated static func word(_ zone: Int) -> String {
        switch zone {
        case 0: String(localized: "Rest", bundle: .module)
        case 1: String(localized: "Steady", bundle: .module)
        default: String(localized: "Push", bundle: .module)
        }
    }

    /// Where a zone starts: "<95", "95–132", "133+".
    public nonisolated static func range(_ zone: Int, thresholds: HRZoneStyle.Thresholds) -> String {
        switch zone {
        case 0: "<\(thresholds.steadyStartBPM.formatted())"
        case 1: "\(thresholds.steadyStartBPM.formatted())–\((thresholds.pushStartBPM - 1).formatted())"
        default: "\(thresholds.pushStartBPM.formatted())+"
        }
    }

    /// A time in zone as a figure and its unit: whole minutes ("28", "min"), under a minute "<1", an hour or more "1:04" and "h".
    public nonisolated static func minutes(seconds: Int, locale: Locale = .current) -> (figure: String, unit: String) {
        let seconds = max(0, seconds)
        if seconds >= 3600 {
            return (String(format: "%d:%02d", seconds / 3600, seconds % 3600 / 60), String(localized: "h", bundle: .module))
        }
        let whole = seconds / 60
        let figure = seconds > 0 && whole == 0 ? "<1" : whole.formatted(.number.locale(locale))
        return (figure, String(localized: "min", bundle: .module))
    }

    /// What VoiceOver reads for one zone's time: "28 minutes", "less than a minute", "1 hour, 4 minutes". Never "0 hours".
    public nonisolated static func spokenDuration(seconds: Int, locale: Locale = .current) -> String {
        let seconds = max(0, seconds)
        if seconds == 0 {
            return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .wide, zeroValueUnits: .show(length: 1)).locale(locale))
        }
        if seconds < 60 { return String(localized: "less than a minute", bundle: .module) }
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds / 60 * 60).formatted(.units(allowed: allowed, width: .wide, zeroValueUnits: .hide).locale(locale))
    }

    /// "Rest 0 minutes, Steady 6 minutes and Push 28 minutes", in the person's language.
    public nonisolated static func spoken(seconds: [Int], locale: Locale = .current) -> String {
        (0..<3).map { zone in
            "\(word(zone)) \(spokenDuration(seconds: zone < seconds.count ? seconds[zone] : 0, locale: locale))"
        }.formatted(.list(type: .and, width: .standard).locale(locale))
    }

    // MARK: Colours

    private func isCurrent(_ zone: Int) -> Bool { currentZone == zone }

    private func nameColor(_ zone: Int) -> Color {
        isPaused ? LivePalette.frozenNumeral : LivePalette.zone(zone)
    }

    private func figureColor(_ zone: Int) -> Color {
        if isPaused { return LivePalette.frozenNumeral }
        if isCurrent(zone) { return StrandPalette.textPrimary }
        return seconds[zone] > 0 ? LivePalette.secondaryText : LivePalette.missing
    }

    private func unitColor(_ zone: Int) -> Color {
        if isPaused { return LivePalette.frozenUnit }
        if isCurrent(zone) { return LivePalette.zone(zone) }
        return seconds[zone] > 0 ? LivePalette.secondaryText : LivePalette.missing
    }

    private func barColor(_ zone: Int) -> Color {
        guard isCurrent(zone) else { return LivePalette.track }
        return isPaused ? LivePalette.frozenNumeral : LivePalette.zone(zone)
    }

    // MARK: Body

    /// The row's height at `scale`: three columns (bar, name and range, minutes), or at the accessibility sizes a row per zone.
    public nonisolated static func height(scale: CGFloat, accessibilitySize: Bool) -> CGFloat {
        accessibilitySize ? (36 * 3 + 12 * 2) * scale : 86 * scale
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize { rows } else { columns }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time in zone", bundle: .module))
        .accessibilityValue(Text(verbatim: Self.spoken(seconds: seconds)))
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            ForEach(0..<3, id: \.self) { zone in
                VStack(alignment: .leading, spacing: 0) {
                    Capsule(style: .continuous)
                        .fill(barColor(zone))
                        .frame(height: 6 * scale)
                        .shadow(color: isCurrent(zone) && !isPaused ? LivePalette.zone(zone).opacity(0.55) : .clear, radius: 7)
                    nameLine(zone).padding(.top, 13 * scale)
                    minutesLine(zone, size: 34 * scale).padding(.top, 6 * scale)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A row per zone: a short bar, the name and where it starts, the minutes at the right.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            ForEach(0..<3, id: \.self) { zone in
                HStack(alignment: .center, spacing: 12 * scale) {
                    Capsule(style: .continuous)
                        .fill(barColor(zone))
                        .frame(width: 6 * scale, height: 36 * scale)
                    nameLine(zone)
                    Spacer(minLength: 8)
                    minutesLine(zone, size: 30 * scale)
                }
                .frame(height: 36 * scale)
            }
        }
    }

    /// "Rest <95" on one line, the name in the zone's colour: one text, so a narrow column scales both together.
    private func nameLine(_ zone: Int) -> some View {
        (Text(verbatim: Self.word(zone)).font(.system(size: nameSize, weight: .semibold)).foregroundStyleCompat(nameColor(zone))
            + Text(verbatim: " " + Self.range(zone, thresholds: thresholds))
                .font(.system(size: rangeSize, weight: .medium)).monospacedDigit().foregroundStyleCompat(LivePalette.secondaryText))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var nameSize: CGFloat { min(scaledName * scale, 20) }
    private var rangeSize: CGFloat { min(scaledRange * scale, 18) }

    private func minutesLine(_ zone: Int, size: CGFloat) -> some View {
        let parts = Self.minutes(seconds: seconds[zone])
        return HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(verbatim: parts.figure)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(figureColor(zone))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(verbatim: parts.unit)
                .textCase(.uppercase)
                .foregroundStyle(unitColor(zone))
                .liveText(12 * scale, weight: .semibold, maxSize: min(size * 0.4, 16), lines: 1)
        }
    }
}
