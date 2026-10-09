import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" card at the bottom.

private struct StressDaytimeLoad: Sendable {
    let daytime: DaytimeStress.Result
    let stressIndex: StressIndex.Components?
    let frequencyDomain: HRVFreqDomain.Bands?
}

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loadState = LatestWinsLoadState()
    /// The hour of today under the finger on the hero ribbon (hold and drag), nil when idle.
    @State private var scrubHour: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    private var presentation: StressPresentation {
        StressPresentation(
            daily: model,
            intraday: daytime,
            historyAvailable: StressPresentation.historyAvailable(
                days: repo.days,
                stored: storedSeries
            )
        )
    }

    var body: some View {
        ScreenScaffold(title: "Stress", subtitle: "Autonomic load from HRV and resting heart rate",
                       onRefresh: { await load() },
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Live / Sleep / Trends: a
                       // fixed, full-bleed time-of-day sky behind the scroll content (does not scroll), so the
                       // Stress screen sits in the same liquid atmosphere as every other tab.
                       topBackground: nil) {
            if let model {
                content(model, mode: presentation.mode)
            } else if presentation.mode == .intradayOnly {
                intradayOnlyContent(
                    presentation.intraday,
                    baselineBuilding: !presentation.historyAvailable
                )
            } else {
                switch loadState.phase {
                case .failed(_, let message):
                    loadErrorState(message)
                case .empty(_), .loaded(_):
                    if presentation.mode == .empty {
                        noSignalState
                    } else {
                        baselineCalibrationState
                    }
                case .idle, .loading(_), .cancelled(_):
                    ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
                }
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
    }

    @MainActor
    private func load() async {
        let requestID = loadState.begin()
        let repositoryRevision = repo.refreshSeq
        let sourceDeviceID = repo.deviceId
        guard await repo.storeHandle() != nil else {
            _ = loadState.finish(
                .failed("NOOP could not open the local health store."),
                requestID: requestID)
            return
        }

        async let storedSeriesLoad = repo.series(key: "stress", source: "my-whoop")
        async let daytimeLoad = readDaytime(deviceID: sourceDeviceID)
        let nextStoredSeries = await storedSeriesLoad
        let nextDaytime = await daytimeLoad
        guard !Task.isCancelled else {
            _ = loadState.finish(.cancelled, requestID: requestID)
            return
        }
        guard loadState.owns(requestID),
              repositoryRevision == repo.refreshSeq,
              sourceDeviceID == repo.deviceId else {
            _ = loadState.finish(.cancelled, requestID: requestID)
            return
        }

        storedSeries = nextStoredSeries
        daytime = nextDaytime.daytime
        stressIndex = nextDaytime.stressIndex
        freqHRV = nextDaytime.frequencyDomain
        rebuildModelIfNeeded()

        let hasData = model != nil || !nextDaytime.daytime.hours.isEmpty
        _ = loadState.finish(hasData ? .loaded : .empty, requestID: requestID)
    }

    /// Read TODAY's banked HR + R-R without mutating view state. The caller publishes this value only
    /// after it proves that the request still owns the selected repository revision.
    @MainActor
    private func readDaytime(deviceID: String) async -> StressDaytimeLoad {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            return StressDaytimeLoad(
                daytime: .empty,
                stressIndex: nil,
                frequencyDomain: nil)
        }
        let rr = (try? await repo.storeHandle()?.rrIntervals(
            deviceId: deviceID, from: from, to: to, limit: 200_000)) ?? []
        // These analytics walk large in-memory arrays. Keep the Repository/store reads actor-safe, then
        // move the pure CPU work off the main actor so a dense day cannot stall navigation or scrolling.
        return await Task { @concurrent in
            StressDaytimeLoad(
                daytime: DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: tz),
                stressIndex: StressIndex.components(rr: rr),
                frequencyDomain: HRVFreqDomain.freqDomain(rr: rr))
        }.value
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    private func loadErrorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Stress could not refresh"),
                systemImage: "exclamationmark.triangle.fill",
                tint: .custom(StrandPalette.statusWarning)
            )
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await load() }
            } label: {
                WidgetChip(appTitle: "Try again", systemImage: "arrow.clockwise", showsChevron: false, overhangs: false)
                    .chipHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Try again"))
        }
    }

    // MARK: Loaded content
    //
    // Flat sections on the canvas, one hairline between them: the hero (the big sibling of Today's stress module),
    // today's markers, the advanced HRV lenses, the history (the Trends hero chart) and how the number is built.

    @ViewBuilder
    private func intradayOnlyContent(
        _ day: DaytimeStress.Result,
        baselineBuilding: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stressHero(
                score: presentation.headlineScore,
                message: day.scored.isEmpty
                    ? (baselineBuilding
                       ? String(localized: "Same-day signal is present, but there is not enough scored data yet while your baseline builds.")
                       : String(localized: "Same-day signal is present, but there is not enough scored data yet."))
                    : (baselineBuilding
                       ? String(localized: "Showing the same-day stress signal while your daily baseline builds.")
                       : String(localized: "Showing the same-day stress signal; a daily score has not landed yet.")),
                mode: .intradayOnly
            )
            if day.sustainedHigh {
                DrillInSeparator()
                sustainedBreatheSection(day)
            }
            if hasAdvancedReadouts {
                DrillInSeparator()
                advancedReadoutsSection
            }
            DrillInSeparator()
            methodologySection(nil)
        }
        .sheet(isPresented: $showBreathe) { breatheSheet }
    }

    @ViewBuilder
    private func content(_ model: StressModel, mode: StressPresentationMode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            stressHero(score: model.score, message: model.explanation, mode: mode)
            // Only when the recent run stays in the HIGH band: a passive in-app nudge, never a notification.
            if let daytime, daytime.sustainedHigh {
                DrillInSeparator()
                sustainedBreatheSection(daytime)
            }
            DrillInSeparator()
            markersSection(model)
            if hasAdvancedReadouts {
                DrillInSeparator()
                advancedReadoutsSection
            }
            DrillInSeparator()
            historySection(model)
            DrillInSeparator()
            methodologySection(model)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet: in-app and passive,
        // inheriting the app environment.
        .sheet(isPresented: $showBreathe) { breatheSheet }
    }

    private var breatheSheet: some View {
        NavigationStack {
            BreathingView()
                #if os(iOS)
                // Modal: the scaffold header carries the one close button, not a system bar "Done".
                .toolbar(.hidden, for: .navigationBar)
                .sheetScreenScaffoldEnvironment(onClose: { showBreathe = false })
                #else
                .toolbar {
                    ToolbarItem {
                        Button("Done") { showBreathe = false }
                    }
                }
                #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 760)
        #endif
    }

    // MARK: Hero

    /// Today's 24 hourly slots: a scored hour carries its 0-3 level, every other hour stays empty. The daily
    /// score never fabricates an hourly history.
    private var stressRibbonSlots: [Double?] {
        StressTimelineSlots.map((daytime?.hours ?? []).map { ($0.hour, $0.level) })
    }

    private func stressBandWord(_ level: Double) -> String {
        switch StressModuleBand.band(level) {
        case 0: return String(localized: "Low")
        case 1: return String(localized: "Moderate")
        default: return String(localized: "High")
        }
    }

    /// The big sibling of Today's Stress module: the same eyebrow, value and state, the same hourly ribbon (taller,
    /// with the band guides), then the hours split by band. Hold and drag on the ribbon reads one hour, and the
    /// value, caption and state word morph into that hour, the way the Trends hero chart reads a day.
    private func stressHero(
        score: Double?,
        message: String,
        headline: String? = nil,
        mode: StressPresentationMode
    ) -> some View {
        let slots = stressRibbonSlots
        let scrubbed: (hour: Int, level: Double)? = scrubHour.flatMap { hour in
            slots.indices.contains(hour) ? slots[hour].map { (hour, $0) } : nil
        }
        let shown = scrubbed?.level ?? score
        let tint = StressModuleBand.color(shown)
        let caption: String? = {
            if let scrubbed { return StressDayRibbon.hourLabel(scrubbed.hour) }
            switch mode {
            case .empty: return nil
            case .intradayOnly: return String(localized: "today so far")
            default: return String(localized: "daily score")
            }
        }()
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow(
                title: String(localized: "Stress monitor"),
                systemImage: "bolt.heart",
                tint: .custom(tint)
            )
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                HeroValue(
                    value: shown.map { DrillInFormat.number($0, fractionDigits: 1) } ?? WidgetMetrics.missingValue,
                    unit: shown == nil ? nil : String(localized: "of 3"),
                    caption: caption,
                    captionPlacement: .below
                )
                Spacer(minLength: NoopMetrics.space2)
                ValuePill(shown.map(stressBandWord) ?? String(localized: "No data"), tint: tint)
            }
            .animation(StrandMotion.fade, value: scrubHour)
            VStack(alignment: .leading, spacing: 2) {
                if let headline {
                    Text(headline)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            StressDayRibbon(
                hours: slots,
                nowHour: Calendar.current.component(.hour, from: Date()),
                summary: ribbonSummary(slots),
                scrubHour: $scrubHour
            )
            hourlySplit(slots, mode: mode)
        }
    }

    private func ribbonSummary(_ slots: [Double?]) -> String {
        let scored = slots.enumerated().compactMap { index, level in level.map { (index, $0) } }
        guard let peak = scored.max(by: { $0.1 < $1.1 }) else {
            return String(localized: "No intraday stress data yet today.")
        }
        let counts = bandCounts(slots)
        return String(localized: "Stress by hour today. Peak \(DrillInFormat.number(peak.1, fractionDigits: 1)) at \(StressDayRibbon.hourLabel(peak.0)). \(counts[0]) hours calm, \(counts[1]) moderate, \(counts[2]) high.")
    }

    private func bandCounts(_ slots: [Double?]) -> [Int] {
        var counts = [0, 0, 0]
        for level in slots.compactMap({ $0 }) { counts[StressModuleBand.band(level)] += 1 }
        return counts
    }

    /// The scored hours by band, inline, and the day's peak; or one honest line when no hour could be scored.
    @ViewBuilder
    private func hourlySplit(_ slots: [Double?], mode: StressPresentationMode) -> some View {
        let scored = slots.enumerated().compactMap { index, level in level.map { (index, $0) } }
        if let peak = scored.max(by: { $0.1 < $1.1 }) {
            let counts = bandCounts(slots)
            let peakText = String(localized: "Peak \(DrillInFormat.number(peak.1, fractionDigits: 1)) · \(StressDayRibbon.hourLabel(peak.0))")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NoopMetrics.space3) {
                    splitKeys(counts)
                    Spacer(minLength: 0)
                    Text(peakText).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: NoopMetrics.space3) { splitKeys(counts) }
                    Text(peakText).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        } else if mode != .empty {
            Text("There is not enough same-day signal to build the hourly timeline yet.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func splitKeys(_ counts: [Int]) -> some View {
        splitKey(String(localized: "\(counts[0])h calm"), color: StressHeatStyle.calm, count: counts[0])
        splitKey(String(localized: "\(counts[1])h moderate"), color: StressHeatStyle.moderate, count: counts[1])
        splitKey(String(localized: "\(counts[2])h high"), color: StressHeatStyle.high, count: counts[2])
    }

    @ViewBuilder
    private func splitKey(_ text: String, color: Color, count: Int) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(text).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
        }
    }

    // MARK: Sustained high

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification, just a section with a button that opens the existing trainer.
    private func sustainedBreatheSection(_ day: DaytimeStress.Result) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Sustained high stress"),
                systemImage: "lungs.fill",
                tint: .custom(StressHeatStyle.high),
                trailing: .pill(LocalizedStringKey("\(day.sustainedRun)h elevated"), tone: .warning)
            )
            Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NoopButton("Start a Breathe session", systemImage: "wind",
                       kind: .primary, fullWidth: true) {
                showBreathe = true
            }
        }
    }

    // MARK: Advanced HRV readouts (additive, on-demand)
    //
    // Two extra, clearly-labelled lenses on the SAME day's R-R the hourly ribbon already reads. Each row is shown
    // only when its engine produced a value (the engines self-gate on clean-beat count and record span), and the
    // section only when at least one did. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power).
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    private var advancedReadoutsSection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Advanced HRV"),
                systemImage: "waveform.path.ecg",
                tint: .hrv,
                trailing: .text(String(localized: "on demand · today's R-R"))
            )
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
                if let si = stressIndex {
                    advancedRow(
                        symbol: "bolt.heart",
                        label: String(localized: "Baevsky Stress Index"),
                        value: String(Int(si.si.rounded())),
                        caption: String(localized: "Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm.")
                    )
                }
                // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for LF (lfhf nil)
                // fall back to the HF (rest) band power so the lens still reads.
                if let f = freqHRV {
                    if let ratio = f.lfhf {
                        advancedRow(
                            symbol: "scale.3d",
                            label: String(localized: "Autonomic balance (LF/HF)"),
                            value: DrillInFormat.number(ratio, fractionDigits: 1),
                            caption: String(localized: "Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward).")
                        )
                    } else if f.hf > 0 {
                        advancedRow(
                            symbol: "waveform",
                            label: String(localized: "HF power"),
                            value: String(Int(f.hf.rounded())),
                            caption: String(localized: "Parasympathetic (rest) band of your HRV.")
                        )
                    }
                }
            }
            Text("These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advancedRow(symbol: String, label: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MetricValueRow(systemImage: symbol, label: label, value: value, tint: .hrv)
            Text(caption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, WidgetMetrics.metricIconWidth + NoopMetrics.space2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Markers (today against your 30-day baseline)

    private func markersSection(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Markers"),
                systemImage: "gauge.with.dots.needle.50percent",
                tint: .neutral
            )
            // The last row's tiles each close with their own hairline and bottom padding; the section separator
            // below is the one rule, so that closing hairline and most of its padding are trimmed off.
            tileGrid(model)
                .padding(.bottom, -11)
                .clipped()
        }
    }

    private func tileGrid(_ model: StressModel) -> some View {
        let columns = typeSize >= .xxxLarge
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: NoopMetrics.space3), GridItem(.flexible())]
        let rampColor = StressModuleBand.color(model.score)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            // Today's stress value, with its band as the caption.
            StatTile(
                label: "Stress",
                value: DrillInFormat.number(model.score, fractionDigits: 1),
                caption: String(localized: "of 3 · \(stressBandWord(model.score))"),
                accent: rampColor,
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: rampColor,
                systemImage: "bolt.heart",
                tint: .custom(rampColor)
            )
            // Resting HR: an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { String(localized: "\($0) bpm") } ?? "—",
                delta: model.rhrDelta,
                symbol: "heart.fill",
                tint: .heart,
                higherIsStress: true
            )
            // HRV: a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { String(localized: "\(Int($0.rounded())) ms") } ?? "—",
                delta: model.hrvDelta,
                symbol: "waveform.path.ecg",
                tint: .hrv,
                higherIsStress: false
            )
            // Estimated calm time: the share of recent days spent in the LOW band.
            StatTile(
                label: "Calm time",
                value: model.calmTimeValue,
                caption: model.calmTimeCaption,
                accent: StressHeatStyle.calm,
                systemImage: "leaf.fill",
                tint: .custom(StressHeatStyle.calm)
            )
        }
    }

    /// A vs-baseline marker. The chip carries only the signed change (the unit is the tile's own, and the caption
    /// says "vs 30-day baseline"), so it never truncates; it is tinted by whether the move is toward stress
    /// (warning) or recovery (positive).
    private func markerTile(label: LocalizedStringKey, value: String, delta: Double?, symbol: String,
                            tint: DomainTint, higherIsStress: Bool) -> some View {
        let deltaText: String
        let deltaColor: Color
        let caption: String?
        if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            deltaText = DrillInFormat.signed(delta.rounded())
            deltaColor = (up == higherIsStress) ? StrandPalette.statusWarning : StrandPalette.statusPositive
            caption = String(localized: "vs 30-day baseline")
        } else {
            deltaText = String(localized: "at baseline")
            deltaColor = StrandPalette.textTertiary
            caption = nil
        }
        return StatTile(
            label: label,
            value: value,
            caption: caption,
            accent: tint.accent,
            delta: deltaText,
            deltaColor: deltaColor,
            systemImage: symbol,
            tint: tint
        )
    }

    // MARK: History (the Trends hero chart)

    private func historySection(_ model: StressModel) -> some View {
        let observations = stressObservations(model)
        return DrillInTrendSection(
            title: String(localized: "Stress trend"),
            metric: .stress,
            observations: observations,
            referenceDate: observations.last?.date ?? Calendar.current.startOfDay(for: Date()),
            latest: model.score,
            valueBounds: 0...3,
            emptyMessage: String(localized: "Not enough recent days to chart a trend yet. Import a history or keep wearing your strap.")
        )
    }

    /// The daily proxy history as calendar days. The model keys each day at UTC midnight of its civil date, so the
    /// civil date is read back in UTC and rebuilt as a local day, the way the rest of the app reads day keys.
    private func stressObservations(_ model: StressModel) -> [CalendarMetricDay] {
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return model.fullTrend.compactMap { point in
            let parts = utc.dateComponents([.year, .month, .day], from: point.date)
            guard let date = local.date(from: parts) else { return nil }
            return CalendarMetricDay(date: local.startOfDay(for: date), value: point.value)
        }
    }

    // MARK: How the number is built (transparency)

    private func methodologySection(_ model: StressModel?) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "How this is computed"),
                systemImage: "function",
                tint: .neutral
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(model?.usingStored == true
                     ? String(localized: "Today's value is your recorded daily stress score (0-3).")
                     : String(localized: "Stress is derived from two autonomic signals."))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BandScaleBar(
                [
                    .init(id: "low", word: String(localized: "Low"), range: "0–1", color: StressHeatStyle.calm),
                    .init(id: "moderate", word: String(localized: "Moderate"), range: "1–2", color: StressHeatStyle.moderate),
                    .init(id: "high", word: String(localized: "High"), range: "2–3", color: StressHeatStyle.high),
                ],
                marker: model.map { min(max($0.score / 3, 0), 1) }
            )
        }
    }

    // MARK: Empty state

    private var baselineCalibrationState: some View {
        ComingSoon(what: "Building your stress baseline. Wear your WHOOP overnight or import prior history.")
    }

    /// Today has no scorable signal, though a baseline exists: the same hero with its honest empty ribbon.
    private var noSignalState: some View {
        VStack(alignment: .leading, spacing: 0) {
            stressHero(
                score: nil,
                message: String(localized: "Your historical baseline is available, but today has not supplied enough daily or hourly signal."),
                headline: String(localized: "No stress signal today"),
                mode: .empty
            )
            DrillInSeparator()
            methodologySection(nil)
        }
    }
}

// MARK: - Stress band

enum StressBand: Hashable {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        guard let today = days.last else { return nil }

        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Baseline window: up to 30 days ending the day BEFORE today, so "today"
        // is measured against its own recent past rather than itself.
        let history = Array(days.dropLast())
        let baseline = Array(history.suffix(30))

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

enum StressPresentationMapper {
    static func band(for level: Double) -> StressBand {
        StressBand(score: level)
    }

    static func peakAnnotation(
        peak: DaytimeStress.HourPoint?,
        hourLabel: (Int) -> String
    ) -> String? {
        guard let peak, let level = peak.level else { return nil }
        return String(localized: "PEAK \(String(format: "%.1f", level)) · \(hourLabel(peak.hour))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}
