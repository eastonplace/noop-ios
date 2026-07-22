import SwiftUI

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
    var valueFormat: (Double) -> String = { "\(Int($0.rounded()))" }
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
    /// The window a gesture started from — pinch/pan scale off this, not the live window.
    @State private var gestureAnchor: ClosedRange<TimeInterval>? = nil
    @State private var plotWidth: CGFloat = 1
    @State private var scrubTime: TimeInterval? = nil
    @State private var scrubEngaged = false
    @State private var revealed = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            plot
                .frame(height: 170)
            timeAxis
            hintRow
            if showsZoneLegend { HRZoneLegend() }
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

    /// Visible samples plus one neighbour either side so the line runs to the plot edges.
    /// Raw resolution — peak/scrub read from this so zooming never changes the truth.
    private var visibleRaw: [HRTrackPoint] {
        guard !points.isEmpty else { return [] }
        var lo = points.firstIndex(where: { $0.t >= window.lowerBound }) ?? points.count - 1
        var hi = points.lastIndex(where: { $0.t <= window.upperBound }) ?? 0
        lo = max(0, lo - 1)
        hi = min(points.count - 1, hi + 1)
        guard lo <= hi else { return [] }
        return Array(points[lo...hi])
    }

    /// The render ladder: the drawn line is capped at ~420 points regardless of zoom, the
    /// same trick Repository.timelineSeries plays with SQL buckets — full-day stays cheap,
    /// deep zooms pick up the fixture's full 30-second resolution.
    private var visible: [HRTrackPoint] {
        let raw = visibleRaw
        let maxRendered = 420
        guard raw.count > maxRendered else { return raw }
        let step = Double(raw.count - 1) / Double(maxRendered - 1)
        var rendered: [HRTrackPoint] = []
        rendered.reserveCapacity(maxRendered)
        for index in 0..<maxRendered {
            rendered.append(raw[Int((Double(index) * step).rounded())])
        }
        return rendered
    }

    /// Padded to the visible extent so zooming into the night re-scales honestly.
    private var yRange: ClosedRange<Double> {
        let values = visible.map(\.bpm)
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return tint == nil ? 40...120 : 0...1
        }
        let pad = (hi - lo) * 0.14
        return max(30, lo - pad)...(hi + pad)
    }

    private var visiblePeak: HRTrackPoint? {
        visibleRaw.max(by: { $0.bpm < $1.bpm })
    }

    private var scrubSample: HRTrackPoint? {
        guard let scrubTime else { return nil }
        return visibleRaw.min(by: { abs($0.t - scrubTime) < abs($1.t - scrubTime) })
    }

    // MARK: Zoom / pan math (pure — mirrors OverviewHRChart.zoomed/panned over TimeInterval)

    static func zoomed(
        _ base: ClosedRange<TimeInterval>, scale: Double, anchorFraction: Double,
        bounds: ClosedRange<TimeInterval>, minSpan: TimeInterval = minZoomSpan
    ) -> ClosedRange<TimeInterval> {
        let span = base.upperBound - base.lowerBound
        guard span > 0, scale > 0 else { return base }
        let pivot = base.lowerBound + span * min(max(anchorFraction, 0), 1)
        let boundsSpan = bounds.upperBound - bounds.lowerBound
        let newSpan = min(max(span / scale, minSpan), max(boundsSpan, minSpan))
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

    private var header: some View {
        HStack {
            Text(zoomDomain == nil ? "24-hour timeline" : "Zoomed window")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            if let sample = scrubSample {
                Text("\(valueFormat(sample.bpm))\(unitSuffix) · \(timeLabel(sample.t))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(sampleColor(sample.bpm))
            } else if let peak = visiblePeak {
                Text("PEAK \(valueFormat(peak.bpm)) · \(timeLabel(peak.t))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(sampleColor(peak.bpm))
            }
        }
    }

    @ViewBuilder
    private var timeAxis: some View {
        let win = window
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
        HStack(spacing: 8) {
            Image(systemName: zoomDomain == nil
                  ? "arrow.up.left.and.arrow.down.right"
                  : "arrow.down.right.and.arrow.up.left")
                .font(StrandFont.micro.weight(.semibold))
            Text(zoomDomain == nil
                 ? "Pinch to zoom · drag to pan · hold to read"
                 : "Zoomed in · drag to pan · double-tap to reset")
            Spacer()
            if zoomDomain != nil {
                Button("Reset") { resetZoom() }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .buttonStyle(.plain)
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            plotLayers(size: size)
                .contentShape(Rectangle())
                // Scrub sits on the inner view so its 0.25 s hold gate arbitrates first: an immediate
                // drag fails the hold and falls through to the pan/pinch below (OverviewHRChart #979).
                .gesture(scrubGesture)
                .onAppear { plotWidth = size.width }
                .onChangeCompat(of: size.width) { plotWidth = $0 }
        }
        .frame(maxWidth: .infinity)
        .gesture(magnifyGesture)
        .simultaneousGesture(panGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() })
        // One collapsed VoiceOver element with a whole-picture summary, never a mark-by-mark walk.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func plotLayers(size: CGSize) -> some View {
        let win = window
        let span = max(win.upperBound - win.lowerBound, 1)
        let yr = yRange
        let ySpan = max(yr.upperBound - yr.lowerBound, 1)
        let xOf: (TimeInterval) -> CGFloat = { size.width * CGFloat(($0 - win.lowerBound) / span) }
        let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(($0 - yr.lowerBound) / ySpan) }
        let rendered = visible.map { (xOf($0.t), yOf($0.bpm)) }

        ZStack {
            sleepLayer(size: size, xOf: xOf)
            gridLayer(size: size, yOf: yOf)
            lineLayer(size: size, rendered: rendered)
            workoutLayer(size: size, xOf: xOf, yOf: yOf)
            peakLayer(xOf: xOf, yOf: yOf)
            scrubLayer(size: size, xOf: xOf, yOf: yOf)
        }
    }

    @ViewBuilder
    private func sleepLayer(size: CGSize, xOf: (TimeInterval) -> CGFloat) -> some View {
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
    private func gridLayer(size: CGSize, yOf: @escaping (Double) -> CGFloat) -> some View {
        ForEach(gridValues, id: \.self) { value in
            let y = yOf(value)
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(
                StrandPalette.hairlineStrong.opacity(0.7),
                style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
            )
            Text(valueFormat(value))
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
                .position(x: size.width - 12, y: max(8, y - 8))
        }
    }

    /// Dashed rails at whole-bpm steps sized to the visible range (2–4 lines, never a dense grid).
    private var gridValues: [Double] {
        let lo = yRange.lowerBound, hi = yRange.upperBound
        let span = hi - lo
        let step = [0.25, 0.5, 1, 2, 5, 10, 20, 25, 50].first(where: { span / $0 <= 4 }) ?? 50
        var values: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v < hi { values.append(v); v += step }
        return values
    }

    @ViewBuilder
    private func lineLayer(size: CGSize, rendered: [(CGFloat, CGFloat)]) -> some View {
        if rendered.count >= 2 {
            areaPath(rendered, height: size.height)
                .fill(
                    LinearGradient(
                        colors: [averageZoneColor.opacity(0.16), averageZoneColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(revealed ? 1 : 0)
            linePath(rendered)
                .trim(from: 0, to: revealed ? 1 : 0)
                .stroke(
                    lineGradient,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
        } else if let only = rendered.first, let sample = visible.first {
            Circle()
                .fill(sampleColor(sample.bpm))
                .frame(width: 7, height: 7)
                .position(x: only.0, y: only.1)
                .opacity(revealed ? 1 : 0)
        }
    }

    @ViewBuilder
    private func workoutLayer(
        size: CGSize, xOf: @escaping (TimeInterval) -> CGFloat, yOf: @escaping (Double) -> CGFloat
    ) -> some View {
        ForEach(workouts) { workout in
            if workout.end > window.lowerBound, workout.start < window.upperBound,
               let peak = visible
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
    private func peakLayer(xOf: (TimeInterval) -> CGFloat, yOf: (Double) -> CGFloat) -> some View {
        if scrubTime == nil, let peak = visiblePeak {
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
        size: CGSize, xOf: (TimeInterval) -> CGFloat, yOf: (Double) -> CGFloat
    ) -> some View {
        if let sample = scrubSample {
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

    /// The colour a single sample speaks: the flat metric tint, or HR's zone ramp.
    private func sampleColor(_ value: Double) -> Color {
        tint ?? HRZoneStyle.color(for: value)
    }

    /// Vertical zone ramp re-projected onto the visible bpm range, so a zoomed-in night reads
    /// all-rest blue and the workout window reads push rose — the colour never lies under zoom.
    /// Flat-tinted metrics ride a simple deep→bright vertical gradient instead (Deep Timeline).
    private var lineGradient: LinearGradient {
        if let tint {
            return LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .bottom, endPoint: .top)
        }
        let lo = yRange.lowerBound
        let span = yRange.upperBound - lo
        let stops = stride(from: 0.0, through: 1.0, by: 0.125).map { position in
            Gradient.Stop(color: HRZoneStyle.color(for: lo + position * span), location: position)
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .bottom, endPoint: .top)
    }

    private var averageZoneColor: Color {
        if let tint { return tint }
        let values = visible.map(\.bpm)
        guard !values.isEmpty else { return HRZoneStyle.rest }
        return HRZoneStyle.color(for: values.reduce(0, +) / Double(values.count))
    }

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
            .onChanged { scale in
                let base = gestureAnchor ?? window
                if gestureAnchor == nil { gestureAnchor = base }
                apply(Self.zoomed(base, scale: Double(scale), anchorFraction: 0.5, bounds: interactionBounds))
            }
            .onEnded { _ in
                gestureAnchor = nil
                onSettledWindow(zoomDomain)
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let base = gestureAnchor ?? window
                if gestureAnchor == nil { gestureAnchor = base }
                let span = base.upperBound - base.lowerBound
                let secondsPerPoint = plotWidth > 0 ? span / Double(plotWidth) : 0
                apply(Self.panned(base, delta: -value.translation.width * secondsPerPoint, bounds: interactionBounds))
            }
            .onEnded { _ in
                gestureAnchor = nil
                onSettledWindow(zoomDomain)
            }
    }

    /// Touch-and-hold-then-drag scrub: the stationary hold is the gate that separates reading
    /// from the pan drag and pinch that own immediate movement (OverviewHRChart #979 contract).
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !scrubEngaged {
                    scrubEngaged = true
                    StrandHaptic.selection.play()
                }
                if let drag {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scrubTime = time(atX: drag.location.x) }
                }
            }
            .onEnded { _ in
                scrubEngaged = false
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { scrubTime = nil }
            }
    }

    private func time(atX x: CGFloat) -> TimeInterval {
        let span = window.upperBound - window.lowerBound
        let fraction = plotWidth > 0 ? min(max(Double(x / plotWidth), 0), 1) : 0
        return window.lowerBound + fraction * span
    }

    /// Gesture frames apply un-animated; a window that covers the whole day normalises back to
    /// nil so the hint row never claims "Zoomed in" at full width (OverviewHRChart's rule).
    private func apply(_ domain: ClosedRange<TimeInterval>) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            zoomDomain = (domain.lowerBound <= interactionBounds.lowerBound && domain.upperBound >= interactionBounds.upperBound)
                ? nil : domain
        }
    }

    private func resetZoom() {
        guard zoomDomain != nil else { return }
        withAnimation(reduceMotion ? nil : StrandMotion.interactive) {
            zoomDomain = nil
            scrubTime = nil
        }
        onSettledWindow(nil)
    }

    private var accessibilitySummary: String {
        guard !points.isEmpty else { return "\(title), no data yet" }
        let values = points.map(\.bpm)
        let average = valueFormat(values.reduce(0, +) / Double(values.count))
        let low = valueFormat(values.min() ?? 0)
        let high = valueFormat(values.max() ?? 0)
        var parts = [
            "\(title), 24 hours",
            "\(points.count) readings",
            "average \(average)",
            "range \(low) to \(high)",
        ]
        if sleep != nil { parts.append("sleep band shown") }
        if !workouts.isEmpty {
            parts.append(workouts.count == 1 ? "1 workout" : "\(workouts.count) workouts")
        }
        return parts.joined(separator: ", ")
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

// MARK: - HRZoneLegend (mirrors StressBandLegend)

public struct HRZoneLegend: View {
    public var body: some View {
        HStack(spacing: 12) {
            key(range: "<60", label: "Rest", color: HRZoneStyle.rest)
            key(range: "60–110", label: "Steady", color: HRZoneStyle.steady)
            key(range: "110+", label: "Push", color: HRZoneStyle.push)
        }
    }

    private func key(range: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 7)
                .accessibilityHidden(true)
            Text(range)
                .font(StrandFont.micro.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label.uppercased())
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
