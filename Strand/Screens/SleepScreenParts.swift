import SwiftUI
import StrandDesign

// MARK: - Sleep tab building blocks
//
// The Sleep tab root is flat sections on the canvas, in the same language as Today and the Coach cards: a
// `SectionEyebrow` header (domain symbol + tracked caps title), values bright with their units muted, one
// hairline between sections and one `DomainTint` per metric. These are the pieces that language needs which
// the shared design system does not ship (a score dial, a labelled fact strip, a hypnogram that fills its
// width, stage rows). They take plain values, so they never see SleepView's private night model.

// MARK: - Page rhythm

enum SleepRhythm {
    /// Layout air above and below the hairline between two flat sections, in points. Today's separators use
    /// 12–15 above and 13.3 below to make the VISIBLE gap equal on both sides; these are tuned the same way for
    /// Sleep's sections and checked with `gaps.py`.
    static let airAbove: CGFloat = 13
    static let airBelow: CGFloat = 14
    /// Space under the night navigator before the first section.
    static let navigatorToContent: CGFloat = 16
    /// Air either side of the hairline between two rows of tiles.
    static let rowAir: CGFloat = 12
}

/// The one hairline between two Sleep sections (Today's own separator, so the weight and colour cannot drift).
struct SleepSectionSeparator: View {
    var above: CGFloat = SleepRhythm.airAbove
    var below: CGFloat = SleepRhythm.airBelow

    var body: some View {
        TodaySectionSeparator(above: above, below: below)
    }
}

/// A flat section: eyebrow header over free-form content, spaced like the Coach cards' interiors.
struct SleepSection<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: DomainTint = .sleep
    var trailing: EyebrowTrailing = .none
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, tint: DomainTint = .sleep,
         trailing: EyebrowTrailing = .none, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow(title, systemImage: systemImage, tint: tint, trailing: trailing)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Values with muted units

enum SleepValueSplit {
    /// "55 bpm" -> ("55", "bpm"), "7:00 AM" -> ("7:00", "AM"). A compound like "6h 49m" or "12 of 21" stays whole:
    /// the tail of a unit has no digit in it.
    static func parts(_ raw: String) -> (number: String, unit: String?) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        guard let split = value.lastIndex(where: { spaces.contains($0) }) else { return (value, nil) }
        let head = value[..<split].trimmingCharacters(in: .whitespaces)
        let tail = value[value.index(after: split)...].trimmingCharacters(in: .whitespaces)
        guard head.contains(where: \.isNumber), !tail.isEmpty, tail.count <= 4,
              !tail.contains(where: \.isNumber) else { return (value, nil) }
        return (head, tail)
    }
}

/// A bright value with its unit small and muted beside it; a missing value is a tertiary dash.
struct SleepValueText: View {
    let value: String
    var size: CGFloat = WidgetMetrics.statValueSize
    var weight: Font.Weight = .semibold

    var body: some View {
        let parts = SleepValueSplit.parts(value)
        let missing = value == WidgetMetrics.missingValue
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.number)
                .font(StrandFont.number(size, weight: weight))
                .foregroundStyle(missing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
            if let unit = parts.unit, !missing {
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Fact strip

struct SleepFact {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }
}

/// Label-over-value columns with hairline dividers, the shape of `StatFooter(.prominent)` with the unit muted.
/// Equal columns, labels on one line, values on one baseline; steps down in size and then stacks as rows before
/// anything truncates.
struct SleepFactStrip: View {
    let facts: [SleepFact]
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = WidgetMetrics.statValueSize
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                columns(size: valueSize)
                columns(size: valueSize * 0.85)
                columns(size: valueSize * 0.72)
                stacked
            }
        }
    }

    private func columns(size: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                if index > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                    SleepValueText(value: fact.value, size: size)
                        // One-line sizes report their full width, so ViewThatFits moves to the next size
                        // rather than truncating one column.
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                .padding(.trailing, index == facts.count - 1 ? 0 : NoopMetrics.space3)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(fact.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: NoopMetrics.space2)
                    SleepValueText(value: fact.value, size: valueSize)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Score dial

/// The Sleep score as the Today dials draw it: a 240 degree open arc, 8pt round line, the sleep tint over a
/// track of the same tint at 16%, the score in the middle. Ticks mark the state bands (50 / 70 / 85) that the
/// state words ("Fair", "Good", "Optimal") come from. With no score the arc is a row of quiet dots and a dash.
struct SleepScoreDial: View {
    let score: Double?
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 112
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private let lineWidth: CGFloat = 8
    private let bandTicks: [Double] = [0.5, 0.7, 0.85]

    private var diameter: CGFloat { min(side, 148) }
    private var fraction: Double { min(max((score ?? 0) / 100, 0), 1) }
    private var accent: Color { DomainTint.sleep.accent }
    private var trackColor: Color {
        score == nil ? StrandPalette.textTertiary.opacity(0.2) : accent.opacity(0.16)
    }

    private func arc(to end: Double) -> some Shape {
        Circle().inset(by: lineWidth / 2)
            .trim(from: 0, to: (2.0 / 3.0) * end)
            .rotation(.degrees(150))
    }

    /// The empty dial's track: round dots evenly spaced about 13.5pt apart with one centred on each end of the arc.
    private func dottedTrack(radius: CGFloat) -> some View {
        let pitch: CGFloat = 13.5
        let length = 2 * .pi * radius * (2.0 / 3.0)
        let intervals = max(1, Int((length / pitch).rounded()))
        return ForEach(0...intervals, id: \.self) { index in
            let angle = Angle.degrees(150 + 240 * Double(index) / Double(intervals))
            Circle().fill(trackColor)
                .frame(width: lineWidth, height: lineWidth)
                .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
        }
    }

    var body: some View {
        let radius = diameter / 2 - lineWidth / 2
        ZStack {
            if score == nil {
                dottedTrack(radius: radius)
            } else {
                arc(to: 1).stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                ForEach(bandTicks, id: \.self) { tick in
                    let angle = Angle.degrees(150 + 240 * tick)
                    Capsule().fill(StrandPalette.hairlineStrong)
                        .frame(width: 1.5, height: lineWidth + 4)
                        .rotationEffect(angle + .degrees(90))
                        .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
                }
                arc(to: revealed ? fraction : 0)
                    .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            Text(verbatim: score.map { "\(Int($0.rounded()))" } ?? WidgetMetrics.missingValue)
                .font(StrandFont.number(diameter * 0.3, weight: .bold))
                .foregroundStyle(score == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .offset(y: 3)
        }
        .frame(width: diameter, height: diameter)
        // The open arc leaves the bottom quarter of its square empty; give that air back so the stats row sits
        // a section-gap under the arc's ends rather than a whole dial-quarter further.
        .frame(width: diameter, height: diameter * 0.84, alignment: .top)
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) { revealed = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Sleep score \(Int($0.rounded()))" } ?? "Sleep score unavailable")
    }
}

// MARK: - Hero

/// The opening section: the score dial beside its state word and a line of context, then the night's three
/// headline numbers. `source` names where the night's numbers came from (the real merge winner), at the
/// eyebrow's trailing edge like a record date.
struct SleepHeroSection: View {
    let score: Double?
    let headline: String?
    let message: String
    let facts: [SleepFact]
    let source: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Sleep score", systemImage: "moon.stars.fill", tint: .sleep,
                           trailing: source.map { .text($0) } ?? .none)
            GaugeLayout {
                SleepScoreDial(score: score)
            } rows: {
                VStack(alignment: .leading, spacing: 4) {
                    if let headline {
                        Text(headline)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SleepFactStrip(facts: facts)
                .padding(.top, NoopMetrics.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chips

/// A small action: the shared `WidgetChip` with a 44pt tap area, an optional title and symbol.
struct SleepChipButton: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    var showsChevron: Bool = false
    let accessibilityLabel: LocalizedStringKey
    var accessibilityHint: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            chip.chipHitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .modifier(OptionalHint(hint: accessibilityHint))
    }

    @ViewBuilder private var chip: some View {
        if let title {
            WidgetChip(appTitle: title, systemImage: systemImage, showsChevron: showsChevron, overhangs: false)
        } else {
            WidgetChip(systemImage: systemImage, showsChevron: showsChevron, overhangs: false)
        }
    }

    private struct OptionalHint: ViewModifier {
        let hint: LocalizedStringKey?
        @ViewBuilder func body(content: Content) -> some View {
            if let hint { content.accessibilityHint(hint) } else { content }
        }
    }
}

/// Chips side by side, dropping to a column when they no longer fit.
struct SleepChipRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space2) { content() }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) { content() }
        }
    }
}

// MARK: - Hypnogram

/// The night's stage timeline, filling its width: four labelled lanes (awake at the top, deep at the bottom),
/// quiet guides, slim rounded bars at their true duration and hairline risers between them, over a start / middle
/// / end clock axis. The bars are the stage colours the rows below use. A highlighted stage keeps full strength
/// while the rest recede. Render-only: the intervals and totals are untouched (the display smoothing is the
/// shared `Hypnogram.displaySmoothed`).
struct SleepStageChart: View {
    private let intervals: [SleepInterval]
    private let origin: TimeInterval
    private let span: TimeInterval
    private let start: Date
    private let highlighted: SleepStage?

    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var plotHeight: CGFloat = 128

    private static let laneOrder: [SleepStage] = [.awake, .rem, .light, .deep]
    private static let barThickness: CGFloat = 10

    init(intervals: [SleepInterval], start: Date, highlighted: SleepStage?) {
        let sorted = intervals.sorted { $0.start < $1.start }
        let smoothed = Hypnogram.displaySmoothed(sorted, minDuration: 300)
        self.intervals = smoothed
        let first = smoothed.first?.start ?? 0
        self.origin = first
        self.span = max(1, (smoothed.map(\.end).max() ?? first + 1) - first)
        self.start = start
        self.highlighted = highlighted
    }

    private func clock(_ seconds: TimeInterval) -> String {
        AppClock.hourMinuteFormatter().string(from: start.addingTimeInterval(seconds))
    }

    private var summary: String {
        let parts = [SleepStage.deep, .rem, .light, .awake].compactMap { stage -> String? in
            let minutes = intervals.filter { $0.stage == stage }.reduce(0.0) { $0 + $1.duration } / 60
            guard minutes > 0 else { return nil }
            return "\(stage.label) \(SleepStageRowPresentation.durationText(minutes))"
        }
        return parts.isEmpty
            ? String(localized: "Sleep stages, no data")
            : String(localized: "Sleep stages, \(parts.joined(separator: ", "))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Self.laneOrder, id: \.self) { stage in
                        Text(stage.label)
                            .font(StrandFont.micro)
                            .foregroundStyle(highlighted == stage ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: gutter, height: plotHeight, alignment: .trailing)
                plot.frame(height: plotHeight)
            }
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Color.clear.frame(width: gutter, height: 1)
                HStack(spacing: 0) {
                    Text(clock(origin)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(clock(origin + span / 2)).frame(maxWidth: .infinity, alignment: .center)
                    Text(clock(origin + span)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var plot: some View {
        Canvas { context, size in
            let lane = size.height / CGFloat(Self.laneOrder.count)
            func y(_ stage: SleepStage) -> CGFloat { lane * (CGFloat(stage.bandRank) + 0.5) }
            func x(_ t: TimeInterval) -> CGFloat { CGFloat((t - origin) / span) * size.width }

            for stage in Self.laneOrder {
                var guide = Path()
                guide.move(to: CGPoint(x: 0, y: y(stage)))
                guide.addLine(to: CGPoint(x: size.width, y: y(stage)))
                context.stroke(guide, with: .color(StrandPalette.hairline), lineWidth: 1)
            }

            var risers = Path()
            for index in intervals.indices.dropLast() {
                let a = intervals[index], b = intervals[index + 1]
                risers.move(to: CGPoint(x: x(b.start), y: y(a.stage)))
                risers.addLine(to: CGPoint(x: x(b.start), y: y(b.stage)))
            }
            context.stroke(risers, with: .color(StrandPalette.textTertiary.opacity(highlighted == nil ? 0.3 : 0.12)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round))

            for interval in intervals {
                let width = max(3, x(interval.end) - x(interval.start))
                let rect = CGRect(x: x(interval.start), y: y(interval.stage) - Self.barThickness / 2,
                                  width: width, height: Self.barThickness)
                let dimmed = highlighted != nil && highlighted != interval.stage
                context.fill(Path(roundedRect: rect, cornerRadius: min(Self.barThickness / 2, width / 2)),
                             with: .color(StrandPalette.sleepStageColor(interval.stage).opacity(dimmed ? 0.18 : 1)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: highlighted)
    }
}

// MARK: - Stage rows

/// One stage of the night: its dot and name, a slim bar of its share of the night, the share and the duration.
/// A button: selecting a row lights that stage up on the chart and recedes the rest (tap again to clear).
struct SleepStageBreakdownRow: View {
    let stage: SleepStage
    let presentation: SleepStageRowPresentation
    let isSelected: Bool
    let othersSelected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    // Column widths follow the text they hold, so a larger Dynamic Type never wraps a share or clips a duration.
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 66
    @ScaledMetric(relativeTo: .caption2) private var shareWidth: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var durationWidth: CGFloat = 74

    private var color: Color { StrandPalette.sleepStageColor(stage) }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                Capsule(style: .continuous).fill(color)
                    .frame(width: max(presentation.fraction > 0 ? 4 : 0, proxy.size.width * presentation.fraction))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var name: some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(stage.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    private var share: some View {
        Text("\(presentation.percent)%").font(StrandFont.micro).monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
    }

    private var duration: some View {
        Text(presentation.duration).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            name
                            share
                            Spacer(minLength: NoopMetrics.space2)
                            duration
                        }
                        bar
                    }
                } else {
                    HStack(spacing: NoopMetrics.space3) {
                        name.frame(width: nameWidth, alignment: .leading)
                        bar
                        share.frame(width: shareWidth, alignment: .trailing)
                        duration.frame(width: durationWidth, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, NoopMetrics.space2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(isSelected ? 0.13 : 0)))
            .opacity(othersSelected ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stage.label): \(presentation.duration), \(presentation.percent) percent of the night")
        .accessibilityHint("Highlights this stage on the sleep chart")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One stage against the user's typical: dot, name and share, last night's duration and its difference from
/// typical, then a bar of last night with a tick at the typical mark.
struct SleepTypicalRow: View {
    let stage: SleepStage
    let value: Double
    let typical: Double?
    let scaleMaximum: Double
    let percent: Int
    let duration: String
    let delta: String?
    let deltaIsGood: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var color: Color { StrandPalette.sleepStageColor(stage) }

    /// The mapper's "−0m vs typ" is a rounding artefact of a difference under half a minute: say so in words.
    private var deltaText: String? {
        guard let delta else { return nil }
        if isOnTypical { return String(localized: "on typical") }
        return delta
    }

    private var isOnTypical: Bool {
        guard let delta else { return false }
        return delta.hasPrefix("+0m ") || delta.hasPrefix("−0m ")
    }

    private var deltaColor: Color {
        if isOnTypical { return StrandPalette.textTertiary }
        switch deltaIsGood {
        case .some(true): return StrandPalette.statusPositive
        case .some(false): return StrandPalette.statusWarning
        case .none: return StrandPalette.textTertiary
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(stage.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("\(percent)%").font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: NoopMetrics.space2)
            Text(duration).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
            if let deltaText {
                Text(deltaText).font(StrandFont.micro)
                    .foregroundStyle(deltaColor)
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) { header }
            } else {
                header
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                    Capsule(style: .continuous).fill(color)
                        .frame(width: width * CGFloat(min(1, max(0, value / scaleMaximum))))
                    if let typical, typical > 0 {
                        Capsule(style: .continuous).fill(StrandPalette.textPrimary.opacity(0.85))
                            .frame(width: 2, height: 14)
                            .offset(x: min(width - 2, max(0, width * CGFloat(min(1, typical / scaleMaximum)) - 1)))
                    }
                }
                .frame(height: proxy.size.height)
            }
            .frame(height: 14)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Night detail tiles

/// One metric of the displayed night: a tinted symbol and label, the value with its unit muted, the metric's own
/// recent history as a quiet sparkline when it has one, and "typical" as a tertiary caption. Always the same
/// order, so a row of tiles keeps its labels and values on shared lines whether or not a tile has a trend.
struct SleepMetricTile: View {
    let label: LocalizedStringKey
    let value: String
    var caption: String? = nil
    let systemImage: String
    var tint: DomainTint = .sleep
    var series: [Double]? = nil
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                // A fixed box so symbols of different heights never move the label or the value below it.
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint.accent)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            SleepValueText(value: value, size: valueSize, weight: .bold)
            if let series, series.count > 1 {
                Sparkline(values: series,
                          gradient: Gradient(colors: [tint.accent.opacity(0.55), tint.accent]),
                          lineWidth: 1.5, showsHover: false)
                    .frame(height: 26)
                    .accessibilityHidden(true)
            }
            if let caption {
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Tiles in rows of two (one column at accessibility sizes) with a hairline between rows and even air either
/// side of it. No hairline at the ends: the sections around it draw those.
struct SleepMetricGrid: View {
    let tiles: [SleepMetricTile]
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: Int { typeSize.isAccessibilitySize ? 1 : 2 }

    var body: some View {
        let rows = stride(from: 0, to: tiles.count, by: columns).map { start in
            Array(start..<min(start + columns, tiles.count))
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    TodaySectionSeparator(above: 0, below: 0)
                }
                HStack(alignment: .top, spacing: NoopMetrics.space5) {
                    ForEach(row, id: \.self) { tiles[$0] }
                    if row.count < columns {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .padding(.top, rowIndex > 0 ? SleepRhythm.rowAir : 0)
                .padding(.bottom, rowIndex < rows.count - 1 ? SleepRhythm.rowAir : 0)
            }
        }
    }
}

// MARK: - Sleep balance bars

/// The per-night balance strip: each night a bar from the centre line, up in the sleep tint for a surplus and down
/// in amber for a deficit, scaled to the largest difference. The first appearance grows the bars; Reduce Motion
/// draws them at full height straight away.
struct SleepBalanceBars: View {
    struct Entry: Identifiable {
        let id: String
        let minutes: Double
    }

    let nights: [Entry]
    let accessibilitySummary: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        // One scale for both directions; the centre line sits where the biggest surplus and the biggest deficit
        // leave room for each, so a fortnight of debt does not draw an empty half above its bars.
        let maxUp = max(nights.map(\.minutes).filter { $0 > 0 }.max() ?? 0, 0)
        let maxDown = max(nights.map { -$0.minutes }.filter { $0 > 0 }.max() ?? 0, 0)
        let total = max(maxUp + maxDown, 1)
        let finalGeometry = reduceMotion || revealed
        GeometryReader { proxy in
            let count = max(nights.count, 1)
            let slot = proxy.size.width / CGFloat(count)
            let barWidth = max(3, min(slot * 0.55, 14))
            let usable = proxy.size.height - 2
            let perMinute = usable / CGFloat(total)
            let mid = min(max(CGFloat(maxUp) * perMinute + 1, 6), proxy.size.height - 6)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(StrandPalette.hairlineStrong).frame(height: 1)
                    .position(x: proxy.size.width / 2, y: mid)
                ForEach(Array(nights.enumerated()), id: \.element.id) { index, night in
                    let room = night.minutes >= 0 ? mid - 2 : proxy.size.height - mid - 2
                    let full = min(room, max(3, CGFloat(abs(night.minutes)) * perMinute))
                    let height = finalGeometry ? full : 3
                    RoundedRectangle(cornerRadius: min(3, barWidth / 2), style: .continuous)
                        .fill(night.minutes >= 0 ? DomainTint.sleep.accent : StrandPalette.statusWarning)
                        .frame(width: barWidth, height: height)
                        .position(x: slot * CGFloat(index) + slot / 2,
                                  y: night.minutes >= 0 ? mid - height / 2 : mid + height / 2)
                        .animation(reduceMotion ? nil : StrandMotion.value.delay(Double(min(index, 13)) * 0.02),
                                   value: revealed)
                }
            }
        }
        .frame(height: 64)
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }
}
