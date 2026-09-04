import Foundation
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One bounded, explicit day-versus-night comparison window. The waking interval starts when the
/// previous main sleep ends and stops when the displayed main sleep starts. Any recorded sleep inside
/// that interval is removed from the wake grid, so a nap is never mislabeled as awake time.
struct SleepHeartRateWindowPlan: Equatable, Sendable {
    struct ExcludedSleep: Equatable, Sendable {
        let start: Int
        let end: Int
    }

    static let cadenceSeconds = 60
    static let minimumWakeWindowSeconds = 30 * 60
    static let maximumWakeWindowSeconds = 36 * 60 * 60

    let wakeStart: Int
    let wakeEnd: Int
    let sleepStart: Int
    let sleepEnd: Int
    let excludedWakeSleep: [ExcludedSleep]

    /// Find the previous day's main sleep using the same shared selector as the Sleep screen. A gap
    /// longer than 36 hours fails closed instead of silently becoming an unbounded history read.
    static func make(
        sleepStart: Int,
        sleepEnd: Int,
        sessions: [CachedSleepSession],
        habitualMidsleepSec: Int?,
        timeZone: TimeZone = .current
    ) -> SleepHeartRateWindowPlan? {
        let (sleepDuration, sleepOverflow) = sleepEnd.subtractingReportingOverflow(sleepStart)
        guard !sleepOverflow, sleepDuration > 0 else { return nil }

        let prior = sessions.filter {
            $0.endTs <= sleepStart && $0.effectiveStartTs < $0.endTs
        }
        let grouped = Dictionary(grouping: prior) { session in
            localDayKey(session.endTs, timeZone: timeZone)
        }
        let candidateDays = grouped.values.sorted {
            ($0.map(\.endTs).max() ?? Int.min) > ($1.map(\.endTs).max() ?? Int.min)
        }

        var priorMainEnd: Int?
        for day in candidateDays {
            let offset = day.map(\.endTs).max().map {
                timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval($0)))
            } ?? 0
            let blocks = day.map {
                SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs)
            }
            guard let indices = SleepStageTotals.mainNightGroupIndices(
                blocks,
                offsetSec: offset,
                habitualMidsleepSec: habitualMidsleepSec
            ) else { continue }
            let end = indices.map { day[$0].endTs }.max()
            if let end, end <= sleepStart {
                priorMainEnd = end
                break
            }
        }

        guard let wakeStart = priorMainEnd else { return nil }
        let (wakeDuration, wakeOverflow) = sleepStart.subtractingReportingOverflow(wakeStart)
        guard !wakeOverflow,
              wakeDuration >= minimumWakeWindowSeconds,
              wakeDuration <= maximumWakeWindowSeconds else { return nil }

        let exclusions = sessions.compactMap { session -> ExcludedSleep? in
            let start = max(wakeStart, session.effectiveStartTs)
            let end = min(sleepStart, session.endTs)
            return start < end ? ExcludedSleep(start: start, end: end) : nil
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }

        return SleepHeartRateWindowPlan(
            wakeStart: wakeStart,
            wakeEnd: sleepStart,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            excludedWakeSleep: exclusions
        )
    }

    /// Convert SQL minute buckets into a complete minute grid. Only full minutes are included. Missing
    /// buckets stay nil, and recorded sleep epochs are omitted from the wake denominator altogether.
    static func fixedGrid(
        buckets: [HRBucket],
        from: Int,
        to: Int,
        excluding: [ExcludedSleep] = []
    ) -> [Double?] {
        guard from >= 0, from < to else { return [] }
        let cadence = cadenceSeconds
        let remainder = from % cadence
        let addition = remainder == 0 ? 0 : cadence - remainder
        let (first, overflow) = from.addingReportingOverflow(addition)
        guard !overflow else { return [] }
        let endExclusive = to - (to % cadence)
        guard first < endExclusive else { return [] }

        let byTimestamp = Dictionary(
            buckets.map { ($0.ts, $0.bpm) },
            uniquingKeysWith: { _, last in last }
        )
        var result: [Double?] = []
        result.reserveCapacity((endExclusive - first) / cadence)
        var timestamp = first
        while timestamp < endExclusive {
            let (next, nextOverflow) = timestamp.addingReportingOverflow(cadence)
            guard !nextOverflow else { return [] }
            let isRecordedSleep = excluding.contains { range in
                timestamp < range.end && next > range.start
            }
            if !isRecordedSleep {
                result.append(byTimestamp[timestamp])
            }
            timestamp = next
        }
        return result
    }

    private static func localDayKey(_ timestamp: Int, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Small task identity for the async comparison leaf. `sessionsRevision` is advanced only when the parent
/// finishes replacing its first-frame rows with complete sleep history, so no session array is hashed on a
/// one-Hz render pass. Habitual timing remains explicit because it can change the shared main-sleep pick.
struct SleepHeartRateLoadKey: Equatable, Sendable {
    let sleepStart: Int
    let sleepEnd: Int
    let sourceId: String?
    let repositoryRevision: Int
    let sessionsRevision: Int
    let habitualMidsleepSec: Int?
}

/// Async leaf for the Sleep screen. It owns both bounded SQL reads and its loading state so the heavy,
/// memoized parent never subscribes to the result or rebuilds during the fetch.
struct SleepHeartRateContrastSection: View {
    let sleepStart: Int
    let sleepEnd: Int
    let sessions: [CachedSleepSession]
    let habitualMidsleepSec: Int?
    /// Changes after the Sleep screen replaces its first-frame deduplicated sessions with the complete
    /// history. This makes newly loaded naps immediately participate in wake-time exclusion even when the
    /// displayed night's own bounds and the repository refresh sequence did not change.
    let sessionsRevision: Int

    @EnvironmentObject private var repo: Repository
    @State private var state: LoadState = .loading

    private enum UnavailableReason: Equatable {
        case noPriorMainSleep
        case ambiguousSource
        case insufficientCoverage
    }

    private enum LoadState: Equatable {
        case loading
        case unavailable(UnavailableReason)
        case ready(SleepHeartRateContrast.Result)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                statusCard(
                    title: String(localized: "Comparing sleep and wake HR"),
                    detail: String(localized: "Reading one-minute heart-rate coverage for this sleep and the waking span before it."),
                    showsProgress: true
                )
            case .unavailable(.noPriorMainSleep):
                statusCard(
                    title: String(localized: "One more full sleep needed"),
                    detail: String(localized: "NOOP needs a prior main sleep to define the waking span before this night."),
                    showsProgress: false
                )
            case .unavailable(.ambiguousSource):
                statusCard(
                    title: String(localized: "One clear strap source needed"),
                    detail: String(localized: "NOOP cannot compare this night while heart-rate history spans more than one strap source."),
                    showsProgress: false
                )
            case .unavailable(.insufficientCoverage):
                statusCard(
                    title: String(localized: "More heart-rate coverage needed"),
                    detail: String(localized: "Wear your strap through the day and overnight. NOOP needs at least 30 valid one-minute readings in both periods."),
                    showsProgress: false
                )
            case .ready(let result):
                resultCard(result)
            }
        }
        .task(id: SleepHeartRateLoadKey(
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            sourceId: repo.sleepHeartRateComparisonSourceId,
            repositoryRevision: repo.refreshSeq,
            sessionsRevision: sessionsRevision,
            habitualMidsleepSec: habitualMidsleepSec
        )) {
            await load(sourceId: repo.sleepHeartRateComparisonSourceId)
        }
    }

    private func load(sourceId: String?) async {
        state = .loading
        guard let sourceId else {
            state = .unavailable(.ambiguousSource)
            return
        }
        guard let plan = SleepHeartRateWindowPlan.make(
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            sessions: sessions,
            habitualMidsleepSec: habitualMidsleepSec
        ) else {
            state = .unavailable(.noPriorMainSleep)
            return
        }

        async let wakeLoad = repo.hrBuckets(
            sourceId: sourceId,
            from: plan.wakeStart,
            to: plan.wakeEnd - 1,
            bucketSeconds: SleepHeartRateWindowPlan.cadenceSeconds
        )
        async let sleepLoad = repo.hrBuckets(
            sourceId: sourceId,
            from: plan.sleepStart,
            to: plan.sleepEnd - 1,
            bucketSeconds: SleepHeartRateWindowPlan.cadenceSeconds
        )
        let (wakeBuckets, sleepBuckets) = await (wakeLoad, sleepLoad)
        guard !Task.isCancelled else { return }

        let wake = SleepHeartRateWindowPlan.fixedGrid(
            buckets: wakeBuckets,
            from: plan.wakeStart,
            to: plan.wakeEnd,
            excluding: plan.excludedWakeSleep
        )
        let sleep = SleepHeartRateWindowPlan.fixedGrid(
            buckets: sleepBuckets,
            from: plan.sleepStart,
            to: plan.sleepEnd
        )
        guard let result = SleepHeartRateContrast.evaluate(wakeHR: wake, primarySleepHR: sleep) else {
            state = .unavailable(.insufficientCoverage)
            return
        }
        state = .ready(result)
    }

    private func statusCard(title: String, detail: String, showsProgress: Bool) -> some View {
        PaperCard {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                if showsProgress {
                    ProgressView()
                        .tint(StrandPalette.restColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(StrandPalette.restColor)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func resultCard(_ result: SleepHeartRateContrast.Result) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("SLEEP VS AWAKE").strandOverline()
                    Spacer()
                    StatePill("descriptive", tone: .neutral, showsDot: false)
                }

                HStack(spacing: NoopMetrics.gap) {
                    comparisonValue("Awake", bpm: result.wakeMeanBpm)
                    comparisonValue("Asleep", bpm: result.sleepMeanBpm)
                }

                Text(deltaText(result.sleepMinusWakeBpm))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                Text("Previous wake span · recorded naps excluded · one-minute means")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Coverage: awake \(percent(result.wakeCoverage)) · asleep \(percent(result.sleepCoverage)). This does not change Resting HR, Charge, Rest, Effort, or any other score.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(result))
    }

    private func comparisonValue(_ title: LocalizedStringKey, bpm: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.0f", bpm))
                    .font(StrandFont.metricValue)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("bpm")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deltaText(_ delta: Double) -> String {
        let amount = String(format: "%.0f", abs(delta))
        if delta < -0.5 { return String(localized: "Heart rate was \(amount) bpm lower during sleep") }
        if delta > 0.5 { return String(localized: "Heart rate was \(amount) bpm higher during sleep") }
        return String(localized: "Heart rate was about the same during sleep")
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }

    private func accessibilitySummary(_ result: SleepHeartRateContrast.Result) -> String {
        String(localized: "Sleep versus awake heart rate. Awake mean \(String(format: "%.0f", result.wakeMeanBpm)) beats per minute. Asleep mean \(String(format: "%.0f", result.sleepMeanBpm)) beats per minute. \(deltaText(result.sleepMinusWakeBpm)). Awake coverage \(percent(result.wakeCoverage)); asleep coverage \(percent(result.sleepCoverage)). Descriptive only; no score changes.")
    }
}

/// Explicitly opt-in pre-sleep feedback. The engine owns consent and all storage cleanup; this leaf
/// reads the persisted observation and boundary fields and applies the pure personal-baseline policy.
struct PreSleepHeartRateFeedbackSection: View {
    let wakeDay: String
    let sleepStart: Int
    let sleepEnd: Int
    let sessions: [CachedSleepSession]
    let habitualMidsleepSec: Int?
    let sessionsRevision: Int

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @AppStorage(PreSleepHeartRateFeedback.enabledKey) private var isEnabled = false

    @State private var feedback: PreSleepHeartRateFeedback.Feedback?
    @State private var loaded = false
    @State private var actionInFlight = false
    @State private var actionMessage: String?
    @State private var reloadGeneration = 0
    @State private var confirmsTurnOff = false

    private var effectiveIsEnabled: Bool {
        #if DEBUG
        AppleDemoSeeder.effectivePreSleepFeedbackEnabled(
            userOptIn: isEnabled,
            demoRequested: AppleDemoSeeder.requested
        )
        #else
        isEnabled
        #endif
    }

    private var isDemoOverride: Bool {
        #if DEBUG
        AppleDemoSeeder.requested && !isEnabled
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if !effectiveIsEnabled {
                optInCard
            } else if !loaded {
                loadingCard
            } else if let feedback {
                enabledCard(feedback)
            } else {
                buildingCard
            }
        }
        .task(id: "\(wakeDay)-\(sleepStart)-\(sleepEnd)-\(effectiveIsEnabled)-\(repo.refreshSeq)-\(sessionsRevision)-\(reloadGeneration)") {
            await loadStoredFeedback()
        }
        .confirmationDialog(
            "Turn off pre-sleep HR?",
            isPresented: $confirmsTurnOff,
            titleVisibility: .visible
        ) {
            Button("Turn off and remove history", role: .destructive) {
                setEnabled(false)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("NOOP removes the stored nightly pre-sleep means, sample counts, and reading bounds. Your raw heart-rate and sleep data stay unchanged.")
        }
    }

    private var optInCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.text.square")
                        .foregroundStyle(StrandPalette.restColor)
                        .accessibilityHidden(true)
                    Text("Pre-sleep heart rate")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Compare your mean heart rate during the 30 minutes before main sleep with your own recent nights.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("When on, NOOP stores one nightly mean, its sample counts, and the sleep bounds used for that reading on this device. It does not change any score, explain why heart rate changed, or give medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(actionInFlight ? "Turning on…" : "Turn on pre-sleep HR") {
                    setEnabled(true)
                }
                .buttonStyle(.noopSecondary)
                .disabled(actionInFlight)
                .frame(minHeight: 44)
                if let actionMessage {
                    Text(actionMessage)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var loadingCard: some View {
        PaperCard {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                ProgressView()
                    .tint(StrandPalette.restColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Building your pre-sleep view")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Reading the nightly summaries stored on this device.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buildingCard: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                enabledHeader
                Text("Needs another complete pre-sleep window")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Keep your strap on for the 30 minutes before main sleep. NOOP needs at least 10 valid heart-rate samples.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionFailureIfNeeded
                turnOffButton
            }
        }
    }

    private func enabledCard(_ feedback: PreSleepHeartRateFeedback.Feedback) -> some View {
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                enabledHeader
                if let observation = feedback.observation {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.0f", observation.meanBpm))
                            .font(StrandFont.metricValue)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .contentTransition(.numericText())
                        Text("bpm")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Text(feedbackHeadline(feedback))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feedbackDetail(feedback))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let context = journalContext(feedback), !context.isEmpty {
                    Text("Journal context: \(context). Context is not a cause.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Descriptive only. This does not change Resting HR, Charge, Rest, Effort, or any other score.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actionFailureIfNeeded
                turnOffButton
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var enabledHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("PRE-SLEEP HR").strandOverline()
            Spacer()
            StatePill("on", tone: .accent, showsDot: false)
        }
    }

    @ViewBuilder
    private var actionFailureIfNeeded: some View {
        if let actionMessage {
            Text(actionMessage)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var turnOffButton: some View {
        Group {
            if !isDemoOverride {
                Button("Turn off") { confirmsTurnOff = true }
                    .buttonStyle(.noopGhost)
                    .disabled(actionInFlight)
                    .frame(minHeight: 44)
                    .accessibilityHint("Removes stored pre-sleep heart-rate summaries after confirmation")
            }
        }
    }

    private func loadStoredFeedback() async {
        feedback = nil
        guard effectiveIsEnabled else {
            loaded = true
            return
        }
        loaded = false
        async let meanLoad = repo.exploreSeries(
            key: PreSleepHeartRateFeedback.meanMetricKey,
            source: "my-whoop",
            days: 60
        )
        async let validLoad = repo.exploreSeries(
            key: PreSleepHeartRateFeedback.validSamplesMetricKey,
            source: "my-whoop",
            days: 60
        )
        async let totalLoad = repo.exploreSeries(
            key: PreSleepHeartRateFeedback.totalSamplesMetricKey,
            source: "my-whoop",
            days: 60
        )
        async let startLoad = repo.exploreSeries(
            key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
            source: "my-whoop",
            days: 60
        )
        async let endLoad = repo.exploreSeries(
            key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
            source: "my-whoop",
            days: 60
        )
        async let journalLoad = repo.journalEntries(days: 60)
        let (means, validSamples, totalSamples, starts, ends, journal) = await (
            meanLoad, validLoad, totalLoad, startLoad, endLoad, journalLoad
        )
        guard !Task.isCancelled else { return }

        let meansByDay = Dictionary(means.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let validByDay = Dictionary(validSamples.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let totalByDay = Dictionary(totalSamples.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let startByDay = Dictionary(starts.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        let endByDay = Dictionary(ends.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        guard let mean = meansByDay[wakeDay],
              let valid = sampleCount(validByDay[wakeDay]),
              let total = sampleCount(totalByDay[wakeDay]),
              valid <= total,
              Self.observationBoundsMatch(
                storedStart: startByDay[wakeDay],
                storedEnd: endByDay[wakeDay],
                currentStart: sleepStart,
                currentEnd: sleepEnd
              ) else {
            loaded = true
            return
        }
        let (windowStart, overflow) = sleepStart.subtractingReportingOverflow(
            PreSleepHeartRateFeedback.defaultPreSleepWindowSeconds
        )
        guard !overflow else {
            loaded = true
            return
        }
        let observation = PreSleepHeartRateFeedback.Observation(
            primarySleepStartTs: sleepStart,
            primarySleepEndTs: sleepEnd,
            windowStartTs: windowStart,
            windowEndTs: sleepStart,
            meanBpm: mean,
            validSamples: valid,
            totalTimestampSamples: total
        )
        let history = Self.validHistoricalReadings(
            means: means,
            storedStarts: startByDay,
            storedEnds: endByDay,
            sessions: sessions,
            habitualMidsleepSec: habitualMidsleepSec,
            calendar: .current
        )
        feedback = PreSleepHeartRateFeedback.evaluate(
            observation: observation,
            history: history,
            journalEntries: journal,
            day: wakeDay
        )
        loaded = true
    }

    /// A day-keyed mean is displayable only against the exact sleep bounds that produced it. Missing
    /// legacy fields and a newly edited bedtime/wake time both fail closed until analysis republishes.
    nonisolated static func observationBoundsMatch(
        storedStart: Double?,
        storedEnd: Double?,
        currentStart: Int,
        currentEnd: Int
    ) -> Bool {
        guard let storedStart, let storedEnd,
              storedStart.isFinite, storedEnd.isFinite,
              currentStart < currentEnd else { return false }
        return storedStart == Double(currentStart) && storedEnd == Double(currentEnd)
    }

    /// Persisted historical means are baseline inputs, so the same exact-boundary rule as the displayed
    /// observation applies to every prior day. Resolve that day's authoritative main-night group from the
    /// complete Sleep navigation rows and drop missing, deleted, or boundary-mismatched observations. This
    /// is the final fail-closed guard when a sleep mutation races an already-running analysis writer.
    nonisolated static func validHistoricalReadings(
        means: [(day: String, value: Double)],
        storedStarts: [String: Double],
        storedEnds: [String: Double],
        sessions: [CachedSleepSession],
        habitualMidsleepSec: Int?,
        calendar: Calendar
    ) -> [PreSleepHeartRateFeedback.HistoricalReading] {
        let sessionsByWakeDay = Dictionary(grouping: sessions.filter {
            $0.effectiveStartTs < $0.endTs
        }) { session in
            let wake = Date(timeIntervalSince1970: TimeInterval(session.endTs))
            let year = calendar.component(.year, from: wake)
            let month = calendar.component(.month, from: wake)
            let day = calendar.component(.day, from: wake)
            return String(format: "%04d-%02d-%02d", year, month, day)
        }

        return means.compactMap { mean in
            guard let daySessions = sessionsByWakeDay[mean.day], !daySessions.isEmpty else { return nil }
            // Match SleepView's authoritative picker, which intentionally uses the device's current
            // civil offset together with the learned habitual midpoint for every browsed day.
            let offsetSeconds = calendar.timeZone.secondsFromGMT()
            guard let indices = SleepStageTotals.mainNightGroupIndices(
                daySessions.map {
                    SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs)
                },
                offsetSec: offsetSeconds,
                habitualMidsleepSec: habitualMidsleepSec
            ),
                  let primaryStart = indices.map({ daySessions[$0].effectiveStartTs }).min(),
                  let primaryEnd = indices.map({ daySessions[$0].endTs }).max(),
                  observationBoundsMatch(
                    storedStart: storedStarts[mean.day],
                    storedEnd: storedEnds[mean.day],
                    currentStart: primaryStart,
                    currentEnd: primaryEnd
                  ) else { return nil }
            return PreSleepHeartRateFeedback.HistoricalReading(
                day: mean.day,
                meanBpm: mean.value
            )
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard !actionInFlight else { return }
        actionInFlight = true
        actionMessage = nil
        Task {
            let succeeded = await intelligence.setPreSleepHeartRateFeedbackEnabled(enabled)
            if !succeeded {
                actionMessage = enabled
                    ? String(localized: "Pre-sleep HR is on, but the first analysis is still waiting. NOOP will retry.")
                    : String(localized: "NOOP kept pre-sleep HR on because it could not verify that its stored summaries were removed.")
            }
            reloadGeneration += 1
            actionInFlight = false
        }
    }

    private func sampleCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0,
              value <= Double(Int.max), value.rounded() == value else { return nil }
        return Int(value)
    }

    private func feedbackHeadline(_ feedback: PreSleepHeartRateFeedback.Feedback) -> String {
        switch feedback.eligibility {
        case .eligible:
            guard let comparison = feedback.comparison else { return String(localized: "Personal comparison unavailable") }
            let amount = String(format: "%.0f", abs(comparison.deltaBpm))
            if comparison.deltaBpm < -0.5 {
                return String(localized: "\(amount) bpm below your recent pre-sleep baseline")
            }
            if comparison.deltaBpm > 0.5 {
                return String(localized: "\(amount) bpm above your recent pre-sleep baseline")
            }
            return String(localized: "About the same as your recent pre-sleep baseline")
        case .insufficientBaseline(let valid, let required):
            return String(localized: "Building your personal baseline · \(valid)/\(required) nights")
        case .staleBaseline(_):
            return String(localized: "Your personal baseline needs recent nights")
        default:
            return String(localized: "More pre-sleep coverage needed")
        }
    }

    private func feedbackDetail(_ feedback: PreSleepHeartRateFeedback.Feedback) -> String {
        if let comparison = feedback.comparison {
            return String(localized: "Compared with \(comparison.baselineNights) prior valid nights. This can show a pattern, not why it happened.")
        }
        switch feedback.eligibility {
        case .insufficientBaseline(_, let required):
            return String(localized: "NOOP needs \(required) prior valid nights before it compares this value with your own recent pattern.")
        case .staleBaseline(let days):
            return String(localized: "The latest valid baseline night was \(days) days ago, so NOOP is not comparing this value yet.")
        default:
            return String(localized: "Keep the strap on during the 30 minutes before main sleep. NOOP needs at least 10 valid samples.")
        }
    }

    private func journalContext(_ feedback: PreSleepHeartRateFeedback.Feedback) -> String? {
        let facts = feedback.journalContext.prefix(2).map { fact in
            if let value = fact.numericValue {
                return "\(fact.question) \(String(format: "%.0f", value))"
            }
            return fact.answeredYes ? fact.question : "No \(fact.question.lowercased())"
        }
        return facts.isEmpty ? nil : facts.joined(separator: ", ")
    }
}
