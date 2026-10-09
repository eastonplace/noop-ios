import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Heart Rate (NOOP scope, data-rich tier)
//
// The Deep-Timeline HR chart rebuilt in the Sleep/Stress paper dialect: a custom SwiftUI
// `Path` (deliberately not Swift Charts, mirroring StressLoadChart's rationale) so the
// gradient stroke, dashed hairline grid, reveal animation, and quiet chrome match the
// production SleepStressComponents exactly. Interactions replicate the production
// OverviewHRChart contract — pinch zooms about the window centre, drag pans, double-tap
// resets, touch-and-hold scrubs a crosshair readout — via the same pure zoom/pan math,
// re-stated here over plain TimeInterval ranges so the component stays fixture-only.
// Zone semantics ride a calm→steady→push ramp exactly like StressLoadStyle's band ramp.

// MARK: Zone style (mirrors StressLoadStyle)

public enum HRZoneStyle {
    public static let rest = StrandPalette.accent
    public static let steady = StrandPalette.statusPositive
    public static let push = StrandPalette.metricRose

    /// Fixed bpm scale the semantic ramp is anchored to (the visible chart re-projects it).
    public static let floor: Double = 40
    public static let ceiling: Double = 180
    /// Band boundaries for the legend / time-in-zone rows.
    public static let restCeiling: Double = 60
    public static let steadyCeiling: Double = 110

    public static let stops: [Gradient.Stop] = [
        .init(color: rest, location: 0),
        .init(color: rest, location: unit(52)),
        .init(color: steady, location: unit(85)),
        .init(color: steady, location: unit(102)),
        .init(color: push, location: unit(140)),
        .init(color: push, location: 1),
    ]

    public static func unit(_ bpm: Double) -> Double {
        min(max((bpm - floor) / (ceiling - floor), 0), 1)
    }

    public static func color(for bpm: Double) -> Color {
        StrandPalette.sample(stops: stops, at: unit(bpm))
    }

    /// 0 rest · 1 steady · 2 push.
    public static func zone(for bpm: Double) -> Int {
        if bpm < restCeiling { return 0 }
        if bpm < steadyCeiling { return 1 }
        return 2
    }

    public static func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 0: rest
        case 1: steady
        default: push
        }
    }
}

// MARK: Value types

public struct HRTrackPoint: Identifiable, Equatable {
    public let id: Int
    /// Seconds from the day's midnight.
    public let t: TimeInterval
    public let bpm: Double
}

public struct HRSleepBand: Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let label: String
}

public struct HRWorkoutMark: Identifiable, Equatable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let symbol: String
}

// MARK: Heart ink (the Live HR module's live-red ramp)

private enum HRTimelineInk {
    static let rest = StrandPalette.liveRed.opacity(0.58)
    static let steady = StrandPalette.liveRed
    static let push = StrandPalette.destructive
    static let live = StrandPalette.liveRed

    static func color(for bpm: Double) -> Color {
        StrandPalette.sample(stops: stops, at: HRZoneStyle.unit(bpm))
    }

    private static let stops: [Gradient.Stop] = [
        .init(color: rest, location: 0),
        .init(color: rest, location: HRZoneStyle.unit(58)),
        .init(color: steady, location: HRZoneStyle.unit(92)),
        .init(color: steady, location: HRZoneStyle.unit(112)),
        .init(color: push, location: HRZoneStyle.unit(142)),
        .init(color: push, location: 1),
    ]
}

// MARK: - HRTimelineChart

public struct HRTimelineChart: View {
    let points: [HRTrackPoint]
    /// The full-day clamp the zoom window can never escape.
    let day: ClosedRange<TimeInterval>
    var sleep: HRSleepBand? = nil
    var workouts: [HRWorkoutMark] = []
    let timeLabel: (TimeInterval) -> String
    /// Metric identity for the header + VoiceOver lead ("Heart rate", "HRV", …).
    var title: String = "Heart rate"
    /// nil = the HR zone ramp; a flat metric tint otherwise (the Deep Timeline colour contract).
    var tint: Color? = nil
    var unit: String = "bpm"
    var valueFormat: (Double) -> String = { ComponentValueFormat.rounded($0) }
    /// The zone legend only speaks for the zone-ramped HR track.
    var showsZoneLegend: Bool = true

    /// Smallest zoom window (the fixture samples every 2 minutes; below ~10 the line is a handful
    /// of points and pinch jitters — same floor rationale as OverviewHRChart.minZoomSpan).
    static let minZoomSpan: TimeInterval = 10 * 60

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var zoomDomainBinding: Binding<ClosedRange<TimeInterval>?>? = nil
    var zoomBounds: ClosedRange<TimeInterval>? = nil
    var onSettledWindow: (ClosedRange<TimeInterval>?) -> Void = { _ in }
    @State private var localZoomDomain: ClosedRange<TimeInterval>? = nil
    /// The window a one-finger pan started from, and the window a pinch started from. They are separate because
    /// a pinch can begin while a pan is still ending (the second finger lands): each scales off its own start,
    /// never off the other's, so the window never jumps between them.
    @State private var panAnchor: ClosedRange<TimeInterval>? = nil
    @State private var pinchAnchor: ClosedRange<TimeInterval>? = nil
    @State private var plotWidth: CGFloat = 1
    @State private var scrubTime: TimeInterval? = nil
    @State private var scrubEngaged = false
    /// Where VoiceOver's adjustable stepping has got to (nil = the latest reading). Never drawn.
    @State private var spokenTime: TimeInterval? = nil
    @State private var revealed = false

    public var body: some View {
        let frame = makeFrame()
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            heroRow(frame)
            VStack(alignment: .leading, spacing: 6) {
                plot(frame)
                    .frame(height: 176)
                timeAxis(frame.window)
            }
            hintRow
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85).delay(0.1)) {
                revealed = true
            }
        }
    }

    // MARK: Window / data

    private var zoomDomain: ClosedRange<TimeInterval>? {
        get { zoomDomainBinding?.wrappedValue ?? localZoomDomain }
        nonmutating set {
            if let zoomDomainBinding {
                zoomDomainBinding.wrappedValue = newValue
            } else {
                localZoomDomain = newValue
            }
        }
    }

    private var interactionBounds: ClosedRange<TimeInterval> { zoomBounds ?? day }
    private var window: ClosedRange<TimeInterval> { zoomDomain ?? day }
    private var dayLength: TimeInterval { day.upperBound - day.lowerBound }

    /// Everything one render needs from the visible window, computed once per body (a scrub or a pan frame used
    /// to rescan the samples a dozen times: for the line, the range, the peak, the readout, the rails).
    private struct Frame {
        let window: ClosedRange<TimeInterval>
        /// The drawn line: the visible samples plus one neighbour either side so it runs to the plot edges, thinned
        /// to ~420 points however far in (the trick Repository.timelineSeries plays with SQL buckets).
        let line: [HRTrackPoint]
        /// The samples that lie inside the window. The readout, the peak bead and the scrub dot all read these, so a
        /// neighbour just outside the window can never be reported as "latest" or drawn off the plot.
        let inView: [HRTrackPoint]
        /// Padded to the visible extent so zooming into the night re-scales honestly.
        let yRange: ClosedRange<Double>
        let peak: HRTrackPoint?
    }

    private func makeFrame() -> Frame {
        let window = self.window
        guard !points.isEmpty else {
            return Frame(window: window, line: [], inView: [], yRange: defaultYRange, peak: nil)
        }
        let first = points.firstIndex(where: { $0.t >= window.lowerBound })
        let last = points.lastIndex(where: { $0.t <= window.upperBound })
        let inView: [HRTrackPoint]
        if let first, let last, first <= last { inView = Array(points[first...last]) } else { inView = [] }

        var lo = (first ?? points.count - 1)
        var hi = (last ?? 0)
        lo = max(0, lo - 1)
        hi = min(points.count - 1, hi + 1)
        let raw = lo <= hi ? Array(points[lo...hi]) : []

        let maxRendered = 420
        let line: [HRTrackPoint]
        if raw.count > maxRendered {
            let step = Double(raw.count - 1) / Double(maxRendered - 1)
            line = (0..<maxRendered).map { raw[Int((Double($0) * step).rounded())] }
        } else {
            line = raw
        }

        // The range comes from every visible sample, not the thinned line, so the peak is always inside the plot.
        var yRange = defaultYRange
        if let low = raw.map(\.bpm).min(), let high = raw.map(\.bpm).max(), high > low {
            let pad = (high - low) * 0.14
            yRange = max(30, low - pad)...(high + pad)
        }
        return Frame(window: window, line: line, inView: inView, yRange: yRange,
                     peak: inView.max(by: { $0.bpm < $1.bpm }))
    }

    private var defaultYRange: ClosedRange<Double> { tint == nil ? 40...120 : 0...1 }

    /// The sample nearest `time`, among those in view.
    private func nearest(to time: TimeInterval, in frame: Frame) -> HRTrackPoint? {
        frame.inView.min(by: { abs($0.t - time) < abs($1.t - time) })
    }

    private func scrubSample(_ frame: Frame) -> HRTrackPoint? {
        scrubTime.flatMap { nearest(to: $0, in: frame) }
    }

    // MARK: Zoom / pan math (pure — mirrors OverviewHRChart.zoomed/panned over TimeInterval)

    /// `maxSpan` caps how far a pinch-out can go (the chart passes the day's length, so zooming out stops at the
    /// whole day however wide the pan range is); nil falls back to the width of `bounds`.
    static func zoomed(
        _ base: ClosedRange<TimeInterval>, scale: Double, anchorFraction: Double,
        bounds: ClosedRange<TimeInterval>, minSpan: TimeInterval = minZoomSpan,
        maxSpan: TimeInterval? = nil
    ) -> ClosedRange<TimeInterval> {
        let span = base.upperBound - base.lowerBound
        guard span > 0, scale > 0 else { return base }
        let pivot = base.lowerBound + span * min(max(anchorFraction, 0), 1)
        let boundsSpan = bounds.upperBound - bounds.lowerBound
        let ceiling = max(min(maxSpan ?? boundsSpan, boundsSpan), minSpan)
        let newSpan = min(max(span / scale, minSpan), ceiling)
        var newLo = pivot - (pivot - base.lowerBound) * (newSpan / span)
        var newHi = newLo + newSpan
        if newLo < bounds.lowerBound { newLo = bounds.lowerBound; newHi = newLo + newSpan }
        if newHi > bounds.upperBound { newHi = bounds.upperBound; newLo = newHi - newSpan }
        newLo = max(newLo, bounds.lowerBound)
        return newLo...max(newLo + 1, newHi)
    }

    static func panned(
        _ base: ClosedRange<TimeInterval>, delta: TimeInterval,
        bounds: ClosedRange<TimeInterval>
    ) -> ClosedRange<TimeInterval> {
        let span = base.upperBound - base.lowerBound
        var newLo = base.lowerBound + delta
        newLo = min(max(newLo, bounds.lowerBound), bounds.upperBound - span)
        newLo = max(newLo, bounds.lowerBound)
        return newLo...(newLo + span)
    }

    // MARK: Chrome

    /// The Live HR module's hero: the number big with its unit, the time it was read under it, and (for heart
    /// rate) the zone word on the shared pill. Hold and drag on the plot morphs it into the reading under the
    /// finger, the way the Trends hero chart reads a day. The reading is the sample under the finger, else the
    /// last reading in view. At accessibility text sizes the pill drops under the number instead of squeezing it.
    private func heroRow(_ frame: Frame) -> some View {
        let scrub = scrubSample(frame)
        let shown = scrub ?? frame.inView.last
        let value = HeroValue(
            value: shown.map { valueFormat($0.bpm) } ?? WidgetMetrics.missingValue,
            unit: shown == nil || unit.isEmpty ? nil : unit,
            caption: heroCaption(shown, scrubbing: scrub != nil),
            captionPlacement: .below
        )
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                value
                Spacer(minLength: NoopMetrics.space2)
                heroPill(shown)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                value
                heroPill(shown)
            }
        }
        .animation(StrandMotion.fade, value: scrub?.id)
    }

    @ViewBuilder
    private func heroPill(_ sample: HRTrackPoint?) -> some View {
        if showsZoneLegend, let sample {
            ValuePill(zoneWord(sample.bpm), tint: HRTimelineInk.live)
        }
    }

    private func heroCaption(_ sample: HRTrackPoint?, scrubbing: Bool) -> String? {
        guard let sample else { return nil }
        return scrubbing
            ? timeLabel(sample.t)
            : String(localized: "latest · \(timeLabel(sample.t))")
    }

    private func zoneWord(_ bpm: Double) -> String {
        switch HRZoneStyle.zone(for: bpm) {
        case 0: return String(localized: "Resting")
        case 1: return String(localized: "Steady")
        default: return String(localized: "Pushing")
        }
    }

    private func timeAxis(_ win: ClosedRange<TimeInterval>) -> some View {
        HStack(spacing: 0) {
            Text(timeLabel(win.lowerBound)).frame(maxWidth: .infinity, alignment: .leading)
            Text(timeLabel((win.lowerBound + win.upperBound) / 2)).frame(maxWidth: .infinity, alignment: .center)
            Text(timeLabel(win.upperBound)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(StrandFont.micro)
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
    }

    /// Names the gestures (a hidden gesture nobody tries is a feature that doesn't exist) and
    /// carries the explicit Reset alongside the double-tap, mirroring the Deep Timeline's hint row.
    private var hintRow: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: zoomDomain == nil
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            if zoomDomain == nil {
                Text("Pinch to zoom · drag to pan · hold to read")
            } else {
                Text("Zoomed in · drag to pan · double-tap to reset")
            }
            Spacer(minLength: NoopMetrics.space2)
            if zoomDomain != nil {
                Button { resetZoom() } label: {
                    WidgetChip(appTitle: "Reset", showsChevron: false, overhangs: false).chipHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Reset zoom"))
            }
        }
        .font(StrandFont.micro)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Plot

    private func plot(_ frame: Frame) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            plotTouch(plotLayers(size: size, frame: frame).contentShape(Rectangle()))
                .onAppear { plotWidth = size.width }
                .onChangeCompat(of: size.width) { plotWidth = $0 }
        }
        .frame(maxWidth: .infinity)
        // One collapsed VoiceOver element: a summary of the window in view, a reading VoiceOver steps through with
        // swipe up/down, and named actions for the pinch and the double tap. Never a mark-by-mark walk.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(frame))
        .accessibilityValue(spokenReading(frame))
        .accessibilityAdjustableAction { direction in stepSpokenReading(direction, frame: frame) }
        .accessibilityActions {
            Button("Zoom in") { zoomForAccessibility(scale: 2) }
            Button("Zoom out") { zoomForAccessibility(scale: 0.5) }
            if zoomDomain != nil { Button("Reset zoom") { resetZoom(announcing: true) } }
        }
    }

    /// The plot's touch handling. On iOS every gesture lives on one UIKit surface so a vertical drag is the
    /// page scrolling (as it is over every other chart), a hold reads, a horizontal drag pans, two fingers
    /// zoom and a double tap resets. Elsewhere the same actions ride on SwiftUI gestures.
    @ViewBuilder
    private func plotTouch<Content: View>(_ content: Content) -> some View {
        #if canImport(UIKit)
        content.overlay(
            HRTimelineTouchSurface(
                onScrub: scrub, onScrubEnd: endScrub,
                onPan: panChanged, onPanEnd: panEnded,
                onPinch: pinchChanged, onPinchEnd: pinchEnded,
                onDoubleTap: { resetZoom() }
            )
            .accessibilityHidden(true)
        )
        #else
        content
            .modifier(TrendsScrubModifier(onScrub: scrub, onEnd: endScrub))
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(panGesture)
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() })
        #endif
    }

    @ViewBuilder
    private func plotLayers(size: CGSize, frame: Frame) -> some View {
        let win = frame.window
        let span = max(win.upperBound - win.lowerBound, 1)
        let yr = frame.yRange
        let ySpan = max(yr.upperBound - yr.lowerBound, 1)
        let xOf: (TimeInterval) -> CGFloat = { size.width * CGFloat(($0 - win.lowerBound) / span) }
        let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(($0 - yr.lowerBound) / ySpan) }
        let rendered = frame.line.map { (xOf($0.t), yOf($0.bpm)) }

        ZStack {
            sleepLayer(size: size, window: win, xOf: xOf)
            gridLayer(size: size, yRange: yr, yOf: yOf)
            // The line runs on to its off-screen neighbours; the plot's own edge is where it stops.
            lineLayer(size: size, rendered: rendered, frame: frame)
                .clipShape(Rectangle())
            workoutLayer(size: size, frame: frame, xOf: xOf, yOf: yOf)
            peakLayer(frame: frame, xOf: xOf, yOf: yOf)
            scrubLayer(size: size, frame: frame, xOf: xOf, yOf: yOf)
        }
    }

    @ViewBuilder
    private func sleepLayer(
        size: CGSize, window: ClosedRange<TimeInterval>, xOf: (TimeInterval) -> CGFloat
    ) -> some View {
        if let sleep, sleep.end > window.lowerBound, sleep.start < window.upperBound {
            let x0 = max(xOf(sleep.start), 0)
            let x1 = min(xOf(sleep.end), size.width)
            if x1 > x0 {
                Rectangle()
                    .fill(StrandPalette.sleepDeep.opacity(0.10))
                    .frame(width: x1 - x0, height: size.height)
                    .position(x: (x0 + x1) / 2, y: size.height / 2)
                if x1 - x0 > 56 {
                    let estWidth = CGFloat(sleep.label.count) * 5.5 + 8
                    Text(sleep.label)
                        .font(StrandFont.micro.weight(.semibold))
                        .foregroundStyle(StrandPalette.sleepLight)
                        .position(
                            x: min(max(x0 + estWidth / 2 + 6, estWidth / 2 + 4), x1 - estWidth / 2 - 4),
                            y: 10
                        )
                }
            }
            // Wake divider — the sleep→day boundary, same dash the production chart draws.
            if sleep.end < window.upperBound, sleep.end > window.lowerBound {
                Path { path in
                    path.move(to: CGPoint(x: xOf(sleep.end), y: 0))
                    path.addLine(to: CGPoint(x: xOf(sleep.end), y: size.height))
                }
                .stroke(StrandPalette.sleepLight.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
    }

    @ViewBuilder
    private func gridLayer(
        size: CGSize, yRange: ClosedRange<Double>, yOf: @escaping (Double) -> CGFloat
    ) -> some View {
        ForEach(gridValues(in: yRange), id: \.self) { value in
            let y = yOf(value)
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(
                StrandPalette.hairlineStrong.opacity(0.7),
                style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
            )
            // Rail labels knock the canvas out of the line, so a line that passes under one stays legible and
            // reads as passing behind it (the Live HR module's and the Trends chart's rails).
            Text(valueFormat(value))
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(StrandPalette.appCanvas.opacity(0.88))
                        .padding(.horizontal, -3)
                        .padding(.vertical, -1)
                }
                .position(x: size.width - 14, y: max(8, y - 8))
        }
    }

    /// Dashed rails at whole-bpm steps sized to the visible range (2–4 lines, never a dense grid).
    private func gridValues(in yRange: ClosedRange<Double>) -> [Double] {
        let lo = yRange.lowerBound, hi = yRange.upperBound
        let span = hi - lo
        let step = [0.25, 0.5, 1, 2, 5, 10, 20, 25, 50].first(where: { span / $0 <= 4 }) ?? 50
        var values: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v < hi { values.append(v); v += step }
        return values
    }

    @ViewBuilder
    private func lineLayer(size: CGSize, rendered: [(CGFloat, CGFloat)], frame: Frame) -> some View {
        if rendered.count >= 2 {
            areaPath(rendered, height: size.height)
                .fill(
                    // The Coach trend charts' wash: the domain ink at 14% fading to nothing.
                    LinearGradient(
                        colors: [washColor.opacity(0.14), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(revealed ? 1 : 0)
            linePath(rendered)
                .trim(from: 0, to: revealed ? 1 : 0)
                .stroke(
                    lineGradient(frame.yRange),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                )
        } else if let only = rendered.first, let sample = frame.line.first {
            Circle()
                .fill(sampleColor(sample.bpm))
                .frame(width: 7, height: 7)
                .position(x: only.0, y: only.1)
                .opacity(revealed ? 1 : 0)
        }
    }

    @ViewBuilder
    private func workoutLayer(
        size: CGSize, frame: Frame,
        xOf: @escaping (TimeInterval) -> CGFloat, yOf: @escaping (Double) -> CGFloat
    ) -> some View {
        ForEach(workouts) { workout in
            if workout.end > frame.window.lowerBound, workout.start < frame.window.upperBound,
               let peak = frame.inView
                   .filter({ $0.t >= workout.start && $0.t <= workout.end })
                   .max(by: { $0.bpm < $1.bpm }) {
                let x = min(max(xOf(peak.t), 14), size.width - 14)
                let y = max(14, yOf(peak.bpm) - 20)
                Image(systemName: workout.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(StrandPalette.surfaceRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(StrandPalette.hairlineStrong, lineWidth: 1)
                    )
                    .position(x: x, y: y)
                    .opacity(revealed ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func peakLayer(
        frame: Frame, xOf: (TimeInterval) -> CGFloat, yOf: (Double) -> CGFloat
    ) -> some View {
        if scrubTime == nil, let peak = frame.peak {
            Circle()
                .fill(sampleColor(peak.bpm))
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                .position(x: xOf(peak.t), y: yOf(peak.bpm))
                .opacity(revealed ? 1 : 0)
        }
    }

    @ViewBuilder
    private func scrubLayer(
        size: CGSize, frame: Frame, xOf: (TimeInterval) -> CGFloat, yOf: (Double) -> CGFloat
    ) -> some View {
        if let sample = scrubSample(frame) {
            let x = xOf(sample.t)
            let y = yOf(sample.bpm)
            let color = sampleColor(sample.bpm)
            RoundedRectangle(cornerRadius: 0.5)
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 1, height: size.height)
                .position(x: x, y: size.height / 2)
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                .position(x: x, y: y)
            ChartTooltip(
                value: "\(valueFormat(sample.bpm))\(unitSuffix)",
                label: timeLabel(sample.t),
                accent: color
            )
            .position(
                ChartTooltipPlacement.position(
                    anchor: CGPoint(x: x, y: y),
                    tooltipSize: CGSize(width: 108, height: 40),
                    in: size
                )
            )
        }
    }

    // MARK: Paint

    private var unitSuffix: String {
        if unit.isEmpty { return "" }
        return unit == "%" ? "%" : " \(unit)"
    }

    /// The colour a single sample speaks: the flat metric tint, or the heart's own ramp.
    private func sampleColor(_ value: Double) -> Color {
        tint ?? HRTimelineInk.color(for: value)
    }

    /// The line's vertical ramp, re-projected onto the visible range: the Live HR module's live-red ramp for the
    /// heart (a quiet red at rest, the full red when steady, the hot red when pushing), so the colour never lies
    /// under zoom. Flat-tinted metrics ride a simple deep-to-bright vertical gradient of their tint instead.
    private func lineGradient(_ yRange: ClosedRange<Double>) -> LinearGradient {
        if let tint {
            return LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .bottom, endPoint: .top)
        }
        let lo = yRange.lowerBound
        let span = yRange.upperBound - lo
        let stops = stride(from: 0.0, through: 1.0, by: 0.125).map { position in
            Gradient.Stop(color: HRTimelineInk.color(for: lo + position * span), location: position)
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .bottom, endPoint: .top)
    }

    /// The wash under the line: the metric's tint, or the heart's.
    private var washColor: Color { tint ?? DomainTint.heart.accent }

    /// Midpoint-bezier smoothing — byte-identical curve construction to StressLoadChart.
    private func linePath(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = (previous.0 + current.0) / 2
            path.addCurve(
                to: CGPoint(x: current.0, y: current.1),
                control1: CGPoint(x: midpoint, y: previous.1),
                control2: CGPoint(x: midpoint, y: current.1)
            )
        }
        return path
    }

    private func areaPath(_ points: [(CGFloat, CGFloat)], height: CGFloat) -> Path {
        var path = linePath(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    // MARK: Gestures

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { pinchChanged(scale: Double($0)) }
            .onEnded { _ in pinchEnded() }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { panChanged(dx: $0.translation.width) }
            .onEnded { _ in panEnded() }
    }

    private func pinchChanged(scale: Double) {
        let base = pinchAnchor ?? window
        if pinchAnchor == nil { pinchAnchor = base }
        // Zooming never leaves the day it started in, and never zooms out past it: a window already dragged back
        // past midnight may roam the wider pan range, but its width still tops out at one day.
        let bounds = Self.contains(day, base) ? day : interactionBounds
        apply(Self.zoomed(base, scale: scale, anchorFraction: 0.5, bounds: bounds, maxSpan: dayLength))
    }

    private func pinchEnded() {
        pinchAnchor = nil
        onSettledWindow(zoomDomain)
    }

    private func panChanged(dx: CGFloat) {
        // A hold that has engaged the crosshair owns the touch: the window stays put under the finger.
        guard !scrubEngaged else { return }
        let base = panAnchor ?? window
        if panAnchor == nil { panAnchor = base }
        let span = base.upperBound - base.lowerBound
        let secondsPerPoint = plotWidth > 0 ? span / Double(plotWidth) : 0
        apply(Self.panned(base, delta: -dx * secondsPerPoint, bounds: interactionBounds))
    }

    private func panEnded() {
        panAnchor = nil
        onSettledWindow(zoomDomain)
    }

    /// Touch-and-hold-then-drag scrub: the stationary hold is the gate that separates reading
    /// from the pan drag and pinch that own immediate movement (OverviewHRChart #979 contract).
    private func scrub(at point: CGPoint) {
        if !scrubEngaged {
            scrubEngaged = true
            StrandHaptic.selection.play()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrubTime = time(atX: point.x) }
    }

    private func endScrub() {
        scrubEngaged = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrubTime = nil }
    }

    private func time(atX x: CGFloat) -> TimeInterval {
        let span = window.upperBound - window.lowerBound
        let fraction = plotWidth > 0 ? min(max(Double(x / plotWidth), 0), 1) : 0
        return window.lowerBound + fraction * span
    }

    /// True when `inner` lies inside `outer` (within a second).
    static func contains(_ outer: ClosedRange<TimeInterval>, _ inner: ClosedRange<TimeInterval>) -> Bool {
        inner.lowerBound >= outer.lowerBound - 1 && inner.upperBound <= outer.upperBound + 1
    }

    /// Gesture frames apply un-animated. A window that is the whole day (within a second) is stored as "no zoom",
    /// so the hint row and the section title never claim "Zoomed in" at full width. Pinching out stops at the day
    /// (`zoomed(maxSpan:)`), so there is no window wider than a day to normalise and nothing snaps on the way.
    private func apply(_ domain: ClosedRange<TimeInterval>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let wholeDay = Self.contains(domain, day) && Self.contains(day, domain)
            zoomDomain = wholeDay ? nil : domain
            spokenTime = nil
        }
    }

    private func resetZoom(announcing: Bool = false) {
        guard zoomDomain != nil else { return }
        panAnchor = nil
        pinchAnchor = nil
        withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
            zoomDomain = nil
            scrubTime = nil
            spokenTime = nil
        }
        onSettledWindow(nil)
        if announcing { announce(String(localized: "Showing the whole day")) }
    }

    // MARK: Accessibility

    /// What VoiceOver hears for the window in view: the title and the span, how many readings, their average and
    /// range, then the sleep band and workouts when they fall inside it. Reflects the zoom, not just the day.
    private func accessibilitySummary(_ frame: Frame) -> String {
        let win = frame.window
        let head = zoomDomain == nil
            ? String(localized: "\(title), 24 hours")
            : String(localized: "\(title), \(timeLabel(win.lowerBound)) to \(timeLabel(win.upperBound))")
        let values = frame.inView.map(\.bpm)
        guard !values.isEmpty else { return String(localized: "\(head), no data in view") }
        let average = valueFormat(values.reduce(0, +) / Double(values.count))
        var parts = [
            head,
            String(localized: "\(values.count) readings"),
            String(localized: "average \(average)"),
            String(localized: "range \(valueFormat(values.min() ?? 0)) to \(valueFormat(values.max() ?? 0))"),
        ]
        if let sleep, sleep.end > win.lowerBound, sleep.start < win.upperBound {
            parts.append(String(localized: "sleep band shown"))
        }
        let inWindow = workouts.filter { $0.end > win.lowerBound && $0.start < win.upperBound }.count
        if inWindow > 0 { parts.append(String(localized: "\(inWindow) workouts")) }
        return parts.joined(separator: ", ")
    }

    /// The reading VoiceOver is parked on: the latest in view until the user steps, then the stepped reading.
    private func spokenReading(_ frame: Frame) -> String {
        let sample = spokenTime.flatMap { nearest(to: $0, in: frame) } ?? frame.inView.last
        guard let sample else { return "" }
        let value = "\(valueFormat(sample.bpm))\(unitSuffix)"
        return spokenTime == nil
            ? "\(value), \(String(localized: "latest · \(timeLabel(sample.t))"))"
            : "\(value), \(timeLabel(sample.t))"
    }

    /// Swipe up/down steps through the window (about 24 steps across it, so a day reads hour by hour), starting at
    /// the latest reading. The step is only ever spoken; it never moves the picture.
    private func stepSpokenReading(_ direction: AccessibilityAdjustmentDirection, frame: Frame) {
        let win = frame.window
        let stride = max((win.upperBound - win.lowerBound) / 24, 1)
        let current = spokenTime.flatMap { win.contains($0) ? $0 : nil } ?? frame.inView.last?.t ?? win.upperBound
        let delta: TimeInterval
        switch direction {
        case .increment: delta = stride
        case .decrement: delta = -stride
        @unknown default: return
        }
        spokenTime = min(max(current + delta, win.lowerBound), win.upperBound)
    }

    /// The pinch as a named action: the window about its centre, one notch in or out (out stops at the day).
    private func zoomForAccessibility(scale: Double) {
        let base = window
        let bounds = Self.contains(day, base) ? day : interactionBounds
        apply(Self.zoomed(base, scale: scale, anchorFraction: 0.5, bounds: bounds, maxSpan: dayLength))
        onSettledWindow(zoomDomain)
        if zoomDomain == nil {
            announce(String(localized: "Showing the whole day"))
        } else {
            let win = window
            announce(String(localized: "Showing \(timeLabel(win.lowerBound)) to \(timeLabel(win.upperBound))"))
        }
    }

    private func announce(_ text: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

// MARK: - HRRangeStrip (mirrors SleepWindowStrip's three-column grammar)

public struct HRRangeStrip: View {
    let low: String
    let lowDetail: String
    let average: String
    let averageDetail: String
    let peak: String
    let peakDetail: String

    public var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, (proxy.size.width - 2) / 3)
            let valueSize: CGFloat = proxy.size.width < 350 ? 17 : 22
            HStack(spacing: 0) {
                column("Low", value: low, detail: lowDetail, alignment: .leading, fontSize: valueSize)
                    .frame(width: columnWidth)
                divider
                column("Average", value: average, detail: averageDetail, alignment: .center, fontSize: valueSize)
                    .frame(width: columnWidth)
                divider
                column("Peak", value: peak, detail: peakDetail, alignment: .trailing, fontSize: valueSize)
                    .frame(width: columnWidth)
            }
        }
        .frame(height: 52)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 48)
    }

    private func column(
        _ label: LocalizedStringKey, value: String, detail: String,
        alignment: HorizontalAlignment, fontSize: CGFloat
    ) -> some View {
        let frameAlignment: Alignment = switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
        return VStack(alignment: alignment, spacing: 4) {
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.number(fontSize))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(detail)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

// MARK: - HRZoneTotalsView (mirrors StressBandTotalsView)

public struct HRZoneTotal: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let duration: String
    public let fraction: Double
    public let zone: Int
}

public struct HRZoneTotalsView: View {
    let totals: [HRZoneTotal]

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(totals) { total in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(total.label)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(total.duration)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    PipBar(
                        value: total.fraction,
                        range: 0...1,
                        segments: 20,
                        tint: HRZoneStyle.zoneColor(total.zone),
                        height: 8
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// Keep stateful public initializers in the declaring file for Swift 6.4 code generation.
public extension HRTimelineChart {
    init(
        _publicAPI: Void = (),
        points: [HRTrackPoint],
        day: ClosedRange<TimeInterval>,
        sleep: HRSleepBand? = nil,
        workouts: [HRWorkoutMark] = [],
        timeLabel: @escaping (TimeInterval) -> String,
        title: String = "Heart rate",
        tint: Color? = nil,
        unit: String = "bpm",
        valueFormat: @escaping (Double) -> String = { value in
            value.isFinite ? value.formatted(.number.precision(.fractionLength(0))) : "—"
        },
        showsZoneLegend: Bool = true,
        zoomDomain: Binding<ClosedRange<TimeInterval>?>? = nil,
        zoomBounds: ClosedRange<TimeInterval>? = nil,
        onSettledWindow: @escaping (ClosedRange<TimeInterval>?) -> Void = { _ in }
    ) {
        self.points = points
        self.day = day
        self.sleep = sleep
        self.workouts = workouts
        self.timeLabel = timeLabel
        self.title = title
        self.tint = tint
        self.unit = unit
        self.valueFormat = valueFormat
        self.showsZoneLegend = showsZoneLegend
        self.zoomDomainBinding = zoomDomain
        self.zoomBounds = zoomBounds
        self.onSettledWindow = onSettledWindow
    }
}

#if canImport(UIKit)

/// The HR timeline's touch surface: hold-to-read, one-finger horizontal pan, pinch and double tap on one
/// transparent UIKit view laid over the plot.
///
/// They share a view because a touch only reaches the recognisers on the view it lands on. Keeping every
/// recogniser here (and none as a SwiftUI gesture on the plot) is what lets a vertical drag fall through to the
/// page's scroll view: the pan declines to begin unless the finger is moving more sideways than up or down, and
/// the hold only reads once the finger has rested for a beat.
private struct HRTimelineTouchSurface: UIViewRepresentable {
    var onScrub: (CGPoint) -> Void
    var onScrubEnd: () -> Void
    var onPan: (CGFloat) -> Void
    var onPanEnd: () -> Void
    var onPinch: (Double) -> Void
    var onPinchEnd: () -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let coordinator = context.coordinator

        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 8

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        for recognizer in [hold, pan, pinch, doubleTap] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScrub = onScrub
        coordinator.onScrubEnd = onScrubEnd
        coordinator.onPan = onPan
        coordinator.onPanEnd = onPanEnd
        coordinator.onPinch = onPinch
        coordinator.onPinchEnd = onPinchEnd
        coordinator.onDoubleTap = onDoubleTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScrub: (CGPoint) -> Void = { _ in }
        var onScrubEnd: () -> Void = {}
        var onPan: (CGFloat) -> Void = { _ in }
        var onPanEnd: () -> Void = {}
        var onPinch: (Double) -> Void = { _ in }
        var onPinchEnd: () -> Void = {}
        var onDoubleTap: () -> Void = {}

        @MainActor @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: onScrub(recognizer.location(in: recognizer.view))
            case .ended, .cancelled, .failed: onScrubEnd()
            default: break
            }
        }

        @MainActor @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: onPan(recognizer.translation(in: recognizer.view).x)
            case .ended, .cancelled, .failed: onPanEnd()
            default: break
            }
        }

        @MainActor @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: onPinch(Double(recognizer.scale))
            case .ended, .cancelled, .failed: onPinchEnd()
            default: break
            }
        }

        @MainActor @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { onDoubleTap() }
        }

        /// A drag that starts more up-and-down than sideways is the page scrolling: the pan stays out of it.
        nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
                let velocity = pan.velocity(in: pan.view)
                return abs(velocity.x) > abs(velocity.y)
            }
        }

        /// The hold may run beside the scroll view's pan and the navigation pop only until it has been
        /// recognised; from then on the reading owns the touch. Pinch and double tap combine with this surface's
        /// own recognisers and nothing else: never with the page's scroll, the navigation pop or a sheet's
        /// dismiss drag, which a pinch has no business moving. A pan never runs beside another pan or the hold.
        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            MainActor.assumeIsolated {
                switch gestureRecognizer {
                case is UILongPressGestureRecognizer: return gestureRecognizer.state == .possible
                case is UIPanGestureRecognizer: return false
                default: return other.view === gestureRecognizer.view
                }
            }
        }
    }
}
#endif
