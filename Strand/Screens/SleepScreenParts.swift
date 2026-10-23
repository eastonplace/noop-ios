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
}

extension FlatSectionSeparator {
    /// The separator between two Sleep sections, at Sleep's tuned air.
    static var sleep: FlatSectionSeparator {
        FlatSectionSeparator(above: SleepRhythm.airAbove, below: SleepRhythm.airBelow)
    }
}

// MARK: - Score dial

/// The Sleep score as the Today dials draw it: a 240 degree open arc, 8pt round line, the sleep tint over a
/// track of the same tint at 16%, the score in the middle. Ticks mark the state bands (50 / 70 / 85) that the
/// state words ("Fair", "Good", "Optimal") come from. With no score the arc is a row of quiet dots and a dash.
struct SleepScoreDial: View {
    let score: Double?
    /// The hero's small ring: 76pt with a 6pt line, so it sits beside the headline instead of above it.
    var compact = false
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 112
    @ScaledMetric(relativeTo: .title) private var compactSide: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var lineWidth: CGFloat { compact ? 6 : 8 }
    private let bandTicks: [Double] = [0.5, 0.7, 0.85]

    private var diameter: CGFloat { compact ? min(compactSide, 112) : min(side, 148) }
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
        let pitch: CGFloat = compact ? 10 : 13.5
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
        .accessibilityLabel(score.map { String(localized: "Sleep score \(Int($0.rounded()))") } ?? String(localized: "Sleep score unavailable"))
    }
}

// MARK: - Hero

/// The opening section: a small score ring beside its state word and a line of context, then the night's four
/// headline numbers. `source` names where the night's numbers came from (the real merge winner), at the
/// eyebrow's trailing edge like a record date.
struct SleepHeroSection: View {
    let score: Double?
    let headline: String?
    let message: String
    let facts: [FactStrip.Fact]
    let source: String?
    /// Opens the Sleep score explainer from the header's ⓘ. Absent, the header has no ⓘ.
    var infoAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow("Sleep score", systemImage: "moon.stars.fill", tint: .sleep,
                           trailing: source.map { .text($0) } ?? .none,
                           infoAction: infoAction,
                           infoAccessibilityLabel: MetricInfo.sleepScore.accessibilityLabel)
            GaugeLayout {
                SleepScoreDial(score: score, compact: true)
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
            FactStrip(facts: facts)
                .padding(.top, NoopMetrics.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hypnogram

/// A night's stage timeline prepared for drawing, built ONCE with the night (never per render): the intervals on
/// one absolute clock (seconds from the night's onset, gaps between fragments kept), sorted and display-smoothed
/// within each unbroken run so a short fragment is never absorbed across a gap, plus the raw per-stage minutes
/// for the spoken summary. Render-only: totals and stored data are untouched.
struct SleepStageTimeline {
    /// A break longer than this between two intervals is a gap (strap off, got up), not an epoch seam.
    static let gapSeconds: TimeInterval = 90

    let intervals: [SleepInterval]
    let origin: TimeInterval
    let span: TimeInterval
    let stageMinutes: [SleepStage: Double]

    var isEmpty: Bool { intervals.isEmpty }

    /// Main actor because the shared display smoothing lives on the (main-actor) `Hypnogram` view type.
    @MainActor
    init(_ raw: [SleepInterval], minimumSegment: TimeInterval = 300) {
        let sorted = raw.sorted { $0.start < $1.start }
        var minutes: [SleepStage: Double] = [:]

        // Unbroken runs. A fragment that overlaps the one before it is clipped to start where that one ends, so
        // overlapped time is neither drawn nor spoken twice.
        var runs: [[SleepInterval]] = []
        for interval in sorted {
            var current = interval
            if let last = runs.last?.last, current.start < last.end {
                current = SleepInterval(stage: current.stage, start: last.end, end: current.end)
                if current.end <= current.start { continue }
            }
            minutes[current.stage, default: 0] += current.duration / 60
            if let last = runs.last?.last, current.start - last.end <= Self.gapSeconds {
                runs[runs.count - 1].append(current)
            } else {
                runs.append([current])
            }
        }
        stageMinutes = minutes
        let smoothed = runs.flatMap { Hypnogram.displaySmoothed($0, minDuration: minimumSegment) }
        intervals = smoothed
        let first = smoothed.first?.start ?? 0
        origin = first
        span = max(1, (smoothed.map(\.end).max() ?? first + 1) - first)
    }

    /// Whether `next` follows `previous` without a gap, so a riser may join them.
    func joins(_ previous: SleepInterval, _ next: SleepInterval) -> Bool {
        next.start - previous.end <= Self.gapSeconds
    }
}

/// Durations as they are said aloud ("1 hour, 38 minutes"), in the user's language.
enum SleepSpokenDuration {
    static func text(minutes: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let total = max(0, Int(minutes.rounded()))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = total < 60 ? [.minutes] : [.hours, .minutes]
        let style = Duration.UnitsFormatStyle.units(
            allowed: allowed, width: .wide,
            zeroValueUnits: total == 0 ? .show(length: 1) : .hide
        ).locale(locale)
        return Duration.seconds(total * 60).formatted(style)
    }
}

/// The night's stage timeline, filling its width: four labelled lanes (awake at the top, deep at the bottom),
/// quiet guides, slim rounded bars at their true time on the night's clock and hairline risers between the bars
/// that follow one another, over a start / middle / end clock axis. Where the night has a gap (a fragment boundary)
/// the lanes are simply empty and no riser crosses it. The bars are the stage colours the rows below use. A
/// highlighted stage keeps full strength while the rest recede. The axis is always left to right, like the trend
/// charts.
struct SleepStageChart: View {
    private let timeline: SleepStageTimeline
    private let start: Date
    private let highlighted: SleepStage?

    @ScaledMetric(relativeTo: .caption2) private var gutter: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var plotHeight: CGFloat = 70

    private static let laneOrder: [SleepStage] = [.awake, .rem, .light, .deep]
    private static let barThickness: CGFloat = 10

    init(timeline: SleepStageTimeline, start: Date, highlighted: SleepStage?) {
        self.timeline = timeline
        self.start = start
        self.highlighted = highlighted
    }

    private func clock(_ seconds: TimeInterval) -> String {
        AppClock.hourMinuteFormatter().string(from: start.addingTimeInterval(seconds))
    }

    private var summary: String {
        let parts = [SleepStage.deep, .rem, .light, .awake].compactMap { stage -> String? in
            guard let minutes = timeline.stageMinutes[stage], minutes > 0 else { return nil }
            return "\(stage.label) \(SleepSpokenDuration.text(minutes: minutes))"
        }
        guard !parts.isEmpty else { return String(localized: "Sleep stages, no data") }
        let from = clock(timeline.origin), to = clock(timeline.origin + timeline.span)
        return String(localized: "Sleep stages from \(from) to \(to): \(parts.joined(separator: ", "))")
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
                    Text(clock(timeline.origin)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(clock(timeline.origin + timeline.span / 2)).frame(maxWidth: .infinity, alignment: .center)
                    Text(clock(timeline.origin + timeline.span)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .accessibilityHidden(true)
        }
        // The plot is drawn in time order from the left edge, so the lane labels, axis and plot all keep one
        // direction in right-to-left languages (the trend charts do the same).
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var plot: some View {
        Canvas { context, size in
            let intervals = timeline.intervals
            let origin = timeline.origin, span = timeline.span
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
                guard timeline.joins(a, b) else { continue }
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

/// One stage of the night in a ~28pt row: its dot and name, a bar of tonight's minutes with a tick at the typical
/// mark, and on the right the difference from typical ("+7m", better in the positive tint, worse muted). With no
/// typical it shows the duration and no tick. Press and hold swaps the right side for the exact time and share
/// ("1h 38m · 23%"); VoiceOver always has them in the label, so nothing needs the hold.
struct SleepStageTypicalRow: View {
    let stage: SleepStage
    let presentation: SleepStageRowPresentation
    let typical: Double?
    /// Minutes the full bar stands for, shared by the four rows so the bars compare with one another.
    let scaleMaximum: Double
    let isHeld: Bool
    let accessibilityLabel: String
    /// Called with true when the hold registers and false when the finger lifts or the scroll takes over.
    let onHold: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var nameWidth: CGFloat = 62
    @ScaledMetric(relativeTo: .caption) private var trailingWidth: CGFloat = 92

    private var color: Color { StrandPalette.sleepStageColor(stage) }

    private var trailingText: String {
        if isHeld { return "\(presentation.duration) · \(presentation.percent)%" }
        guard let delta = presentation.shortDelta else { return presentation.duration }
        return presentation.isOnTypical ? String(localized: "on typical") : delta
    }

    private var trailingColor: Color {
        if isHeld { return StrandPalette.textPrimary }
        guard presentation.shortDelta != nil, !presentation.isOnTypical else { return StrandPalette.textSecondary }
        return presentation.deltaTone == .positive ? StrandPalette.statusPositive : StrandPalette.textTertiary
    }

    private var name: some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(stage.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                Capsule(style: .continuous).fill(color)
                    .frame(width: max(presentation.minutes > 0 ? 4 : 0,
                                      width * CGFloat(min(1, presentation.minutes / scaleMaximum))))
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

    private var trailing: some View {
        Text(trailingText)
            .font(StrandFont.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(trailingColor)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        name
                        Spacer(minLength: NoopMetrics.space2)
                        trailing
                    }
                    bar
                }
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    name.frame(width: nameWidth, alignment: .leading)
                    bar
                    trailing.frame(width: trailingWidth, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHeld)
        .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 24, perform: { onHold(true) },
                            onPressingChanged: { pressing in if !pressing { onHold(false) } })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Collapsed rows

/// A one-line read that opens on tap to its explanation: a tinted symbol, the label over the primary value, an
/// optional delta with a caption on the right, and a chevron. The explanation animates open (Reduce Motion: no
/// animation). `spokenSummary` replaces the default VoiceOver reading when the on-screen text would be misread.
struct SleepExpandableRow<Detail: View>: View {
    let systemImage: String
    let tint: DomainTint
    let label: LocalizedStringKey
    let value: String
    var delta: String? = nil
    var deltaCaption: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var spokenSummary: String? = nil
    @ViewBuilder var detail: () -> Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isExpanded = false

    private var deltaBlock: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
            if let delta {
                Text(delta).font(StrandFont.bodyNumber).foregroundStyle(deltaColor).lineLimit(1)
            }
            if let deltaCaption {
                Text(deltaCaption).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            }
        }
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Text(value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            if !typeSize.isAccessibilitySize { deltaBlock }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Button {
                if reduceMotion { isExpanded.toggle() } else { withAnimation(StrandMotion.press) { isExpanded.toggle() } }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    if typeSize.isAccessibilitySize { deltaBlock }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(verbatim: spokenSummary ?? [value, delta, deltaCaption].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(isExpanded ? "Hides the details" : "Shows the details")
            if isExpanded {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) { detail() }
                    .padding(.leading, 30 + NoopMetrics.space3)
                    .padding(.bottom, NoopMetrics.space2)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Chip flow

/// Chips left to right, wrapping between chips and within a chip that exceeds the available width.
struct SleepChipFlow: Layout {
    var spacing: CGFloat

    struct Geometry {
        struct Item {
            let origin: CGPoint
            let proposedWidth: CGFloat
        }
        let items: [Item]
        let size: CGSize

        init(width: CGFloat?, spacing: CGFloat, count: Int, measure: (Int, CGFloat?) -> CGSize) {
            let availableWidth = width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? .infinity
            var items: [Item] = []
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
            for index in 0..<count {
                let ideal = measure(index, nil)
                var proposedWidth = min(ideal.width, availableWidth)
                var measured = measure(index, proposedWidth)
                // Native text layout can round a constrained chip one pixel wider. Re-measure its
                // actual content once with that overflow removed, retaining the new wrapped height.
                if measured.width > availableWidth {
                    proposedWidth = max(0, proposedWidth - (measured.width - availableWidth))
                    measured = measure(index, proposedWidth)
                }
                if x > 0, x + measured.width > availableWidth {
                    x = 0; y += rowHeight + spacing; rowHeight = 0
                }
                items.append(Item(origin: CGPoint(x: x, y: y), proposedWidth: proposedWidth))
                x += measured.width + spacing
                maxX = max(maxX, x - spacing)
                rowHeight = max(rowHeight, measured.height)
            }
            self.items = items
            size = CGSize(width: maxX, height: y + rowHeight)
        }
    }

    private func geometry(_ subviews: Subviews, width: CGFloat?) -> Geometry {
        Geometry(width: width, spacing: spacing, count: subviews.count) { index, proposedWidth in
            subviews[index].sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        geometry(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = geometry(subviews, width: bounds.width)
        for (subview, item) in zip(subviews, layout.items) {
            subview.place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                          proposal: ProposedViewSize(width: item.proposedWidth, height: nil))
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

    /// The strip's layout as pure numbers: one scale for both directions, with the centre line where the biggest
    /// surplus and the biggest deficit leave room for each, so a fortnight of debt does not draw an empty half
    /// above its bars.
    struct Geometry: Equatable {
        let height: CGFloat
        let mid: CGFloat
        let perMinute: CGFloat

        init(minutes: [Double], height: CGFloat) {
            let up = max(minutes.filter { $0 > 0 }.max() ?? 0, 0)
            let down = max(minutes.filter { $0 < 0 }.map { -$0 }.max() ?? 0, 0)
            self.height = height
            perMinute = (height - 2) / CGFloat(max(up + down, 1))
            mid = min(max(CGFloat(up) * perMinute + 1, 6), height - 6)
        }

        /// A night's bar length: at least 3pt so a small night is still there, never past its side of the strip.
        func barHeight(for minutes: Double) -> CGFloat {
            let room = minutes >= 0 ? mid - 2 : height - mid - 2
            return min(room, max(3, CGFloat(abs(minutes)) * perMinute))
        }
    }

    var body: some View {
        let finalGeometry = reduceMotion || revealed
        GeometryReader { proxy in
            let layout = Geometry(minutes: nights.map(\.minutes), height: proxy.size.height)
            let count = max(nights.count, 1)
            let slot = proxy.size.width / CGFloat(count)
            let barWidth = max(3, min(slot * 0.55, 14))
            ZStack(alignment: .topLeading) {
                Rectangle().fill(StrandPalette.hairlineStrong).frame(height: 1)
                    .position(x: proxy.size.width / 2, y: layout.mid)
                ForEach(Array(nights.enumerated()), id: \.element.id) { index, night in
                    let height = finalGeometry ? layout.barHeight(for: night.minutes) : 3
                    RoundedRectangle(cornerRadius: min(3, barWidth / 2), style: .continuous)
                        .fill(night.minutes >= 0 ? DomainTint.sleep.accent : StrandPalette.statusWarning)
                        .frame(width: barWidth, height: height)
                        .position(x: slot * CGFloat(index) + slot / 2,
                                  y: night.minutes >= 0 ? layout.mid - height / 2 : layout.mid + height / 2)
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

// MARK: - Presentation rules

/// The Sleep score's state band, decided on the whole number the dial shows (so 49.6 reads "50", which is Fair).
enum SleepScoreBand: Equatable {
    case poor, fair, good, optimal

    init(score: Double) {
        switch score.rounded() {
        case ..<50: self = .poor
        case ..<70: self = .fair
        case ..<85: self = .good
        default: self = .optimal
        }
    }
}

/// Whole-number shares of a night that add up to exactly 100: each share is rounded down, then the stages with the
/// biggest remainders take the leftover points, so four stages never read 99% or 101% in total.
enum SleepStageShares {
    static func percents(minutes: [Double]) -> [Int] {
        let clamped = minutes.map { max(0, $0) }
        let total = clamped.reduce(0, +)
        guard total > 0 else { return clamped.map { _ in 0 } }
        let exact = clamped.map { $0 / total * 100 }
        var floors = exact.map { Int($0.rounded(.down)) }
        var leftover = 100 - floors.reduce(0, +)
        let order = exact.indices.sorted {
            let a = exact[$0] - Double(floors[$0]), b = exact[$1] - Double(floors[$1])
            return a != b ? a > b : $0 < $1
        }
        for index in order where leftover > 0 && clamped[index] > 0 {
            floors[index] += 1
            leftover -= 1
        }
        return floors
    }
}

/// A recorded total for this exact displayed night. It remains useful when V2's component series are absent.
struct SleepNeedFallbackPresentation: Equatable {
    enum Source: Equatable { case onDevice, whoop }
    let wakeDay: String
    let minutes: Double
    let source: Source

    static func resolve(wakeDay: String, onDevice: (String) -> Double?,
                        imported: (String) -> Double?) -> Self? {
        if let minutes = onDevice(wakeDay), minutes.isFinite, minutes > 0 {
            return Self(wakeDay: wakeDay, minutes: minutes, source: .onDevice)
        }
        if let minutes = imported(wakeDay), minutes.isFinite, minutes > 0 {
            return Self(wakeDay: wakeDay, minutes: minutes, source: .whoop)
        }
        return nil
    }

    static func shouldShow(mode: SleepPerformanceV2Prefs.Mode, breakdownDay: String?, wakeDay: String) -> Bool {
        !SleepNeedBreakdownVisibility.isVisible(mode: mode) || breakdownDay != wakeDay
    }
}

/// Off retains the recorded total without V2 component UI or component reads. Shadow/on may show the breakdown.
enum SleepNeedBreakdownVisibility {
    static func isVisible(mode: SleepPerformanceV2Prefs.Mode) -> Bool {
        switch mode {
        case .off: return false
        case .shadow, .on: return true
        }
    }
}
