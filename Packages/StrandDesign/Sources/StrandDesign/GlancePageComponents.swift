import SwiftUI

// MARK: - Glance pages
//
// What the live workout screen adds around its big number once it has more than one page: the dots that say which page it
// is on, the bar of time spent in each heart-rate zone, and the faint wash of the zone's colour behind the number.

// MARK: Page dots

/// The row of dots under a paged screen. A swipe turns the page, so the dots only say where the wearer is; for VoiceOver and
/// Switch Control they are one adjustable element ("Page 2 of 3, Heart") whose increment and decrement turn the page.
public struct PageDots: View {
    private let titles: [String]
    @Binding private var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - titles: One name per page, in order; VoiceOver says the selected one.
    ///   - selection: The index of the page showing.
    public init(titles: [String], selection: Binding<Int>) {
        self.titles = titles
        self._selection = selection
    }

    /// The page after moving `step` pages from `selection`, which stops at the first and the last page instead of wrapping.
    public static func moved(_ selection: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selection + step, 0), count - 1)
    }

    /// What VoiceOver says for the selected page.
    public static func spoken(page: Int, count: Int, title: String) -> String {
        String(localized: "Page \(page + 1) of \(count), \(title)", bundle: .module)
    }

    private var current: Int { min(max(selection, 0), max(titles.count - 1, 0)) }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(titles.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == current ? StrandPalette.textPrimary : StrandPalette.textTertiary.opacity(0.5))
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: current)
        .frame(maxWidth: .infinity, minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pages", bundle: .module))
        .accessibilityValue(Text(verbatim: titles.isEmpty ? "" : Self.spoken(page: current, count: titles.count, title: titles[current])))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = Self.moved(current, by: 1, count: titles.count)
            case .decrement: selection = Self.moved(current, by: -1, count: titles.count)
            @unknown default: break
            }
        }
    }
}

// MARK: Time in zone

/// Three segments, one per heart-rate zone, as wide as the time the workout has spent in each, with "Rest 2m · Steady 9m ·
/// Push 23m" under them. The zone the heart is in now is drawn at full strength and the others a step back. At the
/// accessibility sizes the words become rows (word left, time right) under the bar.
public struct ZoneMinutesBar: View {
    private let seconds: [Int]
    private let currentZone: Int?
    private let isDimmed: Bool
    private let showsBar: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameters:
    ///   - seconds: Time in rest, steady and push, in that order.
    ///   - currentZone: The zone the heart is in now, if known.
    ///   - isDimmed: A paused workout, or a quiet strap: the bar is drawn quieter.
    ///   - showsBar: False draws only the words ("Rest 2m · Steady 9m · Push 23m"), for a screen that already has a rail.
    public init(seconds: [Int], currentZone: Int? = nil, isDimmed: Bool = false, showsBar: Bool = true) {
        self.seconds = (0..<3).map { $0 < seconds.count ? max(0, seconds[$0]) : 0 }
        self.currentZone = currentZone
        self.isDimmed = isDimmed
        self.showsBar = showsBar
    }

    /// The share of the bar each zone gets. A zone with time keeps at least `minimumShare` so it never vanishes into a
    /// hairline, and a workout with no time yet draws three equal quiet segments.
    public static let minimumShare: Double = 0.04

    public static func weights(seconds: [Int]) -> [Double] {
        let clean = (0..<3).map { $0 < seconds.count ? max(0, seconds[$0]) : 0 }
        let total = clean.reduce(0, +)
        guard total > 0 else { return [1, 1, 1] }
        return clean.map { max(Double($0) / Double(total), minimumShare) }
    }

    /// A time in zone as short as it can be said: "0m", "<1m", "9m", "1h 4m". Whole minutes, rounded down.
    public static func durationText(seconds: Int, locale: Locale = .current) -> String {
        let seconds = max(0, seconds)
        let minute = Duration.seconds(60).formatted(.units(allowed: [.minutes], width: .narrow).locale(locale))
        if seconds == 0 {
            return Duration.seconds(0).formatted(.units(allowed: [.minutes], width: .narrow, zeroValueUnits: .show(length: 1)).locale(locale))
        }
        if seconds < 60 { return "<\(minute)" }
        let whole = Duration.seconds(seconds / 60 * 60)
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return whole.formatted(.units(allowed: allowed, width: .narrow).locale(locale))
    }

    private static func word(_ zone: Int) -> String {
        switch zone {
        case 0: String(localized: "Rest", bundle: .module)
        case 1: String(localized: "Steady", bundle: .module)
        default: String(localized: "Push", bundle: .module)
        }
    }

    private func strength(_ zone: Int) -> Double {
        guard let currentZone else { return 0.9 }
        return currentZone == zone ? 1 : 0.5
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if showsBar { bar }
            if typeSize.isAccessibilitySize { rows } else { line }
        }
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Time in zone", bundle: .module))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private var bar: some View {
        let hasTime = seconds.reduce(0, +) > 0
        return ProportionalRow(weights: Self.weights(seconds: seconds), spacing: 3) {
            ForEach(0..<3, id: \.self) { zone in
                Capsule(style: .continuous)
                    .fill(HRZoneStyle.zoneColor(zone).opacity(hasTime ? strength(zone) : 0.25))
                    .frame(height: 8)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var line: some View {
        (0..<3).map { zone -> Text in
            let separator = zone == 0 ? Text(verbatim: "") : Text(verbatim: " · ").foregroundStyle(StrandPalette.textTertiary)
            return separator
                + Text(verbatim: Self.word(zone)).foregroundStyle(StrandPalette.textSecondary)
                + Text(verbatim: " ")
                + Text(verbatim: Self.durationText(seconds: seconds[zone])).foregroundStyle(StrandPalette.textPrimary)
        }
        .reduce(Text(verbatim: ""), +)
        .microLabelFit()
        .accessibilityHidden(true)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ForEach(0..<3, id: \.self) { zone in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Circle().fill(HRZoneStyle.zoneColor(zone)).frame(width: 8, height: 8)
                    Text(verbatim: Self.word(zone)).foregroundStyle(StrandPalette.textSecondary).microLabelFit()
                    Spacer(minLength: NoopMetrics.space2)
                    Text(verbatim: Self.durationText(seconds: seconds[zone])).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary).microLabelFit(lines: 1)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var spoken: String {
        (0..<3).map { zone in
            let wide = Duration.seconds(seconds[zone] / 60 * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .wide, zeroValueUnits: .show(length: 1)))
            return "\(Self.word(zone)) \(wide)"
        }.joined(separator: ", ")
    }
}

// MARK: Zone wash

/// A whisper of the displayed zone's colour behind the number: 14% at the top, gone by the middle of the space it is given. It carries no
/// information the zone word does not (the zone line says it in words), and it is neutral (nothing at all) when there is no
/// zone to show: a paused or ending workout, a quiet strap, no reading yet. A change of zone crossfades, in opacity only.
public struct ZoneWashBackground: View {
    /// How strong the wash is where it is strongest.
    public static let peakOpacity: Double = 0.14

    private let zone: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter zone: 0 rest, 1 steady, 2 push; nil is neutral.
    public init(zone: Int?) { self.zone = zone }

    public var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                LinearGradient(
                    colors: [HRZoneStyle.zoneColor(index).opacity(Self.peakOpacity), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5))
                    .opacity(zone == index ? 1 : 0)
            }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.6), value: zone)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
