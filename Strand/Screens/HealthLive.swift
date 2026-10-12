import Combine
import SwiftUI
import StrandDesign

// MARK: - Health Monitor: live heart rate
//
// The live trace in the widget language: the Live Heart Rate header with the wearer's zone word (Resting, Steady,
// Pushing, from the personal boundaries in `\.hrZoneThresholds`, the same as Today's Live Heart Rate card), the number
// as a hero value, a tinted line over a 14% wash with at most four labels (hold and drag reads one second), and a fact
// strip under it.
//
// PERF ISOLATION: this is the only Health leaf that observes `LiveState` / `AppModel` (a connected strap publishes at
// ~1 Hz). The parent never does, so a live tick re-renders this subtree and nothing else.

/// One streamed live-HR reading with the wall-clock time it arrived. Carrying the time (rather than a bare bpm) is what
/// lets the trace read a real clock axis (#198).
struct LiveHRSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

struct HeartRateSection: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var model: AppModel
    /// The wearer's rest / steady / push boundaries, set once at the app's root from their profile.
    @Environment(\.hrZoneThresholds) private var zones
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Rolling buffer of recently-streamed live HR (newest last), so the trace builds a real continuous time-series
    /// instead of collapsing to a 2-point flat line when the strap streams HR but little/no R-R (the #105 case).
    /// Each sample carries the wall-clock time it arrived (#198). Sampled on a fixed 1 Hz clock (#941), so the
    /// 180-sample cap is a strict rolling 3 minutes; resets when the view is recreated, which is fine for a live trace.
    @State private var hrHistory: [LiveHRSample] = []
    /// The sample under the finger while the trace is being read.
    @State private var scrubIndex: Int?

    /// The 1 Hz sampling clock for the trace (#941, reimplemented from ryanbr's PR). The buffer used to append only
    /// when `displayHR` CHANGED, but AppModel deliberately republishes `bpm` only when the smoothed median actually
    /// moves, so a steady heart rate banked ZERO points and the chart drew one long phantom ramp from the last change to
    /// the next. Banking the current median once a second draws steady HR flat.
    private let sampleTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    /// HR to display: the spike-filtered median (model.bpm, #39) when available — raw live.heartRate carries PPG
    /// harmonic spikes (real ~92 read as 170+); AppModel.bpm's doc mandates "every screen should show THIS". Falls back
    /// to the reported value, then R-R-derived, only until the median has a sample.
    private var displayHR: Int? {
        if let hr = model.bpm, hr > 0 { return hr }
        if let hr = live.heartRate, hr > 0 { return hr }
        if let last = live.rr.last, last > 0 { return Int((60_000.0 / Double(last)).rounded()) }
        return nil
    }
    private var hrIsDerived: Bool { (live.heartRate ?? 0) <= 0 && !live.rr.isEmpty }

    /// HR as a fraction of HR-max (0…1).
    private func hrFraction(_ hr: Int?) -> Double {
        guard let hr, profile.hrMax > 0 else { return 0 }
        return min(max(Double(hr) / Double(profile.hrMax), 0), 1)
    }

    /// The wearer's zone for a reading, as a word: Resting below half of their maximum, Steady to 70%, Pushing above.
    private func zoneWord(_ bpm: Double) -> String {
        switch zones.zone(for: bpm) {
        case 0: String(localized: "Resting")
        case 1: String(localized: "Steady")
        default: String(localized: "Pushing")
        }
    }

    /// A short, time-stamped HR series for the trace (newest last). Prefers the accumulated live-HR time-series — that's
    /// what a "live" graph should show, and it keeps growing even when the strap streams HR but sparse R-R (#105). Falls
    /// back to R-R-derived beats, then a flat line at the current HR. The R-R / flat fallbacks have no real per-sample
    /// timestamps, so a 1 Hz trailing window ending "now" is synthesised — the axis still reads as clock time and scrolls,
    /// matching the live buffer's behaviour (#198).
    private func hrSeries(_ hr: Int?) -> [LiveHRSample] {
        if hrHistory.count > 1 { return hrHistory }
        let beats = live.rr.suffix(60).compactMap { rr -> Double? in
            rr > 0 ? 60_000.0 / Double(rr) : nil
        }
        if beats.count > 1 { return Self.synthesiseSeries(beats) }
        if let hr { return Self.synthesiseSeries([Double(hr), Double(hr)]) }
        return []
    }

    /// Wrap a bare value series in trailing 1 Hz timestamps ending at `Date()`, so the fallbacks (R-R-derived beats,
    /// flat line) chart on the same clock axis as the live buffer.
    private static func synthesiseSeries(_ values: [Double]) -> [LiveHRSample] {
        let now = Date()
        let n = values.count
        return values.enumerated().map { i, v in
            LiveHRSample(date: now.addingTimeInterval(Double(i - (n - 1))), bpm: v)
        }
    }

    var body: some View {
        // The derived live values are computed ONCE per body pass and threaded into the subviews.
        let displayHR = self.displayHR
        let hasLiveHR = displayHR != nil
        let series = hrSeries(displayHR)
        let scrubbed = scrubIndex.flatMap { series.indices.contains($0) ? series[$0] : nil }
        let shownBPM = scrubbed.map { Int($0.bpm.rounded()) } ?? displayHR
        let word = shownBPM.map { zoneWord(Double($0)) }

        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            header(hasLiveHR: hasLiveHR, zoneWord: word)
            HeroValue(
                value: shownBPM.map(String.init) ?? WidgetMetrics.missingValue,
                unit: String(localized: "bpm"),
                caption: caption(scrubbed: scrubbed, hasLiveHR: hasLiveHR),
                captionPlacement: .below)
            if series.count > 1 {
                HealthLiveTrace(samples: series, zones: zones, selection: $scrubIndex)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live heart rate over time")
                    .accessibilityValue(shownBPM.map { String(localized: "\($0) beats per minute, \(zoneWord(Double($0)))") }
                                        ?? String(localized: "no data"))
            } else {
                waiting
            }
            FactStrip(facts: [
                .init("Zone", value: word ?? WidgetMetrics.missingValue),
                .init("% Max", value: hasLiveHR ? "\(Int((hrFraction(displayHR) * 100).rounded()))%" : WidgetMetrics.missingValue),
                .init("Max HR", value: "\(profile.hrMax)"),
            ])
        }
        .onReceive(sampleTimer) { now in
            // Bank the CURRENT spike-filtered HR once a second, stamped with the tick's real wall-clock time: this feeds
            // the clock axis (#198) and the #105 trace without the phantom ramp that on-change sampling drew through
            // steady stretches (#941). The 30...220 physiological guard mirrors the Android chart's existing range check;
            // nil banks nothing (disconnect clears the median on both platforms), so a stale value never flat-lines a
            // dead trace.
            guard let v = displayHR, (30...220).contains(v) else { return }
            hrHistory.append(LiveHRSample(date: now, bpm: Double(v)))
            if hrHistory.count > 180 { hrHistory.removeFirst(hrHistory.count - 180) }
        }
    }

    /// What is under the number: the time of the reading while it is being read, else where the number came from.
    private func caption(scrubbed: LiveHRSample?, hasLiveHR: Bool) -> String {
        if let scrubbed { return scrubbed.date.formatted(.dateTime.hour().minute().second()) }
        if hrIsDerived { return String(localized: "Estimated from R-R interval") }
        return hasLiveHR ? String(localized: "Streaming live") : String(localized: "Awaiting strap")
    }

    /// The Live Heart Rate header: a beating heart, the caps title and the zone word as a pill. At an accessibility size
    /// the pill drops under the title and the title wraps instead of truncating.
    @ViewBuilder
    private func header(hasLiveHR: Bool, zoneWord: String?) -> some View {
        let heart = EyebrowPulseIcon(
            systemName: "heart.fill",
            color: hasLiveHR ? StrandPalette.liveRed : StrandPalette.textTertiary,
            period: 1.2, pulses: hasLiveHR)
        let pill = ValuePill(zoneWord ?? String(localized: "Idle"),
                             tint: zoneWord == nil ? StrandPalette.textTertiary : StrandPalette.liveRed)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(spacing: NoopMetrics.space2) {
                    heart
                    Text("Live Heart Rate").strandOverlineFitted().lineLimit(3)
                }
                pill
            }
        } else {
            HStack(spacing: NoopMetrics.space2) {
                heart
                Text("Live Heart Rate").strandOverline().lineLimit(1)
                Spacer(minLength: NoopMetrics.space2)
                pill
            }
        }
    }

    /// No signal yet: a dimmed flat rail and one honest line, never a fabricated trace.
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            Text("Waiting for live signal — keep the strap nearby.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: WidgetMetrics.chartHeight, alignment: .center)
    }
}

// MARK: - Trace

/// The live trace: a tinted line over a wash that fades from 14% to clear, the HR scale's two ends and three clock
/// labels (two at an accessibility size) — at most four labels — and touch-and-hold-then-drag to read one second.
/// The line is fainter below the wearer's resting boundary, so the zones read in the trace itself.
private struct HealthLiveTrace: View {
    let samples: [LiveHRSample]
    let zones: HRZoneStyle.Thresholds
    @Binding var selection: Int?

    @Environment(\.dynamicTypeSize) private var typeSize

    private var tint: Color { DomainTint.heart.accent }

    /// Auto-fitted y bounds with a little headroom so the trace never kisses the edges.
    private var yRange: ClosedRange<Double> {
        let values = samples.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 5)...(hi + 5) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    private var domain: ClosedRange<Date> {
        let first = samples.first?.date ?? Date()
        let last = max(samples.last?.date ?? first, first.addingTimeInterval(5))
        return first...last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            plot.frame(height: WidgetMetrics.chartHeight)
            clockLabels
        }
    }

    private func unitX(_ date: Date) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return CGFloat(min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1))
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let range = yRange
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        // Room at the top for the head's ring, at the bottom for the line's stroke.
        let top: CGFloat = 8, bottom: CGFloat = 4
        let usable = max(size.height - top - bottom, 1)
        let inset: CGFloat = 5
        return samples.map { sample in
            CGPoint(
                x: inset + (size.width - inset * 2) * unitX(sample.date),
                y: top + usable * CGFloat(1 - (sample.bpm - range.lowerBound) / span))
        }
    }

    private var plot: some View {
        GeometryReader { proxy in
            let rendered = points(in: proxy.size)
            layers(rendered: rendered, size: proxy.size)
                .contentShape(Rectangle())
                .holdToScrub(
                    onScrub: { location in
                        var best = 0
                        var distance = CGFloat.greatestFiniteMagnitude
                        for (index, point) in rendered.enumerated() where abs(point.x - location.x) < distance {
                            best = index
                            distance = abs(point.x - location.x)
                        }
                        if best != selection { selection = best }
                    },
                    onEnd: { selection = nil })
        }
    }

    private func layers(rendered: [CGPoint], size: CGSize) -> some View {
        let range = yRange
        return ZStack {
            area(rendered, height: size.height)
                .fill(LinearGradient(colors: [tint.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
            line(rendered)
                .stroke(zoneGradient(range: range),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            railLabel(Int(range.upperBound.rounded()), y: 7, width: size.width)
            railLabel(Int(range.lowerBound.rounded()), y: size.height - 7, width: size.width)
            if let selection, rendered.indices.contains(selection) {
                let spot = rendered[selection]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: spot.x, y: size.height / 2)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(spot)
            } else if let end = rendered.last {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
            }
        }
    }

    /// The line at full strength from the resting boundary up, fainter below it, projected onto the visible range.
    private func zoneGradient(range: ClosedRange<Double>) -> LinearGradient {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let boundary = min(max((zones.rest - range.lowerBound) / span, 0), 1)
        let faint = tint.opacity(0.55)
        return LinearGradient(
            stops: [
                .init(color: faint, location: 0),
                .init(color: faint, location: max(boundary - 0.02, 0)),
                .init(color: tint, location: min(boundary + 0.02, 1)),
                .init(color: tint, location: 1),
            ],
            startPoint: .bottom, endPoint: .top)
    }

    /// The HR scale's end, inset so the head's ring never touches it, with a canvas knock-out so a line passing under it
    /// stays legible.
    private func railLabel(_ value: Int, y: CGFloat, width: CGFloat) -> some View {
        Text(verbatim: "\(value)")
            .font(StrandFont.micro).monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(StrandPalette.appCanvas.opacity(0.88))
                    .padding(.horizontal, -3)
                    .padding(.vertical, -1)
            }
            .frame(width: 28, alignment: .trailing)
            .position(x: width - 16 - 14, y: y)
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = (previous.x + current.x) / 2
            path.addCurve(to: current,
                          control1: CGPoint(x: midpoint, y: previous.y),
                          control2: CGPoint(x: midpoint, y: current.y))
        }
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
        return path
    }

    /// Three clock labels under the plot (two at an accessibility size): the window's start, middle and now.
    private var clockLabels: some View {
        let count = typeSize.isAccessibilitySize ? 2 : 3
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let dates = (0..<count).map { domain.lowerBound.addingTimeInterval(span * Double($0) / Double(count - 1)) }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(dates.enumerated()), id: \.offset) { index, date in
                Text(verbatim: date.formatted(.dateTime.hour().minute().second()))
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity,
                           alignment: index == 0 ? .leading : index == dates.count - 1 ? .trailing : .center)
            }
        }
        .accessibilityHidden(true)
    }
}
