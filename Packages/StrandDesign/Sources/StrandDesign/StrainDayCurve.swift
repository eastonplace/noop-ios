import SwiftUI

// MARK: - Through the day
//
// The cardio part of today's Strain as it builds up: a monotone curve on the fixed 0...21 scale, the target band behind
// it, each workout lit along the curve, a marker at "now". The curve is the cardio component only (the day's score is
// the largest of cardio, steps and energy), so a day whose score comes from steps ends below the score and says so
// with a dashed connector. The view takes plain values and already localized text; the app owns what the words say.

/// One point of the curve: the cardio load (0...21) as of `t`.
public struct StrainCurvePoint: Equatable, Sendable {
    public let t: Date
    public let value: Double

    public init(t: Date, value: Double) {
        self.t = t
        self.value = value
    }
}

/// A workout, lit along the curve between its start and end.
public struct StrainCurveSegment: Equatable, Identifiable, Sendable {
    public let id: Int
    public let start: Date
    public let end: Date
    /// SF Symbol of the sport.
    public let symbol: String

    public init(id: Int, start: Date, end: Date, symbol: String) {
        self.id = id
        self.start = start
        self.end = end
        self.symbol = symbol
    }
}

/// Where the day's score sits when it is not the curve's own end (steps or energy set it): a dashed connector from the
/// end of the curve up to `value`, with `label` beside it.
public struct StrainCurveScoreMarker: Equatable, Sendable {
    public let value: Double
    public let label: String

    public init(value: Double, label: String) {
        self.value = value
        self.label = label
    }
}

/// The plain geometry of the curve, kept free of SwiftUI state so it can be tested and cached.
struct StrainCurveGeometry: Equatable {
    static let axisMaximum = 21.0
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 8

    let size: CGSize
    let domain: ClosedRange<Date>

    func x(_ date: Date) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let unit = span > 0 ? min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1) : 0.5
        return Self.horizontalInset + CGFloat(unit) * max(size.width - 2 * Self.horizontalInset, 1)
    }

    func y(_ value: Double) -> CGFloat {
        let unit = min(max(value / Self.axisMaximum, 0), 1)
        return Self.verticalInset + CGFloat(1 - unit) * max(size.height - 2 * Self.verticalInset, 1)
    }

    /// The date under a horizontal position, clamped to the domain.
    func date(atX x: CGFloat) -> Date {
        let width = max(size.width - 2 * Self.horizontalInset, 1)
        let unit = Double(min(max((x - Self.horizontalInset) / width, 0), 1))
        return domain.lowerBound.addingTimeInterval(unit * domain.upperBound.timeIntervalSince(domain.lowerBound))
    }

    /// Index of the point nearest in time to `date` (`points` sorted by time, not empty).
    static func nearestIndex(to date: Date, in points: [StrainCurvePoint]) -> Int {
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].t < date { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return 0 }
        let before = points[low - 1], after = points[low]
        return date.timeIntervalSince(before.t) <= after.t.timeIntervalSince(date) ? low - 1 : low
    }
}

public struct StrainDayCurve: View {
    private let points: [StrainCurvePoint]
    private let domain: ClosedRange<Date>
    private let ticks: [Date]
    private let target: ClosedRange<Double>?
    private let segments: [StrainCurveSegment]
    private let now: Date?
    private let seedNote: String?
    private let scoreMarker: StrainCurveScoreMarker?
    private let targetLabel: String
    private let valueFormat: (Double) -> String
    private let timeLabel: (Date) -> String
    private let readoutCaption: (Date?) -> String
    private let spokenReading: (StrainCurvePoint) -> String
    private let summary: String
    private let hint: String

    private let layoutToken: Int
    private let tint = DomainTint.strain.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Label offsets and width guesses are in points at the default size; this scales them with `.caption2`, the type
    /// the labels are set in.
    @ScaledMetric(relativeTo: .caption2) private var scaledLabelUnit: CGFloat = 1
    private var labelUnit: CGFloat { typeSize.isAccessibilitySize ? scaledLabelUnit : 1 }
    @State private var revealed = false
    @State private var scrubIndex: Int?
    @State private var plotWidth: CGFloat = 1
    @State private var layoutCache = StrainCurveLayoutCache()
    @State private var adjustReset: Task<Void, Never>?

    private static let plotHeight: CGFloat = 164

    /// At accessibility sizes the labels no longer fit inside a 164 pt plot: the seed note and the score label move out
    /// of it into captions that wrap, the scale numbers and the target word go (the band itself and the Target figure
    /// on the screen above name them), and the time axis keeps its two ends.
    private var roomyLabels: Bool { typeSize.isAccessibilitySize }
    private var visibleTicks: [Date] {
        guard roomyLabels, ticks.count > 2, let first = ticks.first, let last = ticks.last else { return ticks }
        return [first, last]
    }

    /// - Parameters:
    ///   - points: the curve, oldest first (at least two to draw).
    ///   - domain: the time span of the plot (wake to now, say).
    ///   - ticks: where the time labels sit; four or fewer.
    ///   - now: the live edge, or nil on a past day.
    ///   - seedNote: what the curve starts from ("4.0 from sleep"), shown at its start.
    ///   - targetLabel: the word written in the target band.
    ///   - readoutCaption: the caption under the reading: the idle one for nil, one for a scrubbed time otherwise.
    ///   - spokenReading: what VoiceOver says for a point.
    public init(
        points: [StrainCurvePoint],
        domain: ClosedRange<Date>,
        ticks: [Date],
        target: ClosedRange<Double>?,
        segments: [StrainCurveSegment],
        now: Date?,
        seedNote: String?,
        scoreMarker: StrainCurveScoreMarker?,
        targetLabel: String,
        valueFormat: @escaping (Double) -> String,
        timeLabel: @escaping (Date) -> String,
        readoutCaption: @escaping (Date?) -> String,
        spokenReading: @escaping (StrainCurvePoint) -> String,
        summary: String,
        hint: String
    ) {
        self.points = points.sorted { $0.t < $1.t }
        self.domain = domain
        self.ticks = Array(ticks.prefix(WidgetMetrics.maxXAxisLabels))
        self.target = target
        self.segments = segments
        self.now = now
        self.seedNote = seedNote
        self.scoreMarker = scoreMarker
        self.targetLabel = targetLabel
        self.valueFormat = valueFormat
        self.timeLabel = timeLabel
        self.readoutCaption = readoutCaption
        self.spokenReading = spokenReading
        self.summary = summary
        self.hint = hint

        var hasher = Hasher()
        hasher.combine(points.count)
        hasher.combine(points.first?.t)
        hasher.combine(points.last?.t)
        hasher.combine(points.last?.value)
        hasher.combine(domain.lowerBound)
        hasher.combine(domain.upperBound)
        hasher.combine(target?.lowerBound)
        hasher.combine(target?.upperBound)
        for segment in segments {
            hasher.combine(segment.id)
            hasher.combine(segment.start)
            hasher.combine(segment.end)
        }
        hasher.combine(now)
        hasher.combine(scoreMarker?.value)
        hasher.combine(seedNote)
        self.layoutToken = hasher.finalize()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            readout
            VStack(alignment: .leading, spacing: 6) {
                plot.frame(height: Self.plotHeight)
                axisLabels
            }
            if roomyLabels { captions }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(0.05)) { revealed = true }
        }
    }

    // MARK: Readout

    private var shownPoint: StrainCurvePoint? {
        if let scrubIndex, points.indices.contains(scrubIndex) { return points[scrubIndex] }
        return points.last
    }

    private var readout: some View {
        HeroValue(
            value: shownPoint.map { valueFormat($0.value) } ?? WidgetMetrics.missingValue,
            caption: readoutCaption(scrubIndex.flatMap { points.indices.contains($0) ? points[$0].t : nil }),
            captionPlacement: .below,
            size: 28
        )
        .animation(StrandMotion.fade, value: scrubIndex)
    }

    /// The seed note and the score label, below the plot where they can take the room their type needs.
    @ViewBuilder
    private var captions: some View {
        if seedNote != nil || scoreMarker != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let seedNote {
                    Text(verbatim: seedNote)
                }
                if let scoreMarker {
                    Text(verbatim: scoreMarker.label)
                }
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            layers(size: proxy.size)
                .contentShape(Rectangle())
                .modifier(TrendsScrubModifier(onScrub: { scrub(at: $0) }, onEnd: { endScrub() }))
                .onAppear { plotWidth = proxy.size.width }
                .onChangeCompat(of: proxy.size.width) { plotWidth = $0 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: summary))
        .accessibilityValue(Text(verbatim: scrubIndex.flatMap { points.indices.contains($0) ? spokenReading(points[$0]) : nil } ?? ""))
        .accessibilityHint(Text(verbatim: hint))
        .accessibilityAdjustableAction { direction in
            guard !points.isEmpty else { return }
            let stride = max(points.count / 24, 1)
            let current = scrubIndex ?? (points.count - 1)
            switch direction {
            case .increment: scrubIndex = min(current + stride, points.count - 1)
            case .decrement: scrubIndex = max(current - stride, 0)
            default: break
            }
            scheduleAdjustReset()
        }
        .onDisappear { adjustReset?.cancel() }
    }

    private func scheduleAdjustReset() {
        adjustReset?.cancel()
        adjustReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(StrandMotion.interactive) { scrubIndex = nil }
        }
    }

    private func scrub(at location: CGPoint) {
        guard plotWidth > 0, points.count >= 2 else { return }
        let geometry = StrainCurveGeometry(size: CGSize(width: plotWidth, height: Self.plotHeight), domain: domain)
        let index = StrainCurveGeometry.nearestIndex(to: geometry.date(atX: location.x), in: points)
        guard index != scrubIndex else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrubIndex = index }
        StrandHaptic.selection.play()
    }

    private func endScrub() {
        guard scrubIndex != nil else { return }
        withAnimation(StrandMotion.interactive) { scrubIndex = nil }
    }

    @ViewBuilder
    private func layers(size: CGSize) -> some View {
        let geometry = StrainCurveGeometry(size: size, domain: domain)
        let layout = layoutCache.layout(size: size, token: layoutToken &+ Int(labelUnit * 100)) { makeLayout(geometry) }

        ZStack {
            // The target band: a quiet wash, named once on the leading edge above the curve's start.
            if let band = layout.targetRect {
                Rectangle()
                    .fill(StrandPalette.statusPositive.opacity(0.10))
                    .frame(width: size.width, height: band.height)
                    .position(x: size.width / 2, y: band.midY)
                if let spot = layout.targetLabelSpot, !roomyLabels {
                    Text(verbatim: targetLabel)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .position(spot)
                }
            }

            // Rails at 7, 14 and 21, labelled on the leading edge.
            ForEach(layout.rails, id: \.value) { rail in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: rail.y))
                    path.addLine(to: CGPoint(x: size.width, y: rail.y))
                }
                .stroke(StrandPalette.hairline.opacity(0.9), style: StrokeStyle(lineWidth: 0.7))
            }

            // Each workout: a shaded column behind the curve (the glyph sits at its top). The curve is one stroke.
            ForEach(layout.segments) { segment in
                Rectangle()
                    .fill(tint.opacity(0.13))
                    .frame(width: segment.rect.width, height: size.height)
                    .position(x: segment.rect.midX, y: size.height / 2)
            }

            if points.count >= 2 {
                layout.area
                    .fill(LinearGradient(colors: [tint.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                    .opacity(revealed ? 1 : 0)
                layout.line
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            if !roomyLabels {
                ForEach(layout.rails, id: \.value) { rail in
                    Text(verbatim: "\(rail.value)")
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .strainCurveKnockout()
                        .fixedSize()
                        .position(x: 12 * labelUnit, y: rail.y - 8 * labelUnit)
                }
            }

            // Workout glyphs along the top of their bands.
            ForEach(layout.segments) { segment in
                if let spot = segment.iconSpot {
                    Image(systemName: segment.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .position(spot)
                        .accessibilityHidden(true)
                }
            }

            // Where the curve starts from (the sleep seed).
            if let seedNote, let start = layout.startPoint, scrubIndex == nil, !roomyLabels {
                let half = seedNoteHalfWidth(seedNote)
                Text(verbatim: seedNote)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .strainCurveKnockout()
                    .fixedSize()
                    // Kept whole inside the plot: pulled in from either edge rather than clipped.
                    .position(x: min(max(start.x + half, half + 2), max(size.width - half - 2, half)),
                              y: start.y + 14 * labelUnit < size.height - 6 ? start.y + 14 * labelUnit : max(start.y - 13 * labelUnit, 10))
            }

            // The score, when steps or energy set it: a dashed connector from the end of the curve.
            if let marker = scoreMarker, let end = layout.endPoint, scrubIndex == nil {
                let y = geometry.y(marker.value)
                Path { path in
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x, y: y))
                }
                .stroke(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 3]))
                Circle()
                    .stroke(tint, lineWidth: 1.6)
                    .background(Circle().fill(StrandPalette.appCanvas))
                    .frame(width: 9, height: 9)
                    .position(x: end.x, y: y)
                if !roomyLabels {
                    let labelWidth = max(size.width - 40, 80)
                    Text(verbatim: marker.label)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .strainCurveKnockout()
                        .frame(maxWidth: labelWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, size.width - end.x + 12)
                        .frame(width: size.width, height: size.height, alignment: .trailing)
                        .offset(y: min(max(y, 12), size.height - 12) - size.height / 2)
                }
            }

            // The live edge.
            if revealed, scrubIndex == nil, now != nil, let end = layout.endPoint {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
                    .transition(.opacity)
            }

            if let scrubIndex, points.indices.contains(scrubIndex) {
                let point = points[scrubIndex]
                let x = geometry.x(point.t)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: x, y: size.height / 2)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(x: x, y: geometry.y(point.value))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func seedNoteHalfWidth(_ text: String) -> CGFloat {
        max(24, CGFloat(text.count) * 3.1 + 6) * labelUnit
    }

    // MARK: Layout

    private func makeLayout(_ geometry: StrainCurveGeometry) -> StrainCurveLayout {
        let rendered = points.map { CGPoint(x: geometry.x($0.t), y: geometry.y($0.value)) }
        var line = Path()
        var area = Path()
        if rendered.count >= 2 {
            TrendCurve.append(rendered, to: &line)
            TrendCurve.append(rendered, to: &area)
            if let first = rendered.first, let last = rendered.last {
                area.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                area.addLine(to: CGPoint(x: first.x, y: geometry.size.height))
                area.closeSubpath()
            }
        }
        let rails = [7, 14, 21].map { StrainCurveLayout.Rail(value: $0, y: geometry.y(Double($0))) }

        var targetRect: CGRect?
        var targetLabelSpot: CGPoint?
        if let target {
            let top = geometry.y(target.upperBound)
            let bottom = geometry.y(target.lowerBound)
            if bottom > top {
                let rect = CGRect(x: 0, y: top, width: geometry.size.width, height: bottom - top)
                targetRect = rect
                // At the trailing edge, just inside the band's top, unless the curve gets there first.
                let label = CGPoint(x: geometry.size.width - 30 * labelUnit, y: top + 9 * labelUnit)
                let end = rendered.last
                let collides = end.map { $0.y < top + 20 * labelUnit && $0.x > geometry.size.width - 70 * labelUnit } ?? false
                targetLabelSpot = collides ? CGPoint(x: geometry.size.width * 0.5, y: top + 9 * labelUnit) : label
            }
        }

        var segmentLayouts: [StrainCurveLayout.Segment] = []
        var lastIcon: CGFloat = -100
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let x0 = geometry.x(max(segment.start, geometry.domain.lowerBound))
            let x1 = geometry.x(min(segment.end, geometry.domain.upperBound))
            guard segment.end > geometry.domain.lowerBound, segment.start < geometry.domain.upperBound, x1 > x0 else { continue }
            let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 2), height: geometry.size.height)
            var icon: CGPoint?
            if rect.width >= 14, rect.midX - lastIcon >= 18 {
                icon = CGPoint(x: rect.midX, y: 9)
                lastIcon = rect.midX
            }
            segmentLayouts.append(.init(id: segment.id, symbol: segment.symbol, rect: rect, iconSpot: icon))
        }

        return StrainCurveLayout(
            line: line, area: area, rails: rails, targetRect: targetRect, targetLabelSpot: targetLabelSpot,
            segments: segmentLayouts, startPoint: rendered.first, endPoint: rendered.last)
    }

    // MARK: Axis labels

    private var axisLabels: some View {
        GeometryReader { proxy in
            let geometry = StrainCurveGeometry(size: CGSize(width: proxy.size.width, height: 1), domain: domain)
            ZStack(alignment: .topLeading) {
                ForEach(Array(visibleTicks.enumerated()), id: \.offset) { index, tick in
                    Text(verbatim: timeLabel(tick))
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .frame(width: 0, alignment: alignment(for: index, of: visibleTicks.count))
                        .offset(x: geometry.x(tick))
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .frame(height: 16 * labelUnit)
        .accessibilityHidden(true)
    }

    private func alignment(for index: Int, of count: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == count - 1 { return .trailing }
        return .center
    }
}

/// The static layers of the plot in its own coordinates.
struct StrainCurveLayout {
    struct Rail { let value: Int; let y: CGFloat }
    struct Segment: Identifiable {
        let id: Int
        let symbol: String
        let rect: CGRect
        let iconSpot: CGPoint?
    }

    let line: Path
    let area: Path
    let rails: [Rail]
    let targetRect: CGRect?
    let targetLabelSpot: CGPoint?
    let segments: [Segment]
    let startPoint: CGPoint?
    let endPoint: CGPoint?
}

/// Remembers the last layout so a scrub, which redraws the plot on every step, does not rebuild it.
final class StrainCurveLayoutCache {
    private struct Key: Equatable {
        let size: CGSize
        let token: Int
    }

    private var key: Key?
    private var stored: StrainCurveLayout?

    func layout(size: CGSize, token: Int, make: () -> StrainCurveLayout) -> StrainCurveLayout {
        let wanted = Key(size: size, token: token)
        if let stored, key == wanted { return stored }
        let made = make()
        key = wanted
        stored = made
        return made
    }
}

private extension View {
    /// A canvas plate behind a label, so a line that passes under it reads as passing behind it.
    func strainCurveKnockout() -> some View {
        self.background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.appCanvas.opacity(0.88))
                .padding(.horizontal, -3)
                .padding(.vertical, -1)
        }
    }
}
