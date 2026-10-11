import SwiftUI

// MARK: - Drill-in components
//
// The parts the Recovery / Strain / Stress detail screens add to the widget design language: a bigger
// version of the Today dial, a value pill that takes any tint, the hourly stress ribbon at detail size,
// a banded scale with a "you are here" marker, a weight bar, and a Monday-first week of bars.
//
// They compose the same primitives the Today widgets and the Trends tab use (`DomainTint`, `StrandPalette`,
// `WidgetMetrics`, the scrub recogniser that lets the page scroll) and add nothing the screens do not use.

// MARK: - Value pill

/// A short word or value on the shared state-pill chrome (the Coach "Stale" pill's size, a 12% wash and a
/// hairline of `tint`, white type), for the tints `StatePill`'s five tones do not reach: a recovery band's
/// yellow, strain's blue, the stress ramp. The caller passes text it has already localised.
public struct ValuePill: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(verbatim: text)
            .statePillLabel()
            .monospacedDigit()
            .lineLimit(1)
            .statePillChrome(tint: tint)
            .fixedSize()
    }
}

// MARK: - Pillar dial

/// The Today dial, larger: a 240° arc that opens downward, its unfilled part the accent at a whisper, its
/// band ticks and optional target band, the value in the middle with a short caption under it, and the
/// scale's two ends in the gap below. With no value the arc is a row of dots and the numeral reads "—".
public struct PillarDial: View {
    private let value: Double?
    private let maximum: Double
    private let valueText: String
    private let accent: Color
    private let bandTicks: [Double]
    private let targetBand: ClosedRange<Double>?
    private let caption: String?
    private let captionColor: Color
    private let scaleLabels: (start: String, end: String)?
    private let accessibilityText: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @ScaledMetric(relativeTo: .largeTitle) private var numeralSize: CGFloat = 52

    private static let side: CGFloat = 216
    private static let lineWidth: CGFloat = 14
    /// The arc's end caps sit this far (in units of the arc radius) below the dial's centre.
    private static let capDrop: CGFloat = 0.5

    /// - Parameters:
    ///   - bandTicks, targetBand: positions along the arc as fractions of `maximum`'s scale (0...1).
    ///   - scaleLabels: the text at the arc's two ends, or `nil` for none.
    public init(
        value: Double?,
        maximum: Double,
        valueText: String,
        accent: Color,
        bandTicks: [Double] = [],
        targetBand: ClosedRange<Double>? = nil,
        caption: String? = nil,
        captionColor: Color = StrandPalette.textTertiary,
        scaleLabels: (start: String, end: String)? = nil,
        accessibilityText: String
    ) {
        self.value = value
        self.maximum = maximum
        self.valueText = valueText
        self.accent = accent
        self.bandTicks = bandTicks
        self.targetBand = targetBand
        self.caption = caption
        self.captionColor = captionColor
        self.scaleLabels = scaleLabels
        self.accessibilityText = accessibilityText
    }

    private var fraction: Double {
        guard let value, maximum > 0 else { return 0 }
        return min(max(value / maximum, 0), 1)
    }

    private var trackColor: Color {
        value == nil ? StrandPalette.textTertiary.opacity(0.2) : accent.opacity(0.16)
    }

    public var body: some View {
        let side = Self.side
        let width = Self.lineWidth
        let radius = side / 2 - width / 2
        let drop = radius * Self.capDrop
        ZStack {
            arcs(side: side, width: width, radius: radius)
            VStack(spacing: 2) {
                Text(verbatim: valueText)
                    .font(StrandFont.number(numeralSize, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let caption {
                    Text(verbatim: caption)
                        .font(StrandFont.caption)
                        .foregroundStyle(captionColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: radius * 1.5)
            .offset(y: -4)
            if let scaleLabels {
                let x = radius * CGFloat(cos(Double.pi / 6))
                let y = drop + width / 2 + 11
                Text(verbatim: scaleLabels.start)
                    .font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                    .offset(x: -x, y: y)
                Text(verbatim: scaleLabels.end)
                    .font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                    .offset(x: x, y: y)
            }
        }
        .frame(width: side, height: side)
        // The arc opens downward, so the bottom of the square is empty: give back what the labels do not use.
        .frame(width: side, height: side / 2 + drop + width / 2 + 24, alignment: .top)
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.8).delay(0.05)) { revealed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private func arcs(side: CGFloat, width: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            if value == nil {
                dottedTrack(radius: radius, width: width)
            } else {
                Circle().inset(by: width / 2).trim(from: 0, to: 2 / 3)
                    .stroke(trackColor, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(150))
            }
            if let targetBand {
                Circle().inset(by: width / 2)
                    .trim(from: (2 / 3) * targetBand.lowerBound, to: (2 / 3) * targetBand.upperBound)
                    .stroke(StrandPalette.statusPositive.opacity(0.3), style: StrokeStyle(lineWidth: width))
                    .rotationEffect(.degrees(150))
            }
            ForEach(value == nil ? [] : bandTicks, id: \.self) { tick in
                let angle = Angle.degrees(150 + 240 * tick)
                Capsule().fill(StrandPalette.hairlineStrong)
                    .frame(width: 1.5, height: width + 4)
                    .rotationEffect(angle + .degrees(90))
                    .offset(x: CGFloat(cos(angle.radians)) * radius, y: CGFloat(sin(angle.radians)) * radius)
            }
            if value != nil {
                Circle().inset(by: width / 2)
                    .trim(from: 0, to: (2 / 3) * (revealed ? fraction : 0))
                    .stroke(accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(150))
            }
        }
        .frame(width: side, height: side)
    }

    /// Round dots, evenly spaced about 15pt apart, one centred on each end of the arc.
    private func dottedTrack(radius: CGFloat, width: CGFloat) -> some View {
        let arc = 2 * CGFloat.pi * radius * (2 / 3)
        let intervals = max(1, Int((arc / 15).rounded()))
        return ForEach(0...intervals, id: \.self) { index in
            let angle = Angle.degrees(150 + 240 * Double(index) / Double(intervals))
            Circle().fill(trackColor)
                .frame(width: width * 0.7, height: width * 0.7)
                .offset(x: CGFloat(cos(angle.radians)) * radius, y: CGFloat(sin(angle.radians)) * radius)
        }
    }
}

// MARK: - Weight bar

/// One thin bar split into proportional segments, each a metric's share of a score (the five drivers of
/// Recovery). Segments are separated by a 2pt gap and rounded at the ends.
public struct WeightBar: View {
    public struct Segment: Identifiable {
        public let id: String
        public let weight: Double
        public let color: Color
        public init(id: String, weight: Double, color: Color) {
            self.id = id
            self.weight = weight
            self.color = color
        }
    }

    private let segments: [Segment]
    private let height: CGFloat

    public init(_ segments: [Segment], height: CGFloat = 6) {
        self.segments = segments
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let total = max(segments.map(\.weight).reduce(0, +), 0.0001)
            let gap: CGFloat = 2
            let usable = max(proxy.size.width - gap * CGFloat(max(segments.count - 1, 0)), 0)
            HStack(spacing: gap) {
                ForEach(segments) { segment in
                    Capsule(style: .continuous)
                        .fill(segment.color)
                        .frame(width: usable * CGFloat(segment.weight / total))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Band scale

/// A scale cut into named bands (Low / Moderate / High), each a rounded segment in its colour, with the band
/// word and its range under it and an optional marker above showing where a value sits.
public struct BandScaleBar: View {
    public struct Band: Identifiable {
        public let id: String
        public let word: String
        public let range: String
        public let color: Color
        public init(id: String, word: String, range: String, color: Color) {
            self.id = id
            self.word = word
            self.range = range
            self.color = color
        }
    }

    private let bands: [Band]
    private let marker: Double?
    private let markerColor: Color

    /// `marker` is the value's position along the whole scale, 0...1; `nil` draws no marker.
    public init(_ bands: [Band], marker: Double? = nil, markerColor: Color = StrandPalette.textPrimary) {
        self.bands = bands
        self.marker = marker
        self.markerColor = markerColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let gap: CGFloat = 3
                let usable = max(proxy.size.width - gap * CGFloat(max(bands.count - 1, 0)), 0)
                let segment = usable / CGFloat(max(bands.count, 1))
                ZStack(alignment: .topLeading) {
                    HStack(spacing: gap) {
                        ForEach(bands) { band in
                            Capsule(style: .continuous).fill(band.color.opacity(0.9)).frame(width: segment, height: 6)
                        }
                    }
                    .padding(.top, 7)
                    if let marker {
                        let unit = min(max(marker, 0), 1)
                        let x = proxy.size.width * CGFloat(unit)
                        Circle()
                            .fill(markerColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 2))
                            .position(x: min(max(x, 5), max(proxy.size.width - 5, 5)), y: 10)
                    }
                }
            }
            .frame(height: 20)
            HStack(alignment: .top, spacing: 3) {
                ForEach(bands) { band in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Circle().fill(band.color).frame(width: 6, height: 6)
                            Text(verbatim: band.word.uppercased())
                                .font(StrandFont.micro.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(verbatim: band.range)
                            .font(StrandFont.micro)
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.leading, 11)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: bands.map { "\($0.word) \($0.range)" }.joined(separator: ", ")))
    }
}

// MARK: - Stress day ribbon

/// The 24 hourly stress levels as a ribbon of pips, at detail size. Each pip carries its hour's level as height
/// as well as colour (the stress ramp, calm to high); an hour with no scorable signal stays a baseline tick,
/// never a made-up bar. The day's peak wears a bead, the live day a "now" tick. Dashed guides mark the band
/// edges. Hold and drag reads one hour at a time (the page still scrolls under a moving finger); the owner
/// shows the reading through `scrubHour`, and VoiceOver steps hours with the adjustable action.
public struct StressDayRibbon: View {
    private let hours: [Double?]
    private let nowHour: Int?
    private let summary: String
    private let spokenHour: ((Int) -> String)?
    @Binding private var scrubHour: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app's locale, which carries its 12/24-hour setting.
    @Environment(\.locale) private var locale
    @State private var revealed = false
    /// Whether VoiceOver is on the ribbon. The hour it has stepped to is kept for as long as it is, and let go when
    /// focus moves on, so a slow listener who pauses between swipes never finds the position jumped back.
    @AccessibilityFocusState private var voiceOverOnRibbon: Bool

    private static let height: CGFloat = 76
    /// With no scored hour there is nothing to draw tall: the row keeps only its baseline ticks.
    private static let emptyHeight: CGFloat = 14
    private static let tick: CGFloat = 3

    /// - Parameters:
    ///   - hours: 24 slots, `nil` for no signal.
    ///   - nowHour: the hour the "now" tick sits under, or `nil` for a past day.
    ///   - summary: the localised VoiceOver description of the whole ribbon.
    ///   - spokenHour: the localised reading VoiceOver speaks for an hour as it steps ("7 AM, High 2.6"); nil
    ///     leaves the stepping silent.
    public init(
        hours: [Double?], nowHour: Int?, summary: String,
        spokenHour: ((Int) -> String)? = nil, scrubHour: Binding<Int?>
    ) {
        self.hours = hours
        self.nowHour = nowHour
        self.summary = summary
        self.spokenHour = spokenHour
        self._scrubHour = scrubHour
    }

    private var scored: [(hour: Int, level: Double)] {
        hours.enumerated().compactMap { index, level in level.map { (index, $0) } }
    }

    private var peak: (hour: Int, level: Double)? {
        scored.max(by: { $0.level < $1.level })
    }

    private var rowHeight: CGFloat { scored.isEmpty ? Self.emptyHeight : Self.height }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ribbon
            axis
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.05)) { revealed = true }
        }
        .onDisappear { if scrubHour != nil { scrubHour = nil } }
    }

    private var ribbon: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let slot = width / 24
            ZStack(alignment: .bottom) {
                if !scored.isEmpty { guides(width: width) }
                Rectangle()
                    .fill(StrandPalette.hairlineStrong.opacity(0.8))
                    .frame(height: 1)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        pip(hour: hour, slot: slot)
                            .frame(width: slot, alignment: .bottom)
                    }
                }
                if let peak, revealed, scrubHour == nil {
                    Circle()
                        .fill(StressHeatStyle.color(for: peak.level))
                        .frame(width: 5, height: 5)
                        .offset(x: slot * (CGFloat(peak.hour) + 0.5) - width / 2, y: -(pipHeight(peak.level) + 6))
                        .transition(.opacity)
                }
                if let nowHour {
                    Triangle()
                        .fill(StrandPalette.textTertiary)
                        .frame(width: 6, height: 4)
                        .offset(x: slot * (CGFloat(min(max(nowHour, 0), 23)) + 0.5) - width / 2, y: 7)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .modifier(TrendsScrubModifier(
                onScrub: { point in
                    guard width > 0 else { return }
                    let hour = min(max(Int(point.x / width * 24), 0), 23)
                    if hour != scrubHour {
                        scrubHour = hour
                        StrandHaptic.selection.play()
                    }
                },
                onEnd: { withAnimation(StrandMotion.interactive) { scrubHour = nil } }
            ))
        }
        .frame(height: rowHeight)
        .padding(.top, scored.isEmpty ? 2 : 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary))
        .accessibilityValue(Text(verbatim: scrubHour.flatMap { spokenHour?($0) } ?? ""))
        .accessibilityHint(Text("Swipe up or down to step through hours"))
        .accessibilityFocused($voiceOverOnRibbon)
        .accessibilityAdjustableAction { direction in
            // The first swipe lands on where the day is now (or, on a past day, its peak); then each swipe is an hour.
            if let current = scrubHour {
                switch direction {
                case .increment: scrubHour = min(current + 1, 23)
                case .decrement: scrubHour = max(current - 1, 0)
                default: break
                }
            } else {
                scrubHour = min(max(nowHour ?? peak?.hour ?? 12, 0), 23)
            }
        }
        // Stepping ends when VoiceOver leaves the ribbon, not on a timer: the reading is released, and the hero it
        // drives goes back to the day.
        .onChangeCompat(of: voiceOverOnRibbon) { onRibbon in
            if !onRibbon, scrubHour != nil {
                withAnimation(StrandMotion.interactive) { scrubHour = nil }
            }
        }
    }

    /// Dashed rules at the band edges (1 and 2 on the 0...3 scale).
    private func guides(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ForEach([1.0, 2.0], id: \.self) { level in
                Path { path in
                    let y = Self.height - pipHeight(level)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
            }
        }
        .frame(width: width, height: Self.height)
    }

    @ViewBuilder
    private func pip(hour: Int, slot: CGFloat) -> some View {
        let level = hours.indices.contains(hour) ? hours[hour] : nil
        let isScrubbed = scrubHour == hour
        let dimmed = scrubHour != nil && !isScrubbed
        let pipWidth = min(max(slot * 0.5, 4), 9)
        if let level {
            Capsule(style: .continuous)
                .fill(StressHeatStyle.color(for: level))
                .frame(width: pipWidth, height: revealed ? pipHeight(level) : Self.tick)
                .scaleEffect(isScrubbed ? 1.18 : 1, anchor: .bottom)
                .opacity(dimmed ? 0.45 : 1)
                .animation(
                    reduceMotion ? nil : StrandMotion.value.delay(revealed ? 0 : Double(hour) * 0.018),
                    value: revealed
                )
                .animation(StrandMotion.interactive, value: scrubHour)
        } else {
            Capsule(style: .continuous)
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 3, height: Self.tick)
                .opacity(dimmed ? 0.4 : 0.9)
        }
    }

    private func pipHeight(_ level: Double) -> CGFloat {
        Self.tick + 3 + CGFloat(min(max(level / 3, 0), 1)) * (Self.height - Self.tick - 12)
    }

    /// Hour labels in the device's locale and 12/24-hour preference, never a hard-coded "AM".
    private var axis: some View {
        HStack(spacing: 0) {
            ForEach(Array([0, 6, 12, 18, 24].enumerated()), id: \.offset) { index, hour in
                Text(verbatim: Self.hourLabel(hour, locale: locale))
                    .frame(maxWidth: .infinity, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
            }
        }
        .font(StrandFont.micro)
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
    }

    /// "12 AM" / "00" for an hour of the day, in `locale`: the app's own, which carries its 12/24-hour setting (the
    /// device's when none is given).
    public static func hourLabel(_ hour: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let normalized = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: normalized, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour().locale(locale))
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

// MARK: - Week bars

/// One day of the week bars, ready to draw: what it holds, how tall its bar is on the scale, and whether it is the
/// viewed day. Kept apart from the view so the mapping is a plain function with its own tests.
public struct PillarWeekBarSlot: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A day with a score.
        case value(Double)
        /// A day that has happened and has none: drawn as a dot, never as a zero.
        case missing
        /// A day that has not happened yet.
        case future
    }

    public let date: Date
    public let kind: Kind
    /// The bar's height as a fraction of the scale (0...1); nil for a day without a value.
    public let fraction: Double?
    public let isAnchor: Bool

    public var id: Date { date }
}

public enum PillarWeekBarModel {
    /// The seven slots of a Monday-first week, from the days the screen holds.
    /// - Parameters:
    ///   - anchorDate: the day the screen shows, which is drawn brightest.
    ///   - referenceDate: today; later days are future.
    public static func slots(
        days: [CalendarMetricDay],
        maximum: Double,
        anchorDate: Date,
        referenceDate: Date,
        calendar: Calendar
    ) -> [PillarWeekBarSlot] {
        let today = calendar.startOfDay(for: referenceDate)
        return days.prefix(7).map { day in
            let isFuture = calendar.startOfDay(for: day.date) > today
            let isAnchor = calendar.isDate(day.date, inSameDayAs: anchorDate)
            if let value = day.value, value.isFinite, !isFuture {
                let fraction = min(max(value / max(maximum, 0.0001), 0), 1)
                return PillarWeekBarSlot(date: day.date, kind: .value(value), fraction: fraction, isAnchor: isAnchor)
            }
            return PillarWeekBarSlot(
                date: day.date, kind: isFuture ? .future : .missing, fraction: nil, isAnchor: isAnchor)
        }
    }

    /// What VoiceOver reads for the week: each day by its whole name with its value, "no data" for a past day without
    /// one and "Upcoming" for a day still to come, and the day on screen marked as the viewed one.
    /// - Parameters:
    ///   - reading: joins a day's name and what it holds ("Monday", "9.1 of 21") in the app's language.
    ///   - viewed: marks a day's reading as the one the screen shows ("Saturday 15.1 of 21, viewed day").
    public static func spokenSummary(
        _ slots: [PillarWeekBarSlot], dayNames: [String], value: (Double) -> String, noData: String, upcoming: String,
        reading: (String, String) -> String = { "\($0) \($1)" }, viewed: (String) -> String = { $0 }
    ) -> String {
        slots.enumerated().map { index, slot in
            let name = dayNames.indices.contains(index) ? dayNames[index] : ""
            let text: String
            switch slot.kind {
            case .future: text = reading(name, upcoming)
            case .missing: text = reading(name, noData)
            case .value(let number): text = reading(name, value(number))
            }
            return slot.isAnchor ? viewed(text) : text
        }.joined(separator: ", ")
    }
}

/// A Monday-first week of daily bars on a fixed scale, with the target band drawn softly behind them. The viewed
/// day is the bright, bold one; a value sits above its bar only when there is one; a past day without a score is a
/// dot (never an empty bar that reads as zero), and a day still to come is just an empty, quieter track.
public struct PillarWeekBars: View {
    private let days: [CalendarMetricDay]
    private let maximum: Double
    private let target: ClosedRange<Double>?
    private let tint: Color
    private let anchorDate: Date
    private let referenceDate: Date
    private let calendar: Calendar
    private let valueFormat: (Double) -> String
    private let spokenValue: ((Double) -> String)?

    @Environment(\.dynamicTypeSize) private var typeSize
    /// The row above the bars that holds a day's printed value: it grows with the type, and the band and the bar track
    /// are offset by it. At accessibility sizes a seven-column value no longer fits its column, so the row goes (the
    /// spoken summary and the hero carry the values).
    @ScaledMetric(relativeTo: .caption2) private var valueRowBase: CGFloat = 18
    private var showsValues: Bool { !typeSize.isAccessibilitySize }
    private var valueRowHeight: CGFloat { showsValues ? valueRowBase : 0 }
    private static let trackHeight: CGFloat = 86
    private var plotHeight: CGFloat { Self.trackHeight + valueRowHeight }
    private static let barWidth: CGFloat = 16

    public init(
        days: [CalendarMetricDay],
        maximum: Double,
        target: ClosedRange<Double>?,
        tint: Color,
        anchorDate: Date,
        referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent,
        valueFormat: @escaping (Double) -> String,
        spokenValue: ((Double) -> String)? = nil
    ) {
        self.days = days
        self.maximum = maximum
        self.target = target
        self.tint = tint
        self.anchorDate = anchorDate
        self.referenceDate = referenceDate
        self.calendar = calendar
        self.valueFormat = valueFormat
        self.spokenValue = spokenValue
    }

    private var slots: [PillarWeekBarSlot] {
        PillarWeekBarModel.slots(days: days, maximum: maximum, anchorDate: anchorDate,
                                 referenceDate: referenceDate, calendar: calendar)
    }

    public var body: some View {
        let slots = slots
        let names = TrendsWeekdayNames.veryShort(calendar: calendar)
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let target, maximum > 0 {
                    GeometryReader { proxy in
                        let track = max(proxy.size.height - valueRowHeight, 1)
                        let top = valueRowHeight + track * CGFloat(1 - min(target.upperBound / maximum, 1))
                        let bottom = valueRowHeight + track * CGFloat(1 - min(target.lowerBound / maximum, 1))
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(StrandPalette.statusPositive.opacity(0.09))
                            .frame(height: max(bottom - top, 1))
                            .offset(y: top)
                    }
                    .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(slots) { slot in
                        column(for: slot)
                    }
                }
            }
            .frame(height: plotHeight)
            HStack(spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    Text(verbatim: names.indices.contains(index) ? names[index] : "")
                        .font(StrandFont.micro.weight(slot.isAnchor ? .bold : .medium))
                        .foregroundStyle(slot.isAnchor ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary(slots)))
    }

    @ViewBuilder
    private func column(for slot: PillarWeekBarSlot) -> some View {
        VStack(spacing: 0) {
            Group {
                if showsValues, case .value(let value) = slot.kind {
                    Text(verbatim: valueFormat(value))
                        .font(StrandFont.micro.weight(slot.isAnchor ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(slot.isAnchor ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Color.clear
                }
            }
            .frame(height: valueRowHeight)
            ZStack(alignment: .bottom) {
                switch slot.kind {
                case .value:
                    Capsule(style: .continuous).fill(tint.opacity(0.1))
                    if let fraction = slot.fraction {
                        GeometryReader { proxy in
                            Capsule(style: .continuous)
                                .fill(tint.opacity(barOpacity(slot)))
                                .frame(height: max(proxy.size.height * CGFloat(fraction), 6))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                case .missing:
                    Circle().fill(StrandPalette.textTertiary.opacity(0.55)).frame(width: 5, height: 5)
                        .padding(.bottom, 3)
                case .future:
                    // Nothing has happened yet, so no dot (a dot says "no score"): only the empty track, quieter than a
                    // scored day's.
                    Capsule(style: .continuous).fill(tint.opacity(0.04))
                }
            }
            .frame(width: Self.barWidth)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .background {
            if slot.isAnchor {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.08))
                    .padding(.horizontal, 4)
            }
        }
    }

    /// The viewed day is solid; the rest are quieter. No bar is dimmed for missing a target: the band is the viewed
    /// day's, so it says nothing about another day.
    private func barOpacity(_ slot: PillarWeekBarSlot) -> Double {
        slot.isAnchor ? 1 : 0.7
    }

    /// Spoken, so: whole weekday names, the value with its unit (`spokenValue`, else the printed one), "no data" for a
    /// past day without one, and "Upcoming" for a day that has not happened yet.
    private func summary(_ slots: [PillarWeekBarSlot]) -> String {
        PillarWeekBarModel.spokenSummary(
            slots, dayNames: TrendsWeekdayNames.full(calendar: calendar), value: spokenValue ?? valueFormat,
            noData: String(localized: "no data"), upcoming: String(localized: "Upcoming"),
            reading: { String(localized: "\($0) \($1)") }, viewed: { String(localized: "\($0), viewed day") })
    }
}

// MARK: - Band strip

/// One slim capsule per day, each in its band's colour (a day with no value is a quiet hairline), the newest on
/// the right and ringed. Reads as the shape of the last few weeks at a glance.
public struct BandStrip: View {
    private let colors: [Color?]
    private let summary: String?

    /// - Parameter summary: what VoiceOver says for the strip. Leave it nil when a sentence beside it already says
    ///   the same, so the strip is skipped instead of read twice.
    public init(_ colors: [Color?], summary: String? = nil) {
        self.colors = colors
        self.summary = summary
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                let isNewest = index == colors.count - 1
                Capsule(style: .continuous)
                    .fill(color ?? StrandPalette.hairline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .overlay {
                        if isNewest {
                            Capsule(style: .continuous)
                                .stroke(StrandPalette.textPrimary, lineWidth: 1.5)
                                .padding(-2)
                        }
                    }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(summary == nil)
        .accessibilityLabel(Text(verbatim: summary ?? ""))
    }
}
