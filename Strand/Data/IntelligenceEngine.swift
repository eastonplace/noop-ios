import Foundation
import Combine
import NoopPhase34Core
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud , for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    private let repo: Repository
    private let profile: ProfileStore
    /// The CANONICAL id under whose `-noop` sibling this engine WRITES the computed daily rows, and from
    /// which it reads the imported-only baseline (`hist`). STABLE on "my-whoop", it must NOT follow the
    /// active strap, or a remove+re-add would orphan the computed history banked under the canonical id
    /// (the #814 follow-up union model). The engine still reads + scores a re-added strap's RAW streams:
    /// per-day owner resolution (`resolveDayOwner`) reads the registry's OWN active id directly (`regActiveId`
    /// below) and pulls each day's raw under the resolved owner, then persists the result to this STABLE
    /// canonical `-noop` sibling. The Repository's union read then surfaces both the canonical computed
    /// history and the active strap's live data together. So this never moves after construction.
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    private var analysisCompletionSerial = 0
    /// Review round 4 (3): one day's persisted Charge breakdown: the Charge the drivers were built against, its
    /// confidence, and the drivers, biggest mover first. The engine writes it beside the Charge each fold (strap,
    /// Apple Watch, wearable import) stores; the breakdown sheet displays it and recomputes nothing.
    struct StoredChargeBreakdown: Equatable, Sendable {
        let day: String
        let score: Double
        let confidence: ScoreConfidence
        let drivers: [ChargeDriver]
    }
    /// #899 heal bound: true while the last heal already re-armed a rescore, so a heal firing again on
    /// the very next pass cannot re-arm a second time (the Android twin is hard-bounded to exactly one
    /// re-pass; this mirrors it). Reset by any pass whose heal finds nothing, restoring the budget.
    private var healRearmedThisCycle = false

    /// Who supplies the dashboard headline for a By-Day row. The By-Day card always shows NOOP's OWN
    /// on-device numbers, but the WHOLE-DASHBOARD value for the same day can come from an IMPORTED row
    /// that won the per-day merge (imports win field-by-field over computed , see Repository.mergeDaily).
    /// We resolve the REAL provenance so the card's badge tells a strap-scored night apart from an
    /// imported one, instead of always claiming "NOOP-computed". (Sleep overhaul §2.6 honesty fix.)
    /// The `stages=` token of the per-day sleep diagnostic line (#386): `<deep>+<rem>+<light>=<sum>` in
    /// rounded minutes when the day carries a full banked stage split, `nil` when any component is
    /// absent (an unstaged night, or an imported day that only brought a total). The sum is printed
    /// rather than left to the reader so a rollup-vs-stages divergence — the exact identity a "homepage
    /// disagrees with the Sleep tab" report hinges on — is a one-line visual check against the
    /// `totalSleepMin=` field beside it. Pure; mirrors the Android `sleepStagesLogToken` byte-for-byte.
    static func sleepStagesLogToken(deep: Double?, rem: Double?, light: Double?) -> String {
        guard let deep, let rem, let light else { return "nil" }
        return "\(Int(deep.rounded()))+\(Int(rem.rounded()))+\(Int(light.rounded()))=\(Int((deep + rem + light).rounded()))"
    }

    enum DaySource: Equatable {
        /// NOOP scored this day itself from the raw strap streams; no import covers it.
        case computed
        /// A WHOOP export covers this day and wins the dashboard merge.
        case whoopImport
        /// An Apple Health import covers this day and wins the dashboard merge.
        case appleHealth

        /// The badge shown on the By-Day card. Brand wording matches the rest of the app
        /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
        var badge: String {
            switch self {
            case .computed:    return String(localized: "On-device")
            case .whoopImport: return "Whoop"
            case .appleHealth: return "Apple Health"
            }
        }

        /// The short token for the per-day strap-log diagnostic (privacy-safe; no device ids leak).
        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            case .appleHealth: return "imported:apple"
            }
        }

        /// Resolve a day's provenance from the imported day-key sets. A WHOOP export covering the day
        /// WINS the dashboard merge over our computed row (imports win field-by-field , Repository
        /// .mergeDaily), so it takes precedence; Apple Health is next; otherwise the day is purely
        /// computed. WHOOP-over-Apple matches the merge's source priority (whoopImport 0 < appleHealth 2
        /// in DailyMetricSource.vitalPriority). Pure + set-based so it's unit-tested directly and is the
        /// SAME logic `analyzeRecent` ships. Mirrors the Android `IntelligenceEngine.daySourceToken`. (§2.6)
        static func classify(day: String, importedWhoopDays: Set<String>,
                             appleHealthDays: Set<String>) -> DaySource {
            if importedWhoopDays.contains(day) { return .whoopImport }
            if appleHealthDays.contains(day) { return .appleHealth }
            return .computed
        }
    }

    /// Storage ownership is deliberately separate from the badge/provenance source. A raw strap result can
    /// have an Apple/WHOOP row on the same civil day while still being persisted by the engine in the stable
    /// canonical namespace. Publication receipts must verify the real writer, never infer it from a UI badge.
    enum RecoveryPersistenceOwner: Equatable {
        case canonicalComputed
        case appleHealth
    }

    struct CivilDayWindow: Equatable, Sendable {
        let day: String
        let start: Int
        let nextStart: Int
    }

    /// Enumerates real local civil days. Subtracting 86,400 seconds drifts by an hour across DST and can
    /// move overnight samples into the neighboring score day; Calendar arithmetic preserves midnight.
    nonisolated static func civilDayWindows(
        reference: Date,
        startOffset: Int,
        count: Int,
        calendar inputCalendar: Calendar
    ) -> [CivilDayWindow] {
        guard startOffset >= 0, count > 0 else { return [] }
        let calendar = inputCalendar
        let today = calendar.startOfDay(for: reference)
        return (startOffset..<(startOffset + count)).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
            return CivilDayWindow(
                day: String(format: "%04d-%02d-%02d", year, month, day),
                start: Int(start.timeIntervalSince1970),
                nextStart: Int(next.timeIntervalSince1970))
        }
    }

    /// One day's off-actor scan output (FIX 1). Carries the pure `AnalyticsEngine.DayResult` produced by
    /// the off-main scan loop plus the pre-computed RHR floor-vs-mean diagnostic line (#691) , computed
    /// inside the detached task from pure inputs so the main actor can replay it through the
    /// MainActor-bound `diagnosticSink` in the SAME per-day order. The immutable value graph is explicitly
    /// `Sendable` because it crosses from the detached scan back to the main-actor fold.
    private struct DayScan: Sendable {
        /// Civil day this scan represents. It remains available even when scoring is skipped, so
        /// descriptive shadows can still be reconciled from their lower sample thresholds.
        let day: String
        /// Nil when the upstream raw-HR gate rejected this day. Keeping that decision in the detached
        /// result lets the main actor replay its diagnostic without ever touching the sink off actor.
        let result: AnalyticsEngine.DayResult?
        let rhrLine: String?
        /// CAPTURE-B (#814/#799): the resolved READ owner id this day was scored from, and how many HR rows
        /// that owner returned for the night window, carried out of the off-actor loop so the main-actor
        /// fold can emit the universal `dayOwner …` self-diagnostic line (it needs the registry active id +
        /// provenance sets, which are resolved on the main actor).
        let readOwner: String
        let hrRows: Int
        /// Sleep & Rest test-mode gate-trace + Rest sub-score lines for this day, collected off the main
        /// actor and replayed through `diagnosticSink` tagged `.sleep` in per-day order. Empty unless the
        /// Sleep mode is active (the gate is read once before the loop), so the default path is unchanged.
        let sleepTrace: [String]
        /// Steps test-mode raw-counter trace lines (5/MG cumulative @57 series + wrap-aware deltas + dropped
        /// deltas) for this day, collected off the main actor and replayed tagged `.steps` in per-day order.
        /// Empty unless the Steps mode is active (the gate is read once before the loop), so the default path
        /// is byte-identical: the trace recomputes the SAME wrap-aware sum analyzeDay already computed.
        let stepsTrace: [String]
        /// HRV test-mode nightly trace lines (per-5-min-window RMSSD by sleep stage + the whole-night vs
        /// deep-only vs last-SWS summary) for this day, collected off the main actor and replayed tagged
        /// `.hrv` in per-day order. Empty unless the HRV mode is active. (#141)
        let hrvTrace: [String]
        /// #195: the ALWAYS-ON whole-night HRV cleaning summary (`hrv diag …`), built off the main actor
        /// where `rr` is in scope and replayed through `diagnosticSink` in pass 2 (which is main-actor
        /// isolated). nil when the night has no in-sleep R-R.
        let hrvDiag: String?
        /// Structured day-level skin-temperature query, conversion, and availability provenance.
        let skinTempTrace: String?
        /// One privacy-safe reason an upstream day was not scored. A sparse raw stream is materially
        /// different from a stager that found no sleep, so it must survive into the shareable strap log.
        let skippedLine: String?
        /// Shadow-only primary-session mean RHR and raw coverage. Persisted for validation, never scored.
        let primarySessionRHR: PrimarySessionRestingHR.Measurement?
        /// Opt-in descriptive pre-sleep observation. Persisted for display only; never scored.
        let preSleepObservation: PreSleepHeartRateFeedback.Observation?
    }

    /// Small, in-memory pass-1 result. Raw sensor rows are never retained here.
    private struct CachedDayScan: Sendable {
        let key: String
        let scan: DayScan
    }

    /// Candidate cache state produced by the detached scan. It is committed only after the complete
    /// analysis + persistence path succeeds, so cancellation or a failed receipt can never advance it.
    private struct DayScanPass: Sendable {
        let scans: [DayScan]
        let nextCache: [String: CachedDayScan]
        let reused: Int
        let eligible: Int
    }

    /// Test-only loader seams. Production leaves this nil and calls `WhoopStore` directly.
    struct AnalyzeRecentCacheTestingSeams: Sendable {
        let fingerprintLoader: @Sendable (WhoopStore, String, Int, Int) async throws -> (count: Int, maxTs: Int)
        let bundleLoader: @Sendable (WhoopStore, String, Int, Int, Int) async throws -> AnalysisDayBundle

        init(
            fingerprintLoader: @escaping @Sendable (WhoopStore, String, Int, Int) async throws -> (count: Int, maxTs: Int),
            bundleLoader: @escaping @Sendable (WhoopStore, String, Int, Int, Int) async throws -> AnalysisDayBundle
        ) {
            self.fingerprintLoader = fingerprintLoader
            self.bundleLoader = bundleLoader
        }
    }

    /// Version of the per-day scan semantics. It keys both the in-memory day-scan cache and the idle-tick
    /// watermark, so a semantic change re-scores the window on the next pass instead of replaying old scans
    /// or skipping an unchanged-HR tick. v2 (AN-02): days bucket by their civil interval and own offset.
    /// v3 (AN-05): Effort's cycle runs from the day's main-night onset to the next day's cycle start.
    /// v4 (D3b): the daily calorie total fills resting energy for the hours without valid heart rate.
    nonisolated static let analyzeScanVersion = "cache-v4"

    /// F2: each scored night's raw skin-temperature mean (°C), persisted under the computed id so the skin
    /// baseline folds the whole history, as HRV / resting HR / respiration do from the computed rows.
    nonisolated static let nightlySkinMetricKey = "skin_temp_night_mean_c"
    /// Review round 3 (B) and round 4 (1): a WHOOP 4.0 night's mean as a raw register value, keyed by the strap
    /// that recorded it, with the anchor that night was converted with beside it. The register offset is per
    /// strap (#938), so each strap's nights are converted with that strap's one anchor: the current pass's
    /// for a strap this pass read, else the newest one stored for it. The offset cancels within each strap's
    /// run, and a strap swap stays continuous instead of reading the old strap's nights on the new offset.
    nonisolated static let nightlySkinWhoop4RawKeyPrefix = "skin_temp_night_raw_whoop4."
    nonisolated static let nightlySkinWhoop4AnchorKeyPrefix = "skin_temp_night_anchor_whoop4."
    /// Review round 4 (4): who wrote each computed row, persisted beside it for every day the pass reconciles:
    /// `strapRowSource` for a night the raw-HR loop scored, `wearableFoldRowSource` for a wearable import's
    /// row the fold copied in with its Charge. Fold copies carry the import's vitals and stay out of the
    /// strap baselines however the import's values change on a re-import.
    nonisolated static let computedRowSourceMetricKey = "computed_row_source"
    nonisolated static let strapRowSource = 1.0
    nonisolated static let wearableFoldRowSource = 2.0
    /// Review round 4 (3): the persisted Charge breakdown keys under the computed id: the Charge the drivers were
    /// built against, its confidence, and each driver's points, measured value and baseline.
    nonisolated static let chargeBreakdownScoreKey = "charge_breakdown_score"
    nonisolated static let chargeBreakdownConfidenceKey = "charge_breakdown_confidence"
    nonisolated static func chargeBreakdownKey(_ term: ChargeDriverTerm, _ field: String) -> String {
        "charge_breakdown.\(term.rawValue).\(field)"
    }
    nonisolated static let chargeBreakdownKeys: [String] = [chargeBreakdownScoreKey, chargeBreakdownConfidenceKey]
        + ChargeDriverTerm.allCases.flatMap { term in
            ["points", "value", "baseline"].map { chargeBreakdownKey(term, $0) }
        }
    private nonisolated static let chargeBreakdownConfidences: [ScoreConfidence] = [.calibrating, .building, .solid]
    /// Review round 4 (2): the second each computed row's calorie total was filled through: the next midnight
    /// for a completed day, the pass's "now" for today. A production pass scores today only, so without it
    /// yesterday kept the total its last pass filled up to that moment.
    nonisolated static let calorieFillEndMetricKey = "calorie_fill_end"
    /// Review round 5 (2): how many days before today a production pass reaches back to finish a calorie total
    /// filled only part of the way, so a pass is at most three days long.
    nonisolated static let calorieFillCatchUpDays = 2
    /// Review round 4 (5): how long the strap recorded valid heart rate on each computed row's day, the
    /// coverage `DailyCalories.total` weighs the strap total by.
    nonisolated static let strapWornSecondsMetricKey = "strap_worn_seconds"
    /// A legacy unmarked row is a strap night when the day's resolved owner recorded at least this many
    /// heart-rate rows over the raw-HR loop's read window: the loop's own scoring gate (`hr.count >= 200`) on
    /// the device the loop reads (review round 5, 5). Such a day was scored by the strap, and the fold never
    /// writes one, so a fold copy can't be read as a strap night.
    nonisolated static let legacyStrapNightMinHrRows = 200
    /// The raw loop's scoring gate (`hr.count >= 200`): a completed day's owner must reach it in the day's own
    /// window (review round 6).
    nonisolated static let rawLoopMinHrRows = 200

    /// One civil day of the WHOOP 4.0 steps estimate's motion volume, with what it was computed from. A later pass
    /// reuses `motion` only while the day's resolved owner, read window and gravity fingerprint (row count and newest
    /// timestamp, answered from the index) are all unchanged, so an insert, a delete, a timestamp heal or an owner
    /// change re-reads the day and a cached day can never differ from a fresh read.
    struct StepMotionCacheEntry: Sendable, Equatable {
        let owner: String
        let from: Int
        let to: Int
        let rowCount: Int
        let maxTs: Int
        let motion: Double

        func matches(owner: String, from: Int, to: Int, fingerprint: (count: Int, maxTs: Int)) -> Bool {
            self.owner == owner && self.from == from && self.to == to
                && rowCount == fingerprint.count && maxTs == fingerprint.maxTs
        }
    }

    /// What the 60-day steps-calibration gather returns across the detached task: the phone's reference steps and the
    /// strap's motion volume by day, the refreshed motion cache, and how many days it answered.
    struct StepsCalibrationGather: Sendable {
        let refSteps: [String: Double]
        let motion: [String: Double]
        let motionCache: [String: StepMotionCacheEntry]
        let cacheHits: Int
    }

    /// Per-day motion volume for the steps estimate, kept in memory between normal passes (at most 60 days).
    private var stepMotionCache: [String: StepMotionCacheEntry] = [:]
    /// Days the motion cache has answered since launch; a test reads it to prove a pass skipped the gravity read.
    private(set) var stepMotionCacheHits = 0

    /// The steps estimate runs on a normal pass only: window starting today, no source context, and not a
    /// full-history rescore chunk. See the call site.
    nonisolated static func runsStepsCalibration(startOffset: Int, keepUnproducedHistory: Bool,
                                                 hasSourceContext: Bool) -> Bool {
        startOffset == 0 && !keepUnproducedHistory && !hasSourceContext
    }

    /// The calibration a pass that does not fit one applies: the manual override when the owner set one, else the
    /// coefficient the last normal pass fitted and mirrored to the profile. nil until there is one (the estimate is
    /// inert before then, as it always was).
    nonisolated static func persistedStepsCalibration(
        manualOverride: Double?, coefficient: Double, sampleDays: Int, confidence: Double, manual: Bool
    ) -> StepsEstimateEngine.Calibration? {
        if let k = manualOverride, k > 0 {
            return StepsEstimateEngine.Calibration(coefficient: k, sampleDays: sampleDays, confidence: 1.0, manual: true)
        }
        guard coefficient > 0 else { return nil }
        return StepsEstimateEngine.Calibration(
            coefficient: coefficient, sampleDays: sampleDays, confidence: confidence, manual: manual)
    }

    /// One civil day's motion volume for the steps estimate, answered from `cached` when the day's owner, read
    /// window and gravity fingerprint are unchanged, else read from the owner's gravity stream. The fingerprint is
    /// read BEFORE the rows, so a row that lands in between only makes the next pass's fingerprint differ (a re-read),
    /// never a stale hit. A failed gravity read is not cached: it counts as an empty day, as it always did.
    nonisolated static func stepMotion(
        for civilDay: CivilDayWindow, now: Int, cached: StepMotionCacheEntry?, store: WhoopStore,
        devices: [PairedDevice], activeId: String, registry: DeviceRegistryStore, fallbackDeviceId: String
    ) async throws -> (motion: Double, entry: StepMotionCacheEntry?, hit: Bool) {
        let dayEnd = civilDay.nextStart - 1
        let owner = await resolveDayOwner(
            day: civilDay.day, from: civilDay.start, to: dayEnd, store: store,
            devices: devices, activeId: activeId, registry: registry, fallbackDeviceId: fallbackDeviceId,
            completedDay: civilDay.nextStart <= now ? civilDay : nil)
        let fingerprint = try? await store.gravityFingerprint(deviceId: owner, from: civilDay.start, to: dayEnd)
        if let fingerprint, let hit = cached,
           hit.matches(owner: owner, from: civilDay.start, to: dayEnd, fingerprint: fingerprint) {
            return (hit.motion, hit, true)
        }
        let grav = try? await store.gravitySamples(deviceId: owner, from: civilDay.start, to: dayEnd, limit: 200_000)
        try CooperativeAnalysisCancellation.checkpoint()
        let motion = StepsEstimateEngine.dayMotionIntensity(grav ?? [])
        guard let fingerprint, grav != nil else { return (motion, nil, false) }
        return (motion, StepMotionCacheEntry(
            owner: owner, from: civilDay.start, to: dayEnd,
            rowCount: fingerprint.count, maxTs: fingerprint.maxTs, motion: motion), false)
    }

    private var dayScanCache: [String: CachedDayScan] = [:]
    private var dayScanCacheConfigSignature = ""
    private var analyzeRecentCacheTestingSeams: AnalyzeRecentCacheTestingSeams?

    func setAnalyzeRecentCacheTestingSeamsForTesting(_ seams: AnalyzeRecentCacheTestingSeams?) {
        analyzeRecentCacheTestingSeams = seams
    }

    /// Pass-wide inputs that can change a `DayScan` without changing a day's raw-HR fingerprint.
    /// Use exact Double bit patterns so equality is deterministic and locale-free.
    nonisolated static func analyzeRecentCacheConfigSignature(
        profile: UserProfile,
        baselines: AnalyticsEngine.ProfileBaselines,
        maxHROverride: Double?,
        timeZoneIdentifier: String,
        timeZoneOffsetSeconds: Int,
        sleepNeedHours: Double,
        sleepConsistency: Double?,
        habitualMidsleepSec: Int?,
        useSleepStagerV2: Bool,
        useMotionAwareWake: Bool,
        deepHrvWindow: Bool,
        sleepTraceActive: Bool,
        hrvTraceActive: Bool,
        stepsTraceActive: Bool,
        preSleepFeedbackEnabled: Bool = false
    ) -> String {
        func bits(_ value: Double?) -> String { value.map { String($0.bitPattern) } ?? "nil" }
        func baseline(_ value: BaselineState?) -> String {
            guard let value else { return "nil" }
            return [bits(value.baseline), bits(value.spread), String(value.nValid),
                    String(value.nightsSinceUpdate), value.status.rawValue].joined(separator: ",")
        }
        return [
            analyzeScanVersion,
            "analytics=\(StrandAnalytics.version)",
            "strain=\(StrainScorerV2.version)",
            "weight=\(bits(profile.weightKg))",
            "height=\(bits(profile.heightCm))",
            "age=\(bits(profile.age))",
            "sex=\(profile.sex)",
            "stepScale=\(bits(profile.stepTicksPerStep))",
            "maxHR=\(bits(maxHROverride))",
            "hrv=\(baseline(baselines.hrv))",
            "rhr=\(baseline(baselines.restingHR))",
            "tz=\(timeZoneIdentifier)",
            "offset=\(timeZoneOffsetSeconds)",
            "sleepNeed=\(bits(sleepNeedHours))",
            "sleepConsistency=\(bits(sleepConsistency))",
            "habitual=\(habitualMidsleepSec.map(String.init) ?? "nil")",
            "sleepV2=\(useSleepStagerV2)",
            "motionWake=\(useMotionAwareWake)",
            "deepHRV=\(deepHrvWindow)",
            "sleepTrace=\(sleepTraceActive)",
            "hrvTrace=\(hrvTraceActive)",
            "stepsTrace=\(stepsTraceActive)",
            "preSleepFeedback=\(preSleepFeedbackEnabled)",
            // The pass always banks the decoded raw SpO2 candidate; there is no scoring/display toggle
            // in this engine. Keep the state explicit so a future toggle must update this signature.
            "spo2Candidate=raw-banked-v1",
        ].joined(separator: "|")
    }

    /// A real workout plus the store namespace that owns its natural key. `WorkoutRow` intentionally
    /// carries provenance, not a storage device id; retaining the latter at the collision seam prevents
    /// an Apple Health row from being accidentally re-written under the canonical WHOOP namespace.
    private struct OwnedWorkout: Sendable {
        let row: WorkoutRow
        let deviceId: String
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        /// REAL provenance of the day's dashboard headline (computed vs an import that won the merge), so
        /// the By-Day badge is honest. Defaults to `.computed` (the engine always writes a computed row);
        /// set per day from the imported day-key sets resolved in `analyzeRecent`.
        var source: DaySource = .computed
        var recoveryPersistenceOwner: RecoveryPersistenceOwner = .canonicalComputed
        /// Charge (recovery) confidence for the day. Defaults `.solid` for a strap-scored night (the gauge
        /// already gates on the HRV baseline being usable); the Apple-Watch fold below sets this to the
        /// `WatchRecovery` confidence so a watch-only recovery reads "calibrating" until it has enough nights.
        var confidence: ScoreConfidence = .solid
        /// SHARED CONTRACT (engine <-> UI): the ordered "what shaped it" Charge driver list, biggest mover
        /// first. One row per term that actually fed the score (`RecoveryScorer.chargeDrivers`, or the Apple
        /// Watch and wearable folds' `WatchRecovery` drivers); empty when there is no score (cold-start). The
        /// UI renders one row per driver under the Charge ring and gates gracefully when this is empty.
        var drivers: [ChargeDriver] = []
        /// The night's skin temperature expressed as a RELATIVE deviation from the personal baseline
        /// (`RecoveryScorer.skinTempRelative`), or nil when no deviation is available. Surfaced as
        /// "+0.3 C vs your normal" with a relative tier tag; never a fake clinical absolute.
        var skinTempRel: SkinTempRelative? = nil
        var id: String { day }
    }

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the SAME shareable strap
    /// log the user already exports (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the
    /// engine stays testable with no UI. Each line is a concise, counts-only summary ("sleep day=…
    /// totalSleepMin=… matched=… source=…") so the next bug report ships proof of what was computed per
    /// day, addressing the project's log-failures-not-successes blind spot and the data needed to settle
    /// "Rest repeats across days". (Sleep overhaul §2.5.)
    /// `AppModel` wires it to `live.append(log:domain:)`. Each line is a concise, counts-only summary,
    /// optionally tagged with the TestDomain so the Sleep/Battery emitters land under their profile tag.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    /// Test seam: runs on the main actor right after the daily-row reconcile commits, before the rest of the
    /// persistence phase. A test cancels the pass from here to prove what a mid-write cancel leaves behind.
    var afterDailyReconcileForTesting: (() -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    /// Apply the user's pre-sleep-feedback consent boundary. Enabling forces a fresh normal scan.
    /// Disabling removes every persisted pre-sleep point in the canonical computed namespace before
    /// changing the preference, so a failed cleanup cannot claim the feature is fully off.
    @discardableResult
    func setPreSleepHeartRateFeedbackEnabled(_ enabled: Bool) async -> Bool {
        guard !computing else { return false }
        let defaults = UserDefaults.standard
        if enabled {
            defaults.set(true, forKey: PreSleepHeartRateFeedback.enabledKey)
            return await analyzeRecent(force: true)
        }

        // Claim the same admission flag as analysis before the first suspension. MainActor isolation makes
        // this check-and-set atomic: a successful cleanup cannot overlap a pass that captured consent=true
        // and later reinsert the rows, and a pass already running makes opt-out fail closed for retry.
        computing = true
        defer { computing = false }
        guard let store = await repo.storeHandle() else { return false }
        do {
            _ = try await repo.removeAllPreSleepHeartRateFeedback(store: store)
        } catch {
            NSLog("IntelligenceEngine: pre-sleep opt-out cleanup failed: \(error)")
            return false
        }
        defaults.set(false, forKey: PreSleepHeartRateFeedback.enabledKey)
        dayScanCacheConfigSignature = ""
        _ = await repo.refresh(.currentDay)
        return true
    }

    // NOTE (#814 union-model follow-up): the engine intentionally has NO `adoptActiveDeviceId`. Its write
    // target (`deviceId + "-noop"`) and imported-baseline read (`hist` under `deviceId`) stay STABLE on the
    // canonical "my-whoop" so a remove+re-add never orphans the computed history. The active strap's raw is
    // still read + scored per day via `resolveDayOwner` (which uses the registry's own active id), and the
    // result lands on the canonical `-noop` sibling; the Repository unions the canonical history with the
    // active strap's live data at read time.

    /// Median of a list (0 when empty) , used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The per-day RHR floor-vs-mean diagnostic line (#691). NOOP's `floor` is the WHOOP-style resting
    /// HR , the lowest SUSTAINED 5-min in-bed level (SleepStager picks the min 5-min rolling-mean HR per
    /// session, the day takes the .min() across them) , whereas a "sleeping HR" app reports the night MEAN
    /// over the whole asleep span. The mean always sits at-or-above the floor, so NOOP reading lower is BY
    /// DESIGN, not a bug; logging both makes a "NOOP RHR is lower than my other app" report explainable
    /// from the strap log. `inBedBpms` is the bpm of every HR sample inside a matched in-bed session (the
    /// SAME span the floor came from, so the two numbers are directly comparable). Empty in-bed → nightMean
    /// is "nil". Counts/bpm only , no timestamps or PII. Pure so it's unit-tested directly and is the SAME
    /// line `analyzeRecent` ships. Byte-identical to the Android `rhrFloorMeanLogLine`.
    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string , the weekly key Fitness Age writes to.
    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// Assess Fitness Age readiness from `gateDays` (the merged last-7 the readiness card counts) and, when
    /// ready, build the fitness_age (+ optional vo2max) points for `satKey`. Empty when not ready. The
    /// SINGLE source of the gate + compute , shared by the recompute pass and the manual "refresh Fitness
    /// Age" button so the two can never drift. Profile passed as primitives (no cross-actor object read).
    /// Mirrors the Android `IntelligenceEngine.fitnessAgeRows`.
    static func fitnessAgeRows(
        gateDays: [DailyMetric], age: Int, sex: String, waistCm: Double, heightCm: Double, weightKg: Double,
        computedId: String, satKey: String,
    ) -> [MetricPoint] {
        let rhrs = gateDays.compactMap { $0.restingHr }.map(Double.init)
        let strains = gateDays.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let waist: Double? = waistCm > 0 ? waistCm : nil
        let ready = FitnessAgeEngine.assessReadiness(
            hasAge: age > 0, hasSex: !sex.isEmpty,
            rhrDays: rhrs.count, activityDays: gateDays.compactMap { $0.strain }.count,
            hasHeightWeight: heightCm > 0 && weightKg > 0, hasWaist: waist != nil)
        guard ready.canCompute,
              let res = FitnessAgeEngine.compute(
                age: Double(age), sex: sex,
                restingHR: medianOf(rhrs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: strains.count, meanActiveStrain: meanStrain),
                waistCm: waist) else { return [] }
        var rows = [MetricPoint(day: satKey, key: "fitness_age", value: res.fitnessAge)]
        if let v = res.vo2max { rows.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
        return rows
    }

    /// Manual "refresh Fitness Age" (the button on the not-ready card): recompute the weekly Fitness Age NOW
    /// from the PERSISTED merged daily history , NO raw-HR rescoring , and upsert it. Same gate
    /// (`fitnessAgeRows`) + date/window logic as the recompute pass, so it reads exactly what the readiness
    /// card shows. Light + works offline (stored data only). Returns true if a value was written. Mirrors
    /// the Android `recomputeFitnessAgeOnly`.
    func recomputeFitnessAgeOnly(maxDays: Int = 21) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let computedId = deviceId + "-noop"
        let referenceNow = Date()
        let civilDays = Self.civilDayWindows(
            reference: referenceNow, startOffset: 0, count: maxDays, calendar: .current)
        guard let newestDay = civilDays.first?.day, let oldestDay = civilDays.last?.day else { return false }
        let gate7 = Array((await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay))
            .sorted { $0.day < $1.day }.suffix(7))
        let rows = Self.fitnessAgeRows(
            gateDays: gate7, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: computedId,
            satKey: Self.saturdayKey(onOrBefore: newestDay))
        if !rows.isEmpty { _ = try? await store.upsertMetricSeries(rows, deviceId: computedId) }
        return !rows.isEmpty
    }

    /// UserDefaults flag guarding the one-shot #313 full-history Effort rescore (below). Set once the
    /// pass completes so it never re-runs.
    // Versioned for Spec 018: devices that completed the original axis cutover run one
    // additional source-backed pass so newly available historical HR receives V2 rows.
    // v3 (N2): one more full-history pass so persisted days pick up the scorer changes that alter stored
    // values: as-of-yesterday Charge baselines (AN-01/AN-04), civil-day DST bucketing (AN-02) and the
    // sleep-to-sleep Effort cycle (AN-05). Every historical Charge value changes once. The same pass rewrites
    // each stored day's calorie total with the resting-energy fill for its off-wrist hours (D3b).
    static let effortRescoreFlagKey = "intelligence.strainV2CalendarHistory.v3.done"
    static let effortRescoreOffsetKey = "intelligence.strainV2CalendarHistory.v3.offset"
    static let effortRescoreDurableProgressKey = "effort-rescore-v3"
    static let effortRescoreChunkDays = 30
    private enum EffortRescoreMigrationError: Error { case chunkDidNotComplete }

    nonisolated static func boundedHistoryDays(
        earliestTimestamp: Int,
        reference: Date,
        calendar inputCalendar: Calendar,
        cap: Int
    ) -> Int {
        guard cap > 0 else { return 0 }
        let calendar = inputCalendar
        let today = calendar.startOfDay(for: reference)
        let earliestDay = calendar.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(earliestTimestamp)))
        guard earliestDay < today else { return 1 }
        guard let span = calendar.dateComponents([.day], from: earliestDay, to: today).day else {
            return cap
        }
        return min(cap, max(1, span + 1))
    }
    private var effortRescoreRunning = false

    /// One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR , those regenerate at
    /// 0–100 with NO double-rescale risk , rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// `analyzeRecent` once with the `maxDays` cap lifted to the full history, then persist a flag so it
    /// runs exactly once. IMPORTED rows are never rewritten here (the engine only ever writes under the
    /// "-noop" computed source) , those are handled by re-import. A day already on 0–100 is recomputed
    /// from the same raw HR and lands on 0–100 again: UNCHANGED axis (verified by test).
    ///
    /// Review round 8 (2): `reference` and `calendar` bound the history and date every chunk's analysis (now and
    /// the device calendar in production), so a test can drive the migration on a fixed fixture.
    func runEffortRescoreIfNeeded(historyDays: Int = 4000, reference: Date = Date(), calendar: Calendar = .current,
                                  shouldPause: () -> Bool = { false }) async {
        guard !effortRescoreRunning else { return }
        effortRescoreRunning = true
        defer { effortRescoreRunning = false }
        guard let store = await repo.storeHandle() else { return }

        let persistedProgress: DurableMigrationProgress
        do {
            if let existing = try await store.durableMigrationProgress(
                key: Self.effortRescoreDurableProgressKey
            ) {
                persistedProgress = existing
            } else if UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey) {
                // Upgrade completed pre-v50 installs without repeating their full-history scan.
                persistedProgress = try await store.markDurableMigrationComplete(
                    key: Self.effortRescoreDurableProgressKey,
                    nextOffset: max(0, UserDefaults.standard.integer(forKey: Self.effortRescoreOffsetKey))
                )
            } else {
                persistedProgress = try await store.saveDurableMigrationProgress(
                    key: Self.effortRescoreDurableProgressKey,
                    nextOffset: max(0, UserDefaults.standard.integer(forKey: Self.effortRescoreOffsetKey))
                )
            }
        } catch {
            return
        }
        // Review round 7 (4): v3 complete, the settle pass takes this grant.
        guard persistedProgress.state != .complete else {
            await runEffortRescoreSettleIfNeeded(store: store, historyDays: historyDays, reference: reference,
                                                 calendar: calendar, shouldPause: shouldPause)
            return
        }

        let earliestTimestamp: Int?
        do {
            earliestTimestamp = try await earliestSourceHeartRateTimestamp(store: store)
        } catch {
            return
        }
        guard let earliestTimestamp else {
            if (try? await store.markDurableMigrationComplete(
                key: Self.effortRescoreDurableProgressKey,
                nextOffset: persistedProgress.nextOffset
            )) != nil {
                UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey)
            }
            return
        }
        let effectiveHistoryDays = Self.boundedHistoryDays(
            earliestTimestamp: earliestTimestamp,
            reference: reference,
            calendar: calendar,
            cap: max(0, historyDays))

        let (outcome, durableOffset) = await runFullHistoryRescoreBatch(
            store: store,
            progressKey: Self.effortRescoreDurableProgressKey,
            historyDays: effectiveHistoryDays,
            startOffset: persistedProgress.nextOffset,
            reference: reference,
            calendar: calendar,
            shouldPause: shouldPause,
            didCommitOffset: { UserDefaults.standard.set($0, forKey: Self.effortRescoreOffsetKey) }
        )
        do {
            if outcome == .completed {
                _ = try await store.markDurableMigrationComplete(
                    key: Self.effortRescoreDurableProgressKey,
                    nextOffset: durableOffset
                )
                UserDefaults.standard.set(durableOffset, forKey: Self.effortRescoreOffsetKey)
                UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey)
            }
        } catch {
            // Replaying one source-derived batch is idempotent. Leave the durable cursor unchanged.
        }
    }

    /// Review round 7 (4): the settle pass. v3 rescores newest first, so each chunk's Charge baselines read the
    /// older days' resting HR and HRV as stored before those days' own rescore. One more pass over the same
    /// chunks, with the same cursor, chunking and safety net, scores every Charge against the rescored history,
    /// the result a from-scratch oldest-first run gives. It starts only once v3's durable progress is complete,
    /// so it never runs while v3 is incomplete, after an app kill mid-v3 included.
    static let effortRescoreSettleDurableProgressKey = "effort-rescore-v3-settle"

    private func runEffortRescoreSettleIfNeeded(store: WhoopStore, historyDays: Int, reference: Date,
                                                calendar: Calendar, shouldPause: () -> Bool) async {
        let progress: DurableMigrationProgress
        do {
            guard try await store.durableMigrationProgress(key: Self.effortRescoreDurableProgressKey)?.state
                    == .complete else { return }
            if let existing = try await store.durableMigrationProgress(
                key: Self.effortRescoreSettleDurableProgressKey) {
                progress = existing
            } else {
                progress = try await store.saveDurableMigrationProgress(
                    key: Self.effortRescoreSettleDurableProgressKey, nextOffset: 0)
            }
        } catch {
            return
        }
        guard progress.state != .complete else { return }
        let earliestTimestamp: Int?
        do {
            earliestTimestamp = try await earliestSourceHeartRateTimestamp(store: store)
        } catch {
            return
        }
        guard let earliestTimestamp else {
            _ = try? await store.markDurableMigrationComplete(
                key: Self.effortRescoreSettleDurableProgressKey, nextOffset: progress.nextOffset)
            return
        }
        let (outcome, durableOffset) = await runFullHistoryRescoreBatch(
            store: store,
            progressKey: Self.effortRescoreSettleDurableProgressKey,
            historyDays: Self.boundedHistoryDays(
                earliestTimestamp: earliestTimestamp, reference: reference, calendar: calendar,
                cap: max(0, historyDays)),
            startOffset: progress.nextOffset,
            reference: reference,
            calendar: calendar,
            shouldPause: shouldPause,
            didCommitOffset: { _ in }
        )
        if outcome == .completed {
            // A failed write leaves the cursor; replaying one source-derived batch is idempotent.
            _ = try? await store.markDurableMigrationComplete(
                key: Self.effortRescoreSettleDurableProgressKey, nextOffset: durableOffset)
        }
    }

    /// Bound the full-history passes to source-backed history. The prior fixed 4,000-day loop ran 134
    /// analysis batches even on a fresh 30-day install, delaying launch by seconds and making History
    /// appear frozen. Include every registered strap plus active/canonical ids because old paired devices
    /// can still own historical raw days. A read failure throws, so the caller leaves its marker for a retry.
    private func earliestSourceHeartRateTimestamp(store: WhoopStore) async throws -> Int? {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let registeredIds = (try? registry.all().map(\.id)) ?? []
        let sourceIds = Set(registeredIds + repo.importedReadIds + [deviceId])
        var earliestTimestamp: Int?
        for id in sourceIds {
            if let bounds = try await store.hrTimestampBounds(deviceId: id) {
                earliestTimestamp = min(earliestTimestamp ?? bounds.earliest, bounds.earliest)
            }
        }
        return earliestTimestamp
    }

    /// One background maintenance grant's batch of a full-history rescore whose durable cursor is `progressKey`
    /// (v3, then its settle pass). Each chunk keeps the days it can't produce (review round 7, 1). Returns the
    /// driver's outcome and the cursor reached.
    private func runFullHistoryRescoreBatch(
        store: WhoopStore,
        progressKey: String,
        historyDays: Int,
        startOffset: Int,
        reference: Date,
        calendar: Calendar,
        shouldPause: () -> Bool,
        didCommitOffset: @escaping (Int) -> Void
    ) async -> (outcome: HistoricalMigrationDriver.Outcome, offset: Int) {
        var durableOffset = startOffset
        var completed = false
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: historyDays,
            chunkDays: Self.effortRescoreChunkDays,
            isCompleted: { completed },
            loadOffset: { durableOffset },
            saveOffset: { durableOffset = $0 },
            markCompleted: { completed = true },
            shouldPause: shouldPause,
            analyzeChunk: { [weak self] chunk, offset in
                guard let self else { throw EffortRescoreMigrationError.chunkDidNotComplete }
                let before = self.analysisCompletionSerial
                _ = await self.analyzeRecent(
                    maxDays: chunk,
                    startOffset: offset,
                    refreshRepository: false,
                    analysisReference: reference,
                    analysisCalendar: calendar,
                    keepUnproducedHistory: true
                )
                guard self.analysisCompletionSerial > before else {
                    throw EffortRescoreMigrationError.chunkDidNotComplete
                }
                // Commit the cursor before this maintenance grant can yield or the process can suspend.
                // Re-analysis is idempotent, but a completed batch must not depend on later process memory.
                let nextOffset = offset + chunk
                _ = try await store.saveDurableMigrationProgress(
                    key: progressKey,
                    nextOffset: nextOffset
                )
                durableOffset = nextOffset
                didCommitOffset(nextOffset)
            },
            finalRefresh: { [weak self] in
                guard let self else { return false }
                // Review round 7 (4): the full-history lane only refreshes the history extent and reports
                // `.deferred` by design (`Repository.executeRefresh`), so it never returned true and v3 was never
                // marked complete. The rescored recent days are published once, and completion waits for that.
                _ = await self.repo.refresh(.fullHistoryMigration)
                return await self.repo.refresh(.recentDashboard(days: 30))
            },
            // One background maintenance grant owns one bounded batch. A scene change or suspension
            // resumes from the durable cursor instead of monopolizing a foreground session.
            maximumChunksPerRun: 1
        )
        return (outcome, durableOffset)
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 RE-POLLUTION re-arm: a one-shot heal isn't enough when a strap with a WANDERING clock keeps
    /// re-sending bad-dated records across syncs. Whenever a sync's ingest gate drops implausible records
    /// (the strap demonstrably has a bad clock THIS session), `BLEManager` sets this pending flag so the
    /// next analyze tick re-runs the purge , clearing any pollution that slipped in on an OLDER build whose
    /// gate was weaker, rather than permanently gating behind the one-shot `done` flag. Cleared once the
    /// re-heal runs. Pure UserDefaults so the BLE layer can set it without an engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Set only after a timestamp heal changed storage without proving exact civil days. AppModel drains
    /// this flag into the durable bounded maintenance lane once the active source scope is available.
    static let timestampHealMaintenancePendingKey = "intelligence.timestampHeal.v547.maintenancePending"

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547, pikapik). The ingest
    /// gate now keeps garbage-timestamped records out, but a user who synced on an older build already has
    /// rows dated to scattered garbage (far-past, a bogus 2027, FUTURE dates) , which made one ~12h block
    /// re-attribute to every day (the repeated totalSleepMin=721 across many days) and a future row surface
    /// as the Today "last night" carry-over. This purges those rows ONCE, then queues maintenance against
    /// the surviving raw data so the genuine days can be repaired. Idempotent (a clean DB deletes nothing) and
    /// re-running is harmless, but a persisted flag skips it on every later launch. It never performs a
    /// broad dashboard rescore; the maintenance owner publishes bounded exact-day batches.
    func runTimestampHealIfNeeded() async {
        // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547 re-pollution): a
        // wandering-clock strap re-sends bad-dated records across syncs, so a single on-upgrade pass can't
        // be the only line of defence. The pending flag is cleared below once the re-heal completes.
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED , \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        if result.didChange {
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; queued bounded maintenance.", nil)
            UserDefaults.standard.set(true, forKey: Self.timestampHealMaintenancePendingKey)
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        // Clear the re-pollution request now that this re-heal has run , a future bad-clock sync re-arms it.
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Move timestamp-heal evidence into the same durable maintenance table used by legacy receipts. This
    /// method is retryable when the active physical source is not yet wired at launch.
    func enqueuePendingTimestampHealMaintenance() async {
        guard UserDefaults.standard.bool(forKey: Self.timestampHealMaintenancePendingKey),
              case let .active(source) = repo.liveSourceState,
              let store = await repo.storeHandle()
        else { return }
        do {
            let databaseInstanceId = try await store.databaseInstanceId()
            let scope = try HistoricalAnalysisScope(
                databaseInstanceId: databaseInstanceId,
                sourceId: source.id,
                deviceId: source.id,
                deviceLineageId: source.historyLineage,
                cursorEpoch: source.cursorEpoch,
                trimScope: HistoricalCursorScope.defaultTrimScope)
            let watermark = try await store.historicalDataCommitWatermark(
                deviceId: source.id,
                lineage: source.historyLineage,
                cursorEpoch: source.cursorEpoch)
            try await store.enqueueFullHistoryRepairMaintenance(
                scope: scope,
                throughReceiptGeneration: max(1, watermark?.generation ?? 1),
                reason: "timestamp_heal_without_exact_days",
                recordedTimeZoneIdentifier: TimeZone.current.identifier)
            UserDefaults.standard.set(false, forKey: Self.timestampHealMaintenancePendingKey)
        } catch {
            diagnosticSink?("Heal(#547): maintenance admission deferred for retry: \(error)", nil)
        }
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    @discardableResult
    func analyzeRecent(maxDays: Int = 21, startOffset: Int = 0, force: Bool = true,
                       refreshRepository: Bool = true, analysisReference: Date? = nil,
                       analysisCalendar: Calendar = .current,
                       sourceContext: ExactWorkSourceContext? = nil,
                       keepUnproducedHistory: Bool = false) async -> Bool {
        let performanceTrace = PerformanceTrace.begin("analyze_recent")
        var performanceChangedRows = -1
        defer { PerformanceTrace.end(performanceTrace, changedRows: performanceChangedRows) }
        // Production work is admitted by IntelligenceAnalysisCoordinator. A direct legacy caller that
        // collides must report non-completion; the coordinator preserves and retries the exact request.
        // Never spawn an unstructured replay here: it loses the request's publication/postcondition contract.
        guard !computing else { return false }
        // Claim admission before `storeHandle` or the watermark read can suspend. The pre-sleep consent
        // cleanup uses this same flag, closing the MainActor reentrancy window between the old guard and the
        // former late assignment below.
        computing = true
        defer { computing = false }
        guard let store = await repo.storeHandle() else {
            note = String(localized: "No on-device store yet.")
            return false
        }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return false }

        // #836 (idle-tick gate): re-scoring a 21-day window re-reads ~21×54 h of raw HR and re-runs
        // analyzeDay over it. After a big Apple Health import (a reporter's: 2.1 M rows, ~190 k HR/day) that
        // is multi-second, memory-heavy work, and the 15-minute steady-state tick (AppModel) repeats it
        // every tick even when NOTHING new landed — the ongoing lag/crash in #836. A cheap whole-history HR
        // fingerprint (count+maxTs, indexed, no rows materialized) lets a NON-forced caller short-circuit
        // when the raw stream is byte-for-byte unchanged since the last successful run. All-or-nothing: it
        // never produces a PARTIAL pass, so the window-wide reconciliation (stale-day eviction, detected-
        // workout delete) is untouched and no computed history is dropped. Every real update path (sync
        // backfill, import, sleep/workout edit, baseline recalibrate, timestamp heal) calls with the default
        // `force: true` and always rescores, so a skipped tick can never hide new data.
        // DL-02 (N2-7): the witness covers only the backstop window, for every owner whose raw stream can be
        // scored (the canonical id, the registry's active strap and every paired device). The old one counted
        // every HR row ever stored on every pass, forced or not, and was keyed to the canonical id, so rows a
        // re-paired strap wrote under its own id never moved it and the backstop always skipped. It is read
        // at the start of a pass (so data landing mid-pass still moves the next tick) and only by passes
        // that use it: a non-forced tick, or a pass over the current window that refreshes it.
        let referenceNow = analysisReference ?? Date()
        let now = Int(referenceNow.timeIntervalSince1970)
        let wmKey: String
        if !force || (startOffset == 0 && sourceContext == nil) {
            wmKey = await analyzeWatermark(store: store, reference: referenceNow, calendar: analysisCalendar)
        } else {
            wmKey = ""
        }
        if !force, !wmKey.isEmpty,
           UserDefaults.standard.string(forKey: Self.analyzeWatermarkKey) == wmKey {
            performanceChangedRows = 0
            return false
        }

        // Review round 4 (2): the first pass after midnight (or any later one, until it succeeds) also rescores
        // an earlier day if its calorie total was filled only part of the way, so the day's off-wrist
        // resting energy is counted through midnight. Once that pass stores the day filled to its end, passes
        // cover today only again. Review round 5 (2): that day can be two days back after a day without a pass;
        // the pass widens to reach the oldest such day (round 6, 2), never past `calorieFillCatchUpDays`.
        var maxDays = maxDays
        if maxDays == 1, startOffset == 0, sourceContext == nil,
           let offset = await unfinishedCalorieFillOffset(store: store, reference: referenceNow,
                                                          calendar: analysisCalendar) {
            maxDays = offset + 1
        }

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        // Device wall-clock offset (seconds east of UTC) at `referenceNow`. It only keys the pass-wide
        // cache signature. Every per-day decision (day bucket, session attribution, the daytime guard,
        // the main-night pick) uses that civil day's own interval and offset (`clockOffsetByDay`), so a
        // day on the far side of a DST change is not scored an hour off (AN-02).
        let analysisTimeZone = analysisCalendar.timeZone
        let tzOffset = analysisTimeZone.secondsFromGMT(for: referenceNow)

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. For a BLE-only
        // user the imported daily rows are empty, so the HRV baseline isn't usable yet and recovery is
        // null here , but each night's avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we
        // harvest them to SEED the baseline and re-score in pass 2. foldHistory winsorizes outliers.
        //
        // Read the imported rows DIRECTLY (deviceId is the imported id; computed rows live under the
        // sibling `-noop` id) over the full history, sorted chronologically , NOT `repo.days`, which is
        // the merged published cache (it pre-loads prior computed `-noop` rows and back-fills nil
        // imported HRV/RHR/resp fields from computed values). Using the merge contaminated this very
        // "imported-only" baseline with computed values and made the fold window depend on whichever
        // refresh last ran (4000 vs 120 days). This mirrors the Android port's `days(importedDeviceId)`.
        guard !Task.isCancelled else {
            performanceChangedRows = 0
            return false
        }
        let hist: [DailyMetric]
        do {
            hist = try await store.dailyMetrics(
                deviceId: deviceId, from: "0000-01-01", to: "9999-12-31").sorted { $0.day < $1.day }
        } catch {
            note = String(localized: "Recovery analysis is waiting for the local database.")
            NSLog("IntelligenceEngine: required baseline read failed: \(error)")
            return false
        }
        // HRV baseline honours the manual "Recalibrate baseline" epoch (noop.hrvBaselineEpoch); the
        // resting-HR baseline honours the Charge-wide sibling (noop.recoveryBaselineEpoch). Pass the
        // per-value "yyyy-MM-dd" day keys (parallel to the values) so foldHistory can drop every night
        // before the epoch. A 0 / absent epoch makes this byte-identical to the plain fold, so scoring is
        // unchanged until the user taps Recalibrate.
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, dayKeys: hist.map { $0.day }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, dayKeys: hist.map { $0.day },
                                             cfg: rhrCfg, baselineEpoch: Baselines.recoveryBaselineEpoch())
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result (daily metrics + sessions), NOT the raw streams , every field
        // except recovery is baseline-independent, so pass 2 only re-scores the cheap recovery
        // composite. The hr/rr/resp/gravity arrays go out of scope each iteration (memory stays bounded).
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?,
                            sessionMotion: [Int: [Double]],
                            sessionSleepState: [Int: [Int]],
                            hrvDiag: String?)] = []   // #195: carried from loop 1, emitted in the main-actor loop
        // Nightly values harvested in pass 1, keyed by day, to seed the pass-2 baseline.
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        // On-device RSA respiration + wear-gated skin-temp means (baseline-independent), harvested to
        // seed resp/skin-temp baselines the same way avgHrv seeds the HRV baseline.
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]
        var whoop4SkinAnchorByDay: [String: Double] = [:]   // review round 3 (B): each WHOOP 4.0 night's anchor
        var strapWornSecondsByDay: [String: Int] = [:]      // review round 4 (5): calorie coverage

        // Device-registry snapshot for per-day owner resolution (invariant I2 , a day's scores come from
        // exactly ONE source). Read once before the loop: the paired-device list + the active id are
        // stable for the run. With only the seeded 'my-whoop' row paired (the default and every
        // single-WHOOP install) the active strap is `deviceId`, so `resolveDayOwner` below returns
        // `deviceId` for every day and the per-day reads are byte-identical to the pre-I2 behaviour.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let regDevices = (try? registry.all()) ?? []
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        // Resolve today's real LOCAL civil-day boundary (#277). A fixed-offset epoch floor is wrong on a
        // daylight-saving transition because the offset at `referenceNow` may differ from the offset at
        // that day's midnight. Use the same calendar enumerator as every scored day instead.
        guard let currentCivilDay = Self.civilDayWindows(
            reference: referenceNow,
            startOffset: 0,
            count: 1,
            calendar: analysisCalendar).first else {
            performanceChangedRows = 0
            note = String(localized: "Unable to establish a valid local-day window.")
            return false
        }
        let currentCivilDayStart = currentCivilDay.start
        let civilDays = Self.civilDayWindows(
            reference: referenceNow,
            startOffset: startOffset,
            count: maxDays,
            calendar: analysisCalendar)
        guard civilDays.count == maxDays,
              let newestCivilDay = civilDays.first,
              let oldestCivilDay = civilDays.last else {
            performanceChangedRows = 0
            note = String(localized: "Unable to enumerate the requested local-day window.")
            return false
        }

        // F5: a pass over completed days only (a v3 chunk, an exact-day run) first scans the day after its
        // newest one, solely for that day's cycle start, so the newest day's Effort ends at the real next
        // onset instead of at midnight. The lookahead scan is dropped before anything is kept or persisted.
        let lookaheadCivilDay: CivilDayWindow? = startOffset > 0
            ? Self.civilDayWindows(reference: referenceNow, startOffset: startOffset - 1, count: 1,
                                   calendar: analysisCalendar).first
            : nil

        // AN-02: each civil day's own wall-clock offset, plus a day-key lookup for the pass-2 folds.
        let civilDayByKey = Dictionary(civilDays.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let clockOffsetByDay = Dictionary(
            (civilDays + (lookaheadCivilDay.map { [$0] } ?? [])).map {
                ($0.day, AnalyticsEngine.civilDayClockOffset($0.start..<$0.nextStart, timeZone: analysisTimeZone))
            },
            uniquingKeysWith: { first, _ in first })

        let computedId = deviceId + "-noop"
        let windowStart = oldestCivilDay.start - 30 * 3_600
        let windowEnd = startOffset == 0 ? now : newestCivilDay.nextStart
        // Resolve the complete effective sleep-boundary input before pass 1. Shadow RHR and opt-in
        // pre-sleep observations must follow a user's corrected bedtime/wake time in this same pass, and
        // the per-day edit fingerprint below prevents a warm raw-HR cache from replaying old bounds.
        let editedRowsSourceId = repo.deviceId
        let editedRows = await repo.selfHealEditedStages(
            sourceId: editedRowsSourceId,
            from: windowStart,
            to: windowEnd
        )
        // Imported sleep is already an authoritative, user-visible boundary even when the local raw stream
        // cannot detect it again (for example, an import has minute HR but no gravity). Read the bounded
        // window once, outside the per-day loop, and let the descriptive RHR/pre-sleep shadows use it as a
        // fallback. Exact-source maintenance stays isolated to its requested raw source and therefore does
        // not fold the normal presentation union into that lane.
        let persistedShadowSessions: [SourcedCachedSleepSession]
        if sourceContext == nil {
            do {
                persistedShadowSessions = try await repo.requiredImportedSleepSessionsBySource(
                    store: store, from: windowStart, to: windowEnd, limit: 4_000
                )
            } catch {
                note = String(localized: "Sleep history could not be read safely. NOOP will retry.")
                NSLog("IntelligenceEngine: imported sleep shadow read failed: \(error)")
                return false
            }
        } else {
            persistedShadowSessions = []
        }

        // ── Learned habitual midsleep (#547) ──────────────────────────────────
        // Compute the user's habitual midsleep ONCE per run from the trailing sleep history so the
        // main-night scored pick aligns to their REAL bedtime (a late/shift sleeper), not a fixed clock
        // band. Read the stored sleep sessions (imported WHOOP-export + computed "-noop") over the
        // analysis window, make one HistoryBlock per session keyed by the LOCAL calendar day of its
        // midpoint, and let the learner pick the longest block per day (so naps drop out automatically).
        // Returns nil under `habitualMinDays` of history → cold-start: every `analyzeDay`/`sleepEditedDaily`
        // call below stays on the overnight-band bonus. The same value threads into both seams so analytics
        // and the Sleep tab resolve to the identical block. (#547)
        let habitualMidsleepSec = await Self.computeHabitualMidsleep(
            store: store, importedId: deviceId, computedId: computedId,
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeZone: analysisTimeZone)

        // ── FIX 1 (main-actor jank): run the ENTIRE per-day enumeration OFF the main actor ───────────
        // Every `await store.…` read inside this loop has its continuation RESUME on the main actor
        // (the engine is `@MainActor`), so on a fresh-import 4000-day pass the ~32 000 read-resumes
        // monopolise the main actor for ~1 minute and SwiftUI can't render. The per-day reads + scoring
        // touch NO `@Published`/`repo`/`profile` state , only the captured immutable inputs, the
        // `WhoopStore` actor, the nonisolated `registry`, and the pure `resolveDayOwner` /
        // `bandSleepStateSamples` / `AnalyticsEngine.analyzeDay`. So we hoist the whole loop into ONE
        // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, then hop back
        // here only to fold the results into `@Published`-feeding state and `refresh()` once at the end.
        // The per-day SCORING ORDER, the `hr.count >= 200` skip, and the maxDays semantics are unchanged;
        // only the executor the reads resume on changes. Diagnostic (#691) lines are computed inside (pure
        // inputs) and returned so they can be replayed through `diagnosticSink` here, in the SAME order.
        // Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the @Sendable
        // detached closure captures the VALUE, never `self` (which would be an isolation violation).
        let ownerFallbackId = deviceId
        // Sleep & Rest test mode (E5): read the zero-cost gate ONCE here (a single Bool) and capture it
        // into the detached loop. When false (the default), no per-day trace sink is built and analyzeDay
        // runs its byte-identical default path. When true, each day collects its gate-trace + Rest line,
        // replayed below through `diagnosticSink` tagged `.sleep` in per-day order.
        let sleepTraceActive = TestCentre.active(.sleep)
        // HRV & Autonomic test mode (#141): read the zero-cost gate ONCE. When true, each day collects the
        // nightly per-window RMSSD (by stage) + the whole-night/deep-only/last-SWS summary, replayed below
        // tagged `.hrv`. When false (the default), no HRV trace is built and analyzeDay's path is unchanged.
        let hrvTraceActive = TestCentre.active(.hrv)
        // HRV window (#141): read ONCE. When the user picked WHOOP-style, the nightly HRV is RMSSD over deep
        // sleep only; default whole-night otherwise. Captured into the detached loop, threaded to analyzeDay.
        let deepHrvWindow = UserDefaults.standard.string(forKey: UnitPrefs.hrvWindowKey) == HrvWindow.deep.rawValue
        // Steps test mode: read the zero-cost gate ONCE here (a single Bool) and capture it into the detached
        // loop. When false (the default), no raw-counter trace is built per day. When true, each day collects
        // the 5/MG cumulative @57 series + wrap-aware deltas + dropped deltas, replayed below tagged `.steps`.
        // The trace recomputes the SAME wrap-aware sum analyzeDay already did, so the steps total is unchanged.
        let stepsTraceActive = TestCentre.active(.steps)
        // Read the opt-in once per pass. It participates in the cache signature, so toggling it cannot
        // replay a cached scan that omitted (or retained) a pre-sleep observation.
        let storedPreSleepFeedbackEnabled = UserDefaults.standard.bool(
            forKey: PreSleepHeartRateFeedback.enabledKey
        )
        #if DEBUG
        let effectivePreSleepFeedbackEnabled = AppleDemoSeeder.effectivePreSleepFeedbackEnabled(
            userOptIn: storedPreSleepFeedbackEnabled,
            demoRequested: AppleDemoSeeder.requested
        )
        #else
        let effectivePreSleepFeedbackEnabled = storedPreSleepFeedbackEnabled
        #endif
        let preSleepFeedbackEnabled = Self.preSleepFeedbackEnabled(
            optedIn: effectivePreSleepFeedbackEnabled,
            isExactSourceWork: sourceContext != nil
        )
        // Read every pass-wide scoring switch once. Besides making one run internally consistent, these
        // values form the cache signature so a preference/profile/baseline change invalidates all reuse.
        let useSleepStagerV2 = PuffinExperiment.experimentalSleepV2Enabled
        let useMotionAwareWake = PuffinExperiment.motionAwareWakeEnabled
        let sleepNeedHours = AnalyticsEngine.Rest.defaultNeedHours
        let sleepConsistency: Double? = nil
        let cacheConfigSignature = Self.analyzeRecentCacheConfigSignature(
            profile: up,
            baselines: baselines1,
            maxHROverride: maxHR,
            timeZoneIdentifier: analysisCalendar.timeZone.identifier,
            timeZoneOffsetSeconds: tzOffset,
            sleepNeedHours: sleepNeedHours,
            sleepConsistency: sleepConsistency,
            habitualMidsleepSec: habitualMidsleepSec,
            useSleepStagerV2: useSleepStagerV2,
            useMotionAwareWake: useMotionAwareWake,
            deepHrvWindow: deepHrvWindow,
            sleepTraceActive: sleepTraceActive,
            hrvTraceActive: hrvTraceActive,
            stepsTraceActive: stepsTraceActive,
            preSleepFeedbackEnabled: preSleepFeedbackEnabled)
        // Exact-source maintenance stays cache-free in v1. Normal analysis can reuse only a cache built
        // under the identical pass-wide signature; a mismatch behaves exactly like a cold cache.
        let cacheSnapshot: [String: CachedDayScan] = sourceContext == nil
            && dayScanCacheConfigSignature == cacheConfigSignature ? dayScanCache : [:]
        let cacheTestingSeams = analyzeRecentCacheTestingSeams
        let scanPass: DayScanPass
        do {
            scanPass = try await CooperativeAnalysisCancellation.runDetached {
            var out: [DayScan] = []
            var nextCache: [String: CachedDayScan] = [:]
            var cacheReused = 0
            var cacheEligible = 0
            // #938: the WHOOP 4.0 ADC offset is per-device, not per-night. Learn one anchor per owner
            // from the whole scan window and reuse it for every night so cross-night deviations survive.
            let skinAnchorScanFrom = oldestCivilDay.start - 30 * 3_600
            let skinAnchorScanTo = newestCivilDay.start + 18 * 3_600
            var skinAnchorByOwner: [String: Double] = [:]
            var skinAnchorResolvedOwners = Set<String>()
            var backgroundPaceMark = DispatchTime.now().uptimeNanoseconds
            // `civilDays` runs newest first, so D+1 is scanned before D and its cycle start is known (AN-05).
            var newerCivilDay: CivilDayWindow?
            for civilDay in (lookaheadCivilDay.map { [$0] } ?? []) + civilDays {
                defer { newerCivilDay = civilDay }
                try CooperativeAnalysisCancellation.checkpoint()
                try await RescoreBackgroundPolicy.paceIfBackgrounded(since: &backgroundPaceMark)
                let dayStart = civilDay.start
                let day = civilDay.day
                // Read a generous window around the night that ends on `day`; the stager finds the span.
                let from = dayStart - 30 * 3_600
                // Sleep read-window END. For a PAST day the night may end any time before the NEXT local
                // midnight (late sleepers / weekend lie-ins / shift workers wake well after noon), so a
                // hard `dayStart + 18h` (6 PM) bound TRUNCATED the read at exactly 18:00 , and a real wake
                // past it was reported as a flat 18:00 wake (#500). Read a PAST day through to the next
                // local midnight so the stager sees the whole night; TODAY keeps the 18:00 cap (the store
                // clamps to `now` anyway, and an in-progress nap shouldn't be read as a finished night).
                let nextMidnight = civilDay.nextStart
                // Exact work uses the civil-day boundary supplied by the calendar. For the current
                // partial day, clamp the read to the committed analysis reference instead of adding an
                // elapsed-hour approximation that can cross a DST boundary.
                let to = min(nextMidnight, now)
                // AN-05: Effort's cycle for D ends where D+1's begins: D+1's main-night onset, or its civil
                // midnight when it has no main night. Only today, the newest day of a current pass, has no
                // scanned successor and keeps running to its last reading (F5: a partial window scans one
                // lookahead day).
                let nextCycleBoundary: Int? = newerCivilDay.map { newer in
                    let newerScan = out.last.flatMap { $0.day == newer.day ? $0 : nil }
                    return AnalyticsEngine.CycleEnd.next(
                        cycleStart: newerScan?.result?.cycleStart,
                        nextDayInterval: newer.start..<newer.nextStart)
                }
                // Readings between the read window's inclusive end and the boundary (late sleepers).
                let cycleTail: ClosedRange<Int>? = nextCycleBoundary.flatMap { boundary in
                    boundary - 1 >= to + 1 ? (to + 1)...(boundary - 1) : nil
                }

                // I2: pick the single device that owns this day, and read ITS streams below. With one device
                // this resolves to `deviceId` (active strap, has data → priority 0), so nothing changes; with
                // multiple sources the day is scored from exactly one (active strap > other live straps >
                // imports, or a locked override). Falls back to `deviceId` if the registry is unreadable.
                let owner: String
                if let sourceContext {
                    owner = sourceContext.deviceId
                } else {
                    owner = await Self.resolveDayOwner(day: day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId,
                                                       completedDay: civilDay.nextStart <= now ? civilDay : nil)
                }
                let dayInterval = civilDay.start..<civilDay.nextStart
                let dayOffset = clockOffsetByDay[day] ?? tzOffset
                let dayEditedRows = Self.editedRowsForOwnerDay(
                    editedRows,
                    rowsSourceId: editedRowsSourceId,
                    owner: owner,
                    dayWindow: dayInterval
                )
                let sleepEditFingerprint = Self.sleepEditFingerprint(dayEditedRows)
                let dayPersistedShadowSessions = persistedShadowSessions.compactMap {
                    $0.sourceId == owner
                        && $0.session.endTs >= civilDay.start
                        && $0.session.endTs < civilDay.nextStart
                        ? $0.session : nil
                }
                let persistedSleepFingerprint = Self.persistedSleepFingerprint(
                    dayPersistedShadowSessions
                )

                // Resolve the WHOOP 4.0 window-wide skin anchor before the bundle read. The anchor is part of
                // the reuse identity because another night's new skin rows can shift this device-wide value.
                let skinFamily = Self.skinTempFamily(forOwner: owner, devices: regDevices)
                let skinAnchorRaw: Double?
                if skinFamily == .whoop4 {
                    if !skinAnchorResolvedOwners.contains(owner) {
                        try CooperativeAnalysisCancellation.checkpoint()
                        let windowSkin = try await store.skinTempSamples(
                            deviceId: owner, from: skinAnchorScanFrom, to: skinAnchorScanTo, limit: 200_000)
                        try CooperativeAnalysisCancellation.checkpoint()
                        if let anchor = Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) {
                            skinAnchorByOwner[owner] = anchor
                        }
                        skinAnchorResolvedOwners.insert(owner)
                    }
                    skinAnchorRaw = skinAnchorByOwner[owner]
                } else {
                    skinAnchorRaw = nil
                }

                // Conservative v1 eligibility: only a positively identified WHOOP 4.0 from normal analysis.
                // 5/MG, Oura/import providers, and exact-source maintenance always take the full path.
                let ownerDevice = regDevices.first(where: { $0.id == owner })
                let isWhoop4 = skinFamily == .whoop4
                    && ownerDevice?.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
                var dayCacheKey: String?
                if sourceContext == nil, isWhoop4 {
                    cacheEligible += 1
                    try CooperativeAnalysisCancellation.checkpoint()
                    let fingerprint: (count: Int, maxTs: Int)
                    if let loader = cacheTestingSeams?.fingerprintLoader {
                        fingerprint = try await loader(store, owner, from, to)
                    } else {
                        fingerprint = try await store.hrFingerprint(deviceId: owner, from: from, to: to)
                    }
                    try CooperativeAnalysisCancellation.checkpoint()
                    var cycleFingerprint = nextCycleBoundary.map { "c\($0)" } ?? ""
                    if let cycleTail {
                        let tail: (count: Int, maxTs: Int)
                        if let loader = cacheTestingSeams?.fingerprintLoader {
                            tail = try await loader(store, owner, cycleTail.lowerBound, cycleTail.upperBound)
                        } else {
                            tail = try await store.hrFingerprint(
                                deviceId: owner, from: cycleTail.lowerBound, to: cycleTail.upperBound)
                        }
                        cycleFingerprint += ":\(tail.count):\(tail.maxTs)"
                        try CooperativeAnalysisCancellation.checkpoint()
                    }
                    let key = AnalyzeRecentDayCache.cacheKey(
                        owner: owner,
                        hrCount: fingerprint.count,
                        hrMaxTs: fingerprint.maxTs,
                        skinAnchorRaw: skinAnchorRaw,
                        sleepEditFingerprint: sleepEditFingerprint,
                        persistedSleepFingerprint: persistedSleepFingerprint,
                        cycleFingerprint: cycleFingerprint,
                        hrvWindowDetail: dayStart == currentCivilDayStart,
                        calorieFillEnd: dayInterval.upperBound > now ? now : nil)   // D3b: today fills to now
                    dayCacheKey = key
                    if let cached = cacheSnapshot[day], cached.key == key {
                        // A hit replaces pass 1 only. The cached scan still enters the normal main-actor fold
                        // and all pass-2/persistence/reconciliation work below.
                        try CooperativeAnalysisCancellation.checkpoint()
                        out.append(cached.scan)
                        nextCache[day] = cached
                        cacheReused += 1
                        continue
                    }
                }

                try CooperativeAnalysisCancellation.checkpoint()
                let bundle: AnalysisDayBundle
                if let loader = cacheTestingSeams?.bundleLoader {
                    bundle = try await loader(store, owner, from, to, 200_000)
                } else {
                    bundle = try await store.analysisDayBundle(
                        deviceId: owner, from: from, to: to, limit: 200_000)
                }
                try CooperativeAnalysisCancellation.checkpoint()
                try await RescoreBackgroundPolicy.paceIfBackgrounded(since: &backgroundPaceMark)
                let hr = bundle.hr
                // Descriptive shadows have their own evidence thresholds (30 in-sleep samples for the
                // primary-session mean, 10 pre-sleep samples for optional feedback). Evaluate persisted or
                // user-corrected sleep bounds before the legacy 200-row scoring gate so sparse but sufficient
                // observations are not silently discarded. Fresh detector output is unavailable until the
                // scoring pass below, so this early path intentionally uses authoritative stored bounds only.
                let storedShadowSessions = Self.authoritativeShadowSleepSessions(
                    detected: [],
                    persisted: dayPersistedShadowSessions,
                    edits: dayEditedRows
                )
                let storedPrimarySessionRHR = AnalyticsEngine.primarySessionRestingHRWithCoverage(
                    sessions: storedShadowSessions,
                    hr: hr
                )
                let storedPreSleepObservation = preSleepFeedbackEnabled
                    ? PreSleepHeartRateFeedback.evaluate(
                        enabled: true,
                        sessions: storedShadowSessions,
                        hr: hr,
                        history: [],
                        journalEntries: [],
                        day: day,
                        dayWindow: dayInterval,
                        habitualMidsleepSec: habitualMidsleepSec,
                        timeZoneOffsetSeconds: dayOffset
                    ).observation
                    : nil
                guard hr.count >= 200 else {
                    // Keep this lightweight diagnostic in the detached result. `diagnosticSink` is
                    // MainActor-bound, so calling it here would violate the engine's actor boundary.
                    let scan = DayScan(
                        day: day,
                        result: nil,
                        rhrLine: nil,
                        readOwner: owner,
                        hrRows: hr.count,
                        sleepTrace: [],
                        stepsTrace: [],
                        hrvTrace: [],
                        hrvDiag: nil,
                        skinTempTrace: nil,
                        skippedLine: "sleep day=\(day) SKIPPED hrSamples=\(hr.count) (need ≥200)",
                        primarySessionRHR: storedPrimarySessionRHR,
                        preSleepObservation: storedPreSleepObservation
                    )
                    try CooperativeAnalysisCancellation.checkpoint()
                    out.append(scan)
                    if let dayCacheKey { nextCache[day] = CachedDayScan(key: dayCacheKey, scan: scan) }
                    continue
                }   // need real raw data, not a stray sample
                let rr = bundle.rr
                let resp = bundle.resp
                let grav = bundle.gravity
                let steps = bundle.steps
                let skin = bundle.skinTemp
                // #93: WHOOP 4.0 raw SpO2 PPG samples for the night; analyzeDay banks the nightly red/IR ADC
                // means on the DailyMetric. Empty on a 5/MG (no v24 spo2 channels) → the raw means stay nil.
                let spo2 = bundle.spo2
                // Wrist-wear events in the night window, paired into off-wrist [start, end) intervals for the
                // off-wrist sleep backstop (#500). The HR-gap proxy in the stager is the always-on guard;
                // these explicit intervals sharpen it under the FRACTIONAL rule (#504) , a session is dropped
                // only when its off-wrist coverage reaches maxOffWristSleepFraction, so a real night with a
                // short off-wrist tail survives. Pairing needs WRIST_ON too (to bound each interval); a span
                // still open at the window end closes at `to`. Empty when the strap emitted no wrist events.
                let wristEvents = bundle.events
                let wristOff = AnalyticsEngine.offWristIntervals(events: wristEvents, windowEnd: to)

                // Calendar-day window for the ADDITIVE daily totals (steps + calories). The civil-day
                // enumerator owns both bounds, so spring-forward and fall-back days use their real local
                // duration instead of a fixed-offset approximation. The store range is inclusive, so end
                // at one second before the next civil-day start. (#277, local-day bucketing.)
                let dayMid = civilDay.start
                let dayEnd = civilDay.nextStart - 1
                // Same `owner` as the night window above (I2): the additive day totals must come from the
                // one device that owns the day, never a mix.
                // #997 (ryanbr): for a PAST day (20 of 21 in the default scan) the night window above reads
                // through to nextMidnight, so the calendar day [dayMid, dayEnd] is a strict subset of the
                // hr/steps/grav lists already in memory — derive the day streams by filtering them
                // (AnalyticsEngine.daySliceFromNight) instead of a second store read (~60 redundant reads
                // per pass, incl. the big HR ones). TODAY (its day runs past the 18 h night cap) and a
                // night read that hit the 200_000 limit DECLINE (nil) and read directly, so the shortcut
                // can only ever skip work, never change data. Byte-identical: same owner, same inclusive
                // bounds, same ts-ASC order as the direct read. (`??` can't take an `await` right-hand
                // side, hence the explicit if/else at each site.)
                let dayHr: [HRSample]
                if let slice = AnalyticsEngine.daySliceFromNight(hr, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayHr = slice
                } else {
                    dayHr = try await store.hrSamples(
                        deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)
                }
                let daySteps: [StepSample]
                if let slice = AnalyticsEngine.daySliceFromNight(steps, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    daySteps = slice
                } else {
                    daySteps = try await store.stepSamples(
                        deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)
                }
                // Full calendar-day gravity for WORKOUT detection. The night window above ends at
                // dayStart+12h (≈ noon), so an afternoon/evening workout sits outside it and was only
                // detected once a later pass re-read it through the next night window , a ~day lag. This
                // [localMidnight, localMidnight+24h) read (today: clamped to `now` by the store) lets the
                // detector see the whole day, so a 5 pm run shows up on the same day.
                let dayGrav: [GravitySample]
                if let slice = AnalyticsEngine.daySliceFromNight(grav, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayGrav = slice
                } else {
                    dayGrav = try await store.gravitySamples(
                        deviceId: owner, from: dayMid, to: dayEnd, limit: 200_000)
                }

                // CONSUME (#531 / #175): the strap's OWN band sleep_state for the night window as timestamped
                // (ts, state) samples, so the H7 morning-stillness guard can confirm a borderline re-onset
                // against the strap's OWN scored band, AND analyzeDay can grid it per session for persistence.
                // #175 wired the RAW `sleepStateSample` stream end to end: read it directly from `owner` (the
                // strap that owns this night) so it is available THIS pass, not one pass behind, and it comes
                // from the real offload rather than a read-its-own-write of the per-session JSON. Empty on a
                // WHOOP 4.0 (no band_sleep_state stream) or an unbanded window → the guard falls back to the HR
                // bar and no per-session state is persisted. Honest: only real banded epochs are ever surfaced.
                // Fall back to the prior pass's persisted per-session state when the raw stream is absent (an
                // older DB banded before the v21 stream landed), so a legacy install keeps the H7 confirm.
                var bandSleepState = bundle.sleepState.map { (ts: $0.ts, state: $0.state) }
                if bandSleepState.isEmpty {
                    bandSleepState = await Self.bandSleepStateSamples(computedId: computedId,
                                                                     from: from, to: to, store: store)
                }

                // Already OFF the main actor , score directly (the prior nested `Task.detached` here only
                // existed to hop off the main actor; the whole loop now runs off it, so the score is computed
                // inline with the identical inputs and identical result).
                // Sleep & Rest test mode (E5): a per-day collector for the gate trace + Rest sub-score line,
                // built ONLY when the mode is active. nil otherwise = analyzeDay's byte-identical default path.
                var sleepTrace: [String] = []
                let traceSink: ((String) -> Void)? = sleepTraceActive ? { sleepTrace.append($0) } : nil
                // HRV mode (#141): a per-day collector for the nightly per-window RMSSD + summary; nil = default.
                var hrvTrace: [String] = []
                let hrvTraceSink: ((String) -> Void)? = hrvTraceActive ? { hrvTrace.append($0) } : nil
                let cycleEnd: AnalyticsEngine.CycleEnd?
                if let nextCycleBoundary {
                    if let cycleTail {
                        try CooperativeAnalysisCancellation.checkpoint()
                        let tailHr = try await store.hrSamples(
                            deviceId: owner, from: cycleTail.lowerBound, to: cycleTail.upperBound, limit: 200_000)
                        let tailSteps = try await store.stepSamples(
                            deviceId: owner, from: cycleTail.lowerBound, to: cycleTail.upperBound, limit: 200_000)
                        cycleEnd = .init(end: nextCycleBoundary, tailHr: tailHr, tailSteps: tailSteps)
                    } else {
                        cycleEnd = .init(end: nextCycleBoundary)
                    }
                } else {
                    cycleEnd = nil
                }
                try await RescoreBackgroundPolicy.paceIfBackgrounded(since: &backgroundPaceMark)
                let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp, gravity: grav,
                                                     steps: steps, dayHr: dayHr, daySteps: daySteps,
                                                     dayGravity: dayGrav,
                                                     skinTemp: skin,
                                                     skinTempFamily: skinFamily,   // #938
                                                     skinTempAnchorRaw: skinAnchorRaw,   // #938 second capture
                                                     spo2: spo2,                   // #93
                                                     profile: up, baselines: baselines1, maxHROverride: maxHR,
                                                     tzOffsetSeconds: dayOffset,
                                                     dayInterval: dayInterval,   // AN-02
                                                     cycleEnd: cycleEnd,         // AN-05
                                                     nowTs: now,                 // D3b: today fills to now
                                                     wristOff: wristOff,
                                                     sleepNeedHours: sleepNeedHours,
                                                     sleepConsistency: sleepConsistency,
                                                     habitualMidsleepSec: habitualMidsleepSec,
                                                     bandSleepState: bandSleepState,
                                                     // #690: thread the V2 toggle into the NORMAL staging path so
                                                     // it affects detected nights, not just the self-heal restage.
                                                     useSleepStagerV2: useSleepStagerV2,
                                                     // #364 follow-up: same threading for the motion-aware wake
                                                     // refinement post-pass.
                                                     useMotionAwareWake: useMotionAwareWake,
                                                     traceSink: traceSink,
                                                     hrvTraceSink: hrvTraceSink,
                                                     // Per-window HRV detail ONLY for the most-recent night
                                                     // (dayStart == today's local midnight), so the 5000-line
                                                     // ring buffer isn't flooded; every night keeps the summary.
                                                     hrvWindowDetail: dayStart == currentCivilDayStart,
                                                     deepHrvWindow: deepHrvWindow)
                try await RescoreBackgroundPolicy.paceIfBackgrounded(since: &backgroundPaceMark)
                // #195: whole-night HRV cleaning-pipeline summary for the always-on strap log, so a "reads ~2x
                // too high" report is triageable without the HRV test mode: RMSSD vs SDNN (rmssd >> sdnn =
                // beat-to-beat jitter surviving the ectopic filter, not real HRV), meanNN as an HR sanity-check,
                // and how many R-R intervals survived cleaning (a low count also flags the sparse-capture /
                // calibration side — `nInput` is set before the min-beats gate, so a sparse night still shows
                // its count with rmssd=nil). A SEPARATE analyzer pass over the in-sleep R-R — does NOT touch the
                // shipped windowed avgHrv. Built here (loop 1) where `rr` is in scope, but EMITTED in the
                // main-actor replay loop below (diagnosticSink is main-actor isolated), carried on `hrvDiag`.
                // Byte-identical to the Kotlin line.
                let sleepRrRows = rr.filter { r in res.cachedSleep.contains { r.ts >= $0.startTs && r.ts < $0.endTs } }
                let sleepRr = sleepRrRows.map { Double($0.rrMs) }
                let hrvDiag: String?
                if sleepRr.isEmpty {
                    hrvDiag = nil
                } else {
                    let h = HRVAnalyzer.analyze(rawRR: sleepRr)
                    func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "nil" }
                    let rej = h.nInput > 0 ? String(format: "%.0f", 100 * (1 - Double(h.nClean) / Double(h.nInput))) : "0"
                    // #257: coverage (sum of NN ÷ wall-clock span; > 1.0 is impossible without double-counted
                    // R-R) + exact-duplicate beat count, so a "reads ~2x too high" report is self-diagnosing
                    // from the always-on log instead of hand-computing beat density.
                    let ts = sleepRrRows.map { $0.ts }
                    let cov = String(format: "%.2f", HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: sleepRr))
                    let dup = HRVAnalyzer.duplicateBeatCount(tsSec: ts, rrMs: sleepRr)
                    hrvDiag = "hrv diag day=\(res.daily.day) rmssd=\(ms(h.rmssd))ms sdnn=\(ms(h.sdnn))ms "
                        + "meanNN=\(ms(h.meanNN))ms rr=\(h.nInput)/\(h.nClean) rejected=\(rej)% coverage=\(cov) dupBeats=\(dup)"
                }
                let skinTempTrace = SkinTemperatureTrace(
                    stage: .analysis,
                    source: .wearable,
                    family: String(describing: skinFamily),
                    day: day,
                    queryFrom: from,
                    queryTo: to,
                    sampleCount: skin.count,
                    firstTimestamp: skin.first?.ts,
                    lastTimestamp: skin.last?.ts,
                    persistenceOutcome: nil,
                    insertedCount: nil,
                    conversionCount: res.skinTempDiagnostic?.kept,
                    isAvailable: res.nightlySkinTempC != nil
                ).line
                // ── Steps test mode: 5/MG raw-counter trace ──────────────────────────────────────────────
                // Only built when the Steps mode is on (the gate was read once before the loop). Recomputes
                // the SAME wrap-aware @57 sum analyzeDay just ran, over the SAME `daySteps` calendar-day
                // stream, so the reported scaledSteps equals the day's steps_est, so the trace cannot diverge.
                // Pure inputs, carried out so the main actor replays it tagged `.steps` in per-day order.
                var stepsTrace: [String] = []
                // #807 — only a counter strap (WHOOP 5/MG) banks step samples; a WHOOP 4.0 has none, so
                // without the daySteps guard the trace spams "counterSamples=0 (need >=2 for a delta)" every
                // day and buries the motion-volume calibration trace that actually explains a 4.0's steps.
                // Mirrors the Android IntelligenceEngine guard (stepsTraceSink != null && daySteps.isNotEmpty()).
                if stepsTraceActive && !daySteps.isEmpty {
                    stepsTrace = StepsEstimateEngine.rawCounterTrace(
                        daySteps: daySteps, dayKey: day, tzOffsetSeconds: dayOffset,
                        dayInterval: dayInterval,
                        ticksPerStep: up.stepTicksPerStep)
                }
                // ── RHR floor-vs-mean diagnostic (#691) ────────────────────────────────────────────────
                // Make the recurring "NOOP's resting HR reads LOWER than my sleeping-HR app" reports
                // explainable from the strap log instead of a guess. The two numbers measure different
                // things BY DESIGN, not a bug: NOOP's `restingHr` is the WHOOP-style FLOOR (the lowest
                // sustained 5-min in-bed level , SleepStager picks the min 5-min rolling-mean HR per session,
                // and the day takes the .min() across them), whereas a "sleeping HR" app reports the night
                // MEAN over the whole asleep span. The mean always sits above the floor, so NOOP looking
                // lower is correct. Log BOTH so a report ships proof of the gap. Mean is computed over the
                // SAME matched in-bed span the floor came from (so they're directly comparable); a night
                // with no banked floor (no matched sleep) logs nil and the line is skipped. Logging only ,
                // no scoring change. Counts/bpm only; no timestamps or PII (LiveState.append also scrubs).
                // Computed here (pure inputs) and carried out so the main actor can replay it through
                // `diagnosticSink` in the SAME per-day order , the sink is a MainActor-bound closure.
                var rhrLine: String?
                if let floor = res.daily.restingHr {
                    let inBedBpms = hr.filter { s in
                        res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
                    }.map { $0.bpm }
                    rhrLine = Self.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms)
                }
                // Stored/imported bounds are authoritative for a covered wake day, matching the Sleep UI.
                // Detector output fills only days that have no persisted sleep instead of creating a second,
                // slightly shifted copy of the same night.
                let effectiveShadowSessions = Self.authoritativeShadowSleepSessions(
                    detected: res.cachedSleep,
                    persisted: dayPersistedShadowSessions,
                    edits: dayEditedRows
                )
                let primarySessionRHR = AnalyticsEngine.primarySessionRestingHRWithCoverage(
                    sessions: effectiveShadowSessions,
                    hr: hr
                )
                let preSleepObservation = preSleepFeedbackEnabled
                    ? PreSleepHeartRateFeedback.evaluate(
                        enabled: true,
                        sessions: effectiveShadowSessions,
                        hr: hr,
                        history: [],
                        journalEntries: [],
                        day: day,
                        dayWindow: dayInterval,
                        habitualMidsleepSec: habitualMidsleepSec,
                        timeZoneOffsetSeconds: dayOffset
                    ).observation
                    : nil
                let scan = DayScan(day: day, result: res, rhrLine: rhrLine,
                                   readOwner: owner, hrRows: hr.count,
                                   sleepTrace: sleepTrace, stepsTrace: stepsTrace, hrvTrace: hrvTrace,
                                   hrvDiag: hrvDiag, skinTempTrace: skinTempTrace, skippedLine: nil,
                                   primarySessionRHR: primarySessionRHR,
                                   preSleepObservation: preSleepObservation)
                try CooperativeAnalysisCancellation.checkpoint()
                out.append(scan)
                if let dayCacheKey { nextCache[day] = CachedDayScan(key: dayCacheKey, scan: scan) }
            }
                if let lookaheadCivilDay {
                    out.removeAll { $0.day == lookaheadCivilDay.day }
                    nextCache[lookaheadCivilDay.day] = nil
                }
                return DayScanPass(scans: out, nextCache: nextCache,
                                   reused: cacheReused, eligible: cacheEligible)
            }
        } catch is CancellationError {
            performanceChangedRows = 0
            return false
        } catch {
            note = String(localized: "Recovery analysis is waiting for the local database.")
            NSLog("IntelligenceEngine: required day-source read failed: \(error)")
            return false
        }

        let scanned = scanPass.scans

        guard !Task.isCancelled else {
            performanceChangedRows = 0
            return false
        }

        // CAPTURE-B (#814/#799): per-day resolved READ owner + that owner's HR-row count, keyed by day, so
        // the second pass (which has the provenance sets) can emit the universal `dayOwner …` line. The
        // owner is the id this day was actually scored/read from; the registry active id is what the WRITE
        // side uses; when they DIVERGE on a day that has data, that's the #814 read/write split made
        // visible in every export.
        var readOwnerByDay: [String: (owner: String, hrRows: Int)] = [:]
        var primarySessionRHRByDay: [String: PrimarySessionRestingHR.Measurement] = [:]
        var preSleepObservationByDay: [String: PreSleepHeartRateFeedback.Observation] = [:]

        // Back on the main actor: fold the off-actor results into the pass-2 state in the SAME order the
        // loop produced them. Pure assignment / appends , no further store reads , so this is cheap and the
        // main actor was free during the heavy enumeration above.
        for scan in scanned {
            readOwnerByDay[scan.day] = (scan.readOwner, scan.hrRows)
            if let shadow = scan.primarySessionRHR {
                primarySessionRHRByDay[scan.day] = shadow
            }
            if let observation = scan.preSleepObservation {
                preSleepObservationByDay[scan.day] = observation
            }
            if let line = scan.skippedLine {
                diagnosticSink?(line, nil)
                continue
            }
            guard let res = scan.result else { continue }
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            if let anchor = res.skinTempDiagnostic?.resolvedAnchorRaw {
                whoop4SkinAnchorByDay[res.daily.day] = anchor
            }
            strapWornSecondsByDay[res.daily.day] = res.strapWornSeconds
            if let line = scan.rhrLine { diagnosticSink?(line, nil) }
            if let line = scan.skinTempTrace { diagnosticSink?(line, nil) }
            // Sleep & Rest test mode (E5): replay this day's gate-trace + Rest lines tagged `.sleep` so they
            // land under the profile tag in the export. Empty unless the mode is active.
            for line in scan.sleepTrace { diagnosticSink?(line, .sleep) }
            // HRV test mode (#141): replay this day's nightly per-window RMSSD + summary tagged `.hrv`.
            // Empty unless the HRV mode is active, so the default path emits zero `.hrv` lines here.
            for line in scan.hrvTrace { diagnosticSink?(line, .hrv) }
            // Steps test mode: replay this day's 5/MG raw-counter trace tagged `.steps`. Empty unless the
            // mode is active, so the default path emits zero `.steps` lines here.
            for line in scan.stepsTrace { diagnosticSink?(line, .steps) }
            scoredNights.append((daily: res.daily, strain: res.strain,
                                 cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC,
                                 sessionMotion: res.sessionMotionByStart,
                                 sessionSleepState: res.sessionSleepStateByStart,
                                 hrvDiag: scan.hrvDiag))
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // THIS is the BLE-only recovery fix: the "-noop" nightly avgHrv/restingHr finally feed the
        // baseline so a strap-only user crosses Baselines.minNightsSeed and recovery lights up.
        // IMPORTED values win per day: write them first, then fill ONLY days the import doesn't cover
        // (Swift has no putIfAbsent , `dict[day] == nil` is true only when the KEY is absent, so a day
        // imported with a nil avgHrv stays imported, not overwritten by the computed value).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        Self.mergeNightlyIntoHistory(&histHrvByDay, nightlyHrvByDay)
        Self.mergeNightlyIntoHistory(&histRhrByDay, nightlyRhrByDay)
        Self.mergeNightlyIntoHistory(&histRespByDay, nightlyRespByDay)
        // AN-01: computed nights older than this pass's window feed the baseline too (they used to be
        // invisible to a strap-only user, whose baseline then held only the window). Lowest precedence:
        // imported values and this pass's fresh values win.
        let computedHist: [DailyMetric]
        let storedNightlySkin: [MetricPoint]
        var storedWhoop4SkinByIdentity: [String: (raw: [MetricPoint], anchor: [MetricPoint])] = [:]
        do {
            computedHist = try await store.dailyMetrics(
                deviceId: computedId, from: "0000-01-01", to: "9999-12-31")
            storedNightlySkin = try await store.metricSeries(
                deviceId: computedId, key: Self.nightlySkinMetricKey, from: "0000-01-01", to: "9999-12-31")
            for key in try await store.metricKeys(deviceId: computedId)
            where key.hasPrefix(Self.nightlySkinWhoop4RawKeyPrefix) {
                let identity = String(key.dropFirst(Self.nightlySkinWhoop4RawKeyPrefix.count))
                storedWhoop4SkinByIdentity[identity] = (
                    raw: try await store.metricSeries(
                        deviceId: computedId, key: key, from: "0000-01-01", to: "9999-12-31"),
                    anchor: try await store.metricSeries(
                        deviceId: computedId, key: Self.nightlySkinWhoop4AnchorKeyPrefix + identity,
                        from: "0000-01-01", to: "9999-12-31"))
            }
        } catch {
            note = String(localized: "Recovery analysis is waiting for the local database.")
            NSLog("IntelligenceEngine: required baseline read failed: \(error)")
            return false
        }
        // Cancellation checkpoint (a background grant ended or the app came back to the foreground): nothing has
        // been persisted yet, and every read below is whole-history work that should not outlive the grant.
        guard !Task.isCancelled else { performanceChangedRows = 0; return false }
        // N2-UPG-2: the wearable fold below writes Oura / Fitbit / Garmin / Health Connect rows under the
        // computed id on days the strap did not score, and those rows carry that device's HRV and resting HR,
        // not the strap's, so they stay out of the strap baseline (#459 device-scale mix). Read once; the
        // fold reuses the rows.
        var wearableRowsBySource: [String: [DailyMetric]] = [:]
        for source in Repository.wearableImportSources {
            do {
                // DL-04: the fold's baseline reads the source's whole history up to the window's end.
                wearableRowsBySource[source] = try await store.dailyMetrics(
                    deviceId: source, from: "0000-01-01", to: newestCivilDay.day).sorted { $0.day < $1.day }
            } catch {
                note = String(localized: "Recovery analysis is waiting for imported wearable data.")
                NSLog("IntelligenceEngine: required wearable source read failed (\(source)): \(error)")
                return false
            }
        }
        guard !Task.isCancelled else { performanceChangedRows = 0; return false }
        // Review round 4 (4): only the rows the fold wrote are left out, by the marker each pass persists beside
        // its rows. A row from before the marker is classified once and the result persisted: on a day a
        // wearable import with vitals covers, it is a strap night if the raw loop would have scored the day (its
        // resolved owner has the loop's 200 heart-rate rows over the loop's window, review round 5, 5), and
        // otherwise the fold's copy. The fold never writes on a day the strap scored.
        var rowSourceByDay: [String: Double]
        do {
            let marked = try await store.metricSeries(
                deviceId: computedId, key: Self.computedRowSourceMetricKey, from: "0000-01-01", to: "9999-12-31")
            rowSourceByDay = Dictionary(marked.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
            let importVitalsDays = Set(wearableRowsBySource.values.joined().compactMap { row in
                row.avgHrv != nil || row.restingHr != nil || row.respRateBpm != nil ? row.day : nil
            })
            var legacyPoints: [MetricPoint] = []
            for row in computedHist where rowSourceByDay[row.day] == nil && importVitalsDays.contains(row.day) {
                guard let dayStart = Self.civilDayStart(row.day, calendar: analysisCalendar),
                      let nextStart = analysisCalendar.date(
                        byAdding: .day, value: 1, to: Date(timeIntervalSince1970: TimeInterval(dayStart)))
                else { continue }
                let from = dayStart - 30 * 3_600
                let to = min(Int(nextStart.timeIntervalSince1970), now)
                // Review round 6 (1): the owner a production pass resolves, in an exact pass too. The
                // classification covers the whole history and is stored for good; sourceContext is this pass's.
                // Review round 7 (3): that holds in the canonical computed namespace, which holds every device's
                // days. A source-rooted engine's namespace holds its source's days only, so the source owns them.
                let owner: String
                if deviceId == Repository.whoopSource {
                    let window = CivilDayWindow(day: row.day, start: dayStart,
                                                nextStart: Int(nextStart.timeIntervalSince1970))
                    owner = await Self.resolveDayOwner(day: row.day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId,
                                                       completedDay: window.nextStart <= now ? window : nil)
                } else {
                    owner = sourceContext?.deviceId ?? deviceId
                }
                let rows = try await store.hrSamples(
                    deviceId: owner, from: from, to: to, limit: Self.legacyStrapNightMinHrRows)
                let source = rows.count >= Self.legacyStrapNightMinHrRows
                    ? Self.strapRowSource : Self.wearableFoldRowSource
                rowSourceByDay[row.day] = source
                legacyPoints.append(MetricPoint(day: row.day, key: Self.computedRowSourceMetricKey, value: source))
            }
            if !legacyPoints.isEmpty {
                _ = try await store.upsertMetricSeries(legacyPoints, deviceId: computedId)
            }
        } catch {
            note = String(localized: "Recovery analysis is waiting for the local database.")
            NSLog("IntelligenceEngine: computed row provenance read failed: \(error)")
            return false
        }
        let strapComputedHist = computedHist.filter { rowSourceByDay[$0.day] != Self.wearableFoldRowSource }
        Self.mergeNightlyIntoHistory(
            &histHrvByDay,
            Dictionary(strapComputedHist.map { ($0.day, $0.avgHrv) }, uniquingKeysWith: { a, _ in a }))
        Self.mergeNightlyIntoHistory(
            &histRhrByDay,
            Dictionary(strapComputedHist.map { ($0.day, $0.restingHr.map(Double.init)) },
                       uniquingKeysWith: { a, _ in a }))
        Self.mergeNightlyIntoHistory(
            &histRespByDay,
            Dictionary(strapComputedHist.map { ($0.day, $0.respRateBpm) }, uniquingKeysWith: { a, _ in a }))
        // F2: a completed day whose skin baseline can't be built here keeps its stored deviation.
        let storedComputedByDay = Dictionary(computedHist.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        // rhr/resp/skin honour the Charge-wide recalibration epoch (noop.recoveryBaselineEpoch); 0 = no-op,
        // so this is byte-identical to the plain fold until the user taps Recalibrate, at which point the
        // whole Charge build-up (HRV + resting HR + resp + skin) re-anchors together.
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()
        let hrvDayKeys = histHrvByDay.keys.sorted()                         // chronological "yyyy-MM-dd"
        let hrvSeq = hrvDayKeys.map { histHrvByDay[$0]! }                   // chronological [Double?]
        let rhrDayKeys = histRhrByDay.keys.sorted()
        let rhrSeq = rhrDayKeys.map { histRhrByDay[$0]! }
        let respDayKeys = histRespByDay.keys.sorted()
        let respSeq = respDayKeys.map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean), so it
        // folds the nightly means: this pass's, then the ones earlier passes persisted (F2: a window-only fold
        // left the oldest days of every pass without a usable baseline and wiped their stored deviation).
        // Review round 4 (1): persisted WHOOP 4.0 nights are raw register values per strap, each strap's converted
        // with its own anchor: the one this pass converted that strap's fresh nights with, else the newest
        // anchor stored for it. Review round 5 (4): a strap is its physical identity, the registry owner plus the
        // BLE peripheral it had adopted when the night was first stored, so a replacement strap that takes over
        // the same registry id gets its own anchor. A rescored night keeps the identity it was stored under, and
        // a night of an earlier identity is converted with that identity's stored anchor, here and when scored.
        // Limit: samples carry no physical identity, so a pass whose anchor window spans a same-id swap learns
        // one anchor from both straps' samples, and the first nights after the swap can read up to half the
        // register offset between them.
        let whoop4IdentityByDay = storedWhoop4SkinByIdentity.keys.sorted().reduce(into: [String: String]()) {
            result, identity in
            for point in storedWhoop4SkinByIdentity[identity]?.raw ?? [] where result[point.day] == nil {
                result[point.day] = identity
            }
        }
        func currentWhoop4Identity(_ owner: String) -> String {
            Self.whoop4SkinIdentity(owner: owner, peripheralId: regDevices.first { $0.id == owner }?.peripheralId)
        }
        func whoop4Identity(day: String, owner: String) -> String {
            if let kept = whoop4IdentityByDay[day], Self.whoop4SkinOwner(identity: kept) == owner { return kept }
            return currentWhoop4Identity(owner)
        }
        var passWhoop4AnchorByOwner: [String: Double] = [:]
        for (day, anchor) in whoop4SkinAnchorByDay.sorted(by: { $0.key < $1.key }) {
            guard let owner = readOwnerByDay[day]?.owner else { continue }
            let identity = whoop4Identity(day: day, owner: owner)
            if identity == currentWhoop4Identity(owner) {
                passWhoop4AnchorByOwner[owner] = anchor
            } else if let kept = storedWhoop4SkinByIdentity[identity]?.anchor.last?.value,
                      let celsius = nightlySkinByDay[day] ?? nil {
                let converted = Self.whoop4SkinCelsius(
                    raw: Self.whoop4SkinRaw(celsius: celsius, anchorRaw: anchor), anchorRaw: kept)
                nightlySkinByDay[day] = converted
                whoop4SkinAnchorByDay[day] = kept
                if let index = scoredNights.firstIndex(where: { $0.daily.day == day }) {
                    scoredNights[index].nightlySkin = converted
                }
            }
        }
        var histSkinByDay = nightlySkinByDay
        for (identity, stored) in storedWhoop4SkinByIdentity {
            let owner = Self.whoop4SkinOwner(identity: identity)
            let passAnchor = identity == currentWhoop4Identity(owner) ? passWhoop4AnchorByOwner[owner] : nil
            guard let anchor = passAnchor ?? stored.anchor.last?.value else { continue }
            Self.mergeNightlyIntoHistory(
                &histSkinByDay,
                Dictionary(stored.raw.map {
                    ($0.day, Optional(Self.whoop4SkinCelsius(raw: $0.value, anchorRaw: anchor)))
                }, uniquingKeysWith: { a, _ in a }))
        }
        Self.mergeNightlyIntoHistory(
            &histSkinByDay,
            Dictionary(storedNightlySkin.map { ($0.day, Optional($0.value)) }, uniquingKeysWith: { a, _ in a }))
        let skinDayKeys = histSkinByDay.keys.sorted()
        let skinSeq = skinDayKeys.map { histSkinByDay[$0]! }
        // Review round 3 (F): whether the skin fold holds any night from before this pass's window.
        let skinHistoryReachesBeforeWindow = histSkinByDay.contains { $0.key < oldestCivilDay.day && $0.value != nil }
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a
        // baseline object is present , a CALIBRATING (<4-night) baseline would let one noisy
        // RSA night move recovery (mirrors the skin-temp use-site gate; honest cold-start).
        // Skin-temp gated the same way for consistency: its only use-site re-checks `.usable`
        // (AnalyticsEngine's skinTempDevC guard) so this is belt-and-suspenders, but it stops a
        // future use-site from trusting a CALIBRATING baseline. (PR #97 review.)
        // AN-01: one fold per metric keeps every intermediate state, and each day is scored against the
        // state as of the night before it, so a past day's Charge no longer moves when later nights
        // arrive and today's own night no longer damps its z-score.
        // HRV honours noop.hrvBaselineEpoch; rhr/resp/skin honour noop.recoveryBaselineEpoch via their
        // parallel day keys, so the manual Recalibrate restarts the whole Charge build-up together.
        let hrvTimeline = Baselines.foldHistoryAsOf(hrvSeq, dayKeys: hrvDayKeys, cfg: hrvCfg)
        let rhrTimeline = Baselines.foldHistoryAsOf(rhrSeq, dayKeys: rhrDayKeys, cfg: rhrCfg,
                                                    baselineEpoch: recoveryEpoch)
        let respTimeline = Baselines.foldHistoryAsOf(respSeq, dayKeys: respDayKeys, cfg: respCfg,
                                                     baselineEpoch: recoveryEpoch)
        let skinTimeline = Baselines.foldHistoryAsOf(skinSeq, dayKeys: skinDayKeys, cfg: skinCfg,
                                                     baselineEpoch: recoveryEpoch)
        func baselines(asOf day: String) -> AnalyticsEngine.ProfileBaselines {
            let resp = respTimeline.asOf(day)
            let skin = skinTimeline.asOf(day)
            return AnalyticsEngine.ProfileBaselines(
                hrv: hrvTimeline.asOf(day),
                restingHR: rhrTimeline.asOf(day),
                resp: resp.usable ? resp : nil,
                skinTemp: skin.usable ? skin : nil)
        }

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day merge precedence does not cover the workout table). This covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both written under `deviceId`), and apple-health carries Health imports ,
        // a detected bout overlapping ANY of them is skipped below. Port of the Android dedup block.
        // (`computedId` is bound once above, before the off-actor scan loop.)
        let realWorkoutDeviceIds = deviceId == "apple-health" ? [deviceId] : [deviceId, "apple-health"]
        var realWorkouts: [OwnedWorkout] = []
        for realWorkoutDeviceId in realWorkoutDeviceIds {
            let rows = (try? await store.workouts(deviceId: realWorkoutDeviceId, from: windowStart,
                                                   to: windowEnd, limit: 100_000)) ?? []
            realWorkouts += rows.map { OwnedWorkout(row: $0, deviceId: realWorkoutDeviceId) }
        }

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent);
        // every other field was computed once in pass 1. Recovery stays nil until the HRV baseline is
        // usable (≥ minNightsSeed valid nights) , honest cold-start, via RecoveryScorer's usable gate.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var workoutRows: [WorkoutRow] = []
        // Rest composite (0–100) per computed night, persisted as the `sleep_performance` metric
        // series so the dashboard's Rest score reflects the new composite, not raw efficiency.
        var restPoints: [MetricPoint] = []
        // Validation/display-only derived values have complete-set reconciliation below. Keeping them
        // separate from Rest prevents a missing raw window from leaving a stale shadow row behind.
        var shadowPoints: [MetricPoint] = []
        for day in primarySessionRHRByDay.keys.sorted() {
            guard let shadow = primarySessionRHRByDay[day] else { continue }
            shadowPoints.append(MetricPoint(
                day: day,
                key: PrimarySessionRestingHR.meanMetricKey,
                value: shadow.meanHR
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PrimarySessionRestingHR.validSamplesMetricKey,
                value: Double(shadow.coverage.validSamples)
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PrimarySessionRestingHR.durationMetricKey,
                value: shadow.coverage.durationSec
            ))
        }
        for day in preSleepObservationByDay.keys.sorted() {
            guard let observation = preSleepObservationByDay[day] else { continue }
            shadowPoints.append(MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.meanMetricKey,
                value: observation.meanBpm
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.validSamplesMetricKey,
                value: Double(observation.validSamples)
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.totalSamplesMetricKey,
                value: Double(observation.totalTimestampSamples)
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.primarySleepStartMetricKey,
                value: Double(observation.primarySleepStartTs)
            ))
            shadowPoints.append(MetricPoint(
                day: day,
                key: PreSleepHeartRateFeedback.primarySleepEndMetricKey,
                value: Double(observation.primarySleepEndTs)
            ))
        }
        // User-corrected sleep windows override the detected sleep when scoring a day's sleep aggregates,
        // so Rest + recovery honor the edit , not just the Sleep tab's session view. An edited block
        // substitutes its detected twin (matched by the stable detected startTs) before totals recompute.
        // Scope (#318): this only covers the COMPUTED ("-noop") source , the days noop scores itself. An
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here (we don't
        // reproduce WHOOP's cloud scoring). That's an accepted limitation, documented on the PR.
        // Self-heal any night edited before its raw streams synced (see `Repository.selfHealEditedStages`):
        // re-derive stages from the now-available raw over the night's locked bounds, then return the
        // refreshed rows so the daily aggregate below scores the corrected breakdown. A no-op for nights
        // already staged from raw (idempotent) and for imported nights (raw never dense). This MUST run
        // before the scoring loop so the healed stages flow into Rest/recovery this same pass.
        // #299: `editsByStart` is now built PER DAY inside the scoring loop (scoped to the day each edit
        // belongs to), NOT window-wide here. sleepEditedDaily folds any edited row that isn't a twin of THIS
        // day's detected sessions in as a "manual" block, so a window-wide edit set let ONE user edit /
        // hand-logged nap substitute its total onto EVERY night in the window (incl. no-sleep nights) —
        // pinning totalSleepMin to a constant. See the loop below.

        // Provenance sets for the honest By-Day badge + the per-day diagnostic source token. `hist` is the
        // imported daily rows under `deviceId` (the WHOLE imported history, read above for the baseline) ,
        // a non-nil row means a WHOOP export covers that day and WINS the dashboard merge over our computed
        // row (Repository.mergeDaily: imports win field-by-field). Apple-Health daily rows are the same for
        // the Apple brand. Both are key-presence sets only (no values leave), so the lookup is O(1) per day
        // and nothing about the imported numbers is exposed. WHOOP wins over Apple, matching the merge's
        // source priority (whoopImport 0 < appleHealth 2 in DailyMetricSource.vitalPriority).
        let importedWhoopDays = Set(hist.map { $0.day })
        // The WHOLE apple-health daily history, chronological. Used both as a key-presence set for the
        // By-Day badge AND as the SDNN+RHR input for the Apple-Watch recovery fold below (a watch-only user
        // has these daily aggregates but no raw stream, so the raw-HR scoring loop never touched them).
        guard !Task.isCancelled else { return false }
        let appleRows: [DailyMetric]
        do {
            appleRows = try await store.dailyMetrics(
                deviceId: Repository.appleHealthSource,
                from: "0000-01-01", to: "9999-12-31").sorted { $0.day < $1.day }
        } catch {
            note = String(localized: "Recovery analysis is waiting for Apple Health data.")
            NSLog("IntelligenceEngine: required Apple Health read failed: \(error)")
            return false
        }
        let appleHealthDays = Set(appleRows.map { $0.day })

        // Recovery (Charge) test mode (Group G): read the zero-cost gate ONCE here (a single Bool) before
        // the scoring loop. When false (the default), no Charge term-breakdown trace is built and the score
        // path is byte-identical. When true, each scored night emits its Charge breakdown tagged `.recovery`
        // via `recoveryTrace`, which returns the SAME score `recomputeRecovery` computes (it reuses
        // RecoveryScorer.recovery verbatim), so the headline Charge number is unaffected.
        let recoveryTraceActive = TestCentre.active(.recovery)
        // CAPTURE-B (#814/#799): the universal dayOwner line rides every export, so its gate is "ANY mode
        // active" (TestCentre.active(.universal) == anyActive). Read once here, like the other gates.
        let universalTraceActive = TestCentre.active(.universal)
        // Workouts & GPS test mode (#975): read the zero-cost gate ONCE before the scoring loop so the
        // detected-bout persist/drop decision can emit ONE `.workouts` line per derived bout. Without this
        // the auto path produced NO trace at all (the "mode was on but produced NO trace" report), so an
        // "auto workout appeared then vanished" could not be explained from an export. Diagnostic only.
        let workoutsTraceActive = TestCentre.active(.workouts)
        let sleepV2Mode = SleepPerformanceV2Prefs.mode
        var finalDailyByDay: [String: DailyMetric] = [:]
        var summaries: [SleepNightSummary] = []
        if sleepV2Mode != .off {
            for night in scoredNights {
                let nightWindow = civilDayByKey[night.daily.day].map { $0.start..<$0.nextStart }
                let nightOffset = clockOffsetByDay[night.daily.day] ?? tzOffset
                let rows = Self.editedRowsForOwnerDay(
                    editedRows,
                    rowsSourceId: editedRowsSourceId,
                    owner: readOwnerByDay[night.daily.day]?.owner,
                    dayWindow: nightWindow
                )
                let edits = Dictionary(rows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
                let final = sleepEditedDaily(night.daily, detected: night.cachedSleep, editsByStart: edits,
                                             habitualMidsleepSec: habitualMidsleepSec,
                                             tzOffsetSeconds: nightOffset)
                finalDailyByDay[final.day] = final
                let effective = Self.effectiveSleepSessions(detected: night.cachedSleep, edits: rows)
                if let summary = SleepNightSummary.select(
                    from: effective, wakeDay: final.day, totalSleepMinutes: final.totalSleepMin,
                    efficiency: final.efficiency, offsetSeconds: nightOffset,
                    habitualMidsleepSec: habitualMidsleepSec) {
                    summaries.append(summary)
                }
            }
        }
        let scoredSleepV2 = Dictionary(uniqueKeysWithValues: SleepScoringContextBuilder.replay(
            summaries: summaries,
            efforts: scoredNights.compactMap { n in n.strain.map {
                SleepScoringContextBuilder.DailyEffort(day: n.daily.day, value: $0)
            }}).map { ($0.day, $0) })
        var sleepV2Points: [MetricPoint] = []
        var recoveryPaceMark = DispatchTime.now().uptimeNanoseconds
        for night in scoredNights {
            do {
                try await RescoreBackgroundPolicy.paceIfBackgrounded(since: &recoveryPaceMark)
            } catch {
                performanceChangedRows = 0
                return false
            }
            // #299: scope the edits to THIS day before folding. A userEdited row / hand-logged nap belongs
            // to exactly ONE day — the day its night ENDS on, matching the daily's end-day bucket. `endTs`
            // is stable under a bedtime edit (only the onset/`startTsAdjusted` moves), so end-day is the
            // right key. Filtering here keeps a single-night edit overriding only its OWN night instead of
            // every night. `effectiveStartTs` (the #318 user-corrected onset) is preserved on the row.
            let dayEditedRows = Self.editedRowsForOwnerDay(
                editedRows,
                rowsSourceId: editedRowsSourceId,
                owner: readOwnerByDay[night.daily.day]?.owner,
                dayWindow: civilDayByKey[night.daily.day].map { $0.start..<$0.nextStart }
            )
            let editsByStart = Dictionary(dayEditedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
            let daily = finalDailyByDay[night.daily.day] ?? sleepEditedDaily(
                night.daily, detected: night.cachedSleep, editsByStart: editsByStart,
                habitualMidsleepSec: habitualMidsleepSec,
                tzOffsetSeconds: clockOffsetByDay[night.daily.day] ?? tzOffset)
            let legacySleepQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 }
                ?? daily.efficiency
            let v2 = scoredSleepV2[daily.day]
            let recoverySleepQuality = sleepV2Mode == .on ? v2?.performance?.recoveryInput : legacySleepQuality
            let dayBaselines = baselines(asOf: daily.day)
            let recovery = recomputeRecovery(daily, dayBaselines, sleepQuality: recoverySleepQuality)
            // Charge term-breakdown trace (Group G): only when the Recovery test mode is on. Emits which
            // term moved Charge and which was nil and forced the renorm, tagged `.recovery`. The trace's
            // score is RecoveryScorer.recovery verbatim, so the `recovery` written above is unchanged.
            if recoveryTraceActive {
                for line in recoveryTraceLines(daily, dayBaselines, sleepQuality: recoverySleepQuality) {
                    diagnosticSink?(line, .recovery)
                }
            }
            var skinDev = recomputeSkinTempDev(night.nightlySkin, dayBaselines.skinTemp)
            // F2: a completed day whose as-of skin baseline isn't usable here (its earlier nights predate the
            // persisted nightly means) keeps its stored deviation instead of losing it. Review round 3 (F): so
            // does every completed day while the skin fold starts inside this pass's window, as on an upgraded
            // device whose v3 chunks run newest first before any nightly mean is persisted. A chunk-local
            // baseline is no better than the one the stored value was scored against.
            if night.nightlySkin != nil, daily.day < currentCivilDay.day,
               let storedSkinDev = storedComputedByDay[daily.day]?.skinTempDevC,
               (skinDev == nil && dayBaselines.skinTemp == nil) || !skinHistoryReachesBeforeWindow {
                skinDev = storedSkinDev
            }
            let source = DaySource.classify(day: daily.day, importedWhoopDays: importedWhoopDays,
                                            appleHealthDays: appleHealthDays)
            // SHARED CONTRACT enrichment: the ordered Charge driver list + the relative skin-temp marker,
            // built from the SAME inputs `recomputeRecovery` reads so the rows can never disagree with the
            // headline. Both are empty/nil pre-baseline (cold-start), matching the score's own null-honesty.
            let drivers = recomputeChargeDrivers(daily, dayBaselines, sleepQuality: recoverySleepQuality)
            let skinRel = RecoveryScorer.skinTempRelative(deviationC: skinDev)
            // Honest per-day Charge confidence (A3): the strap night reads `.solid`/`.building`/`.calibrating`
            // off the HRV baseline state rather than a blanket `.solid`, so a thin/provisional baseline shows
            // EST. not REL. Pure presentation upstream of the UI; the score itself is unchanged.
            let chargeConf = ScoreConfidence.charge(recovery: recovery, hrvBaseline: dayBaselines.hrv)
            out.append(Computed(day: daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr, source: source, confidence: chargeConf,
                                drivers: drivers, skinTempRel: skinRel))
            // ── Per-day scoring diagnostic (Sleep overhaul §2.5) ─────────────────────────────────────
            // ONE concise, privacy-safe line per scored day into the shareable strap log: the day key, the
            // FINAL computed total-sleep minutes (after any edit substitution), how many sleep blocks the
            // detector matched on the day, and the provenance of the dashboard headline. Counts + a rounded
            // minute only , no HR/HRV/timestamps , so the next report ships PROOF of what was computed per
            // day (the project's log-failures-not-successes blind spot) and lets us settle the "Rest repeats
            // across days" question with data rather than a guess. Gated by the existing strap-log export.
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            // #386: the banked stage split + efficiency ride beside the rollup, so a "homepage disagrees
            // with the Sleep tab" report is self-diagnosing from the export alone — totalSleepMin vs the
            // deep+rem+light sum is the identity both screens must agree on, now verifiable per pass, per
            // day, without screenshots. Rounded minutes only (same privacy class as the rest of the line);
            // stages=nil when the day has no banked stage split (an unstaged or imported-total-only day).
            let effLog = daily.efficiency.map { String(format: "%.2f", $0) } ?? "nil"
            diagnosticSink?("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                            + "stages=\(Self.sleepStagesLogToken(deep: daily.deepMin, rem: daily.remMin, light: daily.lightMin)) "
                            + "eff=\(effLog) "
                            + "matched=\(night.cachedSleep.count) source=\(source.logToken)", nil)
            // #195: one always-on line per scored night with the computed HRV value + the window it used,
            // so an "HRV reads high / deep-sleep window not changing" report is self-diagnosing straight
            // from the strap log — the whole-night vs deep-sleep value, and `avgHrv=nil window=deep` when a
            // deep-window night has no detected deep sleep — without needing the HRV & Autonomic test mode.
            // Counts-only (a rounded ms + the window), PII-free; byte-identical to the Kotlin line.
            let hrvLog = daily.avgHrv.map { String(format: "%.1f", $0) } ?? "nil"
            diagnosticSink?("hrv day=\(daily.day) window=\(deepHrvWindow ? "deep" : "whole") avgHrv=\(hrvLog)", nil)
            // #195: the whole-night HRV cleaning summary built in loop 1 (rmssd vs sdnn / cleaning counts).
            if let hrvDiagLine = night.hrvDiag { diagnosticSink?(hrvDiagLine, nil) }
            // ── CAPTURE-B: universal dayOwner self-diagnostic (#814/#799) ────────────────────────────────
            // ONE line per scored day, tagged `.universal` so it rides EVERY Test Centre export regardless
            // of which mode is on. It pins down the read/write split #814 is about: `readId` is the owner
            // this day was actually read+scored from, `writeActiveId` is the registry's active id the
            // Collector writes raw under; when they DIVERGE on a day with HR rows, the dashboard and the
            // strap are reading two different namespaces. `hrRows` is the owner's HR-row count for the night
            // window; `provenance` says what backed the day (strap-measured vs a WHOOP/Apple import).
            // Counts + ids only (ids are local "my-whoop"/"whoop-…"/import tokens, no PII; LiveState also
            // scrubs). Verbatim format so the export parser reads it.
            // Gated on `.universal` (== any Test Centre mode active) so it rides every export but stays OFF
            // the strap log in normal use, matching the sleep/recovery/steps emitters' call-site gate. The
            // gate is one UserDefaults bool; the line is only built when it passes.
            if universalTraceActive {
                let owned = readOwnerByDay[daily.day]
                diagnosticSink?(Self.dayOwnerLine(
                    day: daily.day, readId: owned?.owner ?? regActiveId, writeActiveId: regActiveId,
                    hrRows: owned?.hrRows ?? 0, importedWhoop: importedWhoopDays.contains(daily.day),
                    importedApple: appleHealthDays.contains(daily.day)), .universal)
            }
            dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev))
            if let scored = v2 {
                sleepV2Points.append(contentsOf: Self.sleepV2MetricPoints(scored))
                let scoreLog = scored.performance.map { String(format: "%.1f", $0.score) } ?? "nil"
                diagnosticSink?("sleepV2 day=\(daily.day) score=\(scoreLog) source=\(scored.summary.source) model=\(scored.modelVersion)", .sleep)
            }
            if sleepV2Mode == .on, let rest = v2?.performance?.score {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            } else if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported/manual workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            for s in night.workouts {
                let durMin = max(0, (s.end - s.start) / 60)
                let validDetectedAverage = s.avgHR.isFinite && (30.0...250.0).contains(s.avgHR)
                let avgBpm = validDetectedAverage ? Int(s.avgHR.rounded()) : 0
                let detectedRow = WorkoutRow(
                    startTs: s.start, endTs: s.end,
                    sport: "detected", source: computedId,
                    durationS: s.durationS, energyKcal: s.caloriesKcal,
                    avgHr: validDetectedAverage ? avgBpm : nil, maxHr: s.peakHR,
                    strain: s.strain, distanceM: nil,
                    zonesJSON: nil, notes: nil,
                    strainVersion: s.strain == nil ? nil : 2
                )
                // The overlap test is bare time overlap (any source), so a detected bout collapses against a
                // manual session even though their SPORTS differ ("detected" vs the user's sport) , the
                // #975 "two workouts, one vanished" seam. Find the collider so the trace can name its source.
                if let index = realWorkouts.firstIndex(where: {
                    s.start < $0.row.endTs && $0.row.startTs < s.end
                }) {
                    let hit = realWorkouts[index]
                    let existing = hit.row
                    let computed = WorkoutDetectedBackfill.ComputedValues(
                        averageHeartRate: validDetectedAverage ? avgBpm : nil,
                        peakHeartRate: s.peakHR,
                        caloriesKcal: s.caloriesKcal,
                        strain: s.strain,
                        strainVersion: s.strain == nil ? nil : 2
                    )
                    let enriched = WorkoutDetectedBackfill.applying(computed, to: existing)
                    var backfillFailed = false
                    var didBackfill = false
                    if enriched != existing {
                        do {
                            try await upsertRealWorkout(enriched, owningDeviceId: hit.deviceId, store: store)
                            realWorkouts[index] = OwnedWorkout(row: enriched, deviceId: hit.deviceId)
                            didBackfill = true
                        } catch {
                            backfillFailed = true
                            // Do not turn a disk error into a silent data loss. Keep the real row intact
                            // and retain the detected row for a later reconciliation; a successful next
                            // pass removes this temporary overlap after it can enrich the real row.
                            workoutRows.append(detectedRow)
                            diagnosticSink?("workout backfill failed for overlapping "
                                + "\(WorkoutSource.sourceLabel(existing)) row; real row preserved and "
                                + "detected metrics retained for retry", .workouts)
                        }
                    }
                    if workoutsTraceActive {
                        diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                            verdict: backfillFailed ? "backfillFailedOverlap"
                                : (didBackfill ? "backfilledOverlap" : "droppedOverlap"),
                            durMin: durMin, avgBpm: avgBpm,
                            overlapSource: WorkoutSource.sourceLabel(existing)), .workouts)
                    }
                    continue
                }
                workoutRows.append(detectedRow)
                if workoutsTraceActive {
                    diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                        verdict: "persisted", durMin: durMin, avgBpm: avgBpm), .workouts)
                }
            }
        }

        // ── Apple-Watch recovery fold (M1 "Watch as a device") ──────────────────────────────────────
        // A watch-only user has apple-health DAILY aggregates (SDNN HRV + resting HR) but no raw stream, so
        // the raw-HR scoring loop above never touched their days and the import left `recovery: nil`. Fill
        // that one gap from the daily aggregate vs the person's own baseline (the cross-lane `WatchRecovery`
        // engine, which mirrors our Charge recovery shape). WHOOP/computed recovery MUST keep winning where
        // both exist, so we skip any day a strap already OWNS: every day the raw-HR loop scored (in `out`,
        // even a cold-start nil-recovery night , that day belongs to the strap, not the watch) plus every
        // WHOOP-imported day (the export carries its own recovery). The result is written back onto the
        // apple-health rows so the source-aware dashboard reads it, and the watch-only days are appended to
        // `out` so the By-Day list shows them with their honest confidence.
        let strapRecoveryDays = Set(out.map { $0.day }).union(importedWhoopDays)
        let watchScored = Self.watchRecoveries(appleRows: appleRows, strapRecoveryDays: strapRecoveryDays)
        // Persist the recovery onto each apple-health row that gained one (nil-recovery days are left as-is,
        // never fabricated). Rebuild the row with the new recovery; every other field is unchanged.
        var persistedMutationCount = 0
        var appleRecoveryRows: [DailyMetric] = []
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for w in watchScored {
            guard let recovery = w.recovery, let row = appleByDay[w.day] else { continue }
            // DL-12: rewrite only rows whose recovery changed, instead of re-upserting every Apple day ever
            // recorded on every pass.
            if row.recovery != recovery {
                appleRecoveryRows.append(row.with(recovery: recovery, skinTempDevC: row.skinTempDevC))
            }
            // Surface every watch-only day in the By-Day list with its watch provenance + confidence. The
            // results keep the whole Apple history (review N2-UPG-5): Smart Alarm's green wake mode and the
            // Charge forecast count these recoveries, and production passes cover a single day.
            out.append(Computed(day: w.day, recovery: recovery, strain: row.strain,
                                sleepMin: row.totalSleepMin, hrv: row.avgHrv, rhr: row.restingHr,
                                source: .appleHealth, recoveryPersistenceOwner: .appleHealth,
                                confidence: w.confidence, drivers: w.drivers))
        }
        if !appleRecoveryRows.isEmpty {
            do {
                guard !Task.isCancelled else { performanceChangedRows = persistedMutationCount; return false }
                persistedMutationCount += try await store.upsertDailyMetrics(
                    appleRecoveryRows, deviceId: Repository.appleHealthSource)
            } catch {
                note = String(localized: "Recovery could not be saved. NOOP will retry.")
                NSLog("IntelligenceEngine: Apple Recovery persistence failed: \(error)")
                return false
            }
        }

        // #277 migration: the loop now keys days by the LOCAL calendar day. A prior run (before this
        // fix) wrote the SAME period under UTC-day keys, so without a cleanup an off-by-one UTC row and
        // the new local row would coexist as duplicate days. We reconcile the COMPUTED ("-noop") daily
        // rows across the recompute window [oldest enumerated local day, newest]: UPSERT the freshly
        // local-keyed rows FIRST, then delete only the STALE rows the new run no longer produces.
        //
        // #521: the old order was delete-the-whole-window THEN re-upsert , a non-atomic gap where a
        // concurrent refresh could read `repo.days.count` LOWER (post-delete) then HIGHER (post-upsert),
        // which the Today inbox mistook for new history and announced as "New data added" on a loop. By
        // upserting before deleting, the row count is MONOTONIC (it only grows or holds during a
        // recompute), so recompute churn can never masquerade as growth. Scoped to the computed source
        // only , imported "my-whoop" rows are never touched (a BLE-only WHOOP 4.0 user has no import
        // fallback). Rows older than the window keep their old keys (cosmetic off-by-one, acceptable).
        // yyyy-MM-dd sorts chronologically, so the string range IS a date range.
        let oldestDay = oldestCivilDay.day
        let newestDay = newestCivilDay.day

        // ── Source-only Charge/Rest fold for wearable imports (Oura / Fitbit / Garmin / Health Connect) ──
        // Same honesty gap the watch fold above closes (#823), extended to the other import-only sources: a
        // user who ONLY imports an Oura/Fitbit/Garmin export (or Health Connect) has DAILY aggregates (HRV +
        // resting HR) but no raw HR stream, so the raw-HR loop never scored their days and the import left
        // recovery nil , Today/Recovery show a blank Charge. Score it from the daily aggregate vs the person's
        // own baseline with the SAME `watchRecoveries` engine the apple fold uses (which reuses
        // RecoveryScorer.recovery verbatim), then write the score under the COMPUTED ("-noop") source so it
        // merges onto Today exactly like a live day. The imported daily row keeps its raw values untouched;
        // the computed row carries the NOOP-derived Charge + the Rest composite. HONEST DATA: the engine
        // returns nil + calibrating until the HRV baseline is usable, so an import-only day stays calibrating
        // rather than faking a number. The strap and a real WHOOP/Apple import keep winning , we skip any day
        // already scored this pass (`dailies`) or owned by a WHOOP/Apple import. The window matches the
        // computed reconcile below, so the fold's rows survive the stale-row eviction.
        var importScoredDays = Set(dailies.map { $0.day }).union(importedWhoopDays).union(appleHealthDays)
        var wearableFoldDays = Set<String>()
        for source in Repository.wearableImportSources {
            // DL-04: the baseline reads the source's whole history up to the window's end (read once above);
            // only days inside the window are scored and written below. A window-only read starved the
            // 7-night baseline, so an import-only user never got Charge.
            let rows = wearableRowsBySource[source] ?? []
            guard !rows.isEmpty else { continue }
            let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            for w in Self.watchRecoveries(appleRows: rows, strapRecoveryDays: importScoredDays)
            where w.day >= oldestDay {
                guard let recovery = w.recovery, let row = byDay[w.day] else { continue }
                let scored = row.with(recovery: recovery, skinTempDevC: row.skinTempDevC)
                dailies.append(scored)
                importScoredDays.insert(w.day)
                wearableFoldDays.insert(w.day)
                if let rest = AnalyticsEngine.Rest.composite(daily: scored) {
                    restPoints.append(MetricPoint(day: w.day, key: "sleep_performance", value: rest))
                }
                out.append(Computed(day: w.day, recovery: recovery, strain: scored.strain,
                                    sleepMin: scored.totalSleepMin, hrv: scored.avgHrv, rhr: scored.restingHr,
                                    source: .computed, confidence: w.confidence, drivers: w.drivers))
            }
        }

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        // Snapshot the persisted/merged daily history BEFORE the upsert + stale-evict below , the
        // accumulated view the readiness card + dashboard read (incl. IMPORTED Apple Health / Health Connect
        // resting HR, which the engine's computed-only `dailies` never carries). Captured here so the
        // Fitness Age gate can't be undercut by this pass's own scoring/eviction. Windowed to the range.
        let faPriorDaily = await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay)

        // Any pass for the still-open civil day can contain only post-sleep daytime samples. This includes
        // exact receipt work and the ordinary dashboard refresh that follows a completed backfill. Such a pass
        // may legitimately refresh Strain/activity while having no overnight replacements; a full row upsert
        // would otherwise clear already-validated sleep, HRV, Recovery and Health Monitor values. Preserve only
        // missing overnight fields from the persisted same-day row, and protect that row from stale eviction
        // when the partial pass produces no daily row at all. Completed historical days keep full-replacement
        // semantics, and every fresh current-day value remains authoritative.
        var reconciledDailies = dailies
        var protectedDailyDays: Set<String> = []
        if let partialDay = civilDays.first(where: { $0.start <= now && now < $0.nextStart }) {
            do {
                let prior = try await store.dailyMetrics(
                    deviceId: computedId,
                    from: partialDay.day,
                    to: partialDay.day
                ).first
                if let prior {
                    if let index = reconciledDailies.firstIndex(where: { $0.day == partialDay.day }) {
                        reconciledDailies[index] = Self.preservingPriorOvernightFields(
                            in: reconciledDailies[index],
                            from: prior
                        )
                        protectedDailyDays.insert(partialDay.day)
                    }
                }

                // A prior buggy exact pass may have deleted the whole daily row or only its overnight
                // vitals while leaving the validated sleep session intact. Once any prior values have been
                // merged, rebuild only still-missing fields the persisted session proves. Fresh daytime
                // activity and already-present overnight values remain authoritative; unsupported vitals
                // stay nil.
                let existingIndex = reconciledDailies.firstIndex { $0.day == partialDay.day }
                let base = existingIndex.map { reconciledDailies[$0] } ?? prior ?? DailyMetric(
                    day: partialDay.day,
                    totalSleepMin: nil,
                    efficiency: nil,
                    deepMin: nil,
                    remMin: nil,
                    lightMin: nil,
                    disturbances: nil,
                    restingHr: nil,
                    avgHrv: nil,
                    recovery: nil,
                    strain: nil,
                    exerciseCount: nil
                )
                let needsPersistedSleepRepair = base.totalSleepMin == nil
                    || base.efficiency == nil
                    || base.deepMin == nil
                    || base.remMin == nil
                    || base.lightMin == nil
                    || base.restingHr == nil
                    || base.avgHrv == nil
                if needsPersistedSleepRepair {
                    let persistedSleep = try await store.sleepSessions(
                        deviceId: computedId,
                        from: windowStart,
                        to: partialDay.nextStart,
                        limit: 4_000
                    )
                    if var rebuilt = Self.rebuildingMissingOvernightFields(
                        in: base,
                        from: persistedSleep,
                        dayStart: partialDay.start,
                        nextDayStart: partialDay.nextStart,
                        habitualMidsleepSec: habitualMidsleepSec,
                        timeZoneOffsetSeconds: clockOffsetByDay[partialDay.day] ?? tzOffset
                    ) {
                        let rest = AnalyticsEngine.Rest.composite(daily: rebuilt)
                        let sleepQuality = rest.map { $0 / 100.0 } ?? rebuilt.efficiency
                        rebuilt = rebuilt.replacing(recovery: .some(
                            rebuilt.recovery ?? recomputeRecovery(
                                rebuilt,
                                baselines(asOf: rebuilt.day),
                                sleepQuality: sleepQuality
                            )
                        ))
                        if let existingIndex {
                            reconciledDailies[existingIndex] = rebuilt
                        } else {
                            reconciledDailies.append(rebuilt)
                        }
                        protectedDailyDays.insert(partialDay.day)
                        if let rest {
                            restPoints.removeAll {
                                $0.day == partialDay.day && $0.key == "sleep_performance"
                            }
                            restPoints.append(MetricPoint(
                                day: partialDay.day,
                                key: "sleep_performance",
                                value: rest
                            ))
                        }
                    }
                }
            } catch {
                note = String(localized: "Current recovery data could not be preserved safely. NOOP will retry.")
                NSLog("IntelligenceEngine: current-day exact reconciliation read failed: \(error)")
                return false
            }
        }

        // Upgrade 231: on a strap-swap or re-pair day the new active strap owns the day from its daytime readings
        // alone, so the day is produced with no night. The stored row still holds the night the previous strap
        // recorded. When another completed-day strap, live or archived, has the raw loop's 200 plausible rows in
        // the night span ending on that day (18:00 the evening before to noon, in the day's zone), the produced
        // row keeps the stored overnight fields, the same merge the still-open day gets, and the day's overnight
        // metric rows (skin, Charge breakdown, shadow) stay with them. Only the migration's chunks do this (fix
        // 3): an ordinary or edited-day pass replaces the row in full, so a night the user deleted stays
        // deleted. Canonical namespace only: a source-rooted namespace holds one strap's days.
        var swapNightKeepDays: Set<String> = []
        let nightlessCompleted = reconciledDailies.indices.filter { index in
            let row = reconciledDailies[index]
            return !Self.hasOvernightFields(row)
                && civilDays.contains { $0.day == row.day && $0.nextStart <= now }
        }
        if keepUnproducedHistory, deviceId == Repository.whoopSource, !nightlessCompleted.isEmpty {
            do {
                let storedByDay = Dictionary(
                    try await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)
                        .map { ($0.day, $0) },
                    uniquingKeysWith: { a, _ in a })
                let straps = regDevices.filter { !$0.isImportSource && $0.sourceKind != .activityFile }
                for index in nightlessCompleted {
                    let row = reconciledDailies[index]
                    guard let prior = storedByDay[row.day], Self.hasOvernightFields(prior),
                          let window = civilDays.first(where: { $0.day == row.day }) else { continue }
                    let owner = readOwnerByDay[row.day]?.owner
                    var nightCovered = false
                    for strap in straps where strap.id != owner {
                        let rows = try await store.plausibleHRCount(
                            deviceId: strap.id, from: window.start - 6 * 3_600, to: window.start + 12 * 3_600,
                            bpmRange: HRValidity.bpmRange, cap: Self.rawLoopMinHrRows)
                        if rows >= Self.rawLoopMinHrRows { nightCovered = true; break }
                    }
                    guard nightCovered else { continue }
                    reconciledDailies[index] = Self.preservingPriorOvernightFields(in: row, from: prior)
                    swapNightKeepDays.insert(row.day)
                    protectedDailyDays.insert(row.day)
                }
            } catch {
                note = String(localized: "Recovery history could not be reconciled. NOOP will retry.")
                NSLog("IntelligenceEngine: swap-day night read failed: \(error)")
                return false
            }
        }
        dailies = reconciledDailies

        // Review round 7 (1): a full-history migration chunk (`keepUnproducedHistory`) never deletes a completed
        // day's stored row, or that day's stored metric rows and detected workouts, unless it produced a
        // replacement. A day this pass can't score (its raw data unreachable, an epoch-reset fold) keeps what
        // the owner sees today. Ordinary passes keep the full-replacement reconcile.
        var historyKeepDays: Set<String> = []
        if keepUnproducedHistory {
            do {
                let stored = try await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)
                historyKeepDays = Set(stored.map(\.day)).subtracting(reconciledDailies.map(\.day))
                historyKeepDays.subtract(civilDays.filter { $0.nextStart > now }.map(\.day))
            } catch {
                note = String(localized: "Recovery history could not be reconciled. NOOP will retry.")
                NSLog("IntelligenceEngine: migration keep-set read failed: \(error)")
                return false
            }
        }

        // Replace the full computed range in one SQLite transaction. Upsert-then-read-then-delete used three
        // separate transactions; any unrelated reader could observe the intermediate generation even when
        // Repository publication was fenced. Manual-Recovery triggers restore protected rows atomically.
        // A migration chunk (`keepUnproducedHistory`: the v3 and settle rescores) is cancelled when the app returns
        // to the foreground, but only up to its first durable write. From the daily reconcile to the end of the
        // persistence phase it runs to completion: the writes are separate transactions, so stopping between them
        // left a day with the new daily row beside its old Rest score, sleep sessions and detected workouts, and
        // no later pass rewrites those days until the same chunk replays. The write phase is short next to the scan.
        // Ordinary passes keep stopping at every checkpoint.
        let writesStopOnCancel = !keepUnproducedHistory
        do {
            guard !Task.isCancelled else { performanceChangedRows = persistedMutationCount; return false }
            persistedMutationCount += try await store.reconcileDailyMetrics(
                reconciledDailies,
                deviceId: computedId,
                from: oldestDay,
                to: newestDay,
                protectedDays: protectedDailyDays.union(historyKeepDays)
            )
            // Review round 4 (4): the provenance marker covers exactly the rows reconciled above.
            let rowSourcePoints = Dictionary(reconciledDailies.compactMap { row -> (String, MetricPoint)? in
                guard row.day >= oldestDay, row.day <= newestDay else { return nil }
                return (row.day, MetricPoint(
                    day: row.day, key: Self.computedRowSourceMetricKey,
                    value: wearableFoldDays.contains(row.day) ? Self.wearableFoldRowSource : Self.strapRowSource))
            }, uniquingKeysWith: { _, last in last })
            persistedMutationCount += try await store.reconcileMetricSeries(
                Array(rowSourcePoints.values),
                deviceId: computedId,
                keys: [Self.computedRowSourceMetricKey],
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays
            )
            // Review round 4 (2): how far each row's calorie total was filled.
            let fillEndPoints = Dictionary(reconciledDailies.compactMap { row -> (String, MetricPoint)? in
                guard row.activeKcalEst != nil, let window = civilDayByKey[row.day] else { return nil }
                return (row.day, MetricPoint(day: row.day, key: Self.calorieFillEndMetricKey,
                                             value: Double(min(window.nextStart, now))))
            }, uniquingKeysWith: { _, last in last })
            persistedMutationCount += try await store.reconcileMetricSeries(
                Array(fillEndPoints.values),
                deviceId: computedId,
                keys: [Self.calorieFillEndMetricKey],
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays
            )
            // Review round 4 (5): and how much of the day the strap covered.
            let wornPoints = Dictionary(reconciledDailies.compactMap { row -> (String, MetricPoint)? in
                guard row.activeKcalEst != nil, civilDayByKey[row.day] != nil,
                      let worn = strapWornSecondsByDay[row.day] else { return nil }
                return (row.day, MetricPoint(day: row.day, key: Self.strapWornSecondsMetricKey, value: Double(worn)))
            }, uniquingKeysWith: { _, last in last })
            persistedMutationCount += try await store.reconcileMetricSeries(
                Array(wornPoints.values),
                deviceId: computedId,
                keys: [Self.strapWornSecondsMetricKey],
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays
            )
        } catch {
            note = String(localized: "Recovery history could not be reconciled. NOOP will retry.")
            NSLog("IntelligenceEngine: computed daily reconciliation failed: \(error)")
            return false
        }
        afterDailyReconcileForTesting?()
        // Review round 4 (3): each day's Charge breakdown, persisted beside the Charge it explains for every fold.
        // In the window: the strap and wearable-fold days whose reconciled row carries exactly the Charge the
        // drivers were built against, and the Apple Watch days no computed Charge overrides. The Apple fold
        // rescores the whole history, so its days outside the window are rewritten only where their Charge
        // changed.
        do {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            let reconciledRecoveryByDay = Dictionary(reconciledDailies.map { ($0.day, $0.recovery) },
                                                     uniquingKeysWith: { _, last in last })
            var windowBreakdowns: [String: StoredChargeBreakdown] = [:]
            for computed in out where computed.day >= oldestDay && computed.day <= newestDay {
                guard let recovery = computed.recovery, !computed.drivers.isEmpty else { continue }
                let storedRecovery = reconciledRecoveryByDay[computed.day] ?? nil
                if computed.recoveryPersistenceOwner == .appleHealth {
                    guard storedRecovery == nil else { continue }
                } else {
                    guard storedRecovery == recovery else { continue }
                }
                windowBreakdowns[computed.day] = StoredChargeBreakdown(
                    day: computed.day, score: recovery, confidence: computed.confidence, drivers: computed.drivers)
            }
            // A protected current day, or a swap day (upgrade 231), that kept its earlier Charge keeps that
            // Charge's breakdown too.
            for day in protectedDailyDays where windowBreakdowns[day] == nil {
                var points: [MetricPoint] = []
                for key in Self.chargeBreakdownKeys {
                    points += try await store.metricSeries(deviceId: computedId, key: key, from: day, to: day)
                }
                if let kept = Self.chargeBreakdown(day: day, points: points),
                   kept.score == reconciledRecoveryByDay[day] ?? nil {
                    windowBreakdowns[day] = kept
                }
            }
            persistedMutationCount += try await store.reconcileMetricSeries(
                windowBreakdowns.values.flatMap { Self.chargeBreakdownPoints($0) },
                deviceId: computedId,
                keys: Self.chargeBreakdownKeys,
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays
            )
            let storedScores = Dictionary(
                try await store.metricSeries(deviceId: computedId, key: Self.chargeBreakdownScoreKey,
                                             from: "0000-01-01", to: "9999-12-31").map { ($0.day, $0.value) },
                uniquingKeysWith: { a, _ in a })
            var staleDays: [String] = []
            var freshPoints: [MetricPoint] = []
            for w in watchScored where w.day < oldestDay || w.day > newestDay {
                guard storedComputedByDay[w.day]?.recovery == nil, !importedWhoopDays.contains(w.day) else { continue }
                let storedScore = storedScores[w.day]
                if let recovery = w.recovery, !w.drivers.isEmpty {
                    guard storedScore != recovery else { continue }
                    if storedScore != nil { staleDays.append(w.day) }
                    freshPoints += Self.chargeBreakdownPoints(StoredChargeBreakdown(
                        day: w.day, score: recovery, confidence: w.confidence, drivers: w.drivers))
                } else if storedScore != nil {
                    staleDays.append(w.day)
                }
            }
            if !staleDays.isEmpty {
                persistedMutationCount += try await store.deleteMetricSeriesGlobally(
                    keys: Self.chargeBreakdownKeys, onDays: staleDays)
            }
            if !freshPoints.isEmpty {
                persistedMutationCount += try await store.upsertMetricSeries(freshPoints, deviceId: computedId)
            }
        } catch {
            NSLog("IntelligenceEngine: Charge breakdown persistence failed: \(error)")
            return false
        }
        do {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            // Exact committed work is source-maintenance, not a consent owner. It must still reconcile
            // validation-only primary-session RHR for the exact raw source, but it cannot interpret the
            // deliberately absent pre-sleep observations as deletion. Those five rows belong exclusively
            // to normal opt-in analysis and the explicit global opt-out cleanup path.
            let reconciledShadowKeys = sourceContext == nil
                ? PrimarySessionRestingHR.metricKeys + PreSleepHeartRateFeedback.metricKeys
                : PrimarySessionRestingHR.metricKeys
            persistedMutationCount += try await store.reconcileMetricSeries(
                shadowPoints,
                deviceId: computedId,
                keys: reconciledShadowKeys,
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays.union(swapNightKeepDays)
            )
        } catch {
            NSLog("IntelligenceEngine: shadow metric reconciliation failed: \(error)")
            return false
        }
        // F2: persist each scored night's raw skin mean, so later passes and the v3 chunks fold the skin
        // baseline over the whole history instead of only their own window. A WHOOP 4.0 night is stored as a
        // raw register value under the strap that recorded it, with its anchor (review round 3 B, round 4 1), keyed
        // by the strap's physical identity (review round 5, 4).
        do {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            var whoop4Identities = Set(storedWhoop4SkinByIdentity.keys)
            let nightlySkinPoints = scoredNights.flatMap { night -> [MetricPoint] in
                guard let mean = night.nightlySkin else { return [] }
                let day = night.daily.day
                if let anchor = whoop4SkinAnchorByDay[day], let owner = readOwnerByDay[day]?.owner {
                    let identity = whoop4Identity(day: day, owner: owner)
                    whoop4Identities.insert(identity)
                    return [
                        MetricPoint(day: day, key: Self.nightlySkinWhoop4RawKeyPrefix + identity,
                                    value: Self.whoop4SkinRaw(celsius: mean, anchorRaw: anchor)),
                        MetricPoint(day: day, key: Self.nightlySkinWhoop4AnchorKeyPrefix + identity, value: anchor),
                    ]
                }
                return [MetricPoint(day: day, key: Self.nightlySkinMetricKey, value: mean)]
            }
            persistedMutationCount += try await store.reconcileMetricSeries(
                nightlySkinPoints,
                deviceId: computedId,
                keys: [Self.nightlySkinMetricKey] + whoop4Identities.sorted().flatMap {
                    [Self.nightlySkinWhoop4RawKeyPrefix + $0, Self.nightlySkinWhoop4AnchorKeyPrefix + $0]
                },
                from: oldestDay,
                to: newestDay,
                protectedDays: historyKeepDays.union(swapNightKeepDays)
            )
        } catch {
            NSLog("IntelligenceEngine: nightly skin mean persistence failed: \(error)")
            return false
        }
        if !restPoints.isEmpty {
            do {
                guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
                persistedMutationCount += try await store.upsertMetricSeries(restPoints, deviceId: computedId)
            } catch {
                NSLog("IntelligenceEngine: Rest series persistence failed: \(error)")
                return false
            }
        }
        if !sleepV2Points.isEmpty {
            do {
                guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
                persistedMutationCount += try await store.upsertMetricSeries(
                    sleepV2Points, deviceId: computedId)
            } catch {
                NSLog("IntelligenceEngine: Sleep V2 persistence failed: \(error)")
                return false
            }
        }

        // ── Fitness Age (Phase 2) , weekly, keyed to the week's Saturday ────────────────────────────
        // Roll the last 7 computed days into the Nes/HUNT inputs and upsert a weekly Fitness Age (+ an
        // optional VO₂max when a waist is set) under the same "-noop" source. Idempotent on the Saturday
        // key, so the number refines through the week and finalises on Saturday. Engine = FitnessAgeEngine
        // (StrandAnalytics), fully unit-tested; the body term cancels so the headline needs no body metric.
        let fa7 = dailies.sorted { $0.day < $1.day }.suffix(7)
        let faRHRs = fa7.compactMap { $0.restingHr }.map(Double.init)
        // The Fitness Age gate + compute read the PERSISTED/MERGED last-7 days , the SAME history the
        // readiness card + dashboard show , NOT this pass's freshly scored `dailies`. A recompute only
        // re-scores nights whose raw HR still lives in the store, so a nightly wearer whose card reads
        // "7 of 7 nights" could still leave the engine seeing <4 RHR nights on `dailies`, and Fitness Age
        // never computed (Vitality did , it needs only 3 of ANY input, which is why Body Age showed but
        // Fitness Age did not). Kept SEPARATE from `fa7` so Vitality (below), which already computes, is
        // untouched. Gate on the UNION of the pre-rewrite persisted history and THIS pass's fresh scores
        // (by day, fresh wins), so an RHR night counts whether it survives in the store, was just scored,
        // or came from an import. The gate + compute live in `fitnessAgeRows`, shared with the manual
        // "refresh Fitness Age" button so the two can never drift.
        var faGateByDay: [String: DailyMetric] = [:]
        for d in faPriorDaily { faGateByDay[d.day] = d }
        for d in dailies { faGateByDay[d.day] = d }
        let faGate7 = Array(faGateByDay.values.sorted { $0.day < $1.day }.suffix(7))
        let faPts = Self.fitnessAgeRows(
            gateDays: faGate7, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: computedId,
            satKey: IntelligenceEngine.saturdayKey(onOrBefore: newestDay))
        if !faPts.isEmpty {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            persistedMutationCount += (try? await store.upsertMetricSeries(
                faPts, deviceId: computedId)) ?? 0
        }

        // ── Vitality / Body Age (Phase 7) , weekly, keyed to the week's Saturday ────────────────────
        // Roll the last 7 days' wearable signals into the mortality-hazard model and upsert a weekly
        // Vitality (0–100) + Body Age. VitalityEngine gates on ≥3 inputs, so a sparse week writes nothing.
        // (VO₂max is omitted here , fitness is already its own Fitness Age headline; Vitality leans on
        // resting HR, sleep duration + regularity, HRV-vs-age-norm, and steps.)
        let vNights = fa7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let vHRVs = fa7.compactMap { $0.avgHrv }
        let vSteps = fa7.compactMap { $0.steps }.map(Double.init)
        let vInputs = VitalityEngine.Inputs(
            chronoAge: Double(profile.age),
            restingHR: faRHRs.isEmpty ? nil : IntelligenceEngine.medianOf(faRHRs),
            sleepHours: vNights.isEmpty ? nil : vNights.reduce(0, +) / Double(vNights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: vNights),
            rmssd: vHRVs.isEmpty ? nil : IntelligenceEngine.medianOf(vHRVs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: vSteps.isEmpty ? nil : vSteps.reduce(0, +) / Double(vSteps.count))
        if let vRes = VitalityEngine.compute(vInputs) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            persistedMutationCount += (try? await store.upsertMetricSeries([
                MetricPoint(day: satKey, key: "vitality", value: vRes.vitality),
                MetricPoint(day: satKey, key: "body_age", value: vRes.bodyAge),
            ], deviceId: computedId)) ?? 0
        }

        // ── Steps ESTIMATE (WHOOP 4.0) , DAILY, keyed to each strap-only day ────────────────────────
        // A WHOOP 4.0 sends no step count over BLE, so for days the phone DIDN'T also count steps we
        // estimate them: calibrate the strap's daily MOTION VOLUME against the phone's real step count
        // on the days both exist, then apply that personal coefficient to the strap-only days. Engine =
        // StepsEstimateEngine (StrandAnalytics), fully unit-tested; this block is pure orchestration ,
        // gather points, fit, store under the same "-noop" source, mirror to ProfileStore for the UI.
        //
        // Idempotent: re-upserts the same (computedId, day, "steps_est") rows. Inert until there's a
        // calibration , a single-source / no-phone user sees no estimate until they set a manual `k`.
        //
        // Calibration window: a generous 60 days (not just the 7 the weekly engines use) so enough
        // both-have days accumulate to fit. Reference steps = the apple-health daily `steps` value
        // (the same source the dashboard's `steps` metric reads, Repository.swift). Motion = the
        // [localMidnight, +24h) gravity volume, the same calendar-day window the daily totals use.
        // Normal passes only. The estimate's inputs are the LATEST 60 days whatever window the pass scores, so a
        // rescore chunk (`startOffset > 0`, `keepUnproducedHistory`) or an exact-day receipt pass (`sourceContext`)
        // would re-read the same 60 days of gravity a normal pass reads and store the same answer. Every v3 and
        // settle chunk used to repeat that gather, and the unpaced 60-day read was the cause of a background CPU kill
        // (cpu_resource_fatal, build 227). The 15-minute and post-sync passes still estimate and mirror the fit.
        if Self.runsStepsCalibration(startOffset: startOffset, keepUnproducedHistory: keepUnproducedHistory,
                                     hasSourceContext: sourceContext != nil) {
            let stepsCalDays = 60
            let stepCivilDays = Self.civilDayWindows(
                reference: referenceNow, startOffset: 0, count: stepsCalDays, calendar: analysisCalendar)
            let calOldest = stepCivilDays.last?.day ?? oldestDay
            // ── FIX 2 (main-actor jank): hoist the 60-day steps-calibration STORE READS off the main actor ──
            // Same residual stall FIX 1 fixed, smaller scale: this class is `@MainActor`, so each `await store.…`
            // below resumes its continuation ON the main actor , the apple-health read + 60 per-day
            // owner-resolve/gravity reads add 60+ read-resumes of main-actor contention every analyzeRecent.
            // The reads touch NO `@Published`/`profile`/`registry`-isolated state , only the captured immutable
            // inputs (calOldest/newestDay/stepCivilDays/regDevices/regActiveId), the `WhoopStore`
            // actor, the nonisolated `registry`, the nonisolated-static `resolveDayOwner`, and the pure static
            // `StepsEstimateEngine.dayMotionIntensity`. So we hoist the whole gather into ONE
            // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, returning two
            // plain `[String: Double]` value types (fully Sendable , even cleaner than FIX 1's [DayScan]). The
            // pure `StepsEstimateEngine.calibrate/estimate/status` fit + the `profile.*` assignments stay on the
            // main actor below, consuming those dictionaries. Same per-day inputs (same window, same owner
            // resolution, same `m > 0` / `steps > 0` filters), same outputs , only the executor the reads resume
            // on changes. Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the
            // @Sendable detached closure captures the VALUE, never `self`, exactly as FIX 1's `ownerFallbackId`.
            let stepsFallbackId = deviceId
            // Per-day motion cache (see `StepMotionCacheEntry`): a normal pass re-read 60 full days of gravity every
            // time. A day whose owner, window and gravity fingerprint are unchanged keeps its motion volume.
            let motionCacheIn = stepMotionCache
            let gatheredStepsCalibration: StepsCalibrationGather
            do {
                gatheredStepsCalibration = try await CooperativeAnalysisCancellation.runDetached {
                    try CooperativeAnalysisCancellation.checkpoint()
                // Phone reference steps per day, from the apple-health daily rows (steps > 0 only).
                // #693: read `appleDaily`, NOT `dailyMetrics`. Apple-Health import writes the phone step count into
                // `appleDaily.steps` (Int?), never into a dailyMetric `steps` row , so the old `dailyMetrics` read
                // was always empty and the calibration never advanced past "Need 3 more days" (Android already reads
                // appleDaily here, IntelligenceEngine.kt:676). `store.appleDaily(deviceId:from:to:)` already exists.
                let appleRows = (try? await store.appleDaily(deviceId: Repository.appleHealthSource,
                                                             from: calOldest, to: newestDay)) ?? []
                var refSteps: [String: Double] = [:]
                for r in appleRows { if let s = r.steps, s > 0 { refSteps[r.day] = Double(s) } }
                // Per-day motion volume over the calibration window, read from the owner-resolved strap streams.
                // (Owner resolution mirrors the scoring loop; one device installs resolve to `deviceId`.)
                var motion: [String: Double] = [:]
                var motionCache: [String: StepMotionCacheEntry] = [:]
                var cacheHits = 0
                for civilDay in stepCivilDays {
                    try CooperativeAnalysisCancellation.checkpoint()
                    let day = try await Self.stepMotion(
                        for: civilDay, now: now, cached: motionCacheIn[civilDay.day], store: store,
                        devices: regDevices, activeId: regActiveId, registry: registry,
                        fallbackDeviceId: stepsFallbackId)
                    if let entry = day.entry { motionCache[civilDay.day] = entry }
                    if day.hit { cacheHits += 1 }
                    if day.motion > 0 { motion[civilDay.day] = day.motion }
                }
                return StepsCalibrationGather(refSteps: refSteps, motion: motion,
                                              motionCache: motionCache, cacheHits: cacheHits)
                }
            } catch is CancellationError {
                performanceChangedRows = 0
                return false
            } catch {
                gatheredStepsCalibration = StepsCalibrationGather(refSteps: [:], motion: [:], motionCache: [:], cacheHits: 0)
            }
            stepMotionCache = gatheredStepsCalibration.motionCache
            stepMotionCacheHits &+= gatheredStepsCalibration.cacheHits
            let refStepsByDay = gatheredStepsCalibration.refSteps
            let motionByDay = gatheredStepsCalibration.motion
            // Build calibration points only for days with BOTH a motion volume and a real phone step count.
            let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
                guard let s = refStepsByDay[day] else { return nil }
                return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
            }
            if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                // Estimate + upsert for each recent scored day that has motion but NO real phone step count.
                // (Days the phone DID count keep their real value , surfaced directly by the Today tile, not
                // overwritten by an estimate.) This runs AFTER any timestamp-heal upstream, so the motion it
                // reads is the healed-day motion, never pre-heal.
                var estPts: [MetricPoint] = []
                for dm in dailies where refStepsByDay[dm.day] == nil {
                    guard let motion = motionByDay[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                    estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
                }
                if !estPts.isEmpty {
                    guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
                    persistedMutationCount += (try? await store.upsertMetricSeries(
                        estPts, deviceId: computedId)) ?? 0
                }
                // Mirror the fit into ProfileStore so the Settings/Steps screen can show + adjust it.
                profile.stepsCalibrationCoefficient = cal.coefficient
                profile.stepsCalibrationSampleDays = cal.sampleDays
                profile.stepsCalibrationConfidence = cal.confidence
                profile.stepsCalibrationManual = cal.manual
            } else {
                // Not yet calibrated (too few overlapping phone-counted days, no manual override). Classify the
                // STATE (#589) and persist the PROGRESS so the Today tile/Settings can say how many more days are
                // needed rather than going silently blank. `status` uses the SAME usable-day filter the fit does.
                // Coefficient stays 0 (the "not calibrated" gate the UI already keys off); sampleDays carries the
                // usable-day count so the message can compute "need N more".
                let stepsStatus = StepsEstimateEngine.status(calPoints, manualOverride: profile.stepsManualOverride)
                if case let .needsMoreDays(have, _) = stepsStatus {
                    profile.stepsCalibrationCoefficient = 0
                    profile.stepsCalibrationSampleDays = have
                    profile.stepsCalibrationConfidence = 0
                    profile.stepsCalibrationManual = false
                }
            }

            // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points + the fitted /
            // manual / withheld calibration state) and a per-day estimate line, tagged `.steps`. Only when the
            // mode is on (the gate was read once before the scan loop), so the default path emits zero `.steps`
            // lines here. The trace reuses StepsEstimateEngine.calibrate/estimate VERBATIM, so it cannot diverge
            // from the coefficient + steps_est just written above.
            if stepsTraceActive {
                for line in StepsEstimateEngine.calibrationTrace(points: calPoints,
                                                                 manualOverride: profile.stepsManualOverride) {
                    diagnosticSink?(line, .steps)
                }
                if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                    for dm in dailies where refStepsByDay[dm.day] == nil {
                        guard let motion = motionByDay[dm.day],
                              let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                        diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                            + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                    }
                }
            }
        } else if let calibration = Self.persistedStepsCalibration(
            manualOverride: profile.stepsManualOverride, coefficient: profile.stepsCalibrationCoefficient,
            sampleDays: profile.stepsCalibrationSampleDays, confidence: profile.stepsCalibrationConfidence,
            manual: profile.stepsCalibrationManual) {
            // A pass that skips the 60-day fit (an exact-day receipt pass, a repair, a rescore chunk) still estimates
            // the days IT scored: the exact-day pipeline is the only thing that scores a completed day while the app
            // is in the background, and nothing else rewrites `steps_est`. The estimate needs only each own day's
            // motion volume (read through the same per-day cache, so a day a normal pass already read costs one
            // index probe) and the last fitted or manual coefficient. The fit and the profile mirror stay with the
            // normal pass. Days older than the 60-day window were never estimated, so none are now.
            let stepCivilDays = Self.civilDayWindows(
                reference: referenceNow, startOffset: 0, count: 60, calendar: analysisCalendar)
            let ownDays = Set(dailies.map(\.day))
            let ownWindows = stepCivilDays.filter { ownDays.contains($0.day) }
            if let ownNewest = ownWindows.first?.day, let ownOldest = ownWindows.last?.day {
                let stepsFallbackId = deviceId
                let motionCacheIn = stepMotionCache
                let gather: @Sendable () async throws -> StepsCalibrationGather = {
                    try CooperativeAnalysisCancellation.checkpoint()
                    let appleRows = (try? await store.appleDaily(deviceId: Repository.appleHealthSource,
                                                                 from: ownOldest, to: ownNewest)) ?? []
                    var refSteps: [String: Double] = [:]
                    for r in appleRows { if let s = r.steps, s > 0 { refSteps[r.day] = Double(s) } }
                    var motion: [String: Double] = [:]
                    var motionCache: [String: StepMotionCacheEntry] = [:]
                    var cacheHits = 0
                    for civilDay in ownWindows where refSteps[civilDay.day] == nil {
                        try CooperativeAnalysisCancellation.checkpoint()
                        let day = try await Self.stepMotion(
                            for: civilDay, now: now, cached: motionCacheIn[civilDay.day], store: store,
                            devices: regDevices, activeId: regActiveId, registry: registry,
                            fallbackDeviceId: stepsFallbackId)
                        if let entry = day.entry { motionCache[civilDay.day] = entry }
                        if day.hit { cacheHits += 1 }
                        if day.motion > 0 { motion[civilDay.day] = day.motion }
                    }
                    return StepsCalibrationGather(refSteps: refSteps, motion: motion,
                                                  motionCache: motionCache, cacheHits: cacheHits)
                }
                let gathered: StepsCalibrationGather
                do {
                    if writesStopOnCancel {
                        gathered = try await CooperativeAnalysisCancellation.runDetached(operation: gather)
                    } else {
                        // A migration chunk is past its first write here and runs to completion (see
                        // `writesStopOnCancel`), so its gather is not cancelled with the grant.
                        gathered = try await Task.detached(priority: .utility, operation: gather).value
                    }
                } catch is CancellationError {
                    performanceChangedRows = persistedMutationCount
                    return false
                } catch {
                    gathered = StepsCalibrationGather(refSteps: [:], motion: [:], motionCache: [:], cacheHits: 0)
                }
                stepMotionCache.merge(gathered.motionCache) { _, new in new }
                stepMotionCacheHits &+= gathered.cacheHits
                var estPts: [MetricPoint] = []
                for dm in dailies where gathered.refSteps[dm.day] == nil {
                    guard let motion = gathered.motion[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: calibration) else { continue }
                    estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
                    if stepsTraceActive {
                        diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                            + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                    }
                }
                if !estPts.isEmpty {
                    guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
                    persistedMutationCount += (try? await store.upsertMetricSeries(
                        estPts, deviceId: computedId)) ?? 0
                }
            }
        }

        // Drop any freshly-detected session that overlaps a night the user has already hand-corrected.
        // A detected onset can drift second-to-second as more raw data arrives, so without this the
        // re-detected night would upsert as a SECOND row beside the edited one (different startTs ⇒ no
        // ON CONFLICT match), and mergeDay would DOUBLE-COUNT both into an inflated time-in-bed. The
        // edited row is already stored (preserved by the upsert guard), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this is the
        // idempotency guard for the edited case. (#318)
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        // #68: also drop any re-detected night the user has DELETED , a dismissedSleep tombstone keeps it
        // from regenerating, mirroring the dismissed-WORKOUT guard above. Overlap (not exact startTs)
        // because a re-detected onset drifts as more raw data arrives. (Android twin: dismissedWindows.)
        let dismissedWindows = repo.dismissedSleepWindows()
        let skipWindows = editedWindows + dismissedWindows
        let preSleepOwnerByDay = readOwnerByDay.mapValues { $0.owner }
        let exactPreSleepIdentityBefore: [String: PreSleepBoundaryIdentity]?
        if sourceContext != nil {
            do {
                exactPreSleepIdentityBefore = try await currentPreSleepBoundaryIdentities(
                    store: store,
                    civilDays: civilDays,
                    ownerByDay: preSleepOwnerByDay,
                    computedId: computedId,
                    editedRowsSourceId: editedRowsSourceId,
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    habitualMidsleepSec: habitualMidsleepSec,
                    timeZone: analysisTimeZone
                )
            } catch {
                NSLog("IntelligenceEngine: exact pre-sleep boundary snapshot failed: \(error)")
                return false
            }
        } else {
            exactPreSleepIdentityBefore = nil
        }
        let cachedSleepKept = cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        if !cachedSleepKept.isEmpty {
            do {
                guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
                persistedMutationCount += try await store.upsertSleepSessions(
                    cachedSleepKept, deviceId: computedId)
            } catch {
                NSLog("IntelligenceEngine: sleep-session persistence failed: \(error)")
                return false
            }
        }
        // Sleep persistence is the last possible writer of the boundary used by the optional observation.
        // Re-read it after the write: exact-source work scrubs days whose authority changed, while normal
        // work rejects an observation produced from a boundary that a concurrent edit has already replaced.
        // Do not honor cancellation between the session write and this fail-closed integrity boundary.
        guard let preSleepPostUpsertChanges = await enforcePreSleepBoundaryPostconditionFailClosed(
            store: store,
            civilDays: civilDays,
            ownerByDay: preSleepOwnerByDay,
            computedId: computedId,
            editedRowsSourceId: editedRowsSourceId,
            windowStart: windowStart,
            windowEnd: windowEnd,
            habitualMidsleepSec: habitualMidsleepSec,
            timeZone: analysisTimeZone,
            exactIdentityBefore: exactPreSleepIdentityBefore,
            generatedObservations: preSleepObservationByDay
        ) else {
            performanceChangedRows = persistedMutationCount
            return false
        }
        persistedMutationCount += preSleepPostUpsertChanges
        // ── Persist per-epoch motion (H8) beside each kept session's stagesJSON ──────────────────────────
        // The sleepSession rows exist now (just upserted), so the targeted motion UPDATE lands. Persist ONLY
        // for the sessions actually kept (not edited/dismissed), keyed by the detected start `analyzeDay`
        // returned. A session whose gravity wouldn't grid was omitted from the map and is left as NULL , an
        // absent motion series stays absent, never a fabricated zero array.
        let keptStarts = Set(cachedSleepKept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        // ── Persist per-epoch BAND sleep_state (#175) beside each kept session's stagesJSON ──────────────
        // This is the source `sessionSleepStateJSON` lacked (v7.7.0 finding: the write path had no producer
        // because the raw stream was dropped at extraction). Now analyzeDay grids the RAW `sleepStateSample`
        // stream per session; persist it here so the NEXT pass's `bandSleepStateSamples` read (the H7 confirm)
        // and the display can see the strap's OWN scored band. ONLY for kept (not edited/dismissed) sessions;
        // a session with no band samples was omitted (no key) and stays NULL — an absent signal stays absent.
        var sleepStateByStart: [Int: [Int]] = [:]
        for night in scoredNights {
            for (start, states) in night.sessionSleepState where keptStarts.contains(start) {
                sleepStateByStart[start] = states
            }
        }
        // ── Overlap-aware banked-sleep heal (#899) ────────────────────────────────────────────────────
        // An unstable strap clock re-banks the SAME night under a shifted timebase, so successive passes
        // detect it at shifted bounds and the upsert above lands a SECOND row beside the stale one (the
        // (deviceId, startTs) key differs, and sleep has no delete-reinsert reconcile like dailyMetric /
        // workout). Collapse the window's stored sessions with the overlap rule, treating the rows THIS
        // pass just banked as the bank-recency witness (the strap's current timebase), and delete the
        // stale copies. Scoped to sessions whose wake day lies inside the [oldestDay, newestDay] daily
        // reconcile window: exactly the days this pass re-scored/evicted, so a session row is never
        // deleted out from under a daily row the pass did not refresh. Edited rows are never dropped.
        let storedSessions: [CachedSleepSession]
        do {
            storedSessions = try await store.sleepSessions(
                deviceId: computedId, from: windowStart, to: windowEnd, limit: 4000)
        } catch {
            NSLog("IntelligenceEngine: sleep reconciliation read failed: \(error)")
            return false
        }
        let healable = storedSessions.filter {
            $0.endTs >= oldestCivilDay.start && $0.endTs < newestCivilDay.nextStart
        }
        let healDropped = SleepSessionDedup.dedupe(healable, freshStarts: keptStarts).dropped
        do {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            let auxResult = try await store.applySleepAuxiliaryMutations(
                deviceId: computedId,
                motionByStart: motionByStart,
                sleepStateByStart: sleepStateByStart,
                deletingSessionStarts: healDropped.map(\.startTs))
            persistedMutationCount += auxResult.totalChanged
        } catch {
            NSLog("IntelligenceEngine: sleep auxiliary reconciliation failed: \(error)")
            return false
        }
        if !healDropped.isEmpty {
            // The auxiliary transaction can delete an overlapping stored session after the first check.
            // Verify again so a changed main-night survivor cannot retain either canonical or orphaned
            // pre-sleep rows, including on the bounded heal-rearm return below.
            guard let preSleepPostHealChanges = await enforcePreSleepBoundaryPostconditionFailClosed(
                store: store,
                civilDays: civilDays,
                ownerByDay: preSleepOwnerByDay,
                computedId: computedId,
                editedRowsSourceId: editedRowsSourceId,
                windowStart: windowStart,
                windowEnd: windowEnd,
                habitualMidsleepSec: habitualMidsleepSec,
                timeZone: analysisTimeZone,
                exactIdentityBefore: exactPreSleepIdentityBefore,
                generatedObservations: preSleepObservationByDay
            ) else {
                performanceChangedRows = persistedMutationCount
                return false
            }
            persistedMutationCount += preSleepPostHealChanges
            diagnosticSink?("Dedup(#899): removed \(healDropped.count) overlapping duplicate sleep "
                + "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.", nil)
            // Re-score against the cleaned store via the existing #899-A re-arm: the days scored THIS
            // pass consumed the read-side deduped view, but that view had no bank-recency witness (the
            // fresh detections weren't banked yet), so its survivor can differ from the heal's. One
            // forced re-pass reconciles them. HARD-BOUNDED: if the re-pass's own heal drops rows
            // again (detection oscillating under its own feedback), it does NOT re-arm a second time,
            // matching the Android one-re-pass bound; the budget restores once a pass heals nothing.
            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                // The admitted batch must replay its exact window and durable postcondition. Return
                // non-completion instead of spawning an unstructured default analysis task.
                performanceChangedRows = persistedMutationCount
                return false
            }
        } else {
            healRearmedThisCycle = false
        }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts in the
        // scored window (a bout's startTs can drift as more HR arrives, which would otherwise orphan
        // stale rows under the (deviceId,startTs,sport) key), then re-insert.
        do {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            // Review round 7 (1): a migration chunk keeps the detected workouts of the days it keeps, and of the
            // older chunk's evening before its window, which that chunk reconciles itself. A stored bout this
            // pass re-detected (overlapping a produced row) is replaced, not duplicated.
            var keptWorkoutRows: [WorkoutRow] = []
            if keepUnproducedHistory {
                let keptWindows = civilDays.filter { historyKeepDays.contains($0.day) }
                keptWorkoutRows = try await store.workouts(
                    deviceId: computedId, from: windowStart, to: windowEnd, limit: 10_000
                ).filter { row in
                    (row.source == computedId || row.source == "detected")
                        && (row.startTs < oldestCivilDay.start
                            || keptWindows.contains { row.startTs >= $0.start && row.startTs < $0.nextStart })
                        && !workoutRows.contains { $0.startTs < row.endTs && row.startTs < $0.endTs }
                }
            }
            let workoutResult = try await store.reconcileDetectedWorkouts(
                workoutRows + keptWorkoutRows, deviceId: computedId, from: windowStart, to: windowEnd)
            persistedMutationCount += workoutResult.totalChanged
        } catch {
            NSLog("IntelligenceEngine: detected-workout reconciliation failed: \(error)")
            return false
        }

        // #137: a manually-started workout is scored from sparse live HR at save time , near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
        let measuredRestingHRByDay: [ManualWorkoutRescore.DailyRestingHR] = civilDays.compactMap { window in
            guard let restingHR = out.first(where: { $0.day == window.day })?.rhr,
                  let owner = readOwnerByDay[window.day]?.owner else { return nil }
            return .init(
                sourceId: owner,
                startTs: window.start,
                endTs: window.nextStart,
                restingHR: Double(restingHR)
            )
        }
        persistedMutationCount += await rescoreManualWorkouts(
            store: store,
            profile: up,
            dailyRestingHR: measuredRestingHRByDay
        )

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your recovery, effort and rest itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately. A heal-only
        // pass (#899 dedup deleted stale session rows but no daily changed) must refresh too, so the
        // Sleep tab stops showing the removed duplicates right away.
        if persistedMutationCount > 0 && refreshRepository {
            guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
            _ = await repo.refresh(.currentDay)
        }
        performanceChangedRows = persistedMutationCount

        // #836: record the raw-HR fingerprint this run scored against, so a later NON-forced tick can
        // short-circuit while it's unchanged. Written ONLY here at the end of a completed run (never on an
        // early guard-return), so an interrupted/failed run can't advance the watermark past unscored data.
        guard !(writesStopOnCancel && Task.isCancelled) else { performanceChangedRows = persistedMutationCount; return false }
        if sourceContext == nil {
            // Pruning happens only here, after the complete pass: `nextCache` contains exactly the eligible
            // days in this active civil-day window. A failed/cancelled pass leaves the prior cache untouched.
            dayScanCache = scanPass.nextCache
            dayScanCacheConfigSignature = cacheConfigSignature
        }
        diagnosticSink?("analyzeRecent dayCache reused=\(scanPass.reused)/\(scanPass.eligible) "
            + "size=\(sourceContext == nil ? dayScanCache.count : 0)", nil)
        if !wmKey.isEmpty { UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey) }
        analysisCompletionSerial += 1
        return true
    }

    /// UserDefaults key for the #836 idle-tick gate: the `(count:maxTs)` HR fingerprint the last completed
    /// `analyzeRecent` scored against. A non-forced tick whose current fingerprint equals this skips the
    /// 21-day rescore; cleared implicitly by any HR insert/delete (the fingerprint moves), so it self-heals.
    private static let analyzeWatermarkKey = "noop.analyzeWatermark"
    /// The window the 15-minute backstop's watermark covers. The tick itself scores today only: the serialized
    /// `analyzeRecent(force:)` shorthand passes `maxDays: 1`.
    static let backstopWindowDays = 21

    /// The backstop window's raw-HR change witness (DL-02): row count and newest timestamp per candidate
    /// owner over the read window the tick scores, plus the scan version and the hour. Empty when a read
    /// fails, so the gate never skips on an unreadable store.
    /// Review round 3 (D): today's calorie total fills resting energy up to now (D3b), so it must rise while the
    /// strap is off-wrist and no heart rate arrives. The hour term lets the first tick of each hour run; the
    /// tick's pass is today only (`analyzeRecent(force:)` passes `maxDays: 1`), plus yesterday once if its
    /// total was filled only part of the way (review round 4, 2).
    private func analyzeWatermark(store: WhoopStore, reference: Date, calendar: Calendar) async -> String {
        let days = Self.civilDayWindows(reference: reference, startOffset: 0,
                                        count: Self.backstopWindowDays, calendar: calendar)
        guard let oldest = days.last else { return "" }
        let from = oldest.start - 30 * 3_600
        let to = Int(reference.timeIntervalSince1970)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        var owners: Set<String> = [deviceId]
        if let active = try? registry.activeDeviceId() { owners.insert(active) }
        for device in (try? registry.all()) ?? [] { owners.insert(device.id) }
        var parts: [String] = []
        for owner in owners.sorted() {
            guard let fingerprint = try? await store.hrFingerprint(deviceId: owner, from: from, to: to) else {
                return ""
            }
            parts.append("\(owner)=\(fingerprint.count):\(fingerprint.maxTs)")
        }
        return parts.joined(separator: "|") + "|\(Self.analyzeScanVersion)"
            + "|h\(Int(reference.timeIntervalSince1970) / Self.todayFillTickSeconds)"
    }

    /// How often an idle backstop tick re-scores today's calorie fill (review round 3, D).
    static let todayFillTickSeconds = 3_600

    /// CAPTURE-B (#814/#799): build the universal `dayOwner …` self-diagnostic line VERBATIM (the Test
    /// Centre export parser depends on this exact shape). `readId` is the owner this day was read+scored
    /// from; `writeActiveId` is the registry's active id the Collector writes raw under; a DIVERGENCE on a
    /// day with HR rows is the #814 read/write split. `provenance` is `imported:whoop` / `imported:apple`
    /// when an export covers the day, else `measured` when the owner returned HR rows, else `none`. Pure +
    /// nonisolated so it's unit-tested directly and so the format can never silently drift. No PII (the ids
    /// are local "my-whoop" / "whoop-…" / import tokens; LiveState.append also scrubs).
    nonisolated static func dayOwnerLine(day: String, readId: String, writeActiveId: String,
                                         hrRows: Int, importedWhoop: Bool, importedApple: Bool) -> String {
        let provenance: String
        if importedWhoop { provenance = "imported:whoop" }
        else if importedApple { provenance = "imported:apple" }
        else if hrRows > 0 { provenance = "measured" }
        else { provenance = "none" }
        return "dayOwner day=\(day) readId=\(readId) writeActiveId=\(writeActiveId) "
            + "hrRows=\(hrRows) provenance=\(provenance)"
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source , never a mix. Builds one `DayOwnerResolver.Candidate` per non-archived device with a
    /// priority (0 = the active strap, 1 = other live straps, 2 = imports; lower wins) and a CHEAP
    /// per-day presence flag (one `LIMIT 1` HR read per device), then applies any locked override from
    /// the dayOwnership table. Returns `deviceId` when the registry yields no owner (no candidate has
    /// data, or it's empty/unreadable) so the legacy single-source path is preserved.
    ///
    /// Single-device install: the only paired row is the seeded active 'my-whoop' (== `fallbackDeviceId`).
    /// Its candidate is priority 0 with `hasData == true` for any day the strap collected HR, so the
    /// resolver returns `fallbackDeviceId` and the caller's reads are byte-identical to the pre-I2 code.
    /// The presence check is the same `LIMIT 1` over the same window the caller already reads.
    ///
    /// `nonisolated static` (FIX 1): the body touches NO `@Published`/instance-isolated state , only the
    /// passed-in `store` actor, the nonisolated `registry` struct, the value params, and `fallbackDeviceId`
    /// (the former `self.deviceId`). Making it `nonisolated` lets the off-main scan loop call it WITHOUT
    /// hopping back to the main actor each iteration, which is the whole point of FIX 1. Logic identical.
    ///
    /// Review round 6: `completedDay` is the day's own civil window when the day is over (callers pass nil for
    /// today). A new strap's first readings late on the day before a swap made it the owner by priority, and the
    /// day, scored from that sliver, fell below the raw loop's 200-row gate and lost its row, so a completed day's
    /// owner is checked against the readings in that window. Each count is one indexed aggregate bounded by the
    /// one-day window. When no strap reaches the gate, the priority owner keeps the day.
    ///
    /// Review round 7 (1): an archived strap still owns the completed days it recorded, so a full-history
    /// rescore scores them from its rows instead of from the live strap's empty window. Today's priority rule
    /// still leaves archived straps out.
    ///
    /// Review round 7 (2): the priority owner keeps a completed day whenever its own plausible readings (30 to
    /// 240 bpm, plus PPG) reach the gate in that day. Only when it misses does the strap with the most plausible
    /// rows take the day, so a second strap worn alongside, a long chest-strap session or an off-wrist strap's
    /// 0 bpm stream can't take a day the active strap covered.
    ///
    /// Review round 8 (1): that early keep is the active strap's only. A lower-priority owner, such as a paired
    /// chest strap with an hour's session, competes on plausible rows with every completed-day candidate (live
    /// and archived straps and sources, the priority owner included), so an archived strap that recorded the
    /// whole day keeps it.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String,
                                            completedDay: CivilDayWindow? = nil) async -> String {
        // A locked override wins outright and skips the presence checks entirely.
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        // No registry rows (shouldn't happen , v15 seeds one , but be safe): keep the legacy id.
        guard !devices.isEmpty else { return fallbackDeviceId }

        let liveDevices = devices.filter { $0.status != .archived }
        let completedDayStraps = completedDay == nil ? [] : devices.filter {
            !$0.isImportSource && $0.sourceKind != .activityFile
        }
        // #970: the default single-WHOOP install has exactly one live device that IS the fallback id, so
        // the owner is a foregone conclusion — the resolver returns that id whether or not it has data in
        // this window (active priority 0 -> its id; or no candidate has data -> nil -> fallbackDeviceId,
        // both == fallbackDeviceId here). Skip the per-day LIMIT-1 HR probe in that case (called once per
        // scanned day, so it saves ~maxDays tiny reads per analyzeRecent). Byte-identical to the loop. The
        // guard is deliberately `== fallbackDeviceId`: a lone IMPORT device whose id differs would NOT be
        // byte-identical (no-data -> fallback, not its own id), so it must still take the probe path.
        if liveDevices.count == 1, liveDevices[0].id == fallbackDeviceId,
           !completedDayStraps.contains(where: { $0.status == .archived }) {
            return fallbackDeviceId
        }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in liveDevices {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            // #137: an activity-file ride ranks BELOW whole-day imports (priority 3 vs 2), so a full-day
            // WHOOP CSV/cloud import keeps ownership of a day it has HR for; the ride only wins a day that
            // nothing else covers (a strap-less day). Kotlin RegistryDayOwnerSource mirrors this ordering.
            let priority: Int
            if d.id == activeId { priority = 0 }
            else if d.sourceKind == .activityFile { priority = 3 }
            else if isImport { priority = 2 }
            else { priority = 1 }
            // Cheap presence check: a single HR row for this device in the night window is enough to
            // mark it a candidate. (LIMIT 1 , not the full pull the caller does once an owner is chosen.)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        let priorityOwner = DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates)
            ?? fallbackDeviceId
        guard let completedDay else { return priorityOwner }
        func plausibleRows(_ deviceId: String, cap: Int) async -> Int {
            (try? await store.plausibleHRCount(
                deviceId: deviceId, from: completedDay.start, to: completedDay.nextStart - 1,
                bpmRange: HRValidity.bpmRange, cap: cap)) ?? 0
        }
        if priorityOwner == activeId,
           await plausibleRows(priorityOwner, cap: rawLoopMinHrRows) >= rawLoopMinHrRows {
            return priorityOwner
        }
        // The priority owner is counted first, so it keeps a tie.
        var best: (deviceId: String, rows: Int)?
        for id in [priorityOwner] + completedDayStraps.map(\.id).filter({ $0 != priorityOwner }) {
            let rows = await plausibleRows(id, cap: completedDay.nextStart - completedDay.start)
            guard rows >= rawLoopMinHrRows, rows > (best?.rows ?? 0) else { continue }
            best = (id, rows)
        }
        return best?.deviceId ?? priorityOwner
    }

    /// The start offset of the oldest stored computed day before today whose calorie total was filled only part of
    /// the way through the day (review round 4, 2; round 5, 2; round 6, 2). Every day with a total in the
    /// `calorieFillCatchUpDays` days before today is checked, with one range read of the rows and one of the fill
    /// markers, so a newer day an exact pass finished can't hide an older unfinished one. A row from before the
    /// fill marker counts as unfinished, so it is finished once.
    private func unfinishedCalorieFillOffset(store: WhoopStore, reference: Date,
                                             calendar: Calendar) async -> Int? {
        let windows = Self.civilDayWindows(
            reference: reference, startOffset: 1, count: Self.calorieFillCatchUpDays, calendar: calendar)
        guard let newest = windows.first, let oldest = windows.last else { return nil }
        let computedId = deviceId + "-noop"
        guard let rows = try? await store.dailyMetrics(deviceId: computedId, from: oldest.day, to: newest.day),
              let markers = try? await store.metricSeries(
                deviceId: computedId, key: Self.calorieFillEndMetricKey, from: oldest.day, to: newest.day)
        else { return nil }
        let daysWithTotal = Set(rows.compactMap { $0.activeKcalEst != nil ? $0.day : nil })
        let fillEndByDay = Dictionary(markers.map { ($0.day, $0.value) }, uniquingKeysWith: { a, _ in a })
        return windows.indices.last { index in
            let window = windows[index]
            return daysWithTotal.contains(window.day)
                && (fillEndByDay[window.day].map { $0 < Double(window.nextStart) } ?? true)
        }.map { $0 + 1 }
    }

    /// One day's breakdown as metric points (review round 4, 3).
    nonisolated static func chargeBreakdownPoints(_ breakdown: StoredChargeBreakdown) -> [MetricPoint] {
        let day = breakdown.day
        var points = [MetricPoint(day: day, key: chargeBreakdownScoreKey, value: breakdown.score)]
        if let index = chargeBreakdownConfidences.firstIndex(of: breakdown.confidence) {
            points.append(MetricPoint(day: day, key: chargeBreakdownConfidenceKey, value: Double(index)))
        }
        for driver in breakdown.drivers {
            guard let term = driver.term, let value = driver.value else { continue }
            points.append(MetricPoint(day: day, key: chargeBreakdownKey(term, "points"),
                                      value: Double(driver.deltaPoints)))
            points.append(MetricPoint(day: day, key: chargeBreakdownKey(term, "value"), value: value))
            if let baseline = driver.baseline {
                points.append(MetricPoint(day: day, key: chargeBreakdownKey(term, "baseline"), value: baseline))
            }
        }
        return points
    }

    /// The breakdown `points` (one day's) encode, or nil without a stored score.
    nonisolated static func chargeBreakdown(day: String, points: [MetricPoint]) -> StoredChargeBreakdown? {
        let byKey = Dictionary(points.filter { $0.day == day }.map { ($0.key, $0.value) },
                               uniquingKeysWith: { a, _ in a })
        guard let score = byKey[chargeBreakdownScoreKey] else { return nil }
        let confidence = byKey[chargeBreakdownConfidenceKey].flatMap { value -> ScoreConfidence? in
            let index = Int(value)
            return chargeBreakdownConfidences.indices.contains(index) ? chargeBreakdownConfidences[index] : nil
        } ?? .calibrating
        let drivers = ChargeDriverTerm.allCases.compactMap { term -> ChargeDriver? in
            guard let points = byKey[chargeBreakdownKey(term, "points")],
                  let value = byKey[chargeBreakdownKey(term, "value")] else { return nil }
            return RecoveryScorer.chargeDriver(term: term, deltaPoints: Int(points), value: value,
                                               baseline: byKey[chargeBreakdownKey(term, "baseline")])
        }
        return StoredChargeBreakdown(day: day, score: score, confidence: confidence,
                                     drivers: RecoveryScorer.orderedByImpact(drivers))
    }

    /// Review round 4 (3): the stored breakdown of `day`'s Charge, or nil when that day has none.
    func storedChargeBreakdown(day: String) async -> StoredChargeBreakdown? {
        guard let store = await repo.storeHandle() else { return nil }
        let computedId = deviceId + "-noop"
        var points: [MetricPoint] = []
        for key in Self.chargeBreakdownKeys {
            guard let rows = try? await store.metricSeries(deviceId: computedId, key: key, from: day, to: day)
            else { return nil }
            if key == Self.chargeBreakdownScoreKey, rows.isEmpty { return nil }
            points += rows
        }
        return Self.chargeBreakdown(day: day, points: points)
    }

    /// The start of civil day `day` ("yyyy-MM-dd") in `calendar`'s time zone.
    nonisolated static func civilDayStart(_ day: String, calendar: Calendar) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return Int(date.timeIntervalSince1970)
    }

    /// A WHOOP 4.0 nightly mean (°C under `anchorRaw`) as the raw register value it maps from (review round 3, B).
    nonisolated static func whoop4SkinRaw(celsius: Double, anchorRaw: Double) -> Double {
        anchorRaw + (celsius - Whoop4SkinTemp.anchorCelsius) / Whoop4SkinTemp.provisionalSlopeCPerRaw
    }

    /// A WHOOP 4.0 strap's physical identity for its stored skin nights (review round 5, 4): the registry owner
    /// plus the BLE peripheral the owner had adopted, empty before one is. A replacement strap that takes over a
    /// registry id adopts a new peripheral, so its nights get their own identity and anchor.
    /// Limit (review round 6, 3): the same strap rebound to a new peripheral (a new or restored iPhone gives it a
    /// new CoreBluetooth identifier) also gets a new identity, splitting its nights into two anchor frames. For
    /// one strap the two anchors are close, so the error is small and fades over the skin fold's 14-night
    /// half-life. Telling a phone change from a replacement needs an explicit replacement signal or the strap's
    /// serial, neither of which the registry has.
    nonisolated static func whoop4SkinIdentity(owner: String, peripheralId: String?) -> String {
        owner + "|" + (peripheralId ?? "")
    }

    /// The registry owner of a stored identity. A key from before identities (review round 4) is the owner alone.
    nonisolated static func whoop4SkinOwner(identity: String) -> String {
        identity.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            ?? identity
    }

    /// The inverse: a persisted WHOOP 4.0 raw mean in °C under `anchorRaw`, the same map the funnel applies.
    nonisolated static func whoop4SkinCelsius(raw: Double, anchorRaw: Double) -> Double {
        Whoop4SkinTemp.anchorCelsius + (raw - anchorRaw) * Whoop4SkinTemp.provisionalSlopeCPerRaw
    }

    /// The strap family that wrote `owner`'s skin-temp rows (#938), so the nightly funnel converts the raw
    /// register on the right scale. The model-label → family mapping (and the `.whoop5` fallback for
    /// unknowns) lives in `DeviceFamily.forRegistryModel` (#171).
    nonisolated static func skinTempFamily(forOwner owner: String, devices: [PairedDevice]) -> DeviceFamily {
        DeviceFamily.forRegistryModel(devices.first(where: { $0.id == owner })?.model)
    }

    /// Persist a collision backfill in the namespace that owns the real row's natural key. The scoring
    /// loop intentionally combines canonical WHOOP and Apple Health rows for de-duplication; using the
    /// active device id here would create a cross-source duplicate instead of enriching the collider.
    private func upsertRealWorkout(_ row: WorkoutRow, owningDeviceId: String,
                                   store: WhoopStore) async throws {
        _ = try await store.upsertWorkouts([row], deviceId: owningDeviceId)
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync , once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories), and only when the recompute is a genuine improvement , so a well-scored
    /// 4.0 workout is never touched and a still-sparse window is a no-op.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile,
                                       dailyRestingHR: [ManualWorkoutRescore.DailyRestingHR] = []) async -> Int {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 24 * 60 * 60
        let hrMax = Double(profile.hrMax)
        // Preserve the original canonical rescore even when a day has no measured RHR. Also include any
        // pass-one owner that supplied a measured RHR. Every workout row, HR sample, RHR, and upsert stays
        // inside one source namespace; a re-pair can therefore never mix an active strap's RHR into the
        // canonical strap's workout.
        let sourceIds = Set([deviceId] + dailyRestingHR.map(\.sourceId)).sorted()
        var totalChanged = 0
        for sourceId in sourceIds {
            guard let rows = try? await store.workouts(
                deviceId: sourceId, from: since, to: now, limit: 200
            ) else { continue }
            var updated: [WorkoutRow] = []
            // A manual row is eligible when it looks under-scored (negligible kcal, #137) OR it's missing
            // strain (the merged-workout case, where kcal is the SUM of inputs so it never looks under-scored
            // yet Effort stays blank forever). `improves` then accepts a strain-only gain for the latter.
            for row in rows where row.source == "manual"
                && (ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) || row.strain == nil) {
                let restingHR = ManualWorkoutRescore.restingHR(
                    forWorkoutStartingAt: row.startTs,
                    sourceId: sourceId,
                    daily: dailyRestingHR,
                    hrMax: hrMax
                )
                guard let samples = try? await store.hrSamples(
                    deviceId: sourceId, from: row.startTs, to: row.endTs, limit: 20_000
                ),
                      let s = ManualWorkoutRescore.scored(
                        windowSamples: samples, profile: up, hrMax: hrMax, restingHR: restingHR,
                        pauses: WorkoutPauseStore.load(startTs: row.startTs, sport: row.sport)
                      ),
                      ManualWorkoutRescore.improves(
                        s, over: row.energyKcal, currentStrain: row.strain, allowStrainOnlyFill: true
                      )
                else { continue }
                // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
                // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
                let kcalBeatsStored = (s.kcal ?? 0) > (row.energyKcal ?? 0)
                    + ManualWorkoutRescore.improvementMarginKcal
                let energyKcal = kcalBeatsStored ? s.kcal : row.energyKcal
                updated.append(WorkoutRow(
                    startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                    durationS: row.durationS, energyKcal: energyKcal, avgHr: s.avgHr, maxHr: s.maxHr,
                    strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes,
                    strainVersion: s.strain == nil ? row.strainVersion : 2))
            }
            guard !updated.isEmpty else { continue }
            totalChanged += (try? await store.upsertWorkouts(updated, deviceId: sourceId)) ?? 0
        }
        return totalChanged
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) , so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines,
                                   sleepQuality: Double?) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation. Both come from the persisted daily
        // fields (the raw streams are gone in pass 2). (Charge/Effort/Rest scoring redesign.)
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: sleepQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// The ordered "what shaped it" Charge driver list for one day (SHARED CONTRACT). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` reads (the SAME `restQuality` derivation) into
    /// `RecoveryScorer.chargeDrivers`, whose per-term deltas come from `RecoveryScorer.recovery` verbatim, so
    /// the rows can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing or the baseline isn't usable yet, mirroring `recomputeRecovery`'s
    /// own early-nil so a cold-start night shows the calibrating state rather than fabricated rows.
    private func recomputeChargeDrivers(_ daily: DailyMetric,
                                        _ baselines: AnalyticsEngine.ProfileBaselines,
                                        sleepQuality: Double?) -> [ChargeDriver] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return []
        }
        return RecoveryScorer.chargeDrivers(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                            respBaseline: baselines.resp, sleepPerf: sleepQuality,
                                            skinTempDev: daily.skinTempDevC)
    }

    /// The Charge term-breakdown trace lines for one day (Recovery test mode, Group G). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` does (the SAME `restQuality` derivation) into RecoveryScorer's
    /// side-effect-free `recoveryTrace`, whose returned score IS `RecoveryScorer.recovery` verbatim, so the
    /// trace can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing, mirroring `recomputeRecovery`'s own early-nil. Only CALLED
    /// when `TestCentre.active(.recovery)` is true, so it costs nothing when the mode is off.
    private func recoveryTraceLines(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines,
                                    sleepQuality: Double?) -> [String] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return ["charge day=\(daily.day) nilScore reason=missingInput "
                + "(hrv/rhr/hrvBaseline required)"]
        }
        let (_, trace) = RecoveryScorer.recoveryTrace(
            hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp, sleepPerf: sleepQuality,
            skinTempDev: daily.skinTempDevC)
        // Prefix each line with the day key so a multi-night export stays parseable, matching the sleep
        // trace's per-day shape. Strip ONLY the leading "charge " token the trace builder writes (every
        // line starts with it), then re-emit as "charge day=<day> ...".
        return trace.map { line in
            let body = line.hasPrefix("charge ") ? String(line.dropFirst("charge ".count)) : line
            return "charge day=\(daily.day) " + body
        }
    }

    /// One day's watch-derived recovery output, keyed by day.
    struct WatchScoredDay: Equatable {
        let day: String
        let recovery: Double?
        let confidence: ScoreConfidence
        var drivers: [ChargeDriver] = []
    }

    /// Compute Apple-Watch recovery (Charge) for the apple-health days that lack a strap recovery.
    ///
    /// The Apple Watch gives DAILY aggregates (an SDNN HRV reading + a resting HR), not a WHOOP-density raw
    /// stream, so the normal `analyzeRecent` raw-HR path (`hr.count >= 200`) never scores these days and the
    /// import leaves `recovery: nil`. This fills that one gap: for each apple-health day it folds the TRAILING
    /// SDNN + RHR history (every earlier apple-health day's `avgHrv` / `restingHr`) into the cross-lane
    /// `WatchRecovery` engine, which mirrors our Charge recovery shape but reads Apple's daily values. It stays
    /// nil + `.calibrating` until there are enough usable nights of HRV baseline, so we never fabricate a number.
    ///
    /// `strapRecoveryDays` are the days a strap (WHOOP / computed) already scored a recovery , those are SKIPPED
    /// so the strap keeps winning (matching the source precedence; we never overwrite a strap recovery with a
    /// lower-density watch one). Pure (no store) so it's unit-tested directly and is the SAME logic
    /// `analyzeRecent` ships. `appleRows` must be chronological (oldest first).
    /// DL-12: one pass over the history (`WatchRecovery.scoreHistory`), not a full re-fold per day, and the
    /// manual recalibration epochs are honoured. Each day still sees only the days before it.
    nonisolated static func watchRecoveries(appleRows: [DailyMetric],
                                strapRecoveryDays: Set<String> = [],
                                hrvEpoch: Double = Baselines.hrvBaselineEpoch(),
                                recoveryEpoch: Double = Baselines.recoveryBaselineEpoch()) -> [WatchScoredDay] {
        WatchRecovery.scoreHistory(
            appleRows.map { WatchRecovery.Day(day: $0.day, sdnn: $0.avgHrv, rhr: $0.restingHr) },
            hrvEpoch: hrvEpoch, recoveryEpoch: recoveryEpoch)
            .filter { !strapRecoveryDays.contains($0.day) }
            .map { WatchScoredDay(day: $0.day, recovery: $0.result.recovery, confidence: $0.result.confidence,
                                  drivers: $0.result.drivers) }
    }

    /// Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
    /// night's blocks was edited. Substitutes each edited block (matched by its stable startTs) for its
    /// detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped stages, so
    /// the Rest composite and recovery score the corrected sleep , not the auto-detected window. No edit
    /// touching the night → the detected daily is returned unchanged. (#318)
    /// #299: the edited / hand-logged sleep rows that belong to one civil day — the ones whose edits may be
    /// folded into THAT day's sleep total. An edit belongs to the day its night ENDS on, matching
    /// AnalyticsEngine's end-day session bucket; `endTs` is stable under a bedtime edit (only the onset
    /// moves). Scoping this per day is the fix: the edit set was built window-wide and `sleepEditedDaily`
    /// folds any row that isn't a twin of a day's detected sessions in as a "manual" block, so one edit / nap
    /// leaked its total onto EVERY night. `dayWindow` is the civil day `[start, nextStart)` (AN-02): a fixed
    /// offset dropped an edit ending in the first hour of a fall-back day. nil (a day outside the pass) → no
    /// rows. Twin of Android `IntelligenceEngine.editedRowsForDay`.
    nonisolated static func editedRowsForDay(_ editedRows: [CachedSleepSession],
                                             dayWindow: Range<Int>?) -> [CachedSleepSession] {
        guard let dayWindow else { return [] }
        return editedRows.filter { dayWindow.contains($0.endTs) }
    }

    /// User-edited computed sleep belongs to one raw source. Apply it only when that source owns the
    /// scored day; a locked canonical day must not inherit bounds edited under a newly paired strap.
    nonisolated static func editedRowsForOwnerDay(
        _ editedRows: [CachedSleepSession],
        rowsSourceId: String,
        owner: String?,
        dayWindow: Range<Int>?
    ) -> [CachedSleepSession] {
        guard owner == rowsSourceId else { return [] }
        return editedRowsForDay(editedRows, dayWindow: dayWindow)
    }

    /// Stable, locale-free cache witness for the only stored sleep fields used by the new descriptive
    /// shadows. Sort first so a database row-order change cannot invalidate an otherwise identical day.
    nonisolated static func sleepEditFingerprint(_ rows: [CachedSleepSession]) -> String {
        rows.sorted {
            if $0.startTs != $1.startTs { return $0.startTs < $1.startTs }
            if $0.effectiveStartTs != $1.effectiveStartTs {
                return $0.effectiveStartTs < $1.effectiveStartTs
            }
            return $0.endTs < $1.endTs
        }.map {
            "\($0.startTs):\($0.effectiveStartTs):\($0.endTs)"
        }.joined(separator: ",")
    }

    /// Stable cache witness for imported sleep bounds used as the descriptive shadow fallback.
    nonisolated static func persistedSleepFingerprint(_ rows: [CachedSleepSession]) -> String {
        rows.sorted {
            if $0.effectiveStartTs != $1.effectiveStartTs {
                return $0.effectiveStartTs < $1.effectiveStartTs
            }
            if $0.endTs != $1.endTs { return $0.endTs < $1.endTs }
            return $0.startTs < $1.startTs
        }.map {
            "\($0.effectiveStartTs):\($0.endTs)"
        }.joined(separator: ",")
    }

    /// Exact-source maintenance can run through a separate engine instance. Keep the user-facing optional
    /// feedback on the shared normal-analysis lane so opt-out and publication have one admission gate.
    nonisolated static func preSleepFeedbackEnabled(optedIn: Bool, isExactSourceWork: Bool) -> Bool {
        optedIn && !isExactSourceWork
    }

    /// The only sleep identity persisted with optional pre-sleep feedback. A bridged main night owns the
    /// earliest onset and latest wake across its selected fragments, exactly as
    /// `PreSleepHeartRateFeedback.evaluate` records them.
    private struct PreSleepBoundaryIdentity: Equatable, Sendable {
        let startTs: Int
        let endTs: Int
    }

    private nonisolated static func preSleepBoundaryIdentity(
        sessions: [SleepSession],
        dayStart: Int,
        nextDayStart: Int,
        habitualMidsleepSec: Int?,
        timeZoneOffsetSeconds: Int
    ) -> PreSleepBoundaryIdentity? {
        let matched = sessions.filter {
            $0.end >= dayStart && $0.end < nextDayStart && $0.start < $0.end
        }
        let indices = SleepStageTotals.mainNightGroupIndices(
            matched.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) },
            offsetSec: timeZoneOffsetSeconds,
            habitualMidsleepSec: habitualMidsleepSec
        ) ?? []
        guard let start = indices.map({ matched[$0].start }).min(),
              let end = indices.map({ matched[$0].end }).max(),
              start < end else { return nil }
        return PreSleepBoundaryIdentity(startTs: start, endTs: end)
    }

    /// Re-read the sleep authority normal feedback would use after this pass's session writes. Imported/raw
    /// bounds win for a covered owner-day; the current computed source fills an empty imported day; and a
    /// user edit from the owning computed sibling substitutes its detected twin. Keeping this reconstruction
    /// beside `authoritativeShadowSleepSessions` prevents the final integrity check from inventing a second
    /// source-precedence rule.
    private func currentPreSleepBoundaryIdentities(
        store: WhoopStore,
        civilDays: [CivilDayWindow],
        ownerByDay: [String: String],
        computedId: String,
        editedRowsSourceId: String,
        windowStart: Int,
        windowEnd: Int,
        habitualMidsleepSec: Int?,
        timeZone: TimeZone
    ) async throws -> [String: PreSleepBoundaryIdentity] {
        let editedComputedId = editedRowsSourceId + "-noop"
        let computed = try await store.sleepSessions(
            deviceId: computedId, from: windowStart, to: windowEnd, limit: 4_000
        ).filter {
            SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
        }
        let editedComputed: [CachedSleepSession]
        if editedComputedId == computedId {
            editedComputed = computed.filter(\.userEdited)
        } else {
            editedComputed = try await store.sleepSessions(
                deviceId: editedComputedId, from: windowStart, to: windowEnd, limit: 4_000
            ).filter {
                $0.userEdited
                    && SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
            }
        }

        let fallbackOwner = deviceId
        let rawSourceIds = Set(civilDays.map { ownerByDay[$0.day] ?? fallbackOwner })
        var rawBySource: [String: [CachedSleepSession]] = [:]
        for sourceId in rawSourceIds.sorted() {
            rawBySource[sourceId] = try await store.sleepSessions(
                deviceId: sourceId, from: windowStart, to: windowEnd, limit: 4_000
            ).filter {
                SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
            }
        }

        func rows(_ sessions: [CachedSleepSession], in day: CivilDayWindow) -> [CachedSleepSession] {
            sessions.filter { $0.endTs >= day.start && $0.endTs < day.nextStart }
        }

        var identities: [String: PreSleepBoundaryIdentity] = [:]
        for day in civilDays {
            let owner = ownerByDay[day.day] ?? fallbackOwner
            let imported = rows(rawBySource[owner] ?? [], in: day)
            let detected = imported.isEmpty ? rows(computed, in: day) : []
            let edits = owner == editedRowsSourceId ? rows(editedComputed, in: day) : []
            let authority = Self.authoritativeShadowSleepSessions(
                detected: detected,
                persisted: imported,
                edits: edits
            )
            if let identity = Self.preSleepBoundaryIdentity(
                sessions: authority,
                dayStart: day.start,
                nextDayStart: day.nextStart,
                habitualMidsleepSec: habitualMidsleepSec,
                timeZoneOffsetSeconds: AnalyticsEngine.civilDayClockOffset(
                    day.start..<day.nextStart, timeZone: timeZone)
            ) {
                identities[day.day] = identity
            }
        }
        return identities
    }

    /// Final consent-data integrity postcondition. Exact-source work never creates optional feedback, but it
    /// can bank or de-duplicate sleep sessions. Normal work can race a user edit after it captured its scan.
    /// In both cases, keep a persisted five-key observation only when its stored bounds still equal the
    /// re-read authoritative main-night identity. An exact pass also compares the pre-write authority so a
    /// changed day is scrubbed globally even when its only old observation lives in an orphan namespace.
    private func enforcePreSleepBoundaryPostcondition(
        store: WhoopStore,
        civilDays: [CivilDayWindow],
        ownerByDay: [String: String],
        computedId: String,
        editedRowsSourceId: String,
        windowStart: Int,
        windowEnd: Int,
        habitualMidsleepSec: Int?,
        timeZone: TimeZone,
        exactIdentityBefore: [String: PreSleepBoundaryIdentity]?,
        generatedObservations: [String: PreSleepHeartRateFeedback.Observation]
    ) async throws -> Int {
        let current = try await currentPreSleepBoundaryIdentities(
            store: store,
            civilDays: civilDays,
            ownerByDay: ownerByDay,
            computedId: computedId,
            editedRowsSourceId: editedRowsSourceId,
            windowStart: windowStart,
            windowEnd: windowEnd,
            habitualMidsleepSec: habitualMidsleepSec,
            timeZone: timeZone
        )
        let scopedDays = Set(civilDays.map(\.day))
        guard let firstDay = scopedDays.min(), let lastDay = scopedDays.max() else { return 0 }

        var keysByDay: [String: Set<String>] = [:]
        var valuesByDay: [String: [String: Double]] = [:]
        for key in PreSleepHeartRateFeedback.metricKeys {
            for point in try await store.metricSeries(
                deviceId: computedId, key: key, from: firstDay, to: lastDay
            ) where scopedDays.contains(point.day) {
                keysByDay[point.day, default: []].insert(key)
                valuesByDay[point.day, default: [:]][key] = point.value
            }
        }

        let completeKeySet = Set(PreSleepHeartRateFeedback.metricKeys)
        var invalidDays = Set<String>()
        if let exactIdentityBefore {
            for day in scopedDays where exactIdentityBefore[day] != current[day] {
                invalidDays.insert(day)
            }
        }
        for (day, observation) in generatedObservations where scopedDays.contains(day) {
            let generated = PreSleepBoundaryIdentity(
                startTs: observation.primarySleepStartTs,
                endTs: observation.primarySleepEndTs
            )
            if current[day] != generated { invalidDays.insert(day) }
        }
        for day in scopedDays {
            guard let storedKeys = keysByDay[day], !storedKeys.isEmpty else { continue }
            guard storedKeys == completeKeySet,
                  let startValue = valuesByDay[day]?[PreSleepHeartRateFeedback.primarySleepStartMetricKey],
                  let endValue = valuesByDay[day]?[PreSleepHeartRateFeedback.primarySleepEndMetricKey],
                  let start = Int(exactly: startValue),
                  let end = Int(exactly: endValue),
                  current[day] == PreSleepBoundaryIdentity(startTs: start, endTs: end) else {
                invalidDays.insert(day)
                continue
            }
        }
        guard !invalidDays.isEmpty else { return 0 }
        return try await store.deleteMetricSeriesGlobally(
            keys: PreSleepHeartRateFeedback.metricKeys,
            onDays: invalidDays.sorted()
        )
    }

    /// A failed verification is not permission to retain possibly mismatched consent data. Fall back to a
    /// narrow global scrub of this pass's civil days; return nil only when that fail-closed delete also fails.
    private func enforcePreSleepBoundaryPostconditionFailClosed(
        store: WhoopStore,
        civilDays: [CivilDayWindow],
        ownerByDay: [String: String],
        computedId: String,
        editedRowsSourceId: String,
        windowStart: Int,
        windowEnd: Int,
        habitualMidsleepSec: Int?,
        timeZone: TimeZone,
        exactIdentityBefore: [String: PreSleepBoundaryIdentity]?,
        generatedObservations: [String: PreSleepHeartRateFeedback.Observation]
    ) async -> Int? {
        do {
            return try await enforcePreSleepBoundaryPostcondition(
                store: store,
                civilDays: civilDays,
                ownerByDay: ownerByDay,
                computedId: computedId,
                editedRowsSourceId: editedRowsSourceId,
                windowStart: windowStart,
                windowEnd: windowEnd,
                habitualMidsleepSec: habitualMidsleepSec,
                timeZone: timeZone,
                exactIdentityBefore: exactIdentityBefore,
                generatedObservations: generatedObservations
            )
        } catch {
            NSLog("IntelligenceEngine: pre-sleep boundary verification failed; scrubbing affected days: \(error)")
            do {
                return try await store.deleteMetricSeriesGlobally(
                    keys: PreSleepHeartRateFeedback.metricKeys,
                    onDays: Array(Set(civilDays.map(\.day))).sorted()
                )
            } catch {
                NSLog("IntelligenceEngine: pre-sleep boundary fail-closed cleanup failed: \(error)")
                return nil
            }
        }
    }

    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession],
                                 habitualMidsleepSec: Int?,
                                 tzOffsetSeconds: Int) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged nap is a userEdited row with NO detected twin , it would never be
        // visited by the substitution pass, so its minutes were dropped from the day's Rest
        // total. Pass those twinless rows through the union channel so they fold in. (#518/#508)
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        // #525/#547: supply each block's EFFECTIVE onset (audit finding C / #8) keyed by its stable
        // detected startTs, plus the device tz offset + learned habitual midsleep, so the edited recompute
        // picks the SAME MAIN NIGHT the Sleep tab shows. The onset must be the user-CORRECTED bedtime
        // (`startTsAdjusted ?? startTs`) when a block was edited, NOT the immutable detected start , a
        // bedtime edit crossing the overnight boundary would otherwise let the seam and the Sleep tab pick
        // different blocks. For a detected block the effective onset is its edited twin's effectiveStartTs
        // (an edit moves the onset) when edited, else the detected block's own effectiveStartTs; for a
        // twinless manual block it's that row's effectiveStartTs. Without these the seam falls back to the
        // legacy SUM and an overnight+nap day would re-include the nap in the headline total.
        var onsetByStart: [Int: Int] = [:]
        // AN-12: each block's effective END too, so the seam selects on the same [onset, end] spans
        // `analyzeDay` scored instead of re-deriving the end from decoded stage minutes.
        var endByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
            endByStart[d.startTs] = editsByStart[d.startTs]?.endTs ?? d.endTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
            endByStart[start] = edit.endTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   endByStart: endByStart,
                                                                   offsetSec: tzOffsetSeconds,
                                                                   habitualMidsleepSec: habitualMidsleepSec),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    private nonisolated static func effectiveSleepSessions(
        detected: [CachedSleepSession], edits: [CachedSleepSession]) -> [CachedSleepSession] {
        let editsByStart = Dictionary(edits.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
        let detectedStarts = Set(detected.map(\.startTs))
        return detected.map { editsByStart[$0.startTs] ?? $0 }
            + edits.filter { !detectedStarts.contains($0.startTs) }
    }

    /// Resolve one bounds authority for a single wake day before mapping to descriptive shadows.
    /// Imported/persisted sessions match the Sleep UI's precedence and replace detector output for a
    /// covered day, including slightly shifted representations of the same night. Detector output fills
    /// only days with no persisted session. User edits are then applied to the chosen authority.
    nonisolated static func authoritativeShadowSleepSessions(
        detected: [CachedSleepSession],
        persisted: [CachedSleepSession],
        edits: [CachedSleepSession]
    ) -> [SleepSession] {
        shadowSleepSessions(
            detected: persisted.isEmpty ? detected : persisted,
            edits: edits
        )
    }

    /// Bounds-only analytics representation for descriptive RHR shadows. User edits replace their
    /// detected twin, and a manually added block joins the candidate set exactly as it does for Rest.
    private nonisolated static func shadowSleepSessions(
        detected: [CachedSleepSession], edits: [CachedSleepSession]
    ) -> [SleepSession] {
        var seen = Set<String>()
        return effectiveSleepSessions(detected: detected, edits: edits).compactMap { session in
            guard session.effectiveStartTs < session.endTs else { return nil }
            // The same physical sleep can exist under both the freshly detected and imported namespace.
            // Keep its first (fresh-detected) copy so duplicate storage never becomes a fake split night.
            let identity = "\(session.effectiveStartTs)-\(session.endTs)"
            guard seen.insert(identity).inserted else { return nil }
            return SleepSession(
                start: session.effectiveStartTs,
                end: session.endTs,
                efficiency: session.efficiency ?? 0,
                stages: [],
                restingHR: session.restingHr,
                avgHRV: session.avgHrv
            )
        }
    }

    private nonisolated static func sleepV2MetricPoints(_ scored: ScoredSleepDay) -> [MetricPoint] {
        var points = [
            MetricPoint(day: scored.day, key: Repository.sleepNeedV2Key, value: scored.need.totalMinutes),
            MetricPoint(day: scored.day, key: "noop_sleep_baseline_need_v2_min", value: scored.need.baselineMinutes),
            MetricPoint(day: scored.day, key: "noop_sleep_strain_need_v2_min", value: scored.need.strainAdjustmentMinutes),
            MetricPoint(day: scored.day, key: "noop_sleep_debt_need_v2_min", value: scored.need.debtRepaymentMinutes),
            MetricPoint(day: scored.day, key: "noop_sleep_nap_credit_v2_min", value: scored.need.napCreditMinutes),
            MetricPoint(day: scored.day, key: "noop_sleep_debt_balance_v2_min",
                        value: scored.debtAfterNight.newBalanceMinutes),
            MetricPoint(day: scored.day, key: Repository.sleepPerformanceV2ModelKey, value: 2),
            MetricPoint(day: scored.day, key: Repository.sleepPerformanceV2SourceKey,
                        value: scored.summary.source == .noopEdited ? 2 : 1),
        ]
        if let performance = scored.performance {
            points += [
                MetricPoint(day: scored.day, key: Repository.sleepPerformanceV2Key,
                            value: performance.score),
                MetricPoint(day: scored.day, key: "noop_sleep_sufficiency_v2",
                            value: performance.components.sufficiency),
                MetricPoint(day: scored.day, key: "noop_sleep_efficiency_v2",
                            value: performance.components.efficiency),
                MetricPoint(day: scored.day, key: "noop_sleep_input_coverage_v2",
                            value: performance.inputCoverage),
            ]
            if let value = performance.components.consistency {
                points.append(MetricPoint(day: scored.day, key: "noop_sleep_consistency_v2", value: value))
            }
            if let value = performance.components.lowStressQuality {
                points.append(MetricPoint(day: scored.day, key: "noop_sleep_low_stress_v2", value: value))
            }
        }
        return points
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) , honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of
    /// history (cold-start). Reads the stored sleep sessions (imported + computed) over the window, makes
    /// one `HistoryBlock` per session , start/end are the EFFECTIVE (edited) bounds so a corrected bedtime
    /// is learned, dayKey is the LOCAL calendar day of the midpoint , and defers to
    /// `SleepStageTotals.habitualMidsleepSec`, which keeps the longest block per day (naps drop out). The
    /// imported + computed sets can overlap; both are unioned and the learner de-dupes per day by length.
    /// (#547) Mirrors the Android `computeHabitualMidsleep`.
    /// CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
    /// `[from, to]`, expanded to timestamped `(ts, state)` samples on the 30 s epoch grid, for the H7
    /// morning-stillness guard's re-onset confirmation. Reads the computed sessions in the window, then each
    /// one's persisted per-epoch sleep_state (NULL when never banded , first pass / imported night), and maps
    /// epoch `i` to `startTs + i*30`. Empty when nothing is banded yet, so the guard simply falls back to the
    /// HR bar. Honest: only real banded states are surfaced, never a fabricated reading. The grid here mirrors
    /// `SleepStager`'s 30 s epoch grid, so an epoch's timestamp lands inside the candidate run it scores.
    /// `nonisolated static` (FIX 1): touches only the `store` actor + value params, so the off-main scan
    /// loop calls it without hopping back to the main actor each iteration. Logic identical.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: WhoopStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        // #899: collapse overlapping timebase-shifted duplicates BEFORE consuming band state. A stale
        // re-banked copy of the night would otherwise feed "asleep" epochs at the OLD times into the H7
        // re-onset guard, letting the stale block keep confirming itself. Read-side only (no bank-recency
        // witness here); the store itself is healed post-upsert in analyzeRecent.
        let storedSessions = (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                                             limit: 4000)) ?? []
        // A persisted session's bounds are input, not a trust boundary. Filter impossible spans BEFORE the
        // de-duplicator calculates overlap/duration so an Int.min/Int.max row cannot make a diagnostic
        // read trap before the valid sessions are considered.
        let sessions = SleepSessionDedup.dedupe(storedSessions.filter {
            SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
        }).kept
        // One range read of the window's banked band state, keyed by startTs, instead of a single-row SELECT
        // per kept session. We still expand ONLY the kept (deduped) sessions, in order, so the output is
        // identical to the old per-session loop — just without the N round-trips.
        let stateByStart = (try? await store.sessionSleepStates(deviceId: computedId,
                                                                from: from, to: to)) ?? [:]
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = stateByStart[s.startTs], !states.isEmpty else { continue }
            // Expand one persisted state series atomically. If a corrupt epoch offset overflows or exits its
            // own session, discard that entire series; a partial stale/asleep tail must never confirm a run.
            var sessionSamples: [(ts: Int, state: Int)] = []
            var validSeries = true
            for (i, st) in states.enumerated() {
                let (offset, offsetOverflow) = i.multipliedReportingOverflow(by: epochS)
                let (timestamp, timestampOverflow) = s.startTs.addingReportingOverflow(offset)
                guard !offsetOverflow, !timestampOverflow, Self.isSafeTimestamp(timestamp), timestamp < s.endTs else {
                    validSeries = false
                    break
                }
                sessionSamples.append((ts: timestamp, state: st))
            }
            if validSeries { samples.append(contentsOf: sessionSamples) }
        }
        return samples
    }

    private static func computeHabitualMidsleep(
        store: WhoopStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, timeZone: TimeZone
    ) async -> Int? {
        guard windowEnd >= windowStart else { return nil }
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        // #899: collapse overlapping timebase-shifted duplicates BEFORE the learner sees the history.
        // A stale re-banked copy of a night lands on a DIFFERENT day key, so the per-day longest-block
        // de-dup below never caught it and the learned midsleep drifted toward the stale timing, which
        // then steered the main-night pick (day assignment) to the stale block. The same collapse also
        // covers an imported night and its computed twin (the longest capture wins, exactly what the
        // per-day length rule chose anyway).
        // Reject malformed stored spans before de-duplication. Apart from avoiding unchecked math below, this
        // prevents an extreme row from reaching its overlap/duration ranking and taking down the entire
        // learned-timing pass.
        let validSessions = (imported + computed).filter {
            SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
        }
        let merged = SleepSessionDedup.dedupe(validSessions).kept
        let blocks = merged.compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard SleepSessionWindow.isValid(start: start, end: end) else { return nil }
            let duration = end - start
            let (mid, midpointOverflow) = start.addingReportingOverflow(duration / 2)
            guard !midpointOverflow else { return nil }
            // AN-02: each night on the wall clock in force at its own midpoint, so nights on both sides of
            // a DST change are learned on one local clock instead of half of them an hour off.
            let offsetSec = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(mid)))
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            guard !dayKey.isEmpty else { return nil }
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey,
                                                 clockOffsetSec: offsetSec)
        }
        // Every block carries its own `clockOffsetSec`, so the shared fallback offset is never read.
        return SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: 0)
    }

    /// Epoch seconds in one UTC date. This is intentionally fixed because UTC has no daylight-saving
    /// transition; local health-day boundaries use `civilDayWindows` instead.
    nonisolated private static let epochDaySeconds = 24 * 60 * 60

    /// Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. Mirrors the Android
    /// IntelligenceEngine.midnightUtc; the floorMod form is correct for any sign.
    /// Returns nil when the mathematical floor cannot be represented in `Int` (for example Int.min, which
    /// sits inside a UTC day whose true floor is below Int.min). A raw bad-clock value must not wrap into a
    /// plausible modern day.
    nonisolated static func midnightUtc(_ ts: Int) -> Int? {
        let (midnight, overflow) = ts.subtractingReportingOverflow(floorMod(ts, epochDaySeconds))
        return overflow ? nil : midnight
    }

    /// Floor a unix-seconds timestamp onto a fixed-offset local epoch grid. `offsetSec` is seconds EAST
    /// of UTC. This helper is retained for protocol/timestamp compatibility; health-day enumeration uses
    /// `civilDayWindows`, which has the time-zone identity needed to handle daylight-saving boundaries.
    /// floorMod keeps the floor correct for negative offsets and negative timestamps. `offsetSec == 0`
    /// reduces exactly to `midnightUtc`. Mirrors the Android IntelligenceEngine.midnightLocal arithmetic.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int? {
        let (localTimestamp, shiftOverflow) = ts.addingReportingOverflow(offsetSec)
        guard !shiftOverflow else { return nil }
        let (localMidnight, floorOverflow) = localTimestamp.subtractingReportingOverflow(
            floorMod(localTimestamp, epochDaySeconds))
        guard !floorOverflow else { return nil }
        let (utcMidnight, unshiftOverflow) = localMidnight.subtractingReportingOverflow(offsetSec)
        return unshiftOverflow ? nil : utcMidnight
    }

    /// Every integer in this range is exactly representable by the `Double` timestamps used by the analytics
    /// layer. It also leaves ample arithmetic headroom for session comparisons, unlike Int.min/Int.max from a
    /// malformed export.
    nonisolated private static let maximumSafeTimestamp = 9_007_199_254_740_991

    nonisolated private static func isSafeTimestamp(_ timestamp: Int) -> Bool {
        timestamp >= -maximumSafeTimestamp && timestamp <= maximumSafeTimestamp
    }

    /// Positive duration that is representable in an Int. Persistent exports are untrusted: comparisons alone
    /// do not make `Int.max - Int.min` safe to evaluate.
    nonisolated private static func representablePositiveDuration(start: Int, end: Int) -> Int? {
        guard isSafeTimestamp(start), isSafeTimestamp(end) else { return nil }
        let (duration, overflow) = end.subtractingReportingOverflow(start)
        guard !overflow, duration > 0 else { return nil }
        return duration
    }

    /// Euclidean modulo (result has the sign of the divisor) , matches Kotlin/Java Math.floorMod, so
    /// the LOCAL-midnight floor is identical across platforms for any sign of ts/offset. Swift's `%`
    /// is a remainder (sign of the dividend), which would mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?) -> DailyMetric {
        replacing(recovery: .some(r), skinTempDevC: .some(sd))
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        replacing(totalSleepMin: .some(tsm), efficiency: .some(eff), deepMin: .some(dm),
                  remMin: .some(rm), lightMin: .some(lm))
    }
}

extension IntelligenceEngine {
    /// A pass over today's incomplete source can refresh daytime fields without replaying the
    /// already-finished sleep window. Keep fresh values whenever present and fill only missing overnight
    /// columns from the persisted same-day row. The caller limits this helper to current-day work and, in the
    /// migration's chunks, to strap-swap days whose night another strap recorded (upgrade 231).
    nonisolated static func preservingPriorOvernightFields(
        in fresh: DailyMetric,
        from prior: DailyMetric
    ) -> DailyMetric {
        guard fresh.day == prior.day else { return fresh }
        return fresh.replacing(
            totalSleepMin: .some(fresh.totalSleepMin ?? prior.totalSleepMin),
            efficiency: .some(fresh.efficiency ?? prior.efficiency),
            deepMin: .some(fresh.deepMin ?? prior.deepMin),
            remMin: .some(fresh.remMin ?? prior.remMin),
            lightMin: .some(fresh.lightMin ?? prior.lightMin),
            disturbances: .some(fresh.disturbances ?? prior.disturbances),
            restingHr: .some(fresh.restingHr ?? prior.restingHr),
            avgHrv: .some(fresh.avgHrv ?? prior.avgHrv),
            recovery: .some(fresh.recovery ?? prior.recovery),
            skinTempDevC: .some(fresh.skinTempDevC ?? prior.skinTempDevC),
            respRateBpm: .some(fresh.respRateBpm ?? prior.respRateBpm),
            spo2Red: .some(fresh.spo2Red ?? prior.spo2Red),
            spo2Ir: .some(fresh.spo2Ir ?? prior.spo2Ir)
        )
    }

    /// Whether a row carries any of the overnight fields `preservingPriorOvernightFields` merges (upgrade 231).
    nonisolated static func hasOvernightFields(_ row: DailyMetric) -> Bool {
        row.totalSleepMin != nil || row.efficiency != nil || row.deepMin != nil || row.remMin != nil
            || row.lightMin != nil || row.disturbances != nil || row.restingHr != nil || row.avgHrv != nil
            || row.recovery != nil || row.skinTempDevC != nil || row.respRateBpm != nil
            || row.spo2Red != nil || row.spo2Ir != nil
    }

    /// Reconstruct the still-open day's missing overnight fields from durable computed sleep sessions.
    /// The main-night selector and stage aggregate match normal analysis, while RHR/HRV retain normal
    /// all-sessions-for-the-wake-day semantics. Unsupported fields remain untouched.
    nonisolated static func rebuildingMissingOvernightFields(
        in fresh: DailyMetric,
        from persistedSessions: [CachedSleepSession],
        dayStart: Int,
        nextDayStart: Int,
        habitualMidsleepSec: Int?,
        timeZoneOffsetSeconds: Int
    ) -> DailyMetric? {
        let matched = persistedSessions.filter {
            $0.endTs >= dayStart
                && $0.endTs < nextDayStart
                && $0.effectiveStartTs < $0.endTs
        }
        guard !matched.isEmpty else { return nil }

        let mainIndices = SleepStageTotals.mainNightGroupIndices(
            matched.map {
                SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs)
            },
            offsetSec: timeZoneOffsetSeconds,
            habitualMidsleepSec: habitualMidsleepSec
        ) ?? []
        let mainGroup = mainIndices.map { matched[$0] }
        let interFragmentAwakeSeconds = SleepStageTotals.interFragmentAwakeSeconds(
            mainGroup.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        )
        let sleep = SleepStageTotals.dailyAggregate(
            mainGroup.map(\.stagesJSON),
            interFragmentAwakeSeconds: interFragmentAwakeSeconds
        )

        let restingHr = matched.compactMap(\.restingHr).min()
        let hrvPairs = matched.compactMap { session -> (value: Double, weight: Double)? in
            guard let value = session.avgHrv, value.isFinite else { return nil }
            let (duration, overflow) = session.endTs.subtractingReportingOverflow(
                session.effectiveStartTs
            )
            guard !overflow, duration > 0 else { return nil }
            return (value, Double(duration))
        }
        let hrvWeight = hrvPairs.reduce(0.0) { $0 + $1.weight }
        let avgHrv: Double? = hrvWeight > 0
            ? hrvPairs.reduce(0.0) { $0 + $1.value * $1.weight } / hrvWeight
            : nil

        let rebuilt = fresh.replacing(
            totalSleepMin: .some(fresh.totalSleepMin ?? sleep?.totalSleepMin),
            efficiency: .some(fresh.efficiency ?? sleep?.efficiency),
            deepMin: .some(fresh.deepMin ?? sleep?.deepMin),
            remMin: .some(fresh.remMin ?? sleep?.remMin),
            lightMin: .some(fresh.lightMin ?? sleep?.lightMin),
            restingHr: .some(fresh.restingHr ?? restingHr),
            avgHrv: .some(fresh.avgHrv ?? avgHrv)
        )
        return rebuilt == fresh ? nil : rebuilt
    }

    /// Merge one metric's on-device pass-1 nightly values into the imported-history map.
    /// Imported (cloud) values WIN per day; the computed estimate only fills days the import
    /// does not cover at all (key absent). Twin of the Kotlin `mergeNightlyIntoHistory`.
    nonisolated static func mergeNightlyIntoHistory(
        _ hist: inout [String: Double?], _ nightly: [String: Double?]
    ) {
        // `hist` values are themselves Optional, so `hist[day] == nil` is only
        // true when the KEY is absent — an imported row with a nil value is
        // `.some(.none)` and would shadow the real computed night forever,
        // starving the baseline (the "Needs the strap" bug). Imported non-nil
        // wins; a nil (or absent) slot is backfilled by the computed value.
        for (day, v) in nightly {
            if let existing = hist[day], existing != nil { continue }  // imported non-nil wins
            hist[day] = v
        }
    }
}
