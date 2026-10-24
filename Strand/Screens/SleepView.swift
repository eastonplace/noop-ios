import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

// MARK: - Sleep presentation mapping

/// Pure, view-only formatting for the two stage-row treatments on the Sleep screen.
/// Inputs are the already-resolved `SleepModel` stage totals; this mapper never reads
/// repository state or changes the engine's stage/debt calculations.
struct SleepStageRowPresentation: Equatable {
    enum DeltaTone: Equatable {
        case positive
        case warning
    }

    let fraction: Double
    let percent: Int
    let minutes: Double
    let duration: String
    let delta: String?
    /// The same difference without the "vs typ" tail ("+7m", "−12m"), for rows that say what it is against.
    let shortDelta: String?
    let deltaTone: DeltaTone?
    /// Within half a minute of the personal typical, whatever the language the delta text is in.
    let isOnTypical: Bool

    /// `percent` overrides the rounded share when the caller has already shared 100% out across the stages
    /// (see `SleepStageShares`), so the rows add up.
    init(stage: SleepStage, minutes: Double, total: Double, typical: Double? = nil, percent: Int? = nil) {
        let clampedMinutes = max(0, minutes)
        self.minutes = clampedMinutes
        fraction = total > 0 ? min(1, max(0, clampedMinutes / total)) : 0
        self.percent = percent ?? Int((fraction * 100).rounded())
        duration = Self.durationText(clampedMinutes)

        guard let typical, typical > 0 else {
            delta = nil
            shortDelta = nil
            deltaTone = nil
            isOnTypical = false
            return
        }

        let difference = clampedMinutes - typical
        isOnTypical = abs(difference) < 0.5
        let sign = difference >= 0 ? "+" : "−"
        delta = String(localized: "\(sign)\(Self.durationText(abs(difference))) vs typ")
        shortDelta = "\(sign)\(Self.durationText(abs(difference)))"

        // Design-lab parity: more Awake is the unfavorable direction; more REM,
        // Deep, or Light is favorable. This is presentation tinting only.
        let isGood = stage == .awake ? difference <= 0 : difference >= 0
        deltaTone = isGood ? .positive : .warning
    }

    static func durationText(_ minutes: Double) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        if rounded < 60 { return String(localized: "\(rounded)m") }
        return String(localized: "\(rounded / 60)h \(rounded % 60)m")
    }
}

/// Honest paper-window strings. Staged nights preserve the existing stage-total semantics;
/// stage-less stubs use the persisted effective start→end coverage for "in bed" and never
/// turn unknown asleep time into a measured zero.
struct SleepWindowPresentation: Equatable {
    let asleepDuration: String
    let inBedDuration: String

    init(
        hasStageData: Bool,
        asleepMinutes: Double,
        stagedInBedMinutes: Double,
        sessionStartTs: Int,
        sessionEndTs: Int
    ) {
        asleepDuration = hasStageData
            ? SleepStageRowPresentation.durationText(asleepMinutes)
            : "—"
        let recordedMinutes = max(0, Double(sessionEndTs - sessionStartTs) / 60.0)
        inBedDuration = SleepStageRowPresentation.durationText(
            hasStageData ? stagedInBedMinutes : recordedMinutes
        )
    }
}

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Scannable in two seconds:
//   1. HERO ChartCard "Last night" — the stage breakdown (Hypnogram if intervals
//      reconstruct from stagesJSON, else a clean proportional stacked stage bar),
//      trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. A uniform grid of fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory, Sleep Debt.
//   2b. The sleep-debt LEDGER card — a rolling 14-night running balance of (slept −
//      personal need) with a plain-English read and a diverging per-night delta bar.
//   3. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   4. A 30-day asleep-hours ChartCard trend.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var behavior: BehaviorStore
    // NOTE: SleepView itself deliberately does NOT observe `LiveState`. A connected strap publishes
    // at ~1 Hz; observing here would re-evaluate this heavy body on every tick. The only two live
    // dependencies — the "going to sleep / awake" mark card (it appends to the strap log) and the
    // "Syncing strap history…" note — each own their OWN `@EnvironmentObject var live` in a small
    // leaf below (mirrors the Today leaf-scoping pattern), so a tick refreshes only that leaf.
    @EnvironmentObject var intelligence: IntelligenceEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    /// Which night the hero hypnogram shows: 0 = last night, N = N sleep-sessions back.
    /// Snaps back to 0 whenever the data key changes — a stale offset would silently point
    /// at a different session after a sync. The memoized trend `model` stays cached since
    /// the trends are night-independent. (#160)
    @State private var nightOffset = 0
    /// Memoized decode of the NAVIGATED night (nil when `nightOffset == 0` — the hero reads
    /// `model.night` then). Rebuilt only by the explicit navigation action / data-key refresh;
    /// `decodedNight` JSON-decodes, which must never run per body pass (1Hz HR ticks). (#160)
    @State private var navNight: Night?

    /// Every sleep BLOCK across both sources, UN-deduplicated (`repo.allSleepSessions`) — `repo.sleeps`
    /// keeps one winner per night for the dashboard, collapsing split-sleep days (a nap + a main
    /// sleep on the same day) into a single block. The hero groups these by day (`navDays`) and
    /// merges each day into one Night, so a split day reads as one correctly-totalled night with the
    /// gaps preserved. Oldest→newest. Falls back to `repo.sleeps` until loaded. (#170)
    @State private var allSessions: [CachedSleepSession] = []
    /// Advances after the complete un-deduplicated session set and habitual midpoint finish loading.
    /// Async leaf views use it to refresh calculations whose visible night's bounds may stay unchanged.
    @State private var sleepHistoryRevision = 0
    @State private var presentationNeeds: [String: SleepPresentationNeed] = [:]
    @State private var needsLoading = true
    @State private var needsFailed = false
    /// Legacy malformed sessions are excluded from all score/display selection but remain repairable here.
    @State private var invalidSessions: [CachedSleepSession] = []

    /// The user's LEARNED habitual midsleep (local time-of-day seconds), or nil under the cold-start
    /// threshold. Loaded from `repo.habitualMidsleepSec()` — the SAME value `AnalyticsEngine.analyzeDay`
    /// threads into the daily total — and fed into the main-night selector so the hero, the naps split,
    /// and the edit target pick the SAME block the analytics rollup did, for a shift/late sleeper too. nil
    /// keeps the existing cold-start overnight-band fallback. (#547) Refreshed with `allSessions`.
    @State private var habitualMidsleepSec: Int? = nil

    /// Persisted per-epoch MOTION series keyed by each session's detected `startTs` (#407). Loaded in the
    /// same `.task` as `allSessions` from `repo.sessionMotions(starts:)`, then laid along the hypnogram for
    /// the SAME main-night GROUP blocks the hero resolved (mergeDay's group) — we do NOT re-resolve the
    /// night, only read the already-chosen group's stored motion. A block with no stored series stays absent
    /// (honest empty state for older rows whose `motionJSON` is NULL). Refreshed with `allSessions`.
    @State private var motionByStart: [Int: [Double]] = [:]

    /// Non-nil while the wake-time editor sheet is open. Carries the night's stable key (`startTs`) and
    /// current wake time so the editor seeds its picker; saving routes through `repo.editSleepWakeTime`,
    /// which marks the session `userEdited` so a later strap sync can't revert the correction. (#318)
    @State private var wakeEdit: WakeEdit?

    /// The ⓘ explainer open from a Sleep section header (score, stages, night detail, tonight), if any.
    @State private var metricInfo: MetricInfo?

    /// Non-nil while the "Add nap" picker sheet is open (#508). Carries a seed bed/wake for the picker;
    /// saving routes through `repo.addManualNap`, which stages the chosen window from raw and writes it as
    /// its OWN separate session row (`userEdited = 1`) — never folded into the night's main sleep.
    @State private var addNap: AddNapSeed?

    /// The "why this is your main sleep" reason, shown as the first section ("Why this night") of the Sleep stages
    /// explainer; set when its ⓘ is tapped. The text comes straight from the foundation `MainNightReason` for the
    /// displayed night's blocks, never re-derived here. (spec 2026-06-20 C1)
    @State private var stagesMainSleepReason: String?
    /// The stable detected key of the nap whose "why this is a nap" popover is open, or nil. Keyed by
    /// the nap's own `startTs` so one popover shows at a time even with several nap rows. (C1)
    @State private var napWhyStartTs: Int?

    /// WHOOP-style stage highlight: tapping a stage row under the timeline lights that stage up on the
    /// chart and recedes the rest (tap again to clear). Display-only selection state. (ryanAtriumAi #988)
    @State private var selectedStage: SleepStage? = nil

    /// The transient UNDO banner shown after a suppressing delete (#65). Non-nil for ~7 seconds: carries
    /// the snapshot needed to restore the deleted night into its ORIGINAL namespace and the window text
    /// for the message. A user-created/edited delete writes no tombstone but still offers undo (restore).
    @State private var sleepUndo: SleepUndoBanner?
    @State private var sleepUndoInFlight: UUID?
    /// The pending auto-dismiss task for `sleepUndo`, cancelled when a new delete replaces the banner or
    /// the user hits Undo, so a stale timer can't clear a fresh banner.
    @State private var sleepUndoTask: Task<Void, Never>?

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        let displayedNight = resolved.map(paperNightContent)
        ScreenScaffold(title: "Sleep",
                       subtitle: LocalizedStringKey(displayedNight?.night.spanLabel ?? String(localized: "Last night")),
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header), builds trailing trend/ledger cards on demand. Combined
                       // with dropping the top-level LiveState observation (the sleep-mark card + the
                       // syncing note now own `live` in their own leaves), so a 1 Hz HR tick no longer
                       // re-evaluates this heavy body.
                       onRefresh: { _ = await repo.refresh(.currentDay) },
                       lazy: true,
                       topBackground: nil,
                       showsSubtitleInExpandedHeader: false) {
            Group {
                if let resolved, let displayedNight {
                    // Keep every section as its own lazy child. Wrapping these in an eager VStack caused
                    // offscreen `onAppear` work (including the debt-bar reveal) to finish before the user
                    // reached it. LazyVStack preserves the exact alignment while making first-appearance
                    // motion genuinely viewport-triggered.
                    //
                    // The page is flat sections on the canvas with one hairline between each pair, like Today:
                    // spacing 0 here, the air lives in `FlatSectionSeparator`. A section that is only
                    // sometimes there (the missed-night prompt, the invalid-window notice, the V2 need, the
                    // typical comparison) carries its own separator so the page never shows a stray one.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if nightOffset == 0, repo.loaded, sleepHistoryRevision > 0 {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                if SleepPresentationPolicy.isMissingCurrentNight(
                                    wakeDates: navSessions.map { Date(timeIntervalSince1970: Double($0.endTs)) },
                                    now: context.date) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        MissedSleepRecoveryBridge()
                                        FlatSectionSeparator.sleep
                                    }
                                }
                            }
                        }
                        nightNavHeader(trailing: displayedNight.night.spanLabel)
                            .padding(.top, 8)
                            .padding(.bottom, SleepRhythm.navigatorToContent)
                        if !invalidSessions.isEmpty {
                            invalidSleepWindowNotice
                                .staggeredAppear(index: 0)
                        }
                        paperSleepHero(
                            resolved,
                            night: displayedNight.night,
                            hasStageData: displayedNight.hasStageData
                        )
                        .staggeredAppear(index: 0)
                        FlatSectionSeparator.sleep
                        // Full editor, bound to the same BehaviorStore and actuation lane as Alarms.
                        SleepAlarmEditorSection()
                            .staggeredAppear(index: 2)
                        FlatSectionSeparator.sleep
                        paperSleepStages(
                            resolved,
                            night: displayedNight.night,
                            hasStageData: displayedNight.hasStageData
                        )
                        .staggeredAppear(index: 2)
                        FlatSectionSeparator(above: SleepRhythm.airAbove, below: 0)
                        // Keep each row's existing divider-to-divider height, with its former outer
                        // separator air split evenly around the content instead of on just one side.
                        // Each async leaf owns its fetch and loading state, so the parent never waits.
                        VStack(alignment: .leading, spacing: 0) {
                            SleepHeartRateContrastSection(
                                sleepStart: displayedNight.night.session.effectiveStartTs,
                                sleepEnd: displayedNight.night.session.endTs,
                                sessions: navSessions,
                                habitualMidsleepSec: habitualMidsleepSec,
                                sessionsRevision: sleepHistoryRevision
                            )
                            .padding(.vertical, SleepRhythm.airBelow / 2)
                            TodaySectionSeparator(above: 0, below: 0)
                            PreSleepHeartRateFeedbackSection(
                                wakeDay: SleepView.wakeDayKey(for: displayedNight.night),
                                sleepStart: displayedNight.night.session.effectiveStartTs,
                                sleepEnd: displayedNight.night.session.endTs,
                                sessions: navSessions,
                                habitualMidsleepSec: habitualMidsleepSec,
                                sessionsRevision: sleepHistoryRevision
                            )
                            .padding(.vertical, SleepRhythm.airAbove / 2)
                        }
                        .staggeredAppear(index: 4)
                        FlatSectionSeparator(above: 0, below: SleepRhythm.airBelow)
                        nightDetail(resolved, night: displayedNight.night).staggeredAppear(index: 5)
                        FlatSectionSeparator.sleep
                        // Tonight: the V2 need (its own leaf: own EnvironmentObject + async fetch, so it never
                        // blocks this screen's memoized model on a store round trip) over the 14-night balance.
                        // The selected night's recorded total and provenance remain when V2 components are absent.
                        SleepNeedBreakdownSection(
                            wakeDay: SleepView.wakeDayKey(for: displayedNight.night),
                            trailing: sleepBalanceTrailing(resolved),
                            infoAction: { metricInfo = .sleepNeed },
                            fallback: SleepNeedFallbackPresentation.resolve(
                                wakeDay: SleepView.wakeDayKey(for: displayedNight.night),
                                onDevice: { presentationNeeds[$0]?.totalMinutes },
                                imported: { repo.importedSleep[$0]?.needMin }),
                            fallbackIsLoading: needsLoading
                        ) {
                            sleepBalanceContent(resolved)
                        }
                        .staggeredAppear(index: 6)
                        FlatSectionSeparator.sleep
                        sleepRhythmEntry.staggeredAppear(index: 7)
                        FlatSectionSeparator.sleep
                        napSection(
                            displayedNight.night,
                            hasStageData: displayedNight.hasStageData
                        )
                        .staggeredAppear(index: 8)
                    }
                } else {
                    // Nothing recorded yet: the explanation comes first, then the tools that still work.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        emptyState
                        FlatSectionSeparator.sleep
                        SleepAlarmEditorSection()
                        FlatSectionSeparator.sleep
                        sleepRhythmEntry
                    }
                }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChangeCompat(of: key) { newKey in
                modelKey = newKey
                model = buildModel()
                // New data invalidates a navigated offset — the same offset would silently
                // point at a different session. Snap back to last night. (#160)
                nightOffset = 0
                navNight = nil
                selectedStage = nil
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                    nightOffset = 0
                    navNight = nil
                    selectedStage = nil
                }
            }
            // Load EVERY sleep block across BOTH sources (un-deduplicated) so the hero's ◀/▶ can
            // browse split-sleep days the dashboard collapses — including Bluetooth-only nights,
            // whose blocks live under the computed source. Re-runs whenever a sync/import bumps
            // refreshSeq; snaps back to the newest day and rebuilds the model so offset 0 reflects
            // the freshly-loaded blocks. (#170)
            .task(id: "\(repo.refreshSeq)-\(repo.canonicalHealth.presentationRevision)") {
                needsLoading = true
                needsFailed = false
                do {
                    let needs = try await repo.sleepPresentationNeeds(from: repo.days.first?.day ?? Repository.localDayKey(Date()), to: Repository.localDayKey(Date()))
                    guard !Task.isCancelled else { return }
                    presentationNeeds = needs
                } catch {
                    guard !Task.isCancelled else { return }
                    presentationNeeds = [:]
                    needsFailed = true
                }
                needsLoading = false
                let sessions = await repo.sleepHistoryPage(limit: 200)
                guard !Task.isCancelled else { return }
                allSessions = sessions
                invalidSessions = await repo.invalidSleepSessions(days: 30)
                // Load the learned habitual midsleep the engine used, so the main-night pick aligns to it
                // (a shift/late sleeper) instead of only the cold-start band. nil under threshold. (#547)
                habitualMidsleepSec = await repo.habitualMidsleepSec(days: 30)
                sleepHistoryRevision &+= 1
                // Per-epoch motion for every block (#407), keyed by detected start. mergeDay reads only the
                // already-resolved group's entries — this just pre-fetches them all so the model build is sync.
                motionByStart = await repo.sessionMotions(starts: allSessions.map { $0.startTs })
                nightOffset = 0
                navNight = nil
                selectedStage = nil
                modelKey = dataKey
                model = buildModel()
            }
            .metricInfoSheet($metricInfo, mainSleepReason: stagesMainSleepReason)
            .sheet(item: $wakeEdit) { edit in
                // The night's RECORDED coverage for the #940 guards: from the immutable detected
                // onset (where the strap actually saw the night; an earlier hand-set onset widens
                // it) through the current wake. A corrected window that abandons this range has no
                // data to stage from, so the editor confirms the move instead of silently creating
                // a phantom night.
                let coverageLo = min(edit.detectedStartTs, edit.bedTs)
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                coverage: coverageLo...max(edit.wakeTs, coverageLo + 1),
                                suppressesReDetection: !edit.userEdited,
                                onSave: { newBedTs, newWakeTs in
                    await repo.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                              storedStagesJSON: edit.stagesJSON,
                                              newStartTs: newBedTs, newEndTs: newWakeTs)
                    // Re-score the day so the dashboard aggregates (Sleep / recovery) honor the corrected
                    // sleep window, not just the Sleep tab's session view; then refresh the read cache.
                    await intelligence.analyzeRecent()
                    _ = await repo.refresh(.currentDay)
                }, onDelete: {
                    // Delete = the edit path minus the re-insert: drop this session so every metric
                    // recomputes immediately as if the night were never recorded, durably tombstoned so a
                    // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                    // #65: the returned snapshot lets the user UNDO within a few seconds. It restores the
                    // deleted row into its ORIGINAL namespace and lifts the tombstone.
                    let snapshot = await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs,
                                                                 endTs: edit.wakeTs)
                    await intelligence.analyzeRecent()
                    _ = await repo.refresh(.currentDay)
                    // `edit.bedTs` is the effective (displayed) onset, so the banner shows the same clock
                    // time the user saw for this night.
                    if let snapshot { presentSleepUndo(snapshot, displayStart: edit.bedTs, windowEnd: edit.wakeTs) }
                })
            }
            // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
            // stored as its OWN separate session — never folded into main sleep (which would mislabel the
            // awake daytime gap as light sleep).
            .sheet(item: $addNap) { seed in
                SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                                title: "Add a nap",
                                blurb: "Pick when the nap started and ended. NOOP stages it from your data as its own session, separate from the night's sleep.",
                                bedLabel: "Nap started", wakeLabel: "Nap ended") { startTs, endTs in
                    await repo.addManualNap(startTs: startTs, endTs: endTs)
                    // Re-score so the day's aggregates pick up the new session, exactly like an edit.
                    await intelligence.analyzeRecent()
                    _ = await repo.refresh(.currentDay)
                }
            }
        }
        .paperToast(
            isPresented: Binding(
                get: { sleepUndo != nil },
                set: { presented in
                    guard !presented else { return }
                    SleepUndoTaskControl.cancelAndClear(&sleepUndoTask)
                    withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
                }
            ),
            autoDismiss: false
        ) {
            sleepUndoToast(sleepUndo!)
        }
        .onDisappear {
            SleepUndoTaskControl.cancelAndClear(&sleepUndoTask)
            sleepUndo = nil
        }
    }

    /// Rhythm is a sleep-context experience, not a Settings destination. Keep one direct entry on
    /// the Sleep surface and let `RhythmHost` preserve its existing consent and lazy data-loading gates.
    /// An eyebrow that is itself the tap target (its chevron says so), with one line of what it opens.
    private var sleepRhythmEntry: some View {
        NavigationLink {
            RhythmHost()
        } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                SectionEyebrow("Rhythm", systemImage: "waveform.path.ecg.rectangle", tint: .sleep, showsChevron: true)
                Text("Experimental beat-to-beat patterns from your recent sleep")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Rhythm")
        .accessibilityHint("Shows the experimental beat-to-beat Rhythm view")
    }

    /// A legacy window outside 30 minutes–16 hours: said plainly, with one chip per saved window to review it. It
    /// closes with its own separator because it only exists some of the time.
    private var invalidSleepWindowNotice: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlatSection("Sleep window needs review", systemImage: "exclamationmark.triangle.fill",
                         tint: .custom(StrandPalette.statusWarning)) {
                Text("NOOP excluded \(invalidSessions.count) saved sleep window\(invalidSessions.count == 1 ? "" : "s") outside 30 minutes–16 hours from recovery, sleep scoring, and your usual-sleep timing. Your data is still saved; review or delete it before relying on that day.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ChipRow {
                    ForEach(Array(invalidSessions.enumerated()), id: \.offset) { _, session in
                        WidgetChipButton(title: "Review saved window", systemImage: "pencil",
                                        accessibilityLabel: "Review saved window") {
                            wakeEdit = WakeEdit(detectedStartTs: session.startTs,
                                                bedTs: session.effectiveStartTs,
                                                wakeTs: session.endTs,
                                                stagesJSON: session.stagesJSON,
                                                userEdited: session.userEdited)
                        }
                    }
                }
            }
            FlatSectionSeparator.sleep
        }
    }

    // MARK: - Delete undo (#65)

    /// Show the transient UNDO banner after a suppressing delete, and arm the 7-second auto-dismiss. A
    /// second delete replaces the banner (its old auto-dismiss task is cancelled first) so only the most
    /// recent delete is undoable. Single-level and transient, matching the WorkoutsView postLogNote idiom.
    private func presentSleepUndo(_ snapshot: SleepDeletionSnapshot, displayStart: Int, windowEnd: Int) {
        SleepUndoTaskControl.cancelAndClear(&sleepUndoTask)
        withAnimation(.easeOut(duration: 0.2)) {
            sleepUndo = SleepUndoBanner(snapshot: snapshot,
                                        displayStart: displayStart, windowEnd: windowEnd)
        }
        let armed = sleepUndo?.id
        sleepUndoTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if this is still the banner we armed (a newer delete would have replaced it).
                if sleepUndo?.id == armed {
                    withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
                    sleepUndoTask = nil
                }
            }
        }
    }

    /// Undo the most recent suppressing delete: restore the row into its ORIGINAL namespace, lift the
    /// tombstone, re-score, then dismiss the banner. A failed/conflicting write keeps its snapshot and
    /// offers a retry; an older completion cannot clear a newer deletion's banner.
    private func undoSleepDelete(_ banner: SleepUndoBanner) async {
        guard sleepUndo?.id == banner.id, sleepUndoInFlight != banner.id else { return }
        sleepUndoInFlight = banner.id
        defer {
            if sleepUndoInFlight == banner.id { sleepUndoInFlight = nil }
        }
        SleepUndoTaskControl.cancelAndClear(&sleepUndoTask)
        guard await repo.undoDeleteSleepSession(banner.snapshot) else {
            if sleepUndo?.id == banner.id { sleepUndo?.undoFailed = true }
            return
        }
        await intelligence.analyzeRecent()
        _ = await repo.refresh(.currentDay)
        await MainActor.run {
            guard sleepUndo?.id == banner.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
        }
    }

    /// Locale-formatted clock time (no date) for the banner's window range.
    private func clockTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(date: .omitted, time: .shortened)
    }

    /// The transient undo presentation keeps the exact existing copy and action semantics while the
    /// shared Paper toast supplies visual grammar. `dismissesOnAction` is false so the async undo path
    /// remains the sole owner of when the banner clears, just as before the visual migration.
    private func sleepUndoToast(_ banner: SleepUndoBanner) -> PaperToast {
        // Branch the copy on userEdited: a hand-edited/added night writes NO tombstone (it is never
        // re-detected), so the suppression promise would be false for it. Only a DETECTED delete writes a
        // tombstone, so only it gets the "won't detect ... again" wording. (#65 banner honesty.)
        let message: String
        if banner.undoFailed {
            message = String(localized: "Couldn't restore this sleep. Try again.")
        } else {
            message = banner.snapshot.session.userEdited
                ? String(localized: "Sleep deleted.")
                : String(localized: "Sleep deleted. NOOP won't detect sleep between \(clockTime(banner.displayStart)) and \(clockTime(banner.windowEnd)) again.")
        }
        return PaperToast(
            LocalizedStringKey(message),
            systemImage: banner.undoFailed ? "exclamationmark.triangle" : "moon.zzz",
            tint: StrandPalette.restColor,
            actionTitle: banner.undoFailed ? "Try again" : "Undo",
            announcement: message,
            dismissesOnAction: false
        ) {
            Task { await undoSleepDelete(banner) }
        }
    }

    // MARK: - Paper sleep summary (S3)

    /// The one night every mounted paper module must render. Offset zero reuses the memoized latest
    /// model. Older offsets reuse the cached decoded `navNight`; a day that cannot decode stages keeps
    /// the legacy honest stage-less stub rather than borrowing the latest night's values.
    private func paperNightContent(_ model: SleepModel) -> PaperNightContent {
        if nightOffset == 0 {
            return PaperNightContent(
                night: model.night,
                hasStageData: !model.isStubNight && model.night.stages.total > 0
            )
        }
        if let navNight {
            return PaperNightContent(
                night: navNight,
                hasStageData: navNight.stages.total > 0
            )
        }
        if let session = sessionRow(at: nightOffset) {
            let stub = Night(
                session: session,
                stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                sourceBlocks: dayBlocks(at: nightOffset),
                habitualMidsleepSec: habitualMidsleepSec
            )
            return PaperNightContent(night: stub, hasStageData: false)
        }
        // The navigation bounds make this unreachable in normal use. Falling back to the memoized
        // latest night is preferable to dropping the whole screen during a concurrent data refresh;
        // the refresh path resets `nightOffset` to zero in the same update.
        return PaperNightContent(
            night: model.night,
            hasStageData: !model.isStubNight && model.night.stages.total > 0
        )
    }

    /// The opening section: the score dial with its state word, then the night's headline numbers. Every value is
    /// read from the existing memoized sleep model; this is presentation-only and deliberately leaves scoring and
    /// stage derivation untouched.
    private func paperSleepHero(_ model: SleepModel, night: Night, hasStageData: Bool) -> some View {
        let wakeDay = Repository.localDayKey(
            Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        )
        let day = repo.days.last(where: { $0.day == wakeDay })
        let score = model.performanceByDay[wakeDay]
        let restingHR = day?.restingHr

        return SleepHeroSection(
            score: score,
            headline: score.map { "\(sleepScoreWord($0)) Sleep" } ?? String(localized: "Calibrating"),
            message: sleepScoreMessage(score),
            facts: [
                FactStrip.Fact("Asleep", value: hasStageData ? durationText(night.stages.asleep) : "—"),
                FactStrip.Fact("Efficiency", value: paperEfficiencyText(night, day: day)),
                FactStrip.Fact("Resting HR", value: restingHR.map { "\($0) bpm" } ?? "—"),
                FactStrip.Fact("Respiratory", value: day?.respRateBpm.map { String(format: "%.1f", $0) } ?? "—"),
            ],
            source: nightSource(night),
            infoAction: { metricInfo = .sleepScore }
        )
    }

    /// One line of context under the state word. The wording follows the score's own bands (what the Sleep score
    /// measures is how much of the night's need was met), so a poor night never reads as a solid one.
    private func sleepScoreMessage(_ score: Double?) -> String {
        guard let score else { return String(localized: "Sleep is still calibrating from your recorded sleep.") }
        // Banded on the score as shown (whole numbers), so 49.6 reads "50 · Fair", never "Poor".
        switch SleepScoreBand(score: score) {
        case .poor: return String(localized: "Your sleep fell well short of what your body needed.")
        case .fair: return String(localized: "Your sleep covered part of what your body needed.")
        case .good, .optimal: return String(localized: "This was a solid night of recovery.")
        }
    }

    /// Selected-night efficiency without the legacy `repo.today` fallback, which would put the newest
    /// day's value on an older stage-less stub. The stored session wins; its matching daily row is the
    /// only fallback. Both values are existing outputs.
    private func paperEfficiencyText(_ night: Night, day: DailyMetric?) -> String {
        guard let efficiency = night.session.efficiency ?? day?.efficiency else { return "—" }
        let percent = efficiency <= 1 ? efficiency * 100 : efficiency
        return "\(Int(percent.rounded()))%"
    }

    /// The night as one section: when you slept (asleep, woke, in bed) with the provenance and edit chips at the
    /// header, the hypnogram in the stage palette, and a row per stage. Hypnogram smoothing remains display-only
    /// and does not alter stored stage totals. This is the old window card folded in: its duration repeated the
    /// hero's, so the times are one line over the timeline they describe, and the stage rows carry the typical.
    private func paperSleepStages(_ model: SleepModel, night: Night, hasStageData: Bool) -> some View {
        let presentation = SleepWindowPresentation(
            hasStageData: hasStageData,
            asleepMinutes: night.stages.asleep,
            stagedInBedMinutes: night.timeInBed,
            sessionStartTs: night.session.effectiveStartTs,
            sessionEndTs: night.session.endTs
        )

        return FlatSection("Sleep stages", systemImage: "bed.double.fill", tint: .sleep,
                            trailing: .custom(AnyView(windowChips(night))),
                            infoAction: {
                                stagesMainSleepReason = mainSleepReasonText(night)
                                metricInfo = .sleepStages
                            },
                            infoAccessibilityLabel: MetricInfo.sleepStages.accessibilityLabel) {
            Text("\(night.onsetText) → \(night.wakeText) · \(presentation.inBedDuration) in bed")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if night.stageTimeline.isEmpty {
                Text("No stage timeline was recorded for this night.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SleepStageChart(timeline: night.stageTimeline, start: night.onsetDate, highlighted: selectedStage)
                stageTypicalRows(model, stages: night.stages)
            }
            // Keep the existing H9 honesty note mounted under the stage section.
            if stageStagingIsLowConfidence(night) {
                stageLowConfidenceNote
            }
        }
        .strandHaptic(.selection, trigger: selectedStage)
    }

    /// The stage section's header action: the wake-time editor as a bare pencil glyph, beside the section's ⓘ.
    /// The main-sleep reason lives in the Sleep stages explainer, not a second ⓘ here.
    @ViewBuilder
    private func windowChips(_ night: Night) -> some View {
        if let target = night.editTarget {
            InfoGlyphButton(systemImage: "pencil",
                            accessibilityLabel: target.userEdited ? "Edit sleep times (edited)" : "Edit sleep times") {
                wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                    bedTs: target.effectiveStartTs,
                                    wakeTs: target.endTs,
                                    stagesJSON: target.stagesJSON,
                                    userEdited: target.userEdited)
            }
        }
    }

    /// A short Sleep state word for the hero gauge — same banding the synthesis hero uses.
    private func sleepScoreWord(_ score: Double) -> String {
        switch SleepScoreBand(score: score) {
        case .poor: return String(localized: "Poor")
        case .fair: return String(localized: "Fair")
        case .good: return String(localized: "Good")
        case .optimal: return String(localized: "Optimal")
        }
    }

    // MARK: - Provenance for the displayed night (COMPONENT 4, spec 2026-06-20)

    /// The REAL per-day merge winner for the DISPLAYED night's sleep numbers, as the same brand wording the
    /// By-Day badge / Today / Intelligence use ("On-device" / "Whoop"). A WHOOP export covering the night's
    /// wake-day wins the dashboard merge (imports win field-by-field, Repository.mergeDaily), so the badge
    /// says "Whoop"; otherwise the night was scored on-device by NOOP. Keyed by the night's LOCAL wake-day
    /// (the `mergeSleep` / importer convention, sleep is filed under the day you woke), so a navigated past
    /// night reads its OWN provenance, not last night's. Honest: never a blanket "on-device". Apple Health
    /// carries no sleep into `importedSleep`, so the sleep merge winner is only ever Whoop vs on-device. (C4)
    private func nightSource(_ night: Night) -> String {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        return repo.importedSleep[wakeDay] != nil ? String(localized: "Whoop") : String(localized: "On-device")
    }

    /// Naps (#508): each of the day's sleep blocks OTHER than the night's main block, individually
    /// editable + deletable with the SAME durable mechanism main sleep uses, plus an "Add nap" affordance.
    /// A nap is always its own session row (never folded into main sleep), so editing or adding one here
    /// never touches the night's main hypnogram and the awake daytime is never mislabelled as light sleep.
    @ViewBuilder
    private func napSection(_ night: Night, hasStageData: Bool = true) -> some View {
        // The day's main sleep is the bridged main-night GROUP (#561): a briefly-interrupted / biphasic
        // night's sibling fragments are part of the night, NOT naps. Only blocks OUTSIDE that group are
        // naps. This matches the hero and AnalyticsEngine.analyzeDay; the old `!= editTarget.startTs` split
        // labelled the bridged siblings as phantom naps (#555). The summary stays explainable: Main X /
        // Nap(s) Y / Total Z, with Main = the whole bridged night. (#508, #518, #555)
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let mainMin = night.stages.total
        let napMin = naps.reduce(0.0) { $0 + Double($1.endTs - $1.effectiveStartTs) / 60.0 }
        FlatSection("Naps", systemImage: "powersleep", tint: .sleep,
                     trailing: .custom(AnyView(
                        WidgetChipButton(title: "Add nap", systemImage: "plus", accessibilityLabel: "Add nap",
                                         accessibilityHint: "Adds a missed nap to this day") {
                            addNap = AddNapSeed(forNight: night)
                        }))) {
            if naps.isEmpty {
                Text("No naps recorded for this day.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                // Daily split (#518): only meaningful once the day has a nap; a single-night day reads
                // exactly as before. Total = main + naps, the time that drives the day's Sleep.
                if hasStageData {
                    napSummaryRow(mainMin: mainMin, napMin: napMin)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(naps, id: \.startTs) { nap in
                        napRow(nap)
                    }
                }
            }
        }
    }

    /// The Main / Naps / Total split for a day that has at least one nap, so what drives the day's Sleep
    /// total is explainable at a glance. Minutes formatted with the shared `durationText`. (#518)
    @ViewBuilder
    private func napSummaryRow(mainMin: Double, napMin: Double) -> some View {
        FactStrip(facts: [
            FactStrip.Fact("Main sleep", value: durationText(mainMin)),
            FactStrip.Fact("Nap(s)", value: durationText(napMin)),
            FactStrip.Fact("Total", value: durationText(mainMin + napMin)),
        ])
    }

    /// One nap row: its clock window + an edit affordance opening the SAME `SleepTimeEditor` main sleep
    /// uses. Editing a nap re-stages it from raw over the corrected window and sticks (`userEdited`), and
    /// can never spawn a duplicate (the detected `startTs` PK is immutable) — exactly the #318/#395 path,
    /// here keyed on the nap's own row. (#508)
    @ViewBuilder
    private func napRow(_ nap: CachedSleepSession) -> some View {
        let isEdited = nap.userEdited
        HStack(spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(napWindowText(nap)).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(durationText(Double(nap.endTs - nap.effectiveStartTs) / 60.0))
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: NoopMetrics.space2)
            // C1 — "why this is a nap" explainer: the nap-row nudge that everything other than the chosen
            // main block is logged as a nap, with the Edit next-step. Keyed by the nap's stable startTs so
            // one popover shows at a time across several nap rows. (spec 2026-06-20)
            WidgetChipButton(systemImage: "info.circle", accessibilityLabel: "Why this is logged as a nap") {
                napWhyStartTs = (napWhyStartTs == nap.startTs) ? nil : nap.startTs
            }
            .popover(isPresented: Binding(
                get: { napWhyStartTs == nap.startTs },
                set: { if !$0 { napWhyStartTs = nil } }), arrowEdge: .bottom) {
                whyPopover(text: "", napSuffix: true)
            }
            WidgetChipButton(systemImage: "pencil",
                            accessibilityLabel: isEdited ? "Edit nap times (edited)" : "Edit nap times") {
                wakeEdit = WakeEdit(detectedStartTs: nap.startTs,
                                    bedTs: nap.effectiveStartTs,
                                    wakeTs: nap.endTs,
                                    stagesJSON: nap.stagesJSON,
                                    userEdited: true)   // a nap row is always manually added → no tombstone on delete
            }
        }
    }

    /// "HH:mm – HH:mm" clock window for a nap row (device 12-/24-h setting via the shared Night formatter).
    private func napWindowText(_ nap: CachedSleepSession) -> String {
        let start = Night.clockString(nap.effectiveStartTs)
        let end = Night.clockString(nap.endTs)
        return "\(start) – \(end)"
    }

    /// H9 — true when this night's staging is LOW-CONFIDENCE: a high-efficiency night (lots of measured
    /// sleep) whose restorative (deep+REM) share is implausibly low, which the EEG-free classifier is far
    /// more likely to have mis-staged than a genuine night with no deep or REM. Delegates to the engine's
    /// pure `ScoreConfidence.rest(...)` H9 overload (efficiency in [0,1], seconds for the totals) so the UI
    /// and the persisted Sleep confidence agree by construction. Needs staged sleep + a real efficiency
    /// reading; a pooled/no-stage or unknown-efficiency night is never flagged (its base tier already
    /// reads honestly). (#H9)
    private func stageStagingIsLowConfidence(_ night: Night) -> Bool {
        let s = night.stages
        guard let effPct = efficiencyPct(night) else { return false }
        return SleepView.isStagingLowConfidence(
            asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem, efficiency: effPct / 100.0)
    }

    /// Pure H9 gate (unit-testable without a live view) — true when a night's staging is low-confidence:
    /// a high-efficiency night whose deep+REM share is below the restorative floor. Built on the engine's
    /// own `ScoreConfidence.rest(...)` so the UI flag and the persisted Sleep confidence agree. `asleepMin`,
    /// `deepMin`, `remMin` are minutes; `efficiency` is asleep/in-bed in [0,1]. Returns false for an unstaged
    /// or zero-asleep night (no staging to doubt). Mirror EXACTLY in Kotlin. (#H9)
    static func isStagingLowConfidence(asleepMin: Double, deepMin: Double, remMin: Double,
                                       efficiency: Double) -> Bool {
        guard asleepMin > 0 else { return false }
        let restorativeMin = max(0, deepMin) + max(0, remMin)
        // An UNSTAGED night (no deep+REM at all) has no staging split to doubt — its base Sleep
        // confidence already reads honestly as `.building` (NOT a downgrade), so it must never be
        // flagged. Only a night that DID stage some sleep can be a suspicious "high efficiency yet
        // implausibly little restorative" staging miss.
        guard restorativeMin > 0 else { return false }
        let tier = ScoreConfidence.rest(
            hasSession: true,
            hasStagedSleep: true,
            asleepSeconds: asleepMin * 60.0,
            restorativeSeconds: restorativeMin * 60.0,
            efficiency: efficiency)
        // The H9 overload only DOWNGRADES solid → building on the suspicious case; a genuinely
        // low-restorative-AND-low-efficiency night keeps its honest base tier and isn't flagged here.
        return tier == .building
            && (restorativeMin / asleepMin) < ScoreConfidence.restorativeLowConfidenceShare
            && efficiency >= ScoreConfidence.highEfficiencyThreshold
    }

    /// The H9 low-confidence note shown beneath the stage breakdown — a warning state pill plus a one-line honest
    /// explanation. No faked stages, no tanked score; just a clear "treat this split with care" so a user doesn't
    /// read a likely staging miss as a real deep/REM drought. (#H9)
    private var stageLowConfidenceNote: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            StatePill("Low confidence", tone: .warning, showsDot: false)
            Text("This night scored high efficiency but very little deep or REM, more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Low confidence staging. This night scored high efficiency but very little deep or REM, more likely an estimate miss than a real restorative shortfall.")
    }

    /// A compact explainer popover: the verbatim foundation reason text, with the nap suffix appended for a
    /// nap row. Plain English, no jargon, no em-dashes (the words come straight from `mainSleepReasonText`
    /// and the spec's nap-row suffix). Sized for both macOS and iOS. (spec 2026-06-20 C1)
    @ViewBuilder
    private func whyPopover(text: String, napSuffix: Bool) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(StrandPalette.restColor)
                    .accessibilityHidden(true)
                Text(napSuffix ? "About this nap" : "About your main sleep")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if !text.isEmpty {
                Text(text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if napSuffix {
                Text("Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.cardInnerPadding)
        .frame(width: 260)
        .background(StrandPalette.surfaceOverlay)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    // MARK: - Stage rows (dot + stage + bar with typical tick + delta)

    /// The four stage rows under the hypnogram, each tonight's minutes against the user's typical for that stage
    /// (computed once in the model build). Holding a row lights its stage up on the chart and shows the exact time
    /// and share in place of the delta. Shares are shared out so the four rows add up to 100%.
    @ViewBuilder
    private func stageTypicalRows(_ model: SleepModel, stages s: Stages) -> some View {
        let order: [(stage: SleepStage, minutes: Double, typical: Double?)] = [
            (.rem, s.rem, model.typicalRemMin), (.deep, s.deep, model.typicalDeepMin),
            (.light, s.light, model.typicalLightMin), (.awake, s.awake, nil),  // no per-day awake column to take a typical from
        ]
        let shares = SleepStageShares.percents(minutes: order.map(\.minutes))
        // One scale for all four bars (with headroom) so they compare with one another and the ticks stay on it.
        let scaleMax = order.map { Swift.max($0.minutes, $0.typical ?? 0) }.max().map { $0 * 1.15 } ?? 1
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.offset) { index, row in
                let presentation = SleepStageRowPresentation(
                    stage: row.stage, minutes: row.minutes, total: s.total, typical: row.typical, percent: shares[index])
                SleepStageTypicalRow(
                    stage: row.stage,
                    presentation: presentation,
                    typical: row.typical,
                    scaleMaximum: scaleMax > 0 ? scaleMax : 1,
                    isHeld: selectedStage == row.stage,
                    accessibilityLabel: stageRowAccessibilityLabel(
                        label: row.stage.label, last: row.minutes, sharePct: presentation.percent, typical: row.typical)
                ) { holding in
                    if reduceMotion {
                        selectedStage = holding ? row.stage : nil
                    } else {
                        withAnimation(StrandMotion.press) { selectedStage = holding ? row.stage : nil }
                    }
                }
            }
        }
        HStack(spacing: NoopMetrics.space3) {
            HStack(spacing: 4) {
                Capsule(style: .continuous).fill(StrandPalette.textPrimary.opacity(0.85)).frame(width: 2, height: 10)
                    .accessibilityHidden(true)
                Text("your typical night")
            }
            Text("Hold a row for time and %")
        }
        .font(StrandFont.micro)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }

    // MARK: - 2. Night detail (Scores-style rows, one per metric of the displayed night)

    /// The displayed night's numbers as `TrendsSummaryRow`s, the same row Trends' Scores list uses: a domain symbol,
    /// the metric over how it sits against the user's typical, its own history as a sparkline and the value. The
    /// Sleep score is the hero's ring and Asleep / Sleep need are in the hero and Tonight, so none repeats here.
    /// Duration opens the 30-night duration trend.
    @ViewBuilder
    private func nightDetail(_ model: SleepModel, night: Night) -> some View {
        let day = Self.wakeDayKey(for: night)
        let daily = repo.days.first { $0.day == day }
        let asleep = night.stages.asleep
        let need = presentationNeeds[day]?.totalMinutes ?? repo.importedSleep[day]?.needMin
        let restorative = asleep > 0 ? (night.stages.deep + night.stages.rem) / asleep * 100 : nil
        let consistency = repo.importedSleep[day]?.consistencyPct ?? (day == repo.days.last?.day ? model.consistency.latest : nil)
        let hoursVsNeed = need.flatMap { $0 > 0 && asleep > 0 ? asleep / $0 * 100 : nil }
        let efficiency = efficiencyPct(night)
        let rest = DomainTint.custom(StrandPalette.sleepREM)
        let breath = DomainTint.custom(StrandPalette.metricCyan)
        let rowGap = TodaySectionSeparator(above: 5, below: 5)

        FlatSection("Night detail", systemImage: "moon.zzz.fill", tint: .sleep,
                     trailing: .text(String(localized: "vs your typical")),
                     infoAction: { metricInfo = .nightDetail },
                     infoAccessibilityLabel: MetricInfo.nightDetail.accessibilityLabel) {
            VStack(alignment: .leading, spacing: 0) {
                percentRow("gauge.medium", String(localized: "Efficiency"), latest: efficiency, typical: model.efficiency.typical,
                           series: model.efficiency.series, tint: .sleep)
                rowGap
                percentRow("scalemass.fill", String(localized: "Hours vs needed"), latest: hoursVsNeed, typical: model.hoursVsNeeded.typical,
                           series: model.hoursVsNeeded.series, tint: .sleep)
                rowGap
                percentRow("sparkles", String(localized: "Restorative"), latest: restorative, typical: model.restorative.typical,
                           series: model.restorative.series, tint: rest)
                rowGap
                percentRow("clock.arrow.2.circlepath", String(localized: "Consistency"), latest: consistency, typical: model.consistency.typical,
                           series: model.consistency.series, tint: .sleep)
                rowGap
                let resp = daily?.respRateBpm
                let respDelta = resp.flatMap { latest in model.respiratory.typical.map { latest - $0 } }
                TrendsSummaryRow(
                    systemImage: "lungs.fill", label: String(localized: "Respiratory rate"),
                    values: spark(model.respiratory.series) ?? [],
                    latest: resp.map { String(format: "%.1f rpm", $0) } ?? "—",
                    delta: respDelta.map { abs($0) < 0.15 ? String(localized: "steady") : Self.vsTypical(signed: $0, digits: 1) }
                        ?? String(localized: "No typical yet"),
                    tone: .neutral, tint: breath)
                rowGap
                durationRow(model, asleepMin: asleep)
            }
        }
    }

    /// One percent metric against its typical: "+2% vs typical" (positive), "−6% vs typical" (negative) or "steady".
    private func percentRow(_ systemImage: String, _ label: String, latest: Double?, typical: Double?,
                            series: [Double], tint: DomainTint) -> some View {
        let diff = latest.flatMap { latest in typical.map { latest - $0 } }
        return TrendsSummaryRow(
            systemImage: systemImage, label: label, values: spark(series) ?? [],
            latest: pctValue(latest),
            delta: diff.map { abs($0) < 0.5 ? String(localized: "steady") : Self.vsTypical(signed: $0, digits: 0, suffix: "%") }
                ?? String(localized: "No typical yet"),
            tone: diff.map { abs($0) < 0.5 ? .neutral : ($0 > 0 ? .positive : .negative) } ?? .neutral,
            tint: tint)
    }

    /// "+2% vs typical" / "−0.3 vs typical": the sign as a real plus or minus, the size rounded to `digits`.
    private static func vsTypical(signed value: Double, digits: Int, suffix: String = "") -> String {
        let amount = String(format: "%.\(digits)f", abs(value))
        return String(localized: "\(value > 0 ? "+" : "−")\(amount)\(suffix) vs typical")
    }

    /// The Duration row: asleep time against the typical night, with a chevron because it opens the 30-night chart.
    private func durationRow(_ model: SleepModel, asleepMin: Double) -> some View {
        let diff = model.typicalTotalMin.map { asleepMin - $0 }
        let row = TrendsSummaryRow(
            systemImage: "timer", label: String(localized: "Duration"),
            values: spark(model.trendPoints.map(\.value)) ?? [],
            latest: asleepMin > 0 ? durationText(asleepMin) : "—",
            delta: asleepMin > 0 ? diff.map { abs($0) < 1 ? String(localized: "steady")
                : String(localized: "\(debtSigned($0)) vs typical") } ?? String(localized: "No typical yet")
                : String(localized: "No stage data"),
            tone: asleepMin > 0 ? diff.map { abs($0) < 1 ? .neutral : ($0 > 0 ? .positive : .negative) } ?? .neutral : .neutral,
            tint: .sleep)
        return NavigationLink {
            SleepDurationTrendDetail(points: model.trendPoints)
                .environment(\.screenScaffoldNavigationRole, .detail)
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                row
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the 30-night sleep duration trend")
    }

    // MARK: - 2b. Sleep balance (rolling 14-night running balance, the evidence under Tonight's need)

    /// The Tonight eyebrow's trailing: the balance's state pill (debt is amber, a surplus positive, a balanced
    /// fortnight neutral), or the window's name until there is a ledger.
    private func sleepBalanceTrailing(_ model: SleepModel) -> EyebrowTrailing {
        let ledger = model.sleepDebtLedger
        guard !needsLoading, !needsFailed, ledger.nightCount > 0 else { return .text(String(localized: "14-night balance")) }
        return .pill(LocalizedStringKey(debtTag(ledger)), tone: debtTone(ledger))
    }

    /// A running balance of (slept − personal need) across the recent fortnight as a diverging bar of each night's
    /// delta (surplus above the line, deficit below) with its first date, running total and "Last night" under it.
    /// Honest: a simple accumulator — a surplus night offsets a deficit one — capped at 14 nights, no-data nights
    /// skipped. (#242)
    @ViewBuilder
    private func sleepBalanceContent(_ model: SleepModel) -> some View {
        let ledger = model.sleepDebtLedger
        if needsLoading {
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().tint(StrandPalette.restColor).accessibilityHidden(true)
                Text("Loading sleep balance…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        } else if needsFailed {
            Text("Sleep balance could not load. Pull to refresh and try again.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if ledger.nightCount == 0 {
            Text("Sleep balance needs recorded sleep and a computed nightly target. Missing nights are not counted as debt.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            debtDeltaBars(ledger)
            HStack {
                Text(ledger.nights.first.map { Self.shortDay($0.day) } ?? "")
                Spacer(minLength: NoopMetrics.space2)
                Text("Running total \(debtSigned(ledger.balanceMin))")
                Spacer(minLength: NoopMetrics.space2)
                Text("Last night")
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityHidden(true)
            Text("Counts nights with a computed target. Repayment is excluded from the target so existing debt is not counted twice.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "9 Oct" for a `yyyy-MM-dd` day key (the keys are UTC calendar days, so format them in UTC).
    private static func shortDay(_ key: String) -> String {
        guard let date = dayParser.date(from: key) else { return key }
        return date.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC") ?? .gmt).day().month(.abbreviated))
    }

    /// The state pill's tone for the balance: debt is the warning amber (the deficit bars' colour), a surplus is
    /// positive and a balanced fortnight is neutral.
    private func debtTone(_ ledger: SleepDebtLedger) -> StrandTone {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return .neutral }
        if !ledger.isDebt { return .positive }
        // Debt is one tone: the same warning amber as the deficit bars, however deep it runs.
        return .warning
    }

    /// The diverging per-night delta strip: each night a bar from the centre line — up in the sleep tint for a
    /// surplus, down in amber for a deficit — scaled to the largest |delta|.
    @ViewBuilder
    private func debtDeltaBars(_ ledger: SleepDebtLedger) -> some View {
        SleepBalanceBars(
            nights: ledger.nights.map { SleepBalanceBars.Entry(id: $0.day, minutes: $0.deltaMin) },
            accessibilitySummary: "Per-night sleep balance: \(ledger.nightCount) nights, net \(debtSigned(ledger.balanceMin))"
        )
    }

    /// Whole-string VoiceOver label for a stage row: one key per variant, never a stitched tail fragment.
    private func stageRowAccessibilityLabel(label: String, last: Double, sharePct: Int, typical: Double?) -> String {
        let spokenLast = SleepSpokenDuration.text(minutes: last)
        if let typical, typical > 0 {
            return String(localized: "\(label): \(spokenLast) last night, \(sharePct) percent of the night, typical \(SleepSpokenDuration.text(minutes: typical))")
        }
        return String(localized: "\(label): \(spokenLast) last night, \(sharePct) percent of the night")
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last,
            refreshSeq: repo.refreshSeq,
            canonicalPresentationRevision: repo.canonicalHealth.presentationRevision)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        // #940: ONE un-mergeable newest day (e.g. an impossible hand-edit staged all-awake) must
        // not blank the whole tab behind the first-run empty state; every older night is still in
        // the DB. Degrade to the SAME honest stage-less stub the ◀/▶ browse shows for such a day,
        // keeping the edit/delete affordances reachable so the user can fix the bad night. nil
        // (the true empty state) only when there is genuinely no day to show.
        let night: Night
        let isStub: Bool
        if let merged = latestNight {
            night = merged
            isStub = false
        } else if let stubSession = SleepView.stubDaySession(dayBlocks(at: 0),
                                                             habitualMidsleepSec: habitualMidsleepSec) {
            night = Night(session: stubSession, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                          sourceBlocks: dayBlocks(at: 0), habitualMidsleepSec: habitualMidsleepSec)
            isStub = true
        } else {
            return nil
        }
        let performance = performanceSnapshot
        let historicalEfficiency = efficiencySeries
        // The metric grid describes the night the header/hero currently displays.  Its
        // sparkline and typical remain historical, but the headline must never borrow a
        // newer day's placeholder efficiency (the exact 0% beside a 5h49 / 6h20 night
        // seen on device).  A selected night without a defensible efficiency stays blank.
        let displayedEfficiency = efficiencyPct(night)
        let efficiency: Metric = (displayedEfficiency, historicalEfficiency.typical,
                                  historicalEfficiency.series)
        return SleepModel(
            night: night,
            isPersistedHypnogram: (night.realSegments?.count ?? 0) >= 2,
            isStubNight: isStub,
            performance: performance.metric,
            performanceByDay: performance.byDay,
            efficiency: efficiency,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints,
            sleepDebtLedger: debtLedger)
    }

    /// The last 14 nights with both recorded duration and an exact-day canonical target.
    /// Excludes repayment from the target and skips unknown nights without zero-filling.
    private var debtLedger: SleepDebtLedger {
        SleepDebt.ledger(nightlyNeeds: repo.days.map { day in
            (day: day.day, totalSleepMin: day.totalSleepMin,
             needMin: presentationNeeds[day.day]?.ledgerMinutes)
        })
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations. TWO stagesJSON formats exist:
    /// imported nights store a dict of MINUTES {"light","deep","rem","awake"}; on-device computed
    /// nights store a SEGMENT ARRAY [{start,end,stage}] (AnalyticsEngine.encodeStages). Only the
    /// dict was decoded before, so a Bluetooth-only user's night vanished from this tab entirely
    /// while Intelligence showed it (#77). Computed nights also carry their REAL timeline now —
    /// the hypnogram draws genuine segments instead of the synthetic reconstruction.
    private var latestNight: Night? { decodedNight(at: 0) }

    /// The browsable block list: every sleep session un-deduplicated (incl. same-day naps / split
    /// sleep). Falls back to `repo.sleeps` (one-per-night) until the fuller list loads, so the hero
    /// is never empty during the first frame. (#170)
    private var navSessions: [CachedSleepSession] {
        allSessions.isEmpty ? repo.sleeps : allSessions
    }

    /// The browsable DAY list: every block grouped by the calendar day it ENDS on (matching the
    /// dashboard's per-night merge), newest day first, blocks within a day oldest→newest. Each day
    /// is ONE ◀/▶ stop, so a split-sleep day reads as a single night and the "N nights ago" label
    /// stays truthful — two blocks of the same day are never "1 night ago" AND "2 nights ago". (#170)
    private var navDays: [[CachedSleepSession]] {
        let cal = Calendar.current
        func endDay(_ s: CachedSleepSession) -> Date {
            cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
        }
        let groups = Dictionary(grouping: navSessions, by: endDay)
        return groups.keys.sorted(by: >).map { key in
            (groups[key] ?? []).sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        }
    }

    /// The device's current UTC offset (seconds east), evaluated once per pick. Feeds the selector's
    /// `offsetSec` so the timing test reads the user's clock via the SAME `offsetSec` math the engine
    /// uses (`SleepStageTotals.localSecOfDay`), instead of `Calendar.current.component(.hour:)` which was
    /// the duplicated, DST-fragile gate the audit flagged. (#547)
    nonisolated static var tzOffsetSec: Int { TimeZone.current.secondsFromGMT() }

    /// The wake-day key for a displayed night — the SAME `Repository.localDayKey(night.session.endTs)`
    /// resolution `paperSleepHero` uses to look up `model.performanceByDay`, factored out so the T702
    /// need-breakdown leaf resolves to the identical day. `fileprivate` because `Night` itself is (the
    /// other call site, `SleepNeedBreakdownSection`, lives in this same file).
    fileprivate static func wakeDayKey(for night: Night) -> String {
        Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
    }

    /// The day's single WINNING main block — the durable-edit anchor (`editTarget`) and the one block whose
    /// learned-timing score won. Scores by learned timing on each block's EFFECTIVE onset (what the user
    /// sees) and returns the owning session. This is the BARE single-block pick (no gap-bridge), because the
    /// edit affordance writes against ONE real row so it must resolve to one block. The HERO display and the
    /// nap split do NOT use this alone: they use `mainNightGroup`, which bridges the winner's adjacent
    /// fragments (a wake gap shorter than `gapBridgeMaxMin`) into ONE night the way `AnalyticsEngine`
    /// does (#561), so a biphasic / briefly-interrupted night is shown as one continuous sleep instead of
    /// phantom naps (#555). `habitualMidsleepSec` is the SAME learned value the engine threads into the
    /// persisted totals (loaded via `repo.habitualMidsleepSec()`), so a shift/late sleeper's pick matches
    /// the analytics rollup; nil keeps the cold-start overnight-band bonus. (#525 / #547 / #561)
    nonisolated static func mainNightSession(_ sessions: [CachedSleepSession],
                                             habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        SleepStageTotals.mainNightIndex(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec).map { sessions[$0] }
    }

    /// The day's MAIN-night GROUP — the winning block PLUS any adjacent fragments bridged into it (a wake
    /// gap shorter than `gapBridgeMaxMin`), so a briefly-interrupted / biphasic night reads as ONE
    /// continuous sleep exactly the way `AnalyticsEngine.analyzeDay` rolls it up for the daily total (#561).
    /// The hero aggregates this whole group and ONLY blocks outside it are naps. Without it the tab used the
    /// un-bridged single-block pick and rendered the bridged siblings as phantom naps (#555). A night with
    /// no bridgeable gap collapses to the single block `mainNightSession` picks, so the common case is byte-
    /// identical. Returns ascending by effective onset. (#561 / #555)
    nonisolated static func mainNightGroup(_ sessions: [CachedSleepSession],
                                           habitualMidsleepSec: Int? = nil) -> [CachedSleepSession] {
        guard let idx = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return [] }
        return idx.map { sessions[$0] }.sorted { $0.effectiveStartTs < $1.effectiveStartTs }
    }

    /// Classify a block as a nap: it's a nap exactly when it is NOT the day's chosen main block. Derived
    /// from the pick (never an independent onset/duration gate), so the label can't contradict the
    /// selection — the contradiction the audit flagged. The main block is never a nap. (#518/#547)
    static func isNap(_ s: CachedSleepSession, main: CachedSleepSession?) -> Bool {
        guard let main else { return false }
        return s.startTs != main.startTs
    }

    // MARK: - Why-this-is-your-main-sleep explainer (COMPONENT 1, spec 2026-06-20)

    /// The verbatim reason copy for the displayed night, with {DUR} filled as "Xh Ym" from the chosen
    /// block's asleep duration — driven entirely by the foundation `MainNightReason`, so the explainer
    /// states exactly what the selector decided (never a re-derived guess). Resolved over the day's blocks
    /// via the same `mainNightSelection` API the analytics pick uses, with the SAME learned habitual the
    /// hero used, so the words match the block the hero shows. nil only when the day has no blocks. (C1)
    private func mainSleepReasonText(_ night: Night) -> String? {
        guard let sel = SleepStageTotals.mainNightSelection(
            night.sourceBlocks.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) },
            offsetSec: SleepView.tzOffsetSec, habitualMidsleepSec: habitualMidsleepSec) else { return nil }
        let dur = durationText(sel.asleepMinutes)
        switch sel.reason {
        case .onlyBlock:
            return String(localized: "This is your only sleep block today.")
        case .longest:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)).")
        case .longestNearUsual:
            return String(localized: "Picked as your main sleep because it was your longest block (\(dur)), near your usual bedtime.")
        case .alignedToUsual:
            return String(localized: "Picked as your main sleep because it started near your usual sleep time.")
        }
    }

    /// Build the hero `Night` for a day around its MAIN-night GROUP — the winning block PLUS any fragments
    /// a brief wake split it into, bridged the way `AnalyticsEngine.analyzeDay` bridges them (#561), so a
    /// biphasic / interrupted night shows as ONE continuous sleep whose total matches the day's headline.
    /// It does NOT merge the whole day: an afternoon nap sits OUTSIDE the bridged group (its gap exceeds
    /// `gapBridgeMaxMin`), so it never folds in and stays a nap (the impossible 1 AM→5 PM merge #518 guarded
    /// against). Stage minutes are SUMMED over the group (the inter-fragment wake gap belongs to no
    /// fragment, so it is excluded from the minutes exactly as the engine excludes it), the hypnogram lays
    /// each fragment's real timeline end-to-end, and `sourceBlocks` keeps every block so the naps card and
    /// the daily Main/Nap/Total summary can read them. A single-block day is byte-identical to the prior
    /// behaviour. Returns nil if the group decodes to no usable stages. (#170, #318, #518, #555, #561)

    /// The night's DISPLAYED onset (bedtime), aligned to the SAME fragment the pencil edit targets so the
    /// shown "Asleep" time and the editor agree (#736). The bug: a night sometimes records a brief, all-awake
    /// pre-sleep stub (e.g. lying in bed scrolling at 21:41) as its own block. The gap-bridge folds it into
    /// the main-night group, so it became `group.first` and drove the shown bedtime, while the pencil edited
    /// the MAIN block (`mainNightSession`, which scores by sleep span/timing and skips the all-awake stub) —
    /// the two diverged and editing couldn't move the displayed bedtime. Fix: skip a leading spurious stub
    /// when deriving the shown onset so it lands on the first fragment with real sleep, which IS the edit
    /// target. A stub is spurious only when it's BRIEF and essentially sleepless AND a later fragment carries
    /// the real sleep; otherwise the earliest effective onset stands (single-block and normal biphasic nights
    /// are byte-identical). Returns a real fragment's `effectiveStartTs`, never a synthetic value.
    private func nightOnsetTs(_ group: [CachedSleepSession]) -> Int {
        // group is ascending by effective onset; first is the earliest fragment.
        guard let first = group.first else { return 0 }
        let asleepMinutes = group.map {
            SleepView.decodedAsleepMinutes($0.stagesJSON, effectiveStartTs: $0.effectiveStartTs)
        }
        let referenceAsleep = asleepMinutes.max() ?? 0
        // Walk past any leading spurious pre-onset awake stubs to the first real-sleep fragment.
        for (index, frag) in group.enumerated() {
            let spanMin = Double(frag.endTs - frag.effectiveStartTs) / 60.0
            if !SleepView.isPreOnsetAwakeStub(
                spanMin: spanMin,
                asleepMin: asleepMinutes[index],
                refAsleepMin: referenceAsleep
            ) { return frag.effectiveStartTs }
        }
        // Whole group is stub-like (shouldn't reach the hero, mergeDay gates on stages.asleep > 0): keep the
        // earliest onset rather than inventing one.
        return first.effectiveStartTs
    }

    /// A fragment is a spurious pre-onset awake stub when it's within the lie-in cap (<= `preOnsetStubMaxMin`)
    /// and carries essentially no sleep (asleep minutes <= `preOnsetStubAsleepMaxMin`). Used only to skip such
    /// a stub when it leads the main-night group, so the displayed bedtime tracks where real sleep began. (#736)
    /// Longest a leading block can be and still be treated as a spurious pre-sleep awake stub (lying in bed
    /// before sleep). Generous (a few hours) because the reporter's stub ran 21:41 → 00:27 — ~2h45m of
    /// pre-sleep awake — so a tight cap missed it (#736). The real guard against swallowing a genuine first
    /// sleep fragment is `preOnsetStubAsleepMaxMin`: a stub must be essentially SLEEPLESS, which a real sleep
    /// block never is. The cap only stops a pathological all-day awake block from being silently dropped.
    static let preOnsetStubMaxMin: Double = 240
    /// Most asleep minutes a fragment can carry and still count as a (sleepless) pre-onset awake stub. A real
    /// first sleep fragment of a biphasic night carries far more, so it's never mistaken for a stub. (#736)
    static let preOnsetStubAsleepMaxMin: Double = 3
    /// A fragment with this much actual sleep is a genuine sleep episode even when it is small
    /// relative to the night's main block. This protects split/biphasic nights from onset trimming.
    static let preOnsetStubMinorAsleepFloorMin: Double = 30
    private static let preOnsetStubRelativeAsleepFraction: Double = 0.15

    /// Pure stub test on a fragment's span + asleep minutes, so the rule is unit-testable without decoding
    /// JSON or building a view. BRIEF and essentially sleepless = a spurious pre-onset awake stub. (#736)
    static func isPreOnsetAwakeStub(
        spanMin: Double,
        asleepMin: Double,
        refAsleepMin: Double = 0
    ) -> Bool {
        guard spanMin <= preOnsetStubMaxMin else { return false }
        if asleepMin <= preOnsetStubAsleepMaxMin { return true }
        guard refAsleepMin > 0,
              asleepMin < preOnsetStubMinorAsleepFloorMin else { return false }
        return asleepMin < refAsleepMin * preOnsetStubRelativeAsleepFraction
    }

    /// The index into an ascending-by-onset group whose fragment supplies the DISPLAYED bedtime: the first
    /// fragment that is NOT a spurious leading pre-onset awake stub, falling back to 0 when every fragment is
    /// stub-like. Pure mirror of `nightOnsetTs`'s walk, driven by per-fragment (spanMin, asleepMin) so a
    /// golden test can pin the #736 behaviour without view internals. (#736)
    static func nightOnsetIndex(spansMin: [Double], asleepsMin: [Double]) -> Int {
        let referenceAsleep = asleepsMin.max() ?? 0
        for i in spansMin.indices {
            let asleep = i < asleepsMin.count ? asleepsMin[i] : 0
            if !isPreOnsetAwakeStub(
                spanMin: spansMin[i], asleepMin: asleep, refAsleepMin: referenceAsleep
            ) { return i }
        }
        return 0
    }

    /// Decode either stored sleep-stage representation into actual asleep minutes. Imported rows
    /// contain a dictionary of minute totals; on-device rows contain timestamped segments. Segment
    /// arrays are clipped at the effective onset so edited pre-onset time never inflates sleep.
    static func decodedAsleepMinutes(_ json: String?, effectiveStartTs: Int) -> Double {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        if let dict = object as? [String: Any] {
            func value(_ key: String) -> Double {
                (dict[key] as? NSNumber)?.doubleValue ?? 0
            }
            return value("light") + value("deep") + value("rem")
        }
        guard let segments = object as? [[String: Any]], !segments.isEmpty else { return 0 }
        return segments.reduce(0) { total, segment in
            guard let start = (segment["start"] as? NSNumber)?.intValue,
                  let end = (segment["end"] as? NSNumber)?.intValue,
                  let stage = segment["stage"] as? String,
                  stage != "wake", stage != "awake" else { return total }
            let clippedStart = max(start, effectiveStartTs)
            return end > clippedStart ? total + Double(end - clippedStart) / 60.0 : total
        }
    }

    private func mergeDay(_ sessions: [CachedSleepSession]) -> Night? {
        let fullGroup = SleepView.mainNightGroup(sessions, habitualMidsleepSec: habitualMidsleepSec)
        // The displayed bedtime is the night's MAIN onset, aligned to the same fragment the pencil edits.
        // The latest wake closes the span. (#318, #736)
        guard let last = fullGroup.last else { return nil }
        let onset = nightOnsetTs(fullGroup), wake = last.endTs
        // Aggregate (stages, hypnogram, motion) from the displayed onset fragment onward so the chart and
        // the totals start where the bedtime label does — a spurious leading pre-sleep awake stub is dropped
        // from the night's reconstruction (#736). It still rides in `sourceBlocks`/`mainGroupStarts`, so it's
        // never lost and never mislabelled as a nap. Without a leading stub this is the whole group (unchanged).
        let group = fullGroup.drop { $0.effectiveStartTs < onset }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var segs: [SleepInterval] = []
        // #407: lay the GROUP's per-epoch motion fragment-by-fragment in the SAME order the stage timeline
        // is laid, reading the already-chosen group's stored series (NOT a re-resolution). The detected key
        // (`startTs`, not `effectiveStartTs`) is the motion store's key. A fragment with no persisted series
        // contributes nothing; if NO fragment has one, `motionEpochs` stays empty → honest empty state.
        var motion: [Double] = []
        for frag in group {
            if let seg = decodeSegments(frag.stagesJSON, sessionStart: onset), seg.stages.total > 0 {
                stages.awake += seg.stages.awake; stages.light += seg.stages.light
                stages.deep  += seg.stages.deep;  stages.rem   += seg.stages.rem
                for iv in seg.intervals {
                    segs.append(SleepInterval(stage: iv.stage, start: iv.start, end: iv.end))
                }
            } else if let st = decodeStages(frag.stagesJSON), st.total > 0 {
                stages.awake += st.awake; stages.light += st.light
                stages.deep  += st.deep;  stages.rem   += st.rem
            }
            if let m = motionByStart[frag.startTs] { motion.append(contentsOf: m) }
        }
        guard stages.asleep > 0 else { return nil }
        let eff = stages.total > 0 ? stages.asleep / stages.total : nil
        let synth = CachedSleepSession(startTs: onset, endTs: wake, efficiency: eff,
                                       restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let realSegs = segs.count >= 2 ? segs.sorted { $0.start < $1.start } : nil
        return Night(session: synth, stages: stages, realSegments: realSegs, sourceBlocks: sessions,
                     motionEpochs: motion, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The real stored blocks composing the day at `offset` (for the stage-less stub Night, so its edit
    /// affordance still targets a real row). Empty when out of range.
    private func dayBlocks(at offset: Int) -> [CachedSleepSession] {
        let days = navDays
        return offset >= 0 && offset < days.count ? days[offset] : []
    }

    /// The merged Night for the DAY `offset` stops back from the most recent (0 = last night).
    /// Backs the hero's ◀/▶ navigation via the `navNight` cache — JSON-decodes, so it only runs
    /// from `buildModel()` and the onChange handlers, never per render. (#160, #170)
    private func decodedNight(at offset: Int) -> Night? {
        let days = navDays
        guard offset >= 0, offset < days.count else { return nil }
        return mergeDay(days[offset])
    }

    /// A synthetic session for the DAY `offset` stops back, spanning the MAIN block's window (not the
    /// whole day), for the honest no-stage-data header when the day's blocks don't decode to usable
    /// stages. Using the main block (#518) keeps the stub header on the real night rather than a
    /// 1 AM→5 PM overnight+nap span. (#160, #170)
    private func sessionRow(at offset: Int) -> CachedSleepSession? {
        SleepView.stubDaySession(dayBlocks(at: offset), habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The stage-less stub SESSION for a day whose blocks decode to no usable sleep: the MAIN
    /// block's effective window (the same pick `sessionRow` always made), falling back to the day's
    /// first block so a day with ANY stored block renders a header. Static and pure so the #940
    /// no-blank rule is unit-testable without view internals (SleepPhantomNightFallbackTests): as
    /// long as a day has a block, the tab has something honest to show and `buildModel` never
    /// collapses the whole screen to the first-run empty state. nil only for an empty day.
    static func stubDaySession(_ blocks: [CachedSleepSession],
                               habitualMidsleepSec: Int? = nil) -> CachedSleepSession? {
        guard let main = mainNightSession(blocks, habitualMidsleepSec: habitualMidsleepSec) ?? blocks.first
        else { return nil }
        return CachedSleepSession(startTs: main.effectiveStartTs, endTs: main.endTs,
                                  efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// The night navigator: a compact row of ‹ date › with the date span as its one primary line and where this
    /// night sits ("Latest recorded night", "3 nights ago") as a quiet caption. ‹ goes older (increasing offset),
    /// › goes newer; each dims at its bound and is disabled there. The chevrons are the shared `WidgetChip` with
    /// its 44pt tap area, so the targets are as large as ever. (#160)
    @ViewBuilder
    private func nightNavHeader(trailing: String) -> some View {
        let lastIndex = max(navDays.count - 1, 0)
        let caption: LocalizedStringKey = nightOffset == 0 ? "Latest recorded night"
            : (nightOffset == 1 ? "1 night ago" : "\(nightOffset) nights ago")
        VStack(spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space3) {
                Button { navigateToNight(nightOffset + 1) } label: {
                    WidgetChip(systemImage: "chevron.left", showsChevron: false, overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(nightOffset >= lastIndex)
                .opacity(nightOffset >= lastIndex ? 0.35 : 1)
                .accessibilityLabel("Previous night")

                VStack(spacing: 2) {
                    Text(trailing)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                    Text(caption)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)

                Button { navigateToNight(nightOffset - 1) } label: {
                    WidgetChip(systemImage: "chevron.right", showsChevron: false, overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .disabled(nightOffset == 0)
                .opacity(nightOffset == 0 ? 0.35 : 1)
                .accessibilityLabel("Next night")
            }
            // When the older-night arrow is disabled because no earlier night is banked yet, the
            // chevron just dimming reads as broken. Show a short, honest hint instead — earlier
            // nights only appear once the strap has offloaded them (next-morning sync). (#614 follow-up)
            if nightOffset >= lastIndex {
                Text("No earlier night stored yet. Earlier nights sync in the morning.")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Resolve the selected night in the same button transaction as its offset. This prevents an
    /// intermediate frame where the navigation label says "1 night ago" while the paper cards still
    /// carry the latest night's values. JSON decoding remains press-scoped, never body-scoped.
    private func navigateToNight(_ requestedOffset: Int) {
        let lastIndex = max(navDays.count - 1, 0)
        let nextOffset = min(max(requestedOffset, 0), lastIndex)
        guard nextOffset != nightOffset else { return }

        navNight = nextOffset == 0 ? nil : decodedNight(at: nextOffset)
        selectedStage = nil
        nightOffset = nextOffset
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    private var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    private func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    private typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    private func metric(_ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance comes from the canonical Repository score model. The view does not recreate
    /// precedence or compute a second production score.
    private var performanceSnapshot: (metric: Metric, byDay: [String: Double]) {
        var series: [Double] = []
        var byDay: [String: Double] = [:]
        series.reserveCapacity(repo.days.count)
        byDay.reserveCapacity(repo.days.count)

        for day in repo.days {
            guard let value = repo.canonicalHealth.sleepScore(day: day.day)?.value,
                  value.isFinite else { continue }
            series.append(value)
            byDay[day.day] = value
        }
        return ((series.last, mean(series), series), byDay)
    }

    private var efficiencySeries: Metric {
        metric { d in
            guard let e = d.efficiency, e.isFinite else { return nil }
            let percent = e <= 1.0 ? e * 100 : e
            // A 0% efficiency with a saved sleep row is a legacy placeholder, not a
            // physiological result.  Do not let it pull the latest sparkline point to
            // zero; the selected-night resolver below derives from measured stage totals.
            guard percent > 0, percent <= 100 else { return nil }
            return percent
        }
    }

    /// Consistency: prefer the imported sleep_consistency series, but only when it covers
    /// the latest night — otherwise "latest" would silently be a months-old import-era
    /// value. Fallback is the APPROXIMATE rolling bedtime-spread score (per session, lower
    /// spread → higher score, same SD→score mapping).
    private var consistencySeries: Metric {
        let imported = repo.importedSleep
        if let lastDay = repo.days.last?.day, imported[lastDay]?.consistencyPct != nil {
            let series = repo.days.compactMap { imported[$0.day]?.consistencyPct }
            return (series.last, mean(series), series)
        }
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = repo.sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night). The imported
    /// sleep_need_min wins per day; else the APPROXIMATE personal-mean need.
    private var hoursVsNeededSeries: Metric {
        let imported = repo.importedSleep
        let fallbackNeed = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            let need = imported[d.day]?.needMin ?? fallbackNeed
            guard need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    private var restorativeSeries: Metric {
        metric { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    private var respiratorySeries: Metric {
        metric { $0.respRateBpm }
    }

    /// Sleep debt (minutes): the imported sleep_debt_min when the export carried it; else
    /// the APPROXIMATE per-night need − asleep, floored at 0 (no "credit").
    private var sleepDebtSeries: Metric {
        let imported = repo.importedSleep
        let need = sleepNeedMin
        let series = repo.days.compactMap { d -> Double? in
            if let debt = imported[d.day]?.debtMin { return debt }   // minutes, export-verbatim
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return Swift.max(0, need - asleep)   // APPROXIMATE fallback
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    private var sleepNeedMin: Double {
        Swift.max(450, typicalTotalMin ?? 450)   // 450 min = 7.5h
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    private var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        return build(repo.days[...]).filter {
            SleepPresentationPolicy.containsInRecentWindow($0.date, now: Date())
        }
    }

    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        // While the strap is mid-offload, say so — "No nights" reads as final otherwise (#77). The note
        // owns the `LiveState` observation in its own leaf so the chunk count ticks without re-rendering
        // SleepView (scroll-stutter isolation; identical output to the prior inline check).
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SleepSyncingNote()
            if repo.loaded {
                sleepRecoveryEmptyState(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
            } else {
                sleepRecoveryEmptyState(what: "Loading your sleep history…")
            }
        }
    }

    // MARK: - Formatting helpers

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    // MARK: - Sleep-debt ledger formatting

    /// Short tag under/beside the headline: DEBT / SURPLUS / ON TARGET.
    private func debtTag(_ ledger: SleepDebtLedger) -> String {
        if ledger.magnitudeMin < SleepDebt.onTargetBandMin { return String(localized: "Balanced") }
        return ledger.isDebt ? String(localized: "Sleep debt") : String(localized: "Surplus")
    }

    /// Signed "+1h 20m" / "−2h 10m" / "0m" balance string.
    private func debtSigned(_ minutes: Double) -> String {
        if abs(minutes) < 1 { return String(localized: "0m") }
        let sign = minutes >= 0 ? "+" : "−"
        return "\(sign)\(durationText(abs(minutes)))"
    }

    /// Efficiency in percent. Prefer a plausible stored session value, else derive from
    /// the measured sleep window.  A historical 0 is a missing placeholder (not a real
    /// sleep efficiency) whenever the window contains asleep minutes.
    private func efficiencyPct(_ night: Night) -> Double? {
        Self.displayEfficiencyPercent(stored: night.session.efficiency,
                                      asleepMinutes: night.stages.asleep,
                                      timeInBedMinutes: night.timeInBed)
    }

    /// Pure presentation resolver behind the selected-night Sleep tile.  Kept internal
    /// so the real "0 stored but 5h49 asleep in 6h20 in bed" regression stays testable.
    nonisolated static func displayEfficiencyPercent(stored: Double?, asleepMinutes: Double,
                                                     timeInBedMinutes: Double) -> Double? {
        if let stored, stored.isFinite {
            let percent = stored <= 1.0 ? stored * 100 : stored
            if percent > 0, percent <= 100 { return percent }
        }
        guard asleepMinutes > 0, timeInBedMinutes > 0 else { return nil }
        return Swift.min(100, asleepMinutes / timeInBedMinutes * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    private func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode the imported stagesJSON dict of MINUTES {"light","deep","rem","awake"}.
    private func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        func val(_ key: String) -> Double {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            if let d = dict[key] as? Double { return d }
            if let i = dict[key] as? Int { return Double(i) }
            return 0
        }
        let s = Stages(awake: val("awake"), light: val("light"),
                       deep: val("deep"), rem: val("rem"))
        return s.total > 0 ? s : nil
    }

    /// Decode the COMPUTED stagesJSON segment array [{"start":epoch,"end":epoch,"stage":"wake"|
    /// "light"|"deep"|"rem"}] into stage totals plus the real timeline (seconds relative to the
    /// session start, the Hypnogram's domain). The on-device SleepStager calls awake "wake". (#77)
    private func decodeSegments(
        _ json: String?, sessionStart: Int
    ) -> (stages: Stages, intervals: [SleepInterval])? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        var stages = Stages(awake: 0, light: 0, deep: 0, rem: 0)
        var intervals: [SleepInterval] = []
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue, end > start,
                  let name = seg["stage"] as? String else { continue }
            let minutes = Double(end - start) / 60.0
            let stage: SleepStage
            switch name {
            case "wake", "awake": stage = .awake; stages.awake += minutes
            case "light": stage = .light; stages.light += minutes
            case "deep": stage = .deep; stages.deep += minutes
            case "rem": stage = .rem; stages.rem += minutes
            default: continue
            }
            intervals.append(SleepInterval(
                stage: stage,
                start: TimeInterval(start - sessionStart),
                end: TimeInterval(end - sessionStart)))
        }
        return stages.total > 0 ? (stages, intervals) : nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// SleepView itself does NOT observe `LiveState` (a connected strap publishes at ~1 Hz, which would
// re-evaluate the heavy Sleep body on every tick). These two small leaves each hold their OWN
// `@EnvironmentObject var live`, so a live tick re-renders only the mark card / syncing note — never
// the hero hypnogram, the stage chart, the metric grid or the trends. They render byte-for-byte what
// the inline code did before the extraction (mirrors the Today leaf-scoping pattern).

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of the Sleep screen.
private struct SleepSyncingNote: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

/// T702 / plan doc G2 + the 14-night balance, as one "Tonight" section: the real V2 Sleep Need for one exact wake
/// day (the total as the hero value, its baseline / Effort / debt repayment / nap credit as chips), then the
/// caller's `balance` content under it as the evidence. Owns its own `Repository` fetch (mirrors the
/// `SleepMarkCard` / `SleepSyncingNote` leaf idiom above) so the async store round trip never blocks SleepView's
/// own memoized model. A recorded exact-day total and its provenance remain visible while V2 is off or its
/// components are absent. The V2 component UI and store read stay off in legacy mode. Never fabricates a component.
private struct SleepNeedBreakdownSection<Balance: View>: View {
    let wakeDay: String
    let trailing: EyebrowTrailing
    /// Opens the Sleep need and balance explainer from the header's information action.
    let infoAction: () -> Void
    let fallback: SleepNeedFallbackPresentation?
    let fallbackIsLoading: Bool
    @ViewBuilder let balance: () -> Balance
    @EnvironmentObject private var repo: Repository
    @State private var breakdown: SleepNeedBreakdown?
    /// The wake day `breakdown` was last loaded for. The section only draws a breakdown whose own `day` is the
    /// displayed night, and "Calibrating" only once that night has loaded, so changing night never flashes the
    /// previous night's figures.
    @State private var loadedDay: String?

    var body: some View {
        let mode = SleepPerformanceV2Prefs.mode
        let isVisible = SleepNeedBreakdownVisibility.isVisible(mode: mode)
        let showFallback = SleepNeedFallbackPresentation.shouldShow(mode: mode, breakdownDay: breakdown?.day, wakeDay: wakeDay)
        FlatSection("Tonight", systemImage: "moon.fill", tint: .sleep, trailing: trailing,
                    infoAction: infoAction, infoAccessibilityLabel: MetricInfo.sleepNeed.accessibilityLabel) {
            if !showFallback, let breakdown {
                needBlock(breakdown)
            } else if let fallback, fallback.wakeDay == wakeDay {
                HeroValue(value: SleepStageRowPresentation.durationText(fallback.minutes),
                          caption: String(localized: "Sleep need"))
                Text(fallback.source == .whoop ? String(localized: "Whoop") : String(localized: "On-device"))
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else if fallbackIsLoading {
                Text("Loading sleep need…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else if isVisible, loadedDay == wakeDay {
                Text("NOOP hasn't computed this night's dynamic Sleep Need breakdown yet — it needs enough scored history first.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isVisible {
                Text("Sleep need is unavailable for this night.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            balance()
        }
        .task(id: "\(wakeDay)-\(repo.refreshSeq)-\(repo.canonicalHealth.presentationRevision)") {
            // Off: legacy stays authoritative with no V2 UI, so there is nothing to read from the store.
            guard SleepNeedBreakdownVisibility.isVisible(mode: SleepPerformanceV2Prefs.mode) else {
                breakdown = nil
                loadedDay = nil
                return
            }
            let day = wakeDay
            let value = await repo.noopSleepNeedBreakdownV2(day: day)
            guard !Task.isCancelled else { return }
            breakdown = value?.day == day ? value : nil
            loadedDay = day
        }
    }

    /// Where tonight's need comes from: the total as the hero value, then each non-zero contribution as a chip.
    /// Every chip is a real stored component; nothing here is invented.
    private func needBlock(_ breakdown: SleepNeedBreakdown) -> some View {
        let unused: Set<String> = Set([("effort", breakdown.strainAdjustmentMinutes),
                                       ("debt", breakdown.debtRepaymentMinutes),
                                       ("nap", breakdown.napCreditMinutes)]
            .filter { abs($0.1) < 0.5 }.map(\.0))
        let lines = Self.lines(for: breakdown).filter { !unused.contains($0.id) }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HeroValue(value: SleepStageRowPresentation.durationText(breakdown.totalMinutes),
                      caption: String(localized: "Sleep need"))
            SleepChipFlow(spacing: NoopMetrics.space2) {
                ForEach(lines) { line in
                    HStack(spacing: 4) {
                        Text(line.title).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line.value).foregroundStyle(StrandPalette.textPrimary).fontWeight(.semibold)
                            .fixedSize()
                    }
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(StrandPalette.surfaceInset))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilitySummary(breakdown))
    }

    /// Baseline unsigned; Effort/debt-repayment/nap-credit signed, matching the promoted card's lab
    /// design exactly. Nap credit SUBTRACTS from the need, so its stored positive minutes negate before
    /// formatting so it reads "−0:20" rather than a misleadingly positive "+0:20".
    private static func lines(for b: SleepNeedBreakdown) -> [SleepNeedBreakdownCard.Line] {
        [
            .init(id: "baseline", title: String(localized: "Baseline need"),
                 value: SleepAlarmTime.hoursMinutes(b.baselineMinutes), tone: StrandPalette.textSecondary),
            .init(id: "effort", title: String(localized: "Yesterday's Effort"),
                 value: SleepAlarmTime.hoursMinutes(b.strainAdjustmentMinutes, signed: true), tone: StrandPalette.strainAccent),
            .init(id: "debt", title: String(localized: "Sleep debt repayment"),
                 value: SleepAlarmTime.hoursMinutes(b.debtRepaymentMinutes, signed: true), tone: StrandPalette.stressAccent),
            .init(id: "nap", title: String(localized: "Nap credit"),
                 value: SleepAlarmTime.hoursMinutes(-b.napCreditMinutes, signed: true), tone: StrandPalette.textTertiary),
        ]
    }

    private static func accessibilitySummary(_ b: SleepNeedBreakdown) -> String {
        String(localized: "Tonight's sleep need \(SleepAlarmTime.duration(Int(b.totalMinutes.rounded()))): baseline \(SleepAlarmTime.hoursMinutes(b.baselineMinutes)), yesterday's Effort \(SleepAlarmTime.hoursMinutes(b.strainAdjustmentMinutes, signed: true)), sleep debt repayment \(SleepAlarmTime.hoursMinutes(b.debtRepaymentMinutes, signed: true)), nap credit \(SleepAlarmTime.hoursMinutes(-b.napCreditMinutes, signed: true))")
    }
}

/// The 30-night sleep duration chart, the page the Night detail "Duration" row opens: the average as the hero
/// value, the trend with its wash, and the low / latest / high underneath. Same content the main page carried
/// before the trim.
private struct SleepDurationTrendDetail: View {
    let points: [TrendPoint]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The axis fitted to the observed range with headroom, so a steady series is not drawn as a flat line
    /// (the Coach trend card's rule).
    private var domain: ClosedRange<Double> {
        let vals = points.map(\.value)
        guard let low = vals.min(), let high = vals.max() else { return 0...1 }
        let pad = Swift.max((high - low) * 0.2, 0.5)
        return Swift.max(0, low - pad)...(high + pad)
    }

    var body: some View {
        // Trailing-30 trend points are precomputed in the model build; read here, not recomputed.
        let values = points.map(\.value)
        let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let tint = DomainTint.sleep
        ScreenScaffold(title: "Sleep duration", subtitle: "Last 30 days") {
            FlatSection("Sleep duration", systemImage: "chart.line.uptrend.xyaxis", tint: tint,
                         trailing: .text(String(localized: "Last 30 days"))) {
                if points.count > 1 {
                    HeroValue(value: avg.map { String(format: "%.1f", $0) } ?? "—", unit: String(localized: "h avg"),
                              caption: String(localized: "\(points.count) recorded nights"))
                    // The Coach trend recipe: the tint's line, a wash fading to clear, at most four evenly spaced
                    // dates, the axis fitted to the data with headroom.
                    TrendChart(points: points,
                               gradient: Gradient(colors: [tint.accent.opacity(0.55), tint.accent]),
                               valueRange: domain,
                               showsArea: true,
                               height: WidgetMetrics.chartHeight,
                               showsHover: false,
                               valueFormat: { String(format: "%.1f h", $0) },
                               accessibilityLabel: String(localized: "Hours asleep trend"),
                               yDomain: domain,
                               xAxisLabelCount: dynamicTypeSize >= .xxLarge ? 3 : WidgetMetrics.maxXAxisLabels)
                    FactStrip(facts: [
                        FactStrip.Fact("Low", value: values.min().map { String(format: "%.1f h", $0) } ?? "—"),
                        FactStrip.Fact("Latest", value: values.last.map { String(format: "%.1f h", $0) } ?? "—"),
                        FactStrip.Fact("High", value: values.max().map { String(format: "%.1f h", $0) } ?? "—"),
                    ])
                } else {
                    Text("Not enough nights yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
    /// Bumped on every Repository.refresh — catches a re-import that changes only the
    /// imported metricSeries figures (importedSleep) without touching days/sleeps.
    let refreshSeq: Int
    /// Canonical production Sleep can change without changing DailyMetric or session rows.
    let canonicalPresentationRevision: Int64
}

/// One fully resolved per-night payload for the active paper cluster. It intentionally contains
/// only existing `Night` and interval values; trends/typicals remain in the memoized `SleepModel`.
private struct PaperNightContent {
    let night: Night
    let hasStageData: Bool
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the stage-timeline reconstruction no longer run on every render.
private struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// True when the night's intervals are the stager's persisted per-epoch segments (on-device
    /// APPROXIMATE staging), not the synthesized architecture.
    let isPersistedHypnogram: Bool
    /// True when `night` is the stage-less STUB for a newest day that failed to merge (#940: e.g.
    /// an impossible hand-edit staged all-awake). The hero then renders the honest no-stage-data
    /// header for it, exactly as the navigated ◀/▶ stub path does, while the tiles / ledger /
    /// trends (all full-history) stay up. It must NEVER blank the whole tab: every older night is
    /// still in the DB and the edit/delete affordance must stay reachable to fix the bad night.
    let isStubNight: Bool

    let performance: Metric
    /// Same already-resolved performance values keyed by wake day, cached once with `performance` so
    /// older-night navigation never invokes the scoring engine from a view body.
    let performanceByDay: [String: Double]
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]

    /// Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
    /// fortnight, with the per-night deltas behind it. Computed once per data change.
    let sleepDebtLedger: SleepDebtLedger
}

private struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

private struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL per-segment timeline for on-device computed nights (nil for imported nights,
    /// whose export carries totals only — those keep the synthetic reconstruction below). (#77)
    var realSegments: [SleepInterval]? = nil
    /// The actual stored block(s) this merged Night was built from. `session` above is a SYNTHETIC
    /// merge for display; an edit must target a real row, so it resolves it from here by identity
    /// rather than re-scanning by wake time. (#318)
    var sourceBlocks: [CachedSleepSession] = []

    /// Per-epoch MOTION for the MAIN-night GROUP, laid fragment-by-fragment in the SAME order `intervals`
    /// lays the group's stage timeline (#407). Empty when no group fragment has a persisted `motionJSON`
    /// (older rows) — the Sleep tab then shows an honest empty state instead of a fabricated zero trace.
    /// This is read off the already-resolved group, NOT a re-resolution of the night.
    var motionEpochs: [Double] = []

    /// The LEARNED habitual midsleep (local time-of-day seconds) the owning view loaded for the user — the
    /// SAME value the engine threaded into the daily total — so `editTarget` resolves the SAME main block
    /// the hero and the analytics rollup did, for a shift/late sleeper too. nil = cold-start band. (#547)
    var habitualMidsleepSec: Int? = nil

    /// The real stored block a sleep-time edit writes against — the day's MAIN block, resolved by the
    /// SAME shared selector (`SleepView.mainNightSession` → `SleepStageTotals.mainNightIndex`) the hero,
    /// the naps card, and `AnalyticsEngine.analyzeDay` use, so all of them and the edit affordance agree
    /// (no re-derived overnight gate). Passes the same learned habitual the hero used, so the edit target
    /// matches the hero block even for a shift/late sleeper. Its `startTs` is a genuine detected key, so
    /// `applySleepEdit` matches. nil when there's no underlying block (a synthetic stub) — the edit
    /// affordance is then hidden. (#318, #518, #547)
    var editTarget: CachedSleepSession? {
        SleepView.mainNightSession(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec)
    }

    /// The `startTs` of every block in the day's bridged MAIN-night GROUP (the winning block plus the
    /// fragments bridged into it, #561), so the naps card excludes ALL of them — only blocks OUTSIDE the
    /// group are naps. Without this the tab treated every block except the single winner as a nap and a
    /// biphasic night rendered as phantom naps. (#555)
    var mainGroupStarts: Set<Int> {
        Set(SleepView.mainNightGroup(sourceBlocks, habitualMidsleepSec: habitualMidsleepSec).map { $0.startTs })
    }

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs)) }

    /// The stage timeline on the night's clock (seconds from its onset), ready to draw. On-device computed nights
    /// use their REAL timeline (fragments on one absolute clock, gaps kept); imported nights are reconstructed
    /// from durations only (the export has no per-epoch timeline). Built once with the night, so no render
    /// re-sorts or re-smooths it.
    let stageTimeline: SleepStageTimeline

    @MainActor
    init(session: CachedSleepSession, stages: Stages, realSegments: [SleepInterval]? = nil,
         sourceBlocks: [CachedSleepSession] = [], motionEpochs: [Double] = [], habitualMidsleepSec: Int? = nil) {
        self.session = session
        self.stages = stages
        self.realSegments = realSegments
        self.sourceBlocks = sourceBlocks
        self.motionEpochs = motionEpochs
        self.habitualMidsleepSec = habitualMidsleepSec
        self.stageTimeline = SleepStageTimeline(Night.makeIntervals(stages: stages, realSegments: realSegments))
    }

    private static func makeIntervals(stages: Stages, realSegments: [SleepInterval]?) -> [SleepInterval] {
        if let real = realSegments, real.count >= 2 { return real }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))) }

    /// Date label that becomes a span when the night crosses midnight (onset on a different
    /// calendar day from wake) — e.g. "Fri 13 → Sat 14 Jun" — otherwise a single date. Lets an
    /// aggregated day that started the previous evening read honestly. (#170)
    var spanLabel: String {
        let onsetDay = Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
        let wakeDay  = Date(timeIntervalSince1970: TimeInterval(session.endTs))
        let cal = Calendar.current
        if cal.isDate(onsetDay, inSameDayAs: wakeDay) { return Night.dateFmt.string(from: onsetDay) }
        return "\(Night.spanFmt.string(from: onsetDay)) → \(Night.dateFmt.string(from: wakeDay))"
    }

    /// A unix-second timestamp as a device-locale clock string ("11:42 PM" / "23:42"). Shared so the nap
    /// rows format their windows identically to the Asleep/Woke row. (#508)
    static func clockString(_ ts: Int) -> String {
        timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // Clock for the Asleep/Woke row — the times people read at a glance. The "jmm" skeleton
    // follows the device's 12-/24-hour setting ("11:42 PM" or "23:42") instead of forcing one
    // on everyone, matching the HR-tooltip / workout times (#337).
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    /// Onset side of a cross-midnight span — no month (the wake side carries it): "Fri 13".
    private static let spanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f
    }()
}

// MARK: - Wake-time editor

/// Tiny presentation-only seam that keeps the legacy Sleep undo cancellation rule
/// directly testable without exposing the banner's private repository payload.
enum SleepUndoTaskControl {
    static func cancelAndClear(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
/// The transient UNDO banner state after a suppressing delete (#65). A unique presentation ID lets a
/// stale task distinguish even a second deletion of the same session from the banner it originally owned;
/// `displayStart` is the effective (shown) onset for the message clock.
private struct SleepUndoBanner {
    let id = UUID()
    let snapshot: SleepDeletionSnapshot
    let displayStart: Int
    let windowEnd: Int
    var undoFailed = false
}

private struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    /// True for a hand-edited / manually-added (nap) night. Such a delete writes NO tombstone (it is
    /// never re-detected), so the editor's delete-confirm copy must NOT promise re-detection suppression
    /// for it. Mirrors the undo-banner branch (#65 banner/confirm honesty).
    let userEdited: Bool
    var id: Int { detectedStartTs }
}

/// Seeds the "Add nap" picker (#508). A nap is short, so seed a 30-minute window anchored to the night's
/// wake (a natural place to look for a missed afternoon nap), clamped to never start before the night's
/// onset. The identity is the seed start so `.sheet(item:)` presents once per request.
private struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
    init(forNight night: Night) {
        // Anchor an hour after the night's wake; a 30-min default window the user adjusts.
        let anchor = night.session.endTs + 3_600
        self.bedTs = anchor
        self.wakeTs = anchor + 30 * 60
    }
}

/// A small sheet to hand-correct a night's bed (onset) and wake (end) times. Seeds both pickers with the
/// current values; the wake picker is bounded to after the chosen bedtime. Hands the chosen unix-second
/// (bed, wake) back via `onSave`. Pure presentation + a single async save — persistence lives in the repo.
private struct SleepTimeEditor: View {
    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete (#68). Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey
    /// The night's RECORDED coverage (detected onset ... current wake, unix seconds) for the #940
    /// guards: a time-only bed roll past the wake auto-decrements the date, and a corrected window
    /// fully outside this range gets an explicit confirm instead of silent acceptance. nil for the
    /// "Add a nap" sheet, whose window deliberately sits outside the night (only the future-bed
    /// guard applies there).
    private let coverage: ClosedRange<Int>?
    /// True when deleting THIS session writes a re-detection tombstone (a DETECTED night). false for a
    /// userEdited/nap row, which is never re-detected, so the delete-confirm copy drops the suppression
    /// promise for it, matching the undo banner. (#65 confirm honesty.)
    private let suppressesReDetection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    /// The bed value BEFORE the in-flight picker change, so the #940 auto-correct can tell a
    /// time-only roll (same calendar day: rescue it) from a deliberate date change (respect it).
    @State private var previousBed: Date
    /// True while the #940 "no recorded data there" confirm is up; Save proceeds only on consent.
    @State private var confirmingDisjoint = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic + day-derived wake are identical either
    /// way — adding a nap is just an edit whose "existing" window is a seed. `onDelete` (#68) is the
    /// optional destructive action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "Asleep",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         coverage: ClosedRange<Int>? = nil,
         suppressesReDetection: Bool = true,
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        // A bed can never be seeded in the future (#940): the "Add a nap" anchor is wake+1h, which is
        // ahead of the clock right after a morning sync; clamp so the picker opens inside its bound.
        let seedBed = min(bedTs, Int(Date().timeIntervalSince1970))
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _previousBed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The wake instant to save: the picked wake TIME-OF-DAY landed on the FIRST occurrence strictly after
    /// bedtime (within 24h). The Woke picker is time-only — its calendar day is always DERIVED from bed
    /// here — so a wake can never be dragged onto an unrelated day. That independent wake-date drag was
    /// what silently re-bucketed a night onto the wrong day and split its stages/totals across two days
    /// (the edit-scramble half of #406). For a normal 23:00→07:00 night this resolves 07:00 to the next
    /// morning; for a short evening nap it resolves to the same evening.
    private func resolvedWake() -> Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: wake)
        // `nextDate(after:matching:)` returns the first instant with that hour:minute within 24h after the
        // anchor, so starting one minute past bed keeps wake strictly after bedtime and inside (bed, bed+24h].
        return cal.nextDate(after: bed.addingTimeInterval(60), matching: hm, matchingPolicy: .nextTime)
            ?? bed.addingTimeInterval(8 * 3600)
    }

    private var proposedWindowIsValid: Bool {
        SleepSessionWindow.isValid(start: Int(bed.timeIntervalSince1970),
                                   end: Int(resolvedWake().timeIntervalSince1970))
    }

    /// The single save funnel: both the direct Save and the #940 disjoint confirm land here.
    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NoopCard(padding: NoopMetrics.cardPadding, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    // Bed is bounded to the PAST (#940): a sleep can't start in the future, and an
                    // unbounded picker let a cross-midnight time roll land the bed on the coming
                    // evening, creating a future-dated night the tab couldn't render.
                    DatePicker(bedLabel, selection: $bed, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                    Divider().overlay(StrandPalette.hairline)
                    // Time-only on purpose — the wake's calendar day is derived from bed (see resolvedWake),
                    // so an edit can't move the night to a different day and scramble its stages/totals (#406).
                    DatePicker(wakeLabel, selection: $wake,
                               displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.restColor)
                }
            }
            if !proposedWindowIsValid {
                Label("Sleep windows must be between 30 minutes and 16 hours.", systemImage: "exclamationmark.triangle.fill")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
            }

            // Destructive delete for an existing night/nap (#68). Confirmation-gated so a tap can't clear
            // a night by accident; nil for the "Add a nap" sheet (nothing to delete). Sits below the
            // pickers, visually separated from the primary Save action.
            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(deleteLabel)
            }

            HStack(spacing: NoopMetrics.gap) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoopButtonStyle(.tertiary, fullWidth: true))
                    .disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    // #940 guard 2: a corrected window that no longer touches the night's recorded
                    // coverage has no data to stage from. Silently accepting it fabricated an
                    // all-awake phantom night; ask first.
                    let start = Int(bed.timeIntervalSince1970)
                    let end = Int(resolvedWake().timeIntervalSince1970)
                    if let coverage, SleepEditGuard.isDisjoint(
                        newStart: start, newEnd: end,
                        coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
                        confirmingDisjoint = true
                    } else {
                        commit(start: start, end: end)
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                .disabled(saving || !proposedWindowIsValid)
            }
        }
        .padding(NoopMetrics.screenPadding)
        .frame(minWidth: 360)
        .background(StrandPalette.surfaceOverlay)
        // #940 guard 1: a time-only roll that lands the bed in the future, or at/after the night's
        // wake, almost always means the PREVIOUS evening (23:00 "yesterday", not tonight). Snap the
        // date back a day so the picker visibly shows the night the user meant. Pure rule + tests:
        // SleepEditGuard.autoCorrectedBed (Android twin in com.noop.analytics).
        .onChangeCompat(of: bed) { newBed in
            let corrected = SleepEditGuard.autoCorrectedBed(
                previousBed: previousBed, candidateBed: newBed,
                originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                now: Date())
            previousBed = corrected
            if corrected != newBed { bed = corrected }
        }
        // #940 guard 2's consent step. On-brand role-tagged .alert, same shape as the delete confirm.
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                let start = Int(bed.timeIntervalSince1970)
                let end = Int(resolvedWake().timeIntervalSince1970)
                guard SleepSessionWindow.isValid(start: start, end: end) else { return }
                commit(start: start, end: end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default. (#68 — Android parity: "Delete this sleep session?")
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
            // tombstone, so its copy drops that (false) promise. Mirrors the undo banner. (#65)
            Text(suppressesReDetection
                 ? "Removes this recorded sleep and recomputes the day without it. NOOP won't re-detect sleep in this window. You can undo for a few seconds after."
                 : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after.")
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.dark)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
