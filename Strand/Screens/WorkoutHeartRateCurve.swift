import SwiftUI
import StrandDesign

// MARK: - Heart-rate curve
//
// A session's heart rate in the heart language the Trends charts speak: a rose line, a faint wash under it fading
// to clear, quiet rails at the peak and the low with the average dashed between them, each rail's number on a canvas
// plate that moves to the stretch the line crosses least, and at most four time labels. Touch and hold, then drag, to
// read any moment; a touch that moves at once is the page scrolling.
//
// The same curve is the summary's one heart-rate picture. On the Heart Rate tab it is full height and readable by touch.
// On the Overview it is `isCompact`: shorter, with no reading of its own (the page around it is the button that opens
// the Heart Rate tab), and it can mark where one heart-rate zone fell.

struct WorkoutHeartRateCurve: View {
    let series: WorkoutHeartRateSeries
    /// Epoch second the session started, so a reading can say what time of day it was.
    let start: Int
    /// What a screen reader calls the chart ("Heart rate during Running").
    let accessibilityName: String
    /// A shorter plot with no reading line and no touch reading, for a curve that is itself a way into the full one.
    var isCompact = false
    /// The stretches of the session to mark behind the line, for one zone. nil marks nothing.
    var highlight: Highlight?

    /// Where one heart-rate zone fell: its number (which picks the colour) and the spans of the session it covered, in
    /// seconds from the start.
    struct Highlight: Equatable {
        let zone: Int
        let spans: [ClosedRange<Double>]
    }

    @State private var scrubIndex: Int?
    /// Whether VoiceOver is on this chart, so a reading set by its adjustable action is cleared when it moves on.
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var labelUnit: CGFloat = 1
    @ScaledMetric(relativeTo: .title3) private var readoutSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var fullHeight: CGFloat = 168
    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = 96

    private var plotHeight: CGFloat { isCompact ? compactHeight : fullHeight }

    @ViewBuilder var body: some View {
        let chart = VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if !isCompact { readout }
            plot
            timeLabels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(Text(verbatim: spokenReading))
        if isCompact {
            chart
        } else {
            chart
                .accessibilityFocused($isAccessibilityFocused)
                .onChange(of: isAccessibilityFocused) { _, focused in
                    // The marker and the reading belong to the focus that set them; leaving the chart puts it back.
                    if !focused { scrubIndex = nil }
                }
                .accessibilityAdjustableAction { direction in
                    let last = series.samples.count - 1
                    let step = max(1, series.samples.count / 24)
                    switch direction {
                    case .increment: scrubIndex = min(last, (scrubIndex ?? -step) + step)
                    case .decrement: scrubIndex = max(0, (scrubIndex ?? step) - step)
                    @unknown default: break
                    }
                }
        }
    }

    // MARK: Reading

    private var scrubSample: WorkoutHeartRateSeries.Sample? {
        guard let index = scrubIndex, series.samples.indices.contains(index) else { return nil }
        return series.samples[index]
    }

    /// The hint while nothing is touched, the reading while it is. Both are laid out, one over the other, so the line is as
    /// tall as the taller of the two and the page never shifts; at accessibility sizes the reading takes two lines and the
    /// hint wraps, rather than either being cut short.
    private var readout: some View {
        let sample = scrubSample
        return ZStack(alignment: .leading) {
            Text("Touch and hold to read the curve")
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(sample == nil ? 1 : 0)
            // With nothing touched the first reading stands in, unseen, to give the line its height.
            if let shown = sample ?? series.samples.first {
                reading(shown).opacity(sample == nil ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: readoutSize * 1.3, alignment: .leading)
    }

    @ViewBuilder private func reading(_ sample: WorkoutHeartRateSeries.Sample) -> some View {
        let value = Text(verbatim: Int(sample.bpm.rounded()).formatted())
            .font(StrandFont.number(readoutSize, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
        let unit = Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        let elapsed = Text(verbatim: WorkoutElapsed.text(sample.seconds))
            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        let clock = Text(verbatim: AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(start) + sample.seconds)))
            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) { value; unit }
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) { elapsed; clock }
            }
            .lineLimit(1)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                value
                unit
                Spacer(minLength: NoopMetrics.space2)
                elapsed
                clock
            }
            .lineLimit(1)
        }
    }

    private var spokenReading: String {
        guard let sample = scrubSample else {
            return String(localized: "Average \(Int(series.average.rounded())) beats per minute, peak \(Int(series.peak.rounded())), low \(Int(series.low.rounded()))")
        }
        return String(localized: "\(Int(sample.bpm.rounded())) beats per minute, \(WorkoutElapsed.spoken(sample.seconds)) into the session")
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = PlotFrame(series: series, size: size, labelUnit: labelUnit)
            let canvas = ZStack {
                zoneBands(size)
                rails(frame, width: size.width)
                if frame.points.count >= 2 {
                    frame.area
                        .fill(LinearGradient(colors: [StrandPalette.metricRose.opacity(0.14), .clear],
                                             startPoint: .top, endPoint: .bottom))
                    frame.line
                        .stroke(StrandPalette.metricRose,
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(frame.labels.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label.text)
                        .font(StrandFont.micro)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .railKnockout()
                        .fixedSize()
                        .position(label.point)
                }
                if let index = scrubIndex, frame.points.indices.contains(index) {
                    let point = frame.points[index]
                    Rectangle()
                        .fill(StrandPalette.hairlineStrong)
                        .frame(width: 1, height: size.height)
                        .position(x: point.x, y: size.height / 2)
                    Circle()
                        .fill(StrandPalette.metricRose)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                        .position(point)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            if isCompact {
                canvas
            } else {
                canvas.holdToScrub(
                    onScrub: { location in
                        guard size.width > 0 else { return }
                        let next = series.index(atFraction: Double(location.x / size.width))
                        if next != scrubIndex { scrubIndex = next }
                    },
                    onEnd: { scrubIndex = nil })
            }
        }
        .frame(height: plotHeight)
    }

    /// The marked zone as tinted full-height bands behind the line, one path for however many stretches there are.
    @ViewBuilder private func zoneBands(_ size: CGSize) -> some View {
        if let highlight, !highlight.spans.isEmpty, series.duration > 0 {
            Path { path in
                for span in highlight.spans {
                    let start = size.width * CGFloat(min(max(span.lowerBound / series.duration, 0), 1))
                    let end = size.width * CGFloat(min(max(span.upperBound / series.duration, 0), 1))
                    path.addRect(CGRect(x: start, y: 0, width: max(1.5, end - start), height: size.height))
                }
            }
            .fill(StrandPalette.hrZoneColor(highlight.zone).opacity(0.3))
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func rails(_ frame: PlotFrame, width: CGFloat) -> some View {
        if let y = frame.peakY { rail(y: y, width: width, dashed: false) }
        if let y = frame.lowY { rail(y: y, width: width, dashed: false) }
        rail(y: frame.averageY, width: width, dashed: true)
    }

    private func rail(y: CGFloat, width: CGFloat, dashed: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 4] : []))
        .accessibilityHidden(true)
    }

    // MARK: Time

    /// Four labels across the plot; from the accessibility sizes only the start and the end, since four at that size
    /// would be cut to "11:…".
    private var labelledTimes: [Double] {
        let times = series.labelTimes()
        guard typeSize.isAccessibilitySize, times.count > 2, let first = times.first, let last = times.last else { return times }
        return [first, last]
    }

    private var timeLabels: some View {
        HStack(spacing: 0) {
            ForEach(Array(labelledTimes.enumerated()), id: \.offset) { index, seconds in
                if index > 0 { Spacer(minLength: NoopMetrics.space1) }
                Text(verbatim: WorkoutElapsed.text(seconds))
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Plot geometry

/// Everything in the plot that depends only on the data and the plot's size, worked out once per layout.
private struct PlotFrame {
    let points: [CGPoint]
    let line: Path
    let area: Path
    let peakY: CGFloat?
    let lowY: CGFloat?
    let averageY: CGFloat
    let labels: [(text: String, point: CGPoint)]

    init(series: WorkoutHeartRateSeries, size: CGSize, labelUnit: CGFloat) {
        let yOf: (Double) -> CGFloat = { size.height * CGFloat(1 - series.unit(forBPM: $0)) }
        let rendered = series.samples.map {
            CGPoint(x: size.width * CGFloat(min(max($0.seconds / series.duration, 0), 1)), y: yOf($0.bpm))
        }
        points = rendered
        var linePath = Path()
        for (index, point) in rendered.enumerated() {
            if index == 0 { linePath.move(to: point) } else { linePath.addLine(to: point) }
        }
        line = linePath
        var areaPath = linePath
        if let first = rendered.first, let last = rendered.last {
            areaPath.addLine(to: CGPoint(x: last.x, y: size.height))
            areaPath.addLine(to: CGPoint(x: first.x, y: size.height))
            areaPath.closeSubpath()
        }
        area = areaPath

        let peak = yOf(series.peak)
        let low = yOf(series.low)
        let average = yOf(series.average)
        averageY = average
        peakY = peak
        // A low that sits on top of the peak rail would only be a second line through the same label.
        let showsLow = low - peak > 16
        lowY = showsLow ? low : nil
        let showsAverageLabel = abs(average - peak) > 14 && (!showsLow || abs(average - low) > 14)

        var placed: [(text: String, point: CGPoint)] = []
        func place(_ text: String, y: CGFloat) {
            if let x = Self.slot(at: y, text: text, width: size.width, samples: rendered, unit: labelUnit) {
                placed.append((text, CGPoint(x: x, y: y)))
            }
        }
        place(Int(series.peak.rounded()).formatted(), y: peak)
        if showsLow { place(Int(series.low.rounded()).formatted(), y: low) }
        if showsAverageLabel { place(String(localized: "avg \(Int(series.average.rounded()))"), y: average) }
        labels = placed
    }

    /// The centre x of the slot on a rail at `y` where the line crosses the label least, searching from the trailing
    /// edge inwards so the first clear stretch wins.
    private static func slot(at y: CGFloat, text: String, width: CGFloat, samples: [CGPoint], unit: CGFloat) -> CGFloat? {
        let half = max(14, CGFloat(text.count) * 2.9 + 6) * unit
        var best: (x: CGFloat, hits: Int)?
        for index in 0..<10 {
            let x = width - 16 - half - CGFloat(index) * 40 * unit
            guard x - half >= 0 else { break }
            let hits = samples.reduce(0) { count, sample in
                abs(sample.x - x) <= half + 3 && abs(sample.y - y) <= 10 * unit ? count + 1 : count
            }
            if best == nil || hits < best!.hits { best = (x, hits) }
            if hits == 0 { break }
        }
        return best?.x
    }
}

private extension View {
    /// The canvas knock-out behind a rail label: it grows outward from the digits, so they do not move, and a line that
    /// passes under a label stays legible and reads as passing behind it.
    func railKnockout() -> some View {
        background {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StrandPalette.appCanvas.opacity(0.88))
                .padding(.horizontal, -3)
                .padding(.vertical, -1)
        }
    }
}
