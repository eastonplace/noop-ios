import SwiftUI
import Combine
import NoopPhase34Core
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport
#if os(iOS)
import UserNotifications
#endif

/// Data source currently running an import from the Data Sources screen.
enum DataSourceImportKind {
    case whoop
    case appleHealth
    case xiaomi
}

enum WorkoutFinishState: Equatable {
    case recording
    case saving
    case saved(WorkoutRow)
    case failed(String)
}

enum WorkoutFinishError: LocalizedError {
    case noActiveWorkout
    case insufficientEvidence
    case storeUnavailable
    case persistenceFailed(String)
    case readBackMissing

    var errorDescription: String? {
        switch self {
        case .noActiveWorkout: return "No workout is recording."
        case .insufficientEvidence: return "Keep recording until heart-rate data or a GPS route is available."
        case .storeUnavailable: return "Workout storage is unavailable. Try again."
        case .persistenceFailed(let message): return "Couldn’t save the workout: \(message)"
        case .readBackMissing: return "The workout could not be verified after saving. Try again."
        }
    }
}

enum AppModelSourceTransitionError: Error, Equatable {
    case storeUnavailable
    case registryUnavailable
    case targetUnavailable
    case externalWorkerUnavailable
    case sinkUnavailable
    case sinkActivationFailed
    case privacyCleanupUnavailable
    case physicalTransitionMissing
}

enum DurableSourceTransitionKind: Equatable {
    case selectExisting
    case replacePeripheral
    case archive
    case deleteData
}

enum FullHistoryRepairAdmissionPolicy {
    /// Broad repair may publish only for the active source after Today hydration. Closed, archived, and
    /// no-active-source rows follow the lifecycle store's explicit durable cancellation policy.
    static func canRun(
        applicationIsActive: Bool,
        repositoryLoaded: Bool,
        hasActiveLiveSource: Bool,
        hasTodaySnapshot: Bool,
        hasActiveImport: Bool,
        isBackfilling: Bool,
        hasActiveWorkout: Bool
    ) -> Bool {
        !applicationIsActive
            && repositoryLoaded
            && hasActiveLiveSource
            && hasTodaySnapshot
            && !hasActiveImport
            && !isBackfilling
            && !hasActiveWorkout
    }
}

/// Root app state: owns the live BLE connection state and the CoreBluetooth engine.
/// More subsystems (Repository, AnalyticsEngine, ImportCoordinator) get wired in here
/// in later milestones.
@MainActor
final class AppModel: ObservableObject {
    /// `sourceTransitionJournal` predates target-scoped transitions and requires every persisted epoch to be
    /// positive. Epoch 1 is the untouched/open initial process-local epoch, so it is the durable sentinel for
    /// a transition that intentionally did not quiesce the global historical/external/sink owners.
    nonisolated private static let noGlobalSourceTransitionEpoch: UInt64 = 1
    /// The live instance, so an AppIntent (Shortcuts) can reach the bonded strap rather than spinning
    /// up a dead second AppModel (which would start a duplicate BLE engine and never buzz). Set in
    /// init(); `weak` so an intent fired while NOOP is closed sees nil and asks the user to open it. (#42)
    static weak var shared: AppModel?

    /// Timestamp formatter for the generic-HR strap-log lines routed through `straplog` into the shared
    /// log (issue #421). Mirrors `BLEManager.logTimeFormatter`'s `HH:mm:ss` so WHOOP and HR-strap lines
    /// read identically in the exported strap log.
    static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// The CANONICAL imported/computed id ("my-whoop"). The WHOOP-IMPORT target (`WhoopImporter`), the
    /// FusionSource `.whoopImport` mapping, and a manually-saved workout all land under THIS stable id, and
    /// the engine writes its computed scores under the matching `-noop` sibling. It must NOT follow the
    /// active strap (#814 union-model follow-up): a remove+re-add gives the strap a fresh "whoop-<uuid>" id,
    /// but if the import/computed target drifted to it, history banked earlier under "my-whoop" would be
    /// orphaned. The Repository's ACTIVE-strap read id follows the registry instead (`adoptActiveDevice`),
    /// and the dashboard reads the UNION of the two, so the re-added strap's live data AND the canonical
    /// history both surface. `let` because nothing moves it.
    let deviceId = "my-whoop"
    /// Source id for imported Apple Health data (stored beside Whoop for per-source pages + consensus).
    let appleDeviceId = "apple-health"
    /// Observable snapshot driven by the BLE engine (connection, HR, battery, log).
    let live: LiveState
    /// CoreBluetooth engine , scans, connects, bonds, streams.
    let ble: BLEManager
    /// Read model over the on-device store (dashboard + detail screens).
    let repo: Repository
    /// User profile (age/sex/body/HR-max) for zones, calories, baselines.
    let profile = ProfileStore()
    /// Behaviour settings: double-tap action, wear automation, zone coaching, smart alarm, illness watch.
    let behavior = BehaviorStore()
    /// On-device WHOOP-style recovery/strain/sleep computation from raw strap streams.
    let intelligence: IntelligenceEngine
    /// The single durable owner for receipt admission, exact-day analysis, verified snapshots, and
    /// downstream outbox work. Launch, foreground, and burst-finalization signals all enter this actor.
    private lazy var historicalPipelineRuntime = makeHistoricalPipelineRuntime()
    /// Broad-repair evidence has no exact civil-day authority. It is therefore owned by a separate durable
    /// maintenance lane. Only the active source can publish; lifecycle changes durably cancel old scopes.
    private lazy var fullHistoryRepairMaintenance = makeFullHistoryRepairMaintenance()

    var backupRestoreLifecycle: DataBackup.RestoreLifecycle {
        DataBackup.RestoreLifecycle(
            quiesce: { [weak self] in
                guard let self else { return }
                try await self.ble.quiesceStoreForRestore()
                do {
                    try await self.repo.quiesceStoreForRestore()
                } catch {
                    try? await self.ble.reopenStoreAfterRestore()
                    throw error
                }
            },
            reopenAndMigrate: { [weak self] in
                guard let self else { return }
                try await self.repo.reopenStoreAfterRestore()
                do {
                    try await self.ble.reopenStoreAfterRestore()
                } catch {
                    try? await self.repo.quiesceStoreForRestore()
                    throw error
                }
            }
        )
    }

    /// Opt-in AI coach (bring-your-own-key) , the one networked feature, off until the user enables it.
    let coach: AICoachEngine

    /// Observable cache over the paired-device registry; `activeDeviceId` drives the source coordinator.
    /// Built lazily once the store opens (see `wireSourceCoordinator`). nil until then , with no generic
    /// strap paired the active id stays "my-whoop", so this never affects the WHOOP startup path.
    /// `@Published` so the Devices screen re-renders the moment the registry is wired in (it observes
    /// `model.deviceRegistry`); nested `registry.$devices` changes are observed by the screen directly.
    @Published private(set) var deviceRegistry: DeviceRegistry?
    /// Shared serialization boundary for source changes, durable scope retirement, Repository invalidation,
    /// and latest-state sink cleanup. BLE callbacks and UI actions can arrive concurrently.
    private let sourceTransitionFence = SourceTransitionFence()
    /// Runs exactly one device's live BLE at a time. DORMANT whenever WHOOP is active (the default and
    /// every no-strap case): it only acts when a non-WHOOP generic strap becomes the active device,
    /// pausing WHOOP and running the isolated `StandardHRSource`. nil until wired (post store-open).
    private(set) var sourceCoordinator: SourceCoordinator?
    private var externalPublicationQuiesce: (() async throws -> UInt64)?
    private var externalPublicationResume: ((UInt64) async throws -> Void)?
    private var externalPublicationSignal: (() async -> Void)?
    private var verifiedSinkLifecycle: (any VerifiedSinkLifecycle)?
    private var sourcePrivacyCleanupDrain: (@Sendable (UUID) async throws -> Void)?

    /// Timestamps of moments marked via a double-tap (persisted).
    @Published var moments: [Date] = []

    /// Timestamps of "sleep marks" tapped on the strap (#461) , bedtime / wake / mid-night marks the
    /// user double-taps without screenshots or remembering the time. Persisted; each also writes a
    /// greppable "Sleep mark @ HH:mm" line into the strap log. Phase-1 foundation for tap-driven sleep
    /// bounds + personal sleep-stage calibration.
    @Published var sleepMarks: [Date] = []

    /// An in-progress manually-tracked workout (requested by users who want to start a session
    /// themselves rather than rely on auto-detection). Holds the start time + the live HR collected
    /// since; on End the window is scored via `StrainScorer` and saved as a `WorkoutRow` (source
    /// "manual"), which then shows in the Workouts view. The day's strain already counts this HR (it's
    /// the same live stream the store persists), so this is a per-session annotation, not a double-count.
    @Published var activeWorkout: ActiveWorkout?
    /// The just-ended workout, for a brief inline confirmation on Live (cleared on the next start).
    @Published var lastWorkout: WorkoutRow?
    @Published private(set) var workoutFinishState: WorkoutFinishState = .recording
    /// A visible, non-blocking warning whenever the active workout has data that is not yet durable.
    @Published private(set) var workoutDurabilityWarning: String?

    /// Records the GPS route of an in-flight distance-type workout (run / ride / walk / hike) from
    /// CoreLocation (#524) , the Apple analogue of Android's `GpsSession` + foreground `LocationManager`.
    /// Fails safe: on a Mac with no GPS, or when location permission is denied, it records nothing and
    /// the session still banks HR + Effort without a route. Observed by the live workout card for live
    /// distance/pace; its final route is persisted on End via `RouteStore`, keyed by the saved row's
    /// natural key (the shared `WorkoutRow` has no route column on Apple). Default behaviour is opt-in by
    /// sport: it only arms for a `WorkoutCatalog.Sport.isDistanceSport`, and only actually captures once
    /// the user grants When-In-Use location.
    let gpsRecorder = GpsWorkoutRecorder()
    /// True while the active workout is a GPS-type session (drives the End-time route persist). Mirrors
    /// Android's `ActiveWorkout.gpsEnabled`.
    private var activeWorkoutIsGps = false
    private var pendingWorkoutSnapshot: ActiveWorkout?
    private var pendingWorkoutEnd: Date?
    private var pendingWorkoutRoute: WorkoutRoute?
    private var pendingWorkoutWasGps = false
    /// Queue admission and durable pointer commit are separate facts. A background writer may accept a
    /// checkpoint then fail later because storage became unavailable or protected.
    private var lastWorkoutSnapshotEnqueuedAt: Date = .distantPast
    private var lastWorkoutSnapshotAt: Date = .distantPast
    private var latestWorkoutSnapshotAttempt: UInt64 = 0
    private var latestGpsSnapshotAttempt: UInt64 = 0
    private var workoutSnapshotDurabilityFailed = false
    private var gpsSnapshotDurabilityFailed = false
    private var gpsHadTerminatedGap = false
    private var applicationIsActive = true

    /// A manual workout in progress. `samples` accumulate from the smoothed live `bpm`; `liveStrain`
    /// is updated by an O(1) accumulator so the active card can show strain building in real time.
    /// Reference-owned live session. The sample buffer grows in place so each accepted HR reading does
    /// not copy the entire retained workout before publishing the next UI update.
    final class ActiveWorkout: ObservableObject {
        let sessionID: UUID
        let start: Date
        /// The named sport chosen at start (e.g. "Tennis", "Padel") , persisted as the saved row's
        /// `sport` so a live-tracked session keeps its label instead of the old generic "Workout".
        /// Defaults to the catalogue default ("Other") when started without a pick. (#519)
        var sport: String = WorkoutCatalog.defaultSportName
        private(set) var samples: [HRSample] = []
        @Published private(set) var liveStrainState: LiveStrainState = .building(readings: 0, coverageSeconds: 0)
        @Published private(set) var avgHr: Int = 0
        @Published private(set) var peakHr: Int = 0
        @Published private(set) var currentBPM: Int?
        @Published private(set) var chartProjection = WorkoutHeartChartProjection.make(samples: [])
        var strainAccumulator: StrainScorerV2.ActivityAccumulator
        private var chartAccumulator = WorkoutHeartChartAccumulator()
        private let maxHR: Double

        init(sessionID: UUID = UUID(), start: Date, sport: String, maxHR: Double) {
            self.sessionID = sessionID
            self.start = start
            self.sport = sport
            self.maxHR = maxHR
            self.strainAccumulator = .init(maxHR: maxHR)
        }

        @discardableResult
        func ingest(_ sample: HRSample) -> Bool {
            guard sample.ts > 0, (30...240).contains(sample.bpm) else { return false }
            if let last = samples.last {
                guard sample.ts >= last.ts else { return false }
                if sample.ts == last.ts {
                    samples[samples.count - 1] = sample
                    guard strainAccumulator.replaceCurrentSecond(with: sample),
                          chartAccumulator.ingest(sample) else { return false }
                } else {
                    samples.append(sample)
                    strainAccumulator.append(sample)
                    guard chartAccumulator.ingest(sample) else { return false }
                }
            } else {
                samples.append(sample)
                strainAccumulator.append(sample)
                guard chartAccumulator.ingest(sample) else { return false }
            }
            publishLiveState(sample: sample)
            return true
        }

        func restore(samples restoredSamples: [HRSample]) {
            var canonical: [HRSample] = []
            for sample in restoredSamples.sorted(by: { $0.ts < $1.ts })
                where sample.ts > 0 && (30...240).contains(sample.bpm) {
                if canonical.last?.ts == sample.ts { canonical[canonical.count - 1] = sample }
                else { canonical.append(sample) }
            }
            samples = canonical
            strainAccumulator = .init(samples: canonical, maxHR: maxHR)
            chartAccumulator = WorkoutHeartChartAccumulator(samples: canonical)
            chartProjection = chartAccumulator.projection
            currentBPM = canonical.last?.bpm
            avgHr = strainAccumulator.averageHR ?? 0
            peakHr = strainAccumulator.peakHR ?? 0
            if let strain = strainAccumulator.strain {
                liveStrainState = .scored(storedValue: strain)
            } else {
                liveStrainState = .building(readings: strainAccumulator.readingCount,
                                            coverageSeconds: strainAccumulator.coverageSeconds)
            }
        }

        private func publishLiveState(sample: HRSample) {
            currentBPM = sample.bpm
            chartProjection = chartAccumulator.projection
            peakHr = strainAccumulator.peakHR ?? sample.bpm
            avgHr = strainAccumulator.averageHR ?? sample.bpm
            if let strain = strainAccumulator.strain {
                liveStrainState = .scored(storedValue: strain)
            } else {
                liveStrainState = .building(readings: strainAccumulator.readingCount,
                                            coverageSeconds: strainAccumulator.coverageSeconds)
            }
        }
    }
    /// Illness/strain early-warning (recent RHR up + HRV down + skin-temp up vs baseline). nil = clear.
    @Published var healthAlert: String?

    // MARK: - v5 pillar snapshot (engines run in the analytics pass; the views read these)
    //
    // The Insights / skin-temp Health-hub cards take pure engine RESULTS by value. The analytics pass
    // (IntelligenceEngine.analyzeRecent → refreshV5Signals) computes them once from the stores and
    // publishes them here; AppModel exposes them so HealthView / InsightsHubView read a snapshot rather
    // than re-deriving. All opt-in / honest-nil , a nil result means "not enough data / not enabled".
    @Published var illnessSignal: IllnessSignalEngine.Result?
    /// Parallel Mahalanobis illness-distance read (IllnessDistance), computed on the SAME illness-ward
    /// z-vector as illnessSignal but NEVER gating the alert. The shipped IllnessSignalEngine stays the
    /// sole fire gate; this only surfaces a "how strong" confidence readout in the Heads-Up card when
    /// the engine has already raised. nil = not computed this pass. (Augment-only, Option A.)
    @Published var illnessDistance: IllnessDistance.Result?
    /// Cycle-phase awareness (only computed when the user has opted in; else nil). Awareness only.
    @Published var cyclePhase: CyclePhaseEngine.Result?
    /// The nightly fused-index curve (oldest→newest) feeding the cycle card's sparkline.
    @Published var cycleCurve: [Double] = []
    /// Body-clock phase estimate (circadian). nil until a usable activity profile exists.
    @Published var circadianPhase: CircadianEngine.PhaseEstimate?

    /// The L3 passive-nudge surface (haptic biofeedback "stress check-in"). The detector fires onto this
    /// from `evaluateStress`; both app roots inject it into the environment so the Breathe screen's card
    /// (and any host) surfaces the pending nudge. Owned here so the central hook can reach it. (v5 L3)
    let stressNudgeCenter = StressNudgeCenter()

    private var lastDoubleTapAt: Date = .distantPast
    private var lastCoachZone: Int = -1
    // L3 stress-onset detector state: a rolling R-R buffer + the replay-safe detector state (persisted
    // via BiofeedbackPrefs so a relaunch can't re-fire), carried verbatim between evaluations.
    private var rrBuf: [Int] = []
    private var stressState = BiofeedbackPrefs.loadStressState()

    /// Import source currently writing to the local store, if any.
    @Published private var activeImportSource: DataSourceImportKind?
    /// Last WHOOP export import result surfaced in the WHOOP card.
    @Published var whoopImportSummary: String?
    /// Last Apple Health import result surfaced in the Apple Health card.
    @Published var appleHealthImportSummary: String?
    /// Last Xiaomi / Mi Band import result surfaced in the Mi Band card.
    @Published var xiaomiImportSummary: String?
    /// Typed failure flags per source , the summary's warning styling reads these instead of
    /// substring-matching the human-readable message (which misses errors like "Couldn't open
    /// the local store."). Surfaced on both the Data Sources cards and the onboarding import step.
    @Published var whoopImportFailed = false
    @Published var appleHealthImportFailed = false
    @Published var xiaomiImportFailed = false

    /// True while any data-source import is writing to the local store.
    var hasActiveImport: Bool { activeImportSource != nil }

    /// Returns true only for the source currently importing.
    func isImporting(_ source: DataSourceImportKind) -> Bool {
        activeImportSource == source
    }

    /// Whether the last import for a source ended in failure (for warning styling).
    func importFailed(_ source: DataSourceImportKind) -> Bool {
        switch source {
        case .whoop: return whoopImportFailed
        case .appleHealth: return appleHealthImportFailed
        case .xiaomi: return xiaomiImportFailed
        }
    }

    /// Smoothed, display-ready live heart rate , median over a short window, spike-filtered.
    /// Every screen should show THIS, not the raw per-beat value (which swings with HRV).
    @Published var bpm: Int?
    private var hrWindow: [(t: Date, v: Double)] = []
    private var hrCancellables = Set<AnyCancellable>()
    /// Drives the READ spine off the registry's active device (#814 HIGH-1). A Devices-screen
    /// switch/remove/re-add calls `registry.setActive` DIRECTLY (not through `registerDevice`), so without
    /// this subscription the reads stayed pinned to whatever id was active at wiring time for the whole
    /// session. Mirrors how `SourceCoordinator` drives the WRITE side off the same publisher. Retained for
    /// the app's lifetime (the registry outlives the session); `removeDuplicates` collapses redundant emits.
    private var readSpineCancellable: AnyCancellable?

    init() {
        let live = LiveState()
        self.live = live
        // SEED every subsystem with the same id (`deviceId`, "my-whoop" at launch). The store/registry
        // aren't open yet here, so the registry's active id can't be read synchronously; `bootstrapStore`
        // (write side) and `wireSourceCoordinator → adoptActiveDevice` (read spine, #814) re-point them to
        // the registry active id once the store opens. Single-device install keeps "my-whoop" throughout.
        self.ble = BLEManager(state: live, deviceId: deviceId)
        self.repo = Repository(deviceId: deviceId)
        self.coach = AICoachEngine(repo: repo)
        self.intelligence = IntelligenceEngine(repo: repo, profile: profile, deviceId: deviceId)
        // Route the engine's per-day scoring diagnostic into the SAME shareable strap log every other
        // subsystem writes to (PII-scrubbed by `live.append(log:)`), so a bug report ships proof of what
        // was computed per day. `live` is captured strongly (created just above) , the engine outlives the
        // app session, so there's no retain-cycle risk worth a weak dance here. (Sleep overhaul §2.5.)
        self.intelligence.diagnosticSink = { [live] line, domain in live.append(log: line, domain: domain) }
        // Workouts & GPS test mode (Test Centre): wire the Repository (auto-detect inputs/why + cross-source
        // dedup decisions) and the GPS recorder (fix-progress) tagged sinks to the SAME shareable strap log.
        // Each emitter re-checks `TestCentre.active(.workouts)` before building a line, so these wirings are
        // inert (one UserDefaults bool read) when the mode is off. `live` is captured strongly, as above.
        self.repo.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        self.gpsRecorder.workoutsLog = { [live] line in live.append(log: line, domain: .workouts) }
        // #961: give the read model the user's HRmax + sex so it can backfill a strap-native workout's
        // Effort on display when the stored value is nil (a live/manual session that ended with sparse HR).
        // Seed it now and keep it in step with any profile edit (objectWillChange fires just before a
        // @Published setter lands, so read the CURRENT values , they're already committed by the time the
        // next reconcile reads `strainProfile`). Display-only; the score itself is unchanged.
        self.repo.strainProfile = Repository.StrainProfile(hrMax: Double(profile.hrMax), sex: profile.sex)
        profile.objectWillChange.sink { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.repo.strainProfile = Repository.StrainProfile(
                    hrMax: Double(self.profile.hrMax), sex: self.profile.sex)
            }
        }.store(in: &hrCancellables)
        // Smooth HR centrally so it's solid everywhere it's shown.
        live.$heartRate.sink { [weak self] _ in self?.ingestDirectHR() }.store(in: &hrCancellables)
        live.$rr.sink { [weak self] rr in self?.ingestRRPacket(rr) }.store(in: &hrCancellables)

        // Physical-input + wear hooks (fired live by FrameRouter).
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
        gpsRecorder.onCheckpoint = { [weak self] checkpoint in
            _ = self?.persistActiveGpsWorkout(checkpoint)
        }
        // Strap battery alerts (#368): low-battery warning + full-charge note. The notifier self-gates
        // on the user's setting and the OS authorization, and carries its own persisted once-per-
        // crossing state, so feeding it every battery reading is safe.
        live.onBatteryUpdate = { [weak self] pct in
            guard let self else { return }
            BatteryNotifier.onBatteryUpdate(pct: Int(pct.rounded()),
                                            charging: self.live.charging,
                                            enabled: self.behavior.batteryAlerts)
            // Predictive runtime alert: the same reading just banked into the SoC buffer, so
            // batteryEstimate is fresh here. Nil estimate (no readings yet) is a no-op — the 15%
            // alert above remains the safety net.
            BatteryNotifier.onRuntimeEstimate(remainingHours: self.live.batteryEstimate?.remainingHours,
                                              charging: self.live.charging,
                                              enabled: self.behavior.batteryAlerts
                                                    && self.behavior.batteryPredictiveAlerts)
        }
        // HR-zone haptic coaching watches the smoothed bpm.
        $bpm.sink { [weak self] hr in self?.coachZone(hr) }.store(in: &hrCancellables)
        // Illness/strain early-warning recomputes when the daily history changes.
        repo.$days.sink { [weak self] days in self?.evaluateIllness(days) }.store(in: &hrCancellables)
        // Re-apply "Continuous HRV capture" on every (re)bond: if on, the strap should hold the dense
        // realtime stream armed even with no Live screen open, so it banks beat-to-beat R-R 24/7 for
        // better overnight HRV/recovery/sleep. The BLE reconciler arms it on the off→on edge; pushing it
        // here (and at the init tail) covers a fresh launch and every reconnect. (See PuffinExperiment.)
        live.$bonded.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
            self.applyPowerSaving()
        }.store(in: &hrCancellables)
        // A backfill burst can end after a clean HISTORY_COMPLETE OR after the idle watchdog, because each
        // chunk is committed before it is acknowledged. Subscribe to the non-optional finalization edge so
        // a heal-only publication still refreshes, while its multi-scope watermark carries every source.
        live.$finalizedHistoricalBurst
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] finalization in
                Task { [weak self] in
                    await self?.refreshAfterBackfillBurst(watermark: finalization.watermark)
                }
            }
            .store(in: &hrCancellables)

        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        // Rehydrate a manual workout that was in flight when iOS killed the app, so it can still be ended
        // + saved on relaunch (#529). Restored here alongside the other UserDefaults-backed state.
        rehydrateActiveWorkout()

        AppModel.shared = self   // publish for App Intents (Shortcuts) , see the static above (#42)

        // Seed the BLE client with the persisted "Continuous HRV capture" intent so `wantsRealtime`
        // reflects it from launch , the reconciler then arms the dense stream as soon as the strap bonds
        // (and the bond sink above re-applies it on every reconnect).
        ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
        applyPowerSaving()

        // Turn the strap's offloaded raw data into dashboard scores on launch and every 15
        // minutes, so recovery / strain / sleep populate from the strap itself with no import.
        // IntelligenceEngine computes, persists under "my-whoop-noop", and refreshes the dashboard.
        // One-shot reclaim of any stale Documents/Inbox picker drops a previous build left behind
        // before cleanup() reclaimed the original, PLUS any stranded `noop-*` temp scratch (e.g. the
        // multi-GB `noop-health-*` export.xml an interrupted import leaves behind , #590). Off the main
        // actor; no-op on macOS for the Inbox part.
        Task.detached { AppModel.purgeImportInbox(); AppModel.purgeImportTemp() }

        // FIX 2(b): the launch sequence runs at `.utility` so its heavy one-shot 4000-day heal/rescore
        // yields to UI rendering instead of contending at the inherited user-initiated QoS. The reads are
        // already off the main actor (analyzeRecent , FIX 1), and at `.utility` the scheduler keeps the
        // main thread free for SwiftUI during the deep-history pass right after an import / first launch.
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let launchTrace = PerformanceTrace.begin("launch_ready")
            #if DEBUG
            // DEBUG-only: when launched with `--demo-seed`, populate a deterministic synthetic
            // dataset so an empty simulator/dev build can walk every screen (verification + marketing
            // screenshots). No-op in Release (whole seeder is #if DEBUG) and once data already exists.
            if AppleDemoSeeder.requested, let store = await self.repo.storeHandle() {
                await AppleDemoSeeder.seedIfRequested(into: store)
                // Give the demo a plausible strap battery so the Today header badge renders (the live
                // battery is runtime-only and nil without a connected strap).
                self.live.batteryPct = 68
            }
            #endif
            // Resolve the active source before first paint. The durable snapshot key includes this lineage,
            // so a re-paired strap can never hydrate the previous source's Recovery/Sleep/Strain values.
            await self.wireSourceCoordinator()
            // First paint is one indexed durable snapshot read. It starts independently from the broad
            // repository refresh, so a stale/missing snapshot can never delay authoritative data loading.
            let firstPaintTask = Task(priority: .userInitiated) { [weak self] in
                await self?.repo.hydrateTodayHealthSnapshot()
            }
            _ = await self.repo.refresh(.initialLoad)          // surface any imported data at once
            _ = await firstPaintTask.value
            await self.recoverPendingSourceTransition()
            // Resume committed source work only after first paint. The receipt path has its own durable
            // checkpoint and exact civil-day scope, so it cannot delay hydration or widen into a launch-time
            // last-21-days sweep. A crash before acknowledgment leaves the same target staged for retry.
            let launchPipeline = await self.signalHistoricalPipeline()
            if launchPipeline.completedWork > 0 {
                await self.refreshV5Signals()
            }
            let repairedArtifacts = await self.repo.repairIncompleteVerifiedArtifacts()
            if repairedArtifacts > 0 {
                await self.signalExternalPublication()
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)  // give the first offload a moment
            // FIX 2(a): DEFER the heavy one-shot 4000-day heal/rescore while an import is in flight. A
            // large Apple Health import is the worst-case launch overlap , running a 4000-iteration heal
            // + rescore concurrently with the import's parse+writes is what produced the ~1-minute app-wide
            // lag. The import refreshes the dashboard itself on completion, and the steady-state cadence
            // loop below still runs, so deferring the ONE-SHOT passes until the import finishes costs
            // nothing but removes the contention. Bounded poll (respects cancellation); typical imports
            // clear in seconds, so this almost always passes through immediately.
            // CAP the wait (#review): `hasActiveImport` is cleared only by finishImport(), which a true
            // non-throwing import HANG would never reach, permanently starving the one-shot passes AND the
            // cadence loop below for the whole session. Bound it so a wedged import can't disable analysis;
            // the merge reads are off-actor now, so proceeding under a still-flagged import is safe.
            var importWaited = 0
            while self.hasActiveImport && !Task.isCancelled && importWaited < 180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s, re-check; ~3 min cap then proceed
                importWaited += 1
            }
            // One-shot on-upgrade heal (#547): purge rows a bad-clock strap dated to scattered garbage
            // (far-past / bogus-2027 / FUTURE) from an older build, then admit a bounded maintenance lane.
            // The persisted flag makes this idempotent on a clean DB; the lane owns all later exact-day work.
            await self.intelligence.runTimestampHealIfNeeded()
            await self.intelligence.enqueuePendingTimestampHealMaintenance()
            await self.fullHistoryRepairMaintenance.signal()
            PerformanceTrace.end(launchTrace)
            while !Task.isCancelled {
                // #547 RE-POLLUTION: a sync since the last tick may have armed a re-heal (its ingest gate
                // dropped bad-clock records). `runTimestampHealIfNeeded` honours the pending flag even after
                // the one-shot done flag is set, purges any pollution, and rescores the affected days , so a
                // wandering-clock strap can't keep re-polluting. A no-op when nothing's pending.
                await self.intelligence.runTimestampHealIfNeeded()
                // #836: the steady-state tick is a BACKSTOP, not a data-driven refresh — every real update
                // (sync backfill, import, edit, recalibrate, heal) already rescores via its own forced call.
                // `force: false` skips the heavy 21-day rescore when the raw HR stream is unchanged since the
                // last run, instead of re-reading ~21×54 h of HR every 15 min on a big-import library. A new
                // sample (the heal above, or a sync) moves the fingerprint and the tick rescores as before.
                await self.intelligence.analyzeRecent(force: false)
                // v5: recompute the skin-temp suite snapshots (cycle phase + body clock) from the
                // freshly-scored history so the Health hub cards read a ready result.
                await self.refreshV5Signals()
                // Advance one durable immutable-artifact repair page per idle cadence grant. The keyset
                // cursor moves past irreparable legacy heads, so later compatible rows cannot starve.
                let cadenceRepairs = await self.repo.repairIncompleteVerifiedArtifacts()
                if cadenceRepairs > 0 {
                    await self.signalExternalPublication()
                }
                try? await Task.sleep(nanoseconds: 900_000_000_000)  // 15 min, matches the offload cadence
            }
        }

        // Shared live physiological-day Strain. A lightweight frontier poll advances only
        // newly banked HR rows, so Today/detail/external publishers stay fresh without a
        // full-day query on each heart-rate tick.
        Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.applicationIsActive && !self.live.backfilling && !self.hasActiveImport {
                    await self.repo.refreshLiveDayStrain(maxHR: Double(self.profile.hrMax))
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Build the device registry + source coordinator once the store is open, then start observing.
    /// #477: push the persisted Power-saving prefs to the BLE manager (parity with Android
    /// `AppViewModel.applyPowerSaving`). Offload-cadence stretch uses the battery-% threshold (0 = off
    /// when the master is off); the HRV pause is a sub-option, only effective while the master is on.
    /// The riskier connection-priority idle throttle is intentionally not wired (Android-only, and dormant).
    func applyPowerSaving() {
        let on = PuffinExperiment.powerSavingEnabled
        ble.setLowBatteryOffloadThrottle(on ? PuffinExperiment.powerSavingBatteryPct : 0)
        // HRV pause is battery-%-aware like the offload lever — pass the same threshold.
        ble.setPauseCaptureOnPowerSave(on && PuffinExperiment.pauseHrvOnPowerSaveEnabled,
                                       thresholdPct: PuffinExperiment.powerSavingBatteryPct)
    }

    /// Attach the single durable external worker after the app composition root creates it. Source
    /// transitions fail closed until this hook is installed; no old sink task may run through a mutation.
    func attachExternalPublicationWorker(_ worker: ExternalPublicationWorker) {
        externalPublicationQuiesce = { try await worker.quiesce() }
        externalPublicationResume = { epoch in try await worker.resume(expectedEpoch: epoch) }
        externalPublicationSignal = { await worker.signal() }
    }

    func attachVerifiedSinkLifecycle(_ lifecycle: any VerifiedSinkLifecycle) {
        verifiedSinkLifecycle = lifecycle
    }

    func attachSourcePrivacyCleanupDrain(
        _ drain: @escaping @Sendable (UUID) async throws -> Void
    ) {
        sourcePrivacyCleanupDrain = drain
    }

    private func quiesceExternalPublication() async throws -> UInt64 {
        guard let externalPublicationQuiesce else {
            throw AppModelSourceTransitionError.externalWorkerUnavailable
        }
        return try await externalPublicationQuiesce()
    }

    private func resumeExternalPublication(_ epoch: UInt64) async throws {
        guard let externalPublicationResume else {
            throw AppModelSourceTransitionError.externalWorkerUnavailable
        }
        try await externalPublicationResume(epoch)
    }

    private func signalExternalPublication() async {
        await externalPublicationSignal?()
    }

    private func sinkDefaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else {
            throw AppModelSourceTransitionError.sinkUnavailable
        }
        return defaults
    }

    private func beginVerifiedSinkTransition() throws -> UInt64 {
        let defaults = try sinkDefaults()
        guard let epoch = ActiveSinkEpochRecovery.beginTransitionRecovering(defaults: defaults) else {
            throw AppModelSourceTransitionError.sinkUnavailable
        }
        ActiveVerifiedSinkEpochStore.clearLegacyKeys(defaults: defaults)
        return epoch
    }

    private func activateVerifiedSinkTransition(epoch: UInt64) throws {
        let defaults = try sinkDefaults()
        guard let contextId = repo.currentVerifiedSinkContextIdForActivation else {
            // An archived/deleted active source is an explicit closed-sink state. Leave the App Group record
            // at (epoch, nil); writers will return superseded until a source is selected again.
            ActiveSinkEpochRecovery.clearVerifiedWidgetState(defaults: defaults)
            ActiveSinkEpochRecovery.clearLiveActivityGeneration(defaults: defaults)
            return
        }
        guard ActiveVerifiedSinkEpochStore.activate(
            contextId: contextId,
            epoch: epoch,
            defaults: defaults) != nil else {
            throw AppModelSourceTransitionError.sinkActivationFailed
        }
    }

    private func makeHistoricalPipelineRuntime() -> HistoricalPipelineRuntime {
        let postAnalysisSnapshotBuilder = RepositoryPostAnalysisSnapshotBuilder.self
        let classifyError: @Sendable (any Error) -> PipelineFailureClassification =
            PR28PipelineErrorClassifier.classify
        let coordinator = HistoricalPipelineCoordinator(dependencies: HistoricalPipelineDependencies(
            leaseNext: { [weak self] owner, now, leaseDuration in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await store.leaseNextHistoricalAnalysisWork(
                    HistoricalAnalysisWorkLeaseRequest(
                        owner: owner, now: now, leaseDuration: leaseDuration
                    )
                )
            },
            applyEvent: { [weak self] workId, event, now in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await store.applyHistoricalAnalysisWorkEvent(
                    workId: workId, event: event, now: now
                )
            },
            analyze: { [weak self] work in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await self.intelligence.analyzeCommittedWork(
                    work, store: store, now: Date()
                )
            },
            loadAnalysis: { [weak self] work in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await self.repo.loadHistoricalAnalysisMutation(
                    work: work, store: store
                )
            },
            verifyAndCommitSnapshot: { [weak self] work, analysis in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await self.repo.buildAndCommitVerifiedHistoricalSnapshot(
                    work: work,
                    analysis: analysis,
                    store: store,
                    now: Date(),
                    snapshotBuilder: postAnalysisSnapshotBuilder
                )
            },
            loadSnapshot: { [weak self] work in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await self.repo.loadHistoricalSnapshotCommit(
                    work: work, store: store
                )
            },
            publishRepository: { [weak self] work, snapshot in
                guard let self else { throw HistoricalPipelineRuntimeError.storeUnavailable }
                let outcome = try await self.repo.publishVerifiedExactDays(
                    snapshot.analyzedDays,
                    recordedTimeZoneIdentifier: snapshot.recordedTimeZoneIdentifier,
                    snapshot: snapshot,
                    sourceDeviceId: work.scope.deviceId
                )
                guard outcome.authoritativeDataPublished else {
                    throw HistoricalPipelineRuntimeError.snapshotUnavailable
                }
            },
            commitOutbox: { [weak self] snapshot in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                let bundle = try await store.verifiedExternalProjectionBundle(
                    contextId: snapshot.projection.contextId,
                    generation: snapshot.snapshotGeneration
                )
                guard let bundle else { return [.healthKit] }
                let destinations = try await store.selectiveExternalPublicationDestinations(
                    snapshot: snapshot,
                    bundle: bundle,
                    now: Date())
                return try await store.enqueueExternalPublications(
                    snapshot: snapshot,
                    destinations: destinations,
                    now: Date())
            },
            classifyError: classifyError,
            now: Date.init
        ))

        let dependencies = HistoricalPipelineRuntimeDependencies(
            rearmEnvironmental: { [weak self] in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                _ = try await store.resumeEnvironmentalBlockedHistoricalAnalysisWork(now: Date())
            },
            admissionContexts: { [weak self] in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
                let rows = try registry.all().filter { $0.status != .archived }
                var contexts: [HistoricalReceiptAdmissionContext] = []
                for sourceId in rows.map(\.id) {
                    guard let scope = try? await store.historicalCursorScope(deviceId: sourceId) else {
                        continue
                    }
                    contexts.append(HistoricalReceiptAdmissionContext(
                        sourceId: sourceId,
                        scope: scope,
                        now: Date()))
                }
                for scope in try await store.drainingHistoricalReceiptScopes()
                    where !contexts.contains(where: { $0.scope == scope }) {
                    contexts.append(HistoricalReceiptAdmissionContext(
                        sourceId: scope.deviceId,
                        scope: scope,
                        now: Date()))
                }
                return contexts
            },
            admit: { [weak self] context in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await store.admitHistoricalReceipts(context)
            },
            coordinator: coordinator,
            pendingWorkCount: { [weak self] in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                return try await store.pendingHistoricalAnalysisWorkCount()
            },
            finalizeDrainedScopes: { [weak self] in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw HistoricalPipelineRuntimeError.storeUnavailable
                }
                _ = try await store.finalizeDrainedHistoricalScopes()
                // Terminal-row pruning is maintenance only. Never let it race first paint or remove a
                // referenced artifact that a delayed publication still needs.
                let canPrune = await MainActor.run {
                    self.repo.loaded && self.repo.todayHealthSnapshot != nil
                }
                guard canPrune else { return }
                let now = Date()
                guard let maintenanceLease = try await store.claimMaintenanceLease(
                    key: DurablePruningCadence.key,
                    owner: "pipeline-prune-\(UUID().uuidString)",
                    now: now,
                    minimumInterval: DurablePruningCadence.minimumInterval
                ) else { return }
                do {
                    _ = try await store.pruneDurablePipelineHistory(now: now)
                    try await store.completeMaintenanceLease(maintenanceLease, at: Date())
                } catch {
                    _ = try? await store.releaseMaintenanceLease(maintenanceLease)
                    throw error
                }
            },
            classifyAdmissionError: PR28PipelineErrorClassifier.classify,
            onAdmissionFailure: { [weak self] failure in
                Task { @MainActor [weak self] in
                    self?.live.append(log: "Historical admission deferred: \(failure.code)")
                }
            },
            report: { [weak self] message in
                Task { @MainActor [weak self] in self?.live.append(log: message) }
            }
        )
        return HistoricalPipelineRuntime(dependencies: dependencies)
    }

    private func makeFullHistoryRepairMaintenance() -> FullHistoryRepairMaintenanceCoordinator {
        FullHistoryRepairMaintenanceCoordinator(dependencies: .init(
            isIdle: { [weak self] in
                guard let self else { return false }
                guard await self.fullHistoryRepairCanRun(),
                      let store = await self.fullHistoryRepairStore() else { return false }
                return (try? await store.pendingHistoricalAnalysisWorkCount()) == 0
            },
            leaseNext: { [weak self] owner, now in
                guard let self else { return nil }
                guard await self.fullHistoryRepairCanRun(),
                      let scope = await self.fullHistoryRepairPresentationScope(),
                      let store = await self.fullHistoryRepairStore() else { return nil }
                return try await store.leaseNextFullHistoryRepair(
                    owner: owner,
                    now: now,
                    scope: scope)
            },
            processNextBatch: { [weak self] work in
                guard let self else { throw FullHistoryRepairMaintenanceError.notIdle }
                return try await self.processFullHistoryRepairBatch(work)
            },
            markProgress: { [weak self] work, hasMore, now in
                guard let self, let store = await self.fullHistoryRepairStore(),
                      let owner = work.leaseOwner else {
                    throw FullHistoryRepairMaintenanceError.leaseLost
                }
                try await store.markFullHistoryRepairProgress(
                    work,
                    owner: owner,
                    hasMore: hasMore,
                    now: now)
            },
            markProgressWithCursor: { [weak self] work, result, now in
                guard let self, let store = await self.fullHistoryRepairStore(),
                      let owner = work.leaseOwner else {
                    throw FullHistoryRepairMaintenanceError.leaseLost
                }
                try await store.markFullHistoryRepairProgress(
                    work,
                    owner: owner,
                    hasMore: result.hasMore,
                    nextStartDay: result.nextStartDay,
                    now: now)
            },
            markFailure: { [weak self] work, error, now in
                guard let self, let store = await self.fullHistoryRepairStore(),
                      let owner = work.leaseOwner else {
                    throw FullHistoryRepairMaintenanceError.leaseLost
                }
                try await store.markFullHistoryRepairFailure(
                    work,
                    owner: owner,
                    error: error,
                    now: now)
            },
            releaseLease: { [weak self] work, now in
                guard let self, let store = await self.fullHistoryRepairStore(),
                      let owner = work.leaseOwner else {
                    throw FullHistoryRepairMaintenanceError.leaseLost
                }
                try await store.cancelFullHistoryRepairLease(
                    work,
                    owner: owner,
                    now: now)
            }
        ))
    }

    private func fullHistoryRepairCanRun() -> Bool {
        FullHistoryRepairAdmissionPolicy.canRun(
            applicationIsActive: applicationIsActive,
            repositoryLoaded: repo.loaded,
            hasActiveLiveSource: repo.liveSourceState.id != nil,
            hasTodaySnapshot: repo.todayHealthSnapshot != nil,
            hasActiveImport: hasActiveImport,
            isBackfilling: live.backfilling,
            hasActiveWorkout: activeWorkout != nil)
    }

    private func fullHistoryRepairPresentationScope() -> HistoricalCursorScope? {
        guard case let .active(source) = repo.liveSourceState else { return nil }
        return HistoricalCursorScope(
            deviceId: source.id,
            lineage: source.historyLineage,
            cursorEpoch: source.cursorEpoch)
    }

    private func fullHistoryRepairOwnsCurrentPresentation(
        _ scope: HistoricalAnalysisScope
    ) -> Bool {
        guard let active = fullHistoryRepairPresentationScope() else { return false }
        return scope.deviceId == active.deviceId
            && scope.deviceLineageId == active.lineage
            && scope.cursorEpoch == active.cursorEpoch
            && scope.trimScope == active.trimScope
    }

    private func fullHistoryRepairStore() async -> WhoopStore? {
        await repo.storeHandle()
    }

    /// Process one bounded oldest-to-newest maintenance window by handing it to the same durable exact-day
    /// executor used by receipt work. The exact executor is the sole Repository publisher. The maintenance
    /// lane advances only its durable cursor after that work reaches `.complete`.
    private func processFullHistoryRepairBatch(
        _ work: FullHistoryRepairWork
    ) async throws -> FullHistoryRepairBatchResult {
        guard fullHistoryRepairCanRun(),
              fullHistoryRepairOwnsCurrentPresentation(work.scope),
              let store = await repo.storeHandle() else {
            throw FullHistoryRepairMaintenanceError.notIdle
        }
        try Task.checkCancellation()

        let fence = TargetScopedPipelineFence.shared
        try await fence.begin(sourceId: work.scope.deviceId)
        var queuedForCancellation: HistoricalAnalysisWork?
        let preparation: (
            queuedWork: HistoricalAnalysisWork,
            hasMore: Bool,
            nextStartDay: CivilDay?
        )
        do {
            guard let bounds = try await store.hrTimestampBounds(deviceId: work.scope.deviceId) else {
                await fence.end(sourceId: work.scope.deviceId)
                return FullHistoryRepairBatchResult(changedDays: [], hasMore: false)
            }
            let calendar = try HealthCalendar(timeZoneIdentifier: work.recordedTimeZoneIdentifier)
            let earliest = try calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(bounds.earliest)))
            let latest = try calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(bounds.latest)))
            let start = work.nextStartDay ?? earliest
            guard start <= latest else {
                await fence.end(sourceId: work.scope.deviceId)
                return FullHistoryRepairBatchResult(changedDays: [], hasMore: false)
            }
            let proposedEnd = try calendar.adding(days: 29, to: start)
            let end = min(proposedEnd, latest)
            let batchDays = try calendar.days(from: start, through: end, limit: 31)
            guard let first = batchDays.first, let last = batchDays.last else {
                await fence.end(sourceId: work.scope.deviceId)
                return FullHistoryRepairBatchResult(changedDays: [], hasMore: false)
            }
            let nextStartDay = try calendar.adding(days: 1, to: last)
            let hasMore = nextStartDay <= latest
            let batchId = Self.deterministicMaintenanceBatchID(
                maintenanceWorkId: work.id,
                startDay: start)
            let interval = try calendar.interval(for: first)
            let lastInterval = try calendar.interval(for: last)
            let exact = try HistoricalAnalysisWork(
                id: batchId,
                scope: work.scope,
                firstReceiptGeneration: work.throughReceiptGeneration,
                lastReceiptGeneration: work.throughReceiptGeneration,
                minimumTs: Int(interval.start.timeIntervalSince1970),
                maximumTs: Int(lastInterval.end.timeIntervalSince1970),
                affectedDays: Set(batchDays),
                kind: .exactDays,
                recordedTimeZoneIdentifier: work.recordedTimeZoneIdentifier,
                createdAt: Date())
            try Task.checkCancellation()
            let queuedWork: HistoricalAnalysisWork
            if let existing = try await store.historicalAnalysisWork(workId: batchId) {
                queuedWork = existing
            } else {
                queuedWork = try await store.enqueueHistoricalAnalysisWork(exact, priority: 20)
            }
            queuedForCancellation = queuedWork
            try Task.checkCancellation()
            guard fullHistoryRepairCanRun(),
                  fullHistoryRepairOwnsCurrentPresentation(work.scope) else {
                throw FullHistoryRepairMaintenanceError.notIdle
            }
            preparation = (queuedWork, hasMore, hasMore ? nextStartDay : nil)
            await fence.end(sourceId: work.scope.deviceId)
        } catch {
            if Task.isCancelled || error is CancellationError, let queuedForCancellation {
                _ = try? await store.cancelPendingHistoricalAnalysisWork(
                    workId: queuedForCancellation.id,
                    scope: queuedForCancellation.scope,
                    reason: "maintenance_owner_cancelled")
            }
            await fence.end(sourceId: work.scope.deviceId)
            throw error
        }

        do {
            var completedWork = try await store.historicalAnalysisWork(
                workId: preparation.queuedWork.id)
            if completedWork?.state != .complete {
                if completedWork?.state == .quarantined {
                    throw FullHistoryRepairMaintenanceError.invalidWork
                }
                _ = await historicalPipelineRuntime.signal()
                try Task.checkCancellation()
                guard fullHistoryRepairOwnsCurrentPresentation(work.scope) else {
                    throw FullHistoryRepairMaintenanceError.notIdle
                }
                completedWork = try await store.historicalAnalysisWork(
                    workId: preparation.queuedWork.id)
            }
            guard let completedWork, completedWork.state == .complete else {
                throw FullHistoryRepairMaintenanceError.notIdle
            }
            return FullHistoryRepairBatchResult(
                changedDays: completedWork.affectedDays,
                hasMore: preparation.hasMore,
                nextStartDay: preparation.nextStartDay)
        } catch {
            if Task.isCancelled || error is CancellationError {
                _ = try? await store.cancelPendingHistoricalAnalysisWork(
                    workId: preparation.queuedWork.id,
                    scope: preparation.queuedWork.scope,
                    reason: "maintenance_owner_cancelled")
            }
            throw error
        }
    }

    private static func deterministicMaintenanceBatchID(
        maintenanceWorkId: UUID,
        startDay: CivilDay
    ) -> UUID {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 10_995_116_282_114_631_977
        let seed = maintenanceWorkId.uuidString + "|" + startDay.key
        for byte in seed.utf8 {
            first ^= UInt64(byte)
            first &*= 1_099_511_628_211
            second ^= UInt64(byte)
            second = (second &* 1_099_511_628_211) &+ 0x9E37_79B9_7F4A_7C15
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff) }
        for index in 0..<8 { bytes[index + 8] = UInt8((second >> UInt64(index * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Tiny and guarded: with no generic strap paired the active id is "my-whoop", so the coordinator
    /// observes WHOOP-active and stays a NO-OP , the existing `scan()`/`disconnect()` WHOOP flow is
    /// untouched. The coordinator only acts if/when a non-WHOOP strap becomes the active device.
    /// `startWhoop`/`stopWhoop` are thin closures over BLEManager's EXISTING public methods (via the
    /// model's `scan()` / `disconnect()`), so the coordinator never references BLEManager directly.
    private func wireSourceCoordinator() async {
        guard sourceCoordinator == nil, let store = await repo.storeHandle() else { return }
        let registry = DeviceRegistry(store: DeviceRegistryStore(dbQueue: store.registryWriter))
        do { try registry.reload() }
        catch {
            live.append(log: "Device registry unavailable; source wiring deferred: \(error)")
            return
        }
        // Establish the source lineage synchronously. The subscription below is still needed for future
        // changes, but its asynchronous initial emission is too late for the startup snapshot contract.
        if let activeDeviceId = registry.activeDeviceId,
           let descriptor = try? registry.sourceDescriptor(for: activeDeviceId) {
            _ = repo.adoptActiveSource(descriptor)
        } else {
            _ = repo.adoptActiveSource(nil)
        }
        let coordinator = SourceCoordinator(
            registry: registry,
            live: live,
            storeHandle: { [weak self] in await self?.repo.storeHandle() },
            startWhoop: { [weak self] in self?.scan() },
            stopWhoop: { [weak self] in self?.disconnect() },
            // WHOOP targeting hooks , thin wrappers over BLEManager's existing additive setters, so the
            // coordinator never references BLEManager directly (mirrors the start/stop injection). On the
            // single-WHOOP path these are setPreferredPeripheral(nil) and (no setActiveDeviceId call),
            // i.e. the BLE engine's defaults , no behaviour change.
            setWhoopPreferredPeripheral: { [weak self] uuid in self?.ble.setPreferredPeripheral(uuid) },
            setWhoopActiveDeviceId: { [weak self] id in self?.ble.setActiveDeviceId(id) },
            // The engine's last-connected WHOOP uuid drives first-connect identity adoption.
            connectedPeripheralUUID: ble.$connectedPeripheralUUID.eraseToAnyPublisher(),
            transitionFence: sourceTransitionFence,
            onPeripheralIdentityWillChange: { _, _ in
                throw AppModelSourceTransitionError.physicalTransitionMissing
            },
            onPeripheralIdentityWillChangeWithPeripheral: { [weak self] deviceId, oldScope, peripheralId in
                try await self?.performSourceTransition(
                    to: deviceId,
                    from: deviceId,
                    kind: .replacePeripheral,
                    replacementPeripheralId: peripheralId,
                    expectedOldScope: oldScope)
            },
            onPeripheralIdentityDidChange: { _ in },
            // Generic-HR connect lifecycle → the SAME strap log BLEManager writes to (`live.append(log:)`),
            // so a "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc
            // path. Timestamp matches BLEManager.log()'s "HH:mm:ss" so the lines read consistently.
            straplog: { [weak self] line in
                self?.live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            })
        coordinator.start()
        self.deviceRegistry = registry
        self.sourceCoordinator = coordinator
        // #814 READ SPINE (HIGH-1): drive the read side off the registry's `activeDeviceId` for the WHOLE
        // session, exactly as SourceCoordinator drives the WRITE side off the SAME publisher. A Devices-
        // screen switch/remove/re-add calls `registry.setActive` DIRECTLY (NOT through `registerDevice`), so
        // a one-shot adopt at wiring time would leave the reads pinned to the launch-time active id all
        // session, a re-add's fresh "whoop-<uuid>" raw never surfaced until the next relaunch. The
        // subscription re-points the Repository's active-strap READ id on every change; `adoptActiveDevice`
        // is idempotent, so the initial emission (the current active id) does the first adopt and any later
        // explicit `adoptActiveDevice` call (e.g. from `registerDevice`) is safely redundant. The import +
        // computed WRITE targets stay STABLE on the canonical id (see `adoptActiveDevice`'s union-model note).
        readSpineCancellable = registry.$activeDeviceId
            .removeDuplicates()
            .sink { [weak self] id in
                Task { await self?.adoptActiveDevice(id) }
            }
    }

    /// Re-point the Repository's ACTIVE-strap READ id at `activeId` and, if it moved, refresh + re-score so a
    /// re-added strap's LIVE raw (written under its fresh "whoop-<uuid>" id) surfaces on the dashboard (#814).
    /// Centralised so the registry-active subscription and a device add/activate share one path. A no-op (no
    /// refresh) when the id is unchanged (the common single-device case).
    ///
    /// UNION MODEL (#814 follow-up): this moves ONLY the read-side active-strap id. The WHOOP-IMPORT + the
    /// engine's COMPUTED write target, and the FusionSource `.whoopImport` mapping, stay STABLE on the
    /// canonical `deviceId` ("my-whoop"), they must NOT follow the active strap, or history imported/scored
    /// earlier under the canonical id would be orphaned. The Repository reads the UNION of the active strap +
    /// the canonical id, so both the re-added strap's live data AND the canonical history surface. The engine
    /// already resolves the active strap per day via the registry's own active id (`resolveDayOwner`), so it
    /// reads + scores the re-added strap's raw and writes the computed result to the STABLE canonical
    /// `-noop` sibling, no engine re-point needed.
    private func adoptActiveDevice(_ activeId: String?) async {
        guard let activeId else {
            _ = repo.adoptActiveSource(nil)
            return
        }
        await sourceTransitionFence.run { @MainActor [weak self] in
            await self?.adoptActiveDeviceUnfenced(activeId)
        }
    }

    private func restoreVerifiedSinkTransition(
        _ record: SourceTransitionRecoveryRecord
    ) throws {
        let defaults = try sinkDefaults()
        if let contextId = record.previousSinkContextId {
            if let current = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
               current.contextId == contextId {
                guard verifiedSinkLifecycle?.activate(
                    contextId: contextId,
                    epoch: current.epoch
                ) == true else {
                    throw AppModelSourceTransitionError.sinkActivationFailed
                }
                return
            }
            let storedRecord = defaults.data(forKey: ActiveVerifiedSinkEpochStore.activeKey)
                .flatMap { try? JSONDecoder().decode(ActiveVerifiedSinkEpochRecord.self, from: $0) }
            let epoch = record.sinkEpoch ?? storedRecord?.epoch ?? record.previousSinkEpoch
            guard let epoch, epoch > 0 else {
                throw AppModelSourceTransitionError.sinkActivationFailed
            }
            guard ActiveVerifiedSinkEpochStore.activate(
                contextId: contextId,
                epoch: epoch,
                defaults: defaults) != nil else {
                throw AppModelSourceTransitionError.sinkActivationFailed
            }
            guard verifiedSinkLifecycle?.activate(contextId: contextId, epoch: epoch) == true else {
                throw AppModelSourceTransitionError.sinkActivationFailed
            }
        } else {
            ActiveSinkEpochRecovery.clearVerifiedWidgetState(defaults: defaults)
            ActiveSinkEpochRecovery.clearLiveActivityGeneration(defaults: defaults)
        }
    }

    private func sourceTransitionCoordinator(
        mutation: DurableSourceLifecycleMutation?,
        sourceDeviceId: String,
        transitionScope: SourceTransitionScope,
        previousSinkContextId: String?
    ) -> SourceTransitionRecoveryCoordinator<DurableSourceLifecycleCommit> {
        let activeProjectionTransition = transitionScope == .activeProjection
        let derivedDeviceId = sourceDeviceId + "-noop"
        let dependencies = SourceTransitionRecoveryDependencies<DurableSourceLifecycleCommit>(
            quiesceHistorical: { [weak self] in
                guard let self else { throw AppModelSourceTransitionError.storeUnavailable }
                await self.fullHistoryRepairMaintenance.suspend()
                let epoch: UInt64
                do {
                    epoch = activeProjectionTransition
                        ? try await self.historicalPipelineRuntime.quiesce()
                        : Self.noGlobalSourceTransitionEpoch
                } catch {
                    await self.fullHistoryRepairMaintenance.resume()
                    throw error
                }
                await TargetScopedPipelineFence.shared.quiesce(sourceId: sourceDeviceId)
                await TargetScopedPipelineFence.shared.quiesce(sourceId: derivedDeviceId)
                await self.fullHistoryRepairMaintenance.waitForCancellation()
                return epoch
            },
            quiesceExternal: { [weak self] in
                guard let self else { throw AppModelSourceTransitionError.externalWorkerUnavailable }
                return activeProjectionTransition
                    ? try await self.quiesceExternalPublication()
                    : Self.noGlobalSourceTransitionEpoch
            },
            stopAffectedLiveSource: { [weak self] in
                guard let self, activeProjectionTransition else { return }
                let repo = await MainActor.run {
                    self.sourceCoordinator?.stopForTransition()
                    self.repo.invalidateVerifiedExternalSurface()
                    return self.repo
                }
                await repo.invalidateTodayHealthSnapshot()
            },
            restartPreviousSource: { [weak self] record in
                guard let self, activeProjectionTransition else { return }
                await MainActor.run {
                    self.sourceCoordinator?.activeDeviceChanged(to: record.previousActiveDeviceId)
                    self.schedulePostCommitSourceWork(targetDeviceId: record.previousActiveDeviceId)
                }
            },
            beginSinkTransition: { [weak self] in
                guard let self else { throw AppModelSourceTransitionError.sinkUnavailable }
                guard activeProjectionTransition else {
                    return Self.noGlobalSourceTransitionEpoch
                }
                guard let lifecycle = await MainActor.run(body: {
                    self.verifiedSinkLifecycle
                }) else {
                    throw AppModelSourceTransitionError.sinkUnavailable
                }
                // No explicit carry-forward identity exists. Clear and reload every active-projection
                // surface before the App Group token rotates, including ordinary A-to-B selection.
                await lifecycle.prepareTransition(scope: .clearPrivacyVisibleState)
                return try await MainActor.run {
                    try self.beginVerifiedSinkTransition()
                }
            },
            restorePrecommitSink: { [weak self] record in
                guard let self, activeProjectionTransition else { return }
                try await MainActor.run {
                    try self.restoreVerifiedSinkTransition(record)
                }
            },
            persistRecovery: { [weak self] record in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw AppModelSourceTransitionError.storeUnavailable
                }
                try await store.persistSourceTransitionRecovery(record)
            },
            loadRecovery: { [weak self] in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw AppModelSourceTransitionError.storeUnavailable
                }
                return try await store.latestSourceTransitionRecovery()
            },
            commitStoreMutation: { [weak self] prepared in
                guard let self, let mutation, let store = await self.repo.storeHandle() else {
                    throw AppModelSourceTransitionError.storeUnavailable
                }
                return try await store.commitSourceLifecycleMutation(
                    mutation,
                    recovery: prepared
                )
            },
            loadCommittedMutation: { [weak self] transitionId in
                guard let self, let store = await self.repo.storeHandle() else {
                    throw AppModelSourceTransitionError.storeUnavailable
                }
                return try await store.sourceTransitionCommit(transitionId: transitionId)
            },
            activateSink: { [weak self] epoch, commit in
                guard let self else { throw AppModelSourceTransitionError.storeUnavailable }
                let repo = try await MainActor.run { () throws -> Repository in
                    try self.deviceRegistry?.reload()
                    if let activeId = commit?.activeDeviceId,
                       let registry = self.deviceRegistry,
                       let descriptor = try? registry.sourceDescriptor(for: activeId) {
                        _ = self.repo.adoptActiveSource(descriptor)
                    } else if self.deviceRegistry?.activeDeviceId == nil {
                        _ = self.repo.adoptActiveSource(nil)
                    }
                    return self.repo
                }
                guard activeProjectionTransition else { return }
                if let store = await repo.storeHandle() {
                    try await store.retireLatestStatePublications(contextId: previousSinkContextId)
                }
                let activation = try await MainActor.run { () throws -> (String?, Bool) in
                    try self.activateVerifiedSinkTransition(epoch: epoch)
                    guard let contextId = self.repo.currentVerifiedSinkContextIdForActivation else {
                        return (nil, true)
                    }
                    let activated = self.verifiedSinkLifecycle?.activate(
                        contextId: contextId,
                        epoch: epoch
                    ) ?? false
                    return (contextId, activated)
                }
                guard activation.0 == nil || activation.1 else {
                    throw AppModelSourceTransitionError.sinkActivationFailed
                }
            },
            resumeHistorical: { [weak self] epoch in
                guard let self else { return }
                var resumeError: (any Error)?
                if activeProjectionTransition {
                    do {
                        try await self.historicalPipelineRuntime.resume(expectedEpoch: epoch)
                    } catch {
                        resumeError = error
                    }
                }
                await TargetScopedPipelineFence.shared.resume(sourceId: derivedDeviceId)
                await TargetScopedPipelineFence.shared.resume(sourceId: sourceDeviceId)
                await self.fullHistoryRepairMaintenance.resume()
                if let resumeError { throw resumeError }
            },
            resumeExternal: { [weak self] epoch in
                guard let self, activeProjectionTransition else { return }
                try await self.resumeExternalPublication(epoch)
            },
            startCommittedSource: { [weak self] commit in
                guard let self, activeProjectionTransition else { return }
                await MainActor.run {
                    self.sourceCoordinator?.activeDeviceChanged(to: commit?.activeDeviceId)
                }
            },
            scheduleExactPostCommit: { [weak self] record, commit in
                guard let self else { return }
                if let cleanupWorkId = record.cleanupWorkId {
                    guard let drain = await MainActor.run(body: {
                        self.sourcePrivacyCleanupDrain
                    }) else {
                        throw AppModelSourceTransitionError.privacyCleanupUnavailable
                    }
                    try await drain(cleanupWorkId)
                }
                guard activeProjectionTransition else { return }
                await MainActor.run {
                    self.schedulePostCommitSourceWork(targetDeviceId: commit?.activeDeviceId)
                }
            },
            classify: { String(describing: $0) }
        )
        return SourceTransitionRecoveryCoordinator(dependencies: dependencies)
    }

    /// Re-enter the single durable source-transition state machine after launch, foreground, or protected-data
    /// recovery. The same fence serializes this with device actions and registry/BLE callbacks.
    func recoverPendingSourceTransition() async {
        await sourceTransitionFence.run { @MainActor [weak self] in
            await self?.recoverDurableSourceTransitionIfNeededUnfenced()
        }
    }

    /// A prepared record aborts safely. Postcommit stages load the exact commit payload captured in the same
    /// SQLite transaction and move forward. Call only while `sourceTransitionFence` owns source mutation.
    private func recoverDurableSourceTransitionIfNeededUnfenced() async {
        guard let store = await repo.storeHandle(),
              let record = try? await store.latestSourceTransitionRecovery() else { return }
        let coordinator = sourceTransitionCoordinator(
            mutation: nil,
            sourceDeviceId: record.sourceDeviceId,
            transitionScope: record.transitionScope,
            previousSinkContextId: record.previousSinkContextId
        )
        do {
            try await coordinator.recoverPending()
        } catch {
            live.append(log: "Durable source transition recovery deferred: \(error)")
        }
    }

    private func adoptActiveDeviceUnfenced(_ activeId: String) async {
        let trimmed = activeId.trimmingCharacters(in: .whitespaces)
        let descriptor = deviceRegistry.flatMap { try? $0.sourceDescriptor(for: trimmed) }
        let repoMoved = repo.adoptActiveSource(descriptor)
        guard repoMoved else { return }
        live.append(log: "Read spine re-pointed to active device after registry change (#814).")
        _ = await repo.refresh(.activeDeviceChanged)
        _ = await signalHistoricalPipeline()
    }

    /// One-size-fits-all source cleanup caused ordinary A->B selection to retire A and delete its pending
    /// HealthKit state. This operation keeps the four lifecycle cases explicit.
    private func performSourceTransition(
        to targetDeviceId: String?,
        from oldDeviceId: String?,
        kind: DurableSourceTransitionKind,
        archivedDeviceId: String? = nil,
        replacementPeripheralId: String? = nil,
        expectedOldScope: HistoricalCursorScope? = nil
    ) async throws {
        guard let registry = deviceRegistry else {
            throw AppModelSourceTransitionError.registryUnavailable
        }
        if let targetDeviceId,
           !registry.devices.contains(where: { $0.id == targetDeviceId && $0.status != .archived }) {
            throw AppModelSourceTransitionError.targetUnavailable
        }
        guard await repo.storeHandle() != nil else {
            throw AppModelSourceTransitionError.storeUnavailable
        }

        let sourceDeviceId: String
        if kind == .selectExisting {
            guard let targetDeviceId else { throw AppModelSourceTransitionError.targetUnavailable }
            sourceDeviceId = targetDeviceId
        } else {
            guard let resolved = oldDeviceId ?? archivedDeviceId ?? targetDeviceId else {
                throw AppModelSourceTransitionError.targetUnavailable
            }
            sourceDeviceId = resolved
        }
        let mutation: DurableSourceLifecycleMutation
        let mutationName: String
        switch kind {
        case .selectExisting:
            mutation = .selectExisting(deviceId: sourceDeviceId)
            mutationName = "selectExisting"
        case .replacePeripheral:
            guard let replacementPeripheralId, let expectedOldScope,
                  expectedOldScope.deviceId == sourceDeviceId else {
                throw AppModelSourceTransitionError.physicalTransitionMissing
            }
            mutation = .replacePeripheral(
                deviceId: sourceDeviceId,
                expectedOldLineage: expectedOldScope.lineage,
                peripheralId: replacementPeripheralId,
                consumerId: "phase34.analysis")
            mutationName = "replacePeripheral"
        case .archive:
            guard archivedDeviceId == sourceDeviceId else {
                throw AppModelSourceTransitionError.targetUnavailable
            }
            mutation = .archive(
                deviceId: sourceDeviceId,
                replacementActiveId: targetDeviceId,
                consumerId: "phase34.analysis")
            mutationName = "archive"
        case .deleteData:
            guard oldDeviceId == sourceDeviceId else {
                throw AppModelSourceTransitionError.targetUnavailable
            }
            mutation = .deleteData(deviceId: sourceDeviceId, consumerId: "phase34.analysis")
            mutationName = "deleteData"
        }

        let previousActiveDeviceId = registry.activeDeviceId
        let previousSinkRecord: ActiveVerifiedSinkEpochRecord? = {
            guard let defaults = try? sinkDefaults(),
                  let data = defaults.data(forKey: ActiveVerifiedSinkEpochStore.activeKey) else {
                return nil
            }
            return try? JSONDecoder().decode(ActiveVerifiedSinkEpochRecord.self, from: data)
        }()
        let contributors = ActiveProjectionContributorSet(
            deviceIds: repo.activeProjectionContributorIds
        )
        let transitionScope: SourceTransitionScope = kind == .selectExisting
            ? .activeProjection
            : contributors.scope(affecting: sourceDeviceId)
        let plannedRecord = SourceTransitionRecoveryRecord(
            mutationKind: mutationName,
            sourceDeviceId: sourceDeviceId,
            targetDeviceId: targetDeviceId,
            previousActiveDeviceId: previousActiveDeviceId,
            previousSinkContextId: previousSinkRecord?.contextId,
            previousSinkEpoch: previousSinkRecord?.epoch,
            contributorIds: contributors.deviceIds,
            transitionScope: transitionScope,
            cleanupWorkId: kind == .deleteData ? UUID() : nil
        )
        let coordinator = sourceTransitionCoordinator(
            mutation: mutation,
            sourceDeviceId: sourceDeviceId,
            transitionScope: transitionScope,
            previousSinkContextId: plannedRecord.previousSinkContextId)
        try await coordinator.perform(plannedRecord: plannedRecord)
        try registry.reload()
        live.append(log: "Source transition committed for \(sourceDeviceId).")
    }

    private func schedulePostCommitSourceWork(targetDeviceId: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let targetDeviceId,
               let registry = self.deviceRegistry,
               let descriptor = try? registry.sourceDescriptor(for: targetDeviceId) {
                _ = self.repo.adoptActiveSource(descriptor)
            } else if self.deviceRegistry?.activeDeviceId == nil {
                _ = self.repo.adoptActiveSource(nil)
            }
            _ = await self.repo.refresh(.activeDeviceChanged)
            _ = await self.signalHistoricalPipeline()
        }
    }

    /// Devices screen and pairing-wizard entry point. The mutation itself is queued with old-scope cleanup.
    func makeActiveDevice(_ id: String) {
        Task { @MainActor [weak self] in
            guard let self, let registry = self.deviceRegistry else { return }
            let oldId = registry.activeDeviceId
            guard oldId != id else { return }
            do {
                try await self.sourceTransitionFence.runThrowing { @MainActor [weak self] in
                    guard let self else { throw AppModelSourceTransitionError.registryUnavailable }
                    try await self.performSourceTransition(
                        to: id, from: oldId, kind: .selectExisting)
                }
                self.schedulePostCommitSourceWork(targetDeviceId: id)
            } catch {
                self.live.append(log: "Make Active failed closed: \(error)")
            }
        }
    }

    /// Archive a device through the same source-lineage fence. Raw data remains until the user chooses the
    /// separate delete-data action, but pending work and external projections for that source are retired.
    func archiveDevice(_ id: String) {
        Task { @MainActor [weak self] in
            guard let self, let registry = self.deviceRegistry else { return }
            let replacement = registry.activeDeviceId == id ? nil : registry.activeDeviceId
            do {
                try await self.sourceTransitionFence.runThrowing { @MainActor [weak self] in
                    guard let self else { throw AppModelSourceTransitionError.registryUnavailable }
                    try await self.performSourceTransition(
                        to: replacement,
                        from: id,
                        kind: .archive,
                        archivedDeviceId: id)
                }
            } catch {
                self.live.append(log: "Archive failed closed: \(error)")
            }
        }
    }

    /// Delete one source's durable rows behind the existing destructive UI gate. The operation also clears
    /// external publication state and advances the source lineage before the dashboard refreshes.
    func deleteDeviceData(_ id: String) {
        Task { @MainActor [weak self] in
            guard let self, let registry = self.deviceRegistry else { return }
            do {
                try await self.sourceTransitionFence.runThrowing { @MainActor [weak self] in
                    guard let self else { throw AppModelSourceTransitionError.registryUnavailable }
                    try await self.performSourceTransition(
                        to: registry.activeDeviceId,
                        from: id,
                        kind: .deleteData)
                }
            } catch {
                self.live.append(log: "Privacy delete failed closed: \(error)")
            }
        }
    }

    private func refreshAfterBackfillBurst(watermark: HistoricalReceiptWatermark? = nil) async {
        let trace = PerformanceTrace.begin("backfill_finalize")
        defer { PerformanceTrace.end(trace) }
        if let watermark {
            let scopes = watermark.coordinates.map {
                "\($0.sourceIdentity.deviceId)#\($0.sourceIdentity.lineage)#\($0.sourceIdentity.epoch) through \($0.throughGeneration)"
            }.joined(separator: ", ")
            live.append(log: "Backfill: refreshing dashboard cache for source scopes [\(scopes)]")
        } else {
            live.append(log: "Backfill: refreshing dashboard cache from timestamp-heal publication")
        }
        let pipeline = await signalHistoricalPipeline()
        if pipeline.completedWork > 0 {
            await refreshV5Signals()
            return
        }

        // A timestamp-heal-only finalization has no receipt to checkpoint. Preserve its existing dedicated
        // recovery route; a receipt-bearing burst must fail closed instead of falling back to a broad scan.
        guard watermark == nil else {
            if pipeline.deferredWork > 0 || pipeline.pendingWork ?? 0 > 0 {
                live.append(log: "Backfill: durable receipt analysis remains pending; retaining the prior Home generation.")
            }
            return
        }
        await intelligence.enqueuePendingTimestampHealMaintenance()
        await fullHistoryRepairMaintenance.signal()
        live.append(log: "Backfill: timestamp-heal evidence remains in the bounded maintenance lane.")
    }

    /// Signal the durable pipeline. Counts are diagnostic only; durable work remains the source of truth.
    private func signalHistoricalPipeline() async -> HistoricalPipelineRuntimeResult {
        await intelligence.enqueuePendingTimestampHealMaintenance()
        let result = await historicalPipelineRuntime.signal()
        // Broad repair is intentionally separate from the exact receipt drain. It can only acquire work
        // after this call has had a chance to admit/finish current-day work, and its own idle gate enforces
        // Today-first-paint plus background/no-import/no-workout conditions.
        await fullHistoryRepairMaintenance.signal()
        if result.admittedReceipts > 0 || result.completedWork > 0 {
            let pending = result.pendingWork.map(String.init) ?? "unknown"
            live.append(log: "Historical pipeline: admitted \(result.admittedReceipts) receipt(s), completed \(result.completedWork) exact work item(s), pending \(pending).")
        }
        return result
    }

    /// Lifecycle re-arm for environmental failures. The runtime performs the
    /// whitelist re-arm and drains immediately; structural rows remain blocked.
    func resumeEnvironmentalBlockedHistoricalWorkAndDrain() async {
        _ = await signalHistoricalPipeline()
    }

    /// One post-analysis refresh publishes both committed raw history and its computed rows. It runs only
    /// after receipt acknowledgement or the pre-existing heal-only path, so it never replaces a visible
    /// dashboard generation with a half-analyzed result.
    private func publishAfterCommittedHistoricalAnalysis() async {
        _ = await repo.refresh(.currentDay)
        await refreshV5Signals()
        #if os(iOS)
        // #980: a strap backfill routinely completes while the app is BACKGROUNDED (it runs as a
        // bluetooth-central, so it stays alive to receive the offload). The only other widget-publish
        // sites are gated on scenePhase == .active, so a background sync would rescore today's data but
        // never rewrite the shared App-Group snapshot or call WidgetCenter.reloadAllTimelines — the
        // widget kept showing yesterday's numbers. Publishing here, on the real "new data landed"
        // signal, pushes the fresh snapshot to the home-screen widget without needing a foreground.
        _ = await WidgetSnapshot.publish(from: self)
        #endif
    }

    /// Direct HR and R-R are independent live streams. Keeping their sinks separate prevents one R-R
    /// packet from re-running HR smoothing/workout capture and prevents a direct-HR tick from appending
    /// the same R-R packet to the stress window a second time.
    private func ingestDirectHR() {
        guard let hr = live.heartRate, hr >= 30, hr <= 220 else {
            // #39: when the live source is gone (disconnect blanks heartRate AND rr), drop the stale
            // median so screens that now prefer `bpm` fall through to "," instead of freezing on the
            // last value. Mirrors Android (_bpm = null on disconnect). A transient out-of-range sample
            // with the link still up (heartRate or rr still present) keeps the last median.
            if live.heartRate == nil && live.rr.isEmpty { resetSmoothing() }
            return
        }
        ingestInstantaneousHR(Double(hr))
    }

    private func ingestRRPacket(_ packet: [Int]) {
        evaluateStress(packet)
        // R-R is only an HR fallback. When a valid direct-HR stream exists, its publisher owns
        // smoothing and workout capture, so the higher-frequency R-R publisher cannot duplicate work.
        guard !(live.heartRate.map { (30...220).contains($0) } ?? false),
              let rr = packet.last, rr > 0 else { return }
        let fallback = 60_000.0 / Double(rr)
        guard fallback >= 30, fallback <= 220 else { return }
        ingestInstantaneousHR(fallback)
    }

    /// Fold one fresh instantaneous HR into the 10-second median window.
    private func ingestInstantaneousHR(_ inst: Double) {
        let now = Date()
        hrWindow.append((now, inst))
        hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10s window
        if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
        let vals = hrWindow.map(\.v).sorted()
        // live perf: only republish when the SMOOTHED value actually changes. ingestHR fires on every
        // heartRate AND rr update (~1–3 Hz), but the median is stable across most of them , an
        // unconditional assign re-renders every bpm observer (Live, menu bar, widgets) for nothing.
        let smoothed = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
        if bpm != smoothed { bpm = smoothed }
        captureWorkoutSample()
    }

    // MARK: - Manual workout tracking

    /// Begin a manually-tracked workout for the named `sport` (the picker passes the chosen catalogue
    /// name; callers that don't pick a sport get the catalogue default "Other", parity with Android's
    /// `startWorkout(sport:)`). The active card on Live then shows elapsed time, live HR and strain
    /// building; End scores + saves it under this sport. Confirms with a single buzz. (#519)
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        activeWorkout = ActiveWorkout(start: started, sport: resolved,
                                      maxHR: Double(profile.hrMax))
        acquireWorkoutRealtimeHR()
        workoutFinishState = .recording
        pendingWorkoutSnapshot = nil
        pendingWorkoutEnd = nil
        pendingWorkoutRoute = nil
        pendingWorkoutWasGps = false
        workoutSnapshotDurabilityFailed = false
        gpsSnapshotDurabilityFailed = false
        gpsHadTerminatedGap = false
        refreshWorkoutDurabilityWarning()
        // #524: arm GPS route recording for a distance-type sport (run / ride / walk / hike), mirroring
        // Android, which defaults GPS on for `isDistanceSport`. Manual-first / opt-in: only these sports
        // record a route, and the recorder still captures nothing unless the user grants When-In-Use
        // location (and on a Mac with no GPS it stays empty) , the session always banks HR + Effort
        // regardless. A non-distance sport (yoga, strength) never touches location at all.
        activeWorkoutIsGps = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.start(
                sessionID: activeWorkout!.sessionID,
                startMs: Int64(started.timeIntervalSince1970 * 1000)
            )
            if let checkpoint = gpsRecorder.persistenceCheckpoint() {
                _ = persistActiveGpsWorkout(checkpoint, synchronously: true)
            }
        }
        // Make the session durable from the first instant (#529): persist it now so an OS kill right
        // after Start , before any HR sample lands , can still be rehydrated + ended on relaunch.
        let initialSnapshotCommitted = persistActiveWorkout(force: true, synchronously: true)
            || persistActiveWorkout(force: true, synchronously: true)
        if !initialSnapshotCommitted {
            workoutSnapshotDurabilityFailed = true
            refreshWorkoutDurabilityWarning()
        }
        // Workouts & GPS test mode (Test Centre): one session-start line tagged `.workouts`. Zero-cost when
        // off (the gate is one UserDefaults bool read), so the lifecycle of a missing workout is visible.
        emitWorkoutsTrace(WorkoutsTrace.sessionLine(
            event: "start", sportKey: WorkoutSource.traceSportKey(resolved), hrSamples: 0))
        buzz(loops: 1)
    }

    /// Emit one Workouts & GPS test-mode line tagged `.workouts` iff the mode is on. The cheap
    /// `TestCentre.active(.workouts)` gate is checked BEFORE the @autoclosure builds the line, so nothing is
    /// constructed when the mode is off. Diagnostic only - the session lifecycle is unchanged.
    private func emitWorkoutsTrace(_ build: @autoclosure () -> String) {
        guard TestCentre.active(.workouts) else { return }
        live.append(log: build(), domain: .workouts)
    }

    /// The gated sink the import handlers pass to the importers for the Import & Data Ingest test mode.
    /// Returns nil when the mode is off, so the importer takes its byte-identical untraced path (it builds
    /// no trace line and captures nothing extra); returns a `@Sendable` closure that hops the batch of
    /// already-redacted lines to the main actor (LiveState is @MainActor) and appends them, tagged
    /// `.dataImport`, in order, when the mode is on. The importer runs nonisolated, so the main-actor hop
    /// keeps the append race-free. One UserDefaults bool read decides whether any of this runs.
    private func importTraceSink() -> (@Sendable ([String]) -> Void)? {
        guard TestCentre.active(.dataImport) else { return nil }
        return { [weak self] lines in
            Task { @MainActor in
                guard let self else { return }
                for line in lines { self.live.append(log: line, domain: .dataImport) }
            }
        }
    }

    /// Emit the file-meta line for an import run (detected kind + extension + size BUCKET, never the path or
    /// name), tagged `.dataImport`, iff the mode is on. Called by the handlers that have the materialized
    /// URL. The size is bucketed inside `ImportTrace`, so no byte-exact size or filename leaves the device.
    private func emitImportFileMeta(kind: DataSourceKind, url: URL) {
        guard TestCentre.active(.dataImport) else { return }
        let ext = url.pathExtension
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        live.append(log: ImportTrace.fileMetaLine(sourceKind: kind, ext: ext, sizeBytes: size),
                    domain: .dataImport)
    }

    /// Persist the in-flight manual workout to `UserDefaults` so it survives the app being killed mid-
    /// session (#529). Called on start + each captured sample. A no-op when nothing is running. Apple has
    /// no GPS-route session, so every manual workout is the "non-GPS" case and gets this durability ,
    /// the Apple analogue of Android's `persistNonGpsWorkout`.
    @discardableResult
    private func persistActiveWorkout(
        force: Bool = false,
        synchronously: Bool = false
    ) -> Bool {
        guard let w = activeWorkout else { return true }
        let now = Date()
        guard force || now.timeIntervalSince(lastWorkoutSnapshotEnqueuedAt) >= 5 else { return true }
        latestWorkoutSnapshotAttempt &+= 1
        let attempt = latestWorkoutSnapshotAttempt
        let sessionID = w.sessionID
        let accepted = ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                sessionID: sessionID,
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport,
                samples: w.samples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrainState: w.liveStrainState),
            synchronously: synchronously,
            onCommit: { [weak self] committed in
                guard let self,
                      self.activeWorkout?.sessionID == sessionID,
                      self.latestWorkoutSnapshotAttempt == attempt
                else { return }
                if committed {
                    self.lastWorkoutSnapshotAt = now
                    self.workoutSnapshotDurabilityFailed = false
                } else {
                    self.lastWorkoutSnapshotEnqueuedAt = .distantPast
                    self.workoutSnapshotDurabilityFailed = true
                }
                self.refreshWorkoutDurabilityWarning()
            }
        )
        if accepted {
            lastWorkoutSnapshotEnqueuedAt = now
            // Synchronous callers have received the actual metadata-commit result, so their durable
            // timestamp can advance immediately. Asynchronous callers wait for `onCommit` above.
            if synchronously {
                lastWorkoutSnapshotAt = now
                workoutSnapshotDurabilityFailed = false
                refreshWorkoutDurabilityWarning()
            }
        } else {
            lastWorkoutSnapshotEnqueuedAt = .distantPast
            workoutSnapshotDurabilityFailed = true
            refreshWorkoutDurabilityWarning()
        }
        return accepted
    }

    @discardableResult
    private func persistActiveGpsWorkout(
        _ checkpoint: ActiveGpsWorkoutPersistence.Checkpoint,
        synchronously: Bool = false
    ) -> Bool {
        guard activeWorkout?.sessionID == checkpoint.sessionID, activeWorkoutIsGps else { return true }
        latestGpsSnapshotAttempt &+= 1
        let attempt = latestGpsSnapshotAttempt
        let sessionID = checkpoint.sessionID
        let accepted = ActiveGpsWorkoutPersistence.store(
            checkpoint,
            synchronously: synchronously,
            onCommit: { [weak self] committed in
                guard let self,
                      self.activeWorkout?.sessionID == sessionID,
                      self.latestGpsSnapshotAttempt == attempt else { return }
                self.gpsSnapshotDurabilityFailed = !committed
                self.refreshWorkoutDurabilityWarning()
            }
        )
        if synchronously {
            gpsSnapshotDurabilityFailed = !accepted
            refreshWorkoutDurabilityWarning()
        } else if !accepted {
            gpsSnapshotDurabilityFailed = true
            refreshWorkoutDurabilityWarning()
        }
        return accepted
    }

    private func refreshWorkoutDurabilityWarning() {
        guard activeWorkout != nil else {
            workoutDurabilityWarning = nil
            return
        }
        if workoutSnapshotDurabilityFailed || gpsSnapshotDurabilityFailed {
            workoutDurabilityWarning = String(localized: "This workout is recording, but recent changes are not safely recoverable if NOOP closes. Keep the app open and free storage before continuing.")
        } else if gpsHadTerminatedGap {
            workoutDurabilityWarning = String(localized: "GPS paused while NOOP was closed. Your captured route was restored and recording can resume. The gap is separated and is not added to distance.")
        } else {
            workoutDurabilityWarning = nil
        }
    }

    /// If a manual workout was in flight when iOS killed the app, rebuild `activeWorkout` from the durable
    /// snapshot so reopening doesn't lose it , the session can still be ended + saved (#529). The Apple
    /// analogue of Android's `rehydrateActiveNonGpsWorkout`. No-op when a workout is already live (a live
    /// session wins over a stale snapshot) or nothing is stored. Called once from `init`.
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        let w = ActiveWorkout(sessionID: snap.sessionID,
                              start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport, maxHR: Double(profile.hrMax))
        w.restore(samples: snap.samples)
        activeWorkout = w
        acquireWorkoutRealtimeHR()
        if let gps = ActiveGpsWorkoutPersistence.load(), gps.sessionID == snap.sessionID {
            activeWorkoutIsGps = true
            gpsRecorder.restore(gps)
            if gps.recordingWasActive {
                gpsHadTerminatedGap = true
                refreshWorkoutDurabilityWarning()
            }
        }
    }

    /// Flushes the in-flight workout before iOS suspends the process.
    @discardableResult
    func flushActiveWorkoutSnapshot() -> Bool {
        let gpsCommitted = !activeWorkoutIsGps || ActiveGpsWorkoutPersistence.flushPendingWrites()
        gpsSnapshotDurabilityFailed = !gpsCommitted
        let workoutCommitted = persistActiveWorkout(force: true, synchronously: true)
            || persistActiveWorkout(force: true, synchronously: true)
        workoutSnapshotDurabilityFailed = !workoutCommitted
        refreshWorkoutDurabilityWarning()
        return gpsCommitted && workoutCommitted
    }

    func setApplicationActive(_ active: Bool) {
        applicationIsActive = active
        if !active {
            if !flushActiveWorkoutSnapshot(), activeWorkout != nil {
                refreshWorkoutDurabilityWarning()
            }
            // Effort history migration is maintenance work. Run one 30-day batch only after Today first
            // paint and only while the app is inactive. Every batch persists its cursor before yielding.
            Task(priority: .background) { [weak self] in
                guard let self,
                      self.repo.loaded,
                      self.repo.todayHealthSnapshot != nil,
                      !self.applicationIsActive,
                      !self.hasActiveImport,
                      !self.live.backfilling,
                      self.activeWorkout == nil else { return }
                await self.intelligence.runEffortRescoreIfNeeded {
                    self.applicationIsActive || self.hasActiveImport
                        || self.live.backfilling || self.activeWorkout != nil
                }
            }
        } else {
            Task { [weak self] in
                guard let self,
                      self.repo.loaded,
                      !self.live.backfilling,
                      !self.hasActiveImport
                else { return }
                await self.repo.refreshLiveDayStrain(maxHR: Double(self.profile.hrMax))
            }
        }
        // Re-arm the broad-repair lane at both scene edges. Its durable idle gate rejects the active edge,
        // while the inactive edge allows one bounded chronological batch after Today is already visible.
        Task { [weak self] in
            _ = await self?.signalHistoricalPipeline()
        }
    }

    /// Finish the active workout: finalize the GPS route (#524), score the captured HR window, and save it
    /// as a `WorkoutRow`. A session with no HR window AND no real GPS route is discarded quietly (parity
    /// with Android) , but a GPS-only walk with HR not streaming still saves. Double-buzz confirms.
    func endWorkout() async -> Result<WorkoutRow, WorkoutFinishError> {
        guard let current = activeWorkout else { return .failure(.noActiveWorkout) }
        guard workoutFinishState != .saving else { return .failure(.persistenceFailed("Save already in progress.")) }
        let w = pendingWorkoutSnapshot ?? current
        let trace = PerformanceTrace.begin("workout_end")
        defer { PerformanceTrace.end(trace, changedRows: lastWorkout == nil ? 0 : 1) }
        workoutFinishState = .saving
        if pendingWorkoutSnapshot == nil {
            pendingWorkoutSnapshot = current
            pendingWorkoutEnd = Date()
            pendingWorkoutWasGps = activeWorkoutIsGps
        }
        let wasGps = pendingWorkoutWasGps
        // #524: finalize the GPS route. Stop the recorder and take its captured route , it kept
        // accumulating from CoreLocation independently of the HR window. `capturedRoute()` is nil unless
        // ≥2 points actually landed (honest: no route, no distance, when nothing was captured , e.g. a
        // Mac with no GPS, or denied permission). A non-GPS session never armed the recorder.
        if wasGps && pendingWorkoutRoute == nil {
            gpsRecorder.stop()
            if !ActiveGpsWorkoutPersistence.flushPendingWrites() {
                gpsSnapshotDurabilityFailed = true
                refreshWorkoutDurabilityWarning()
            }
            pendingWorkoutRoute = gpsRecorder.capturedRoute()
        }
        let route = pendingWorkoutRoute
        let samples = w.samples
        // Save when there's an HR window OR a real GPS route , a GPS-only walk (HR not streaming) is
        // still a workout (parity with Android's `samples.size < 2 && track.size < 2` discard gate).
        guard samples.count >= 2 || route != nil else {
            // Workouts & GPS test mode: record WHY a session vanished (too short / no route), tagged `.workouts`.
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "discarded", sportKey: WorkoutSource.traceSportKey(w.sport),
                hrSamples: samples.count, gpsPoints: route == nil ? 0 : nil))
            lastWorkout = nil
            pendingWorkoutSnapshot = nil
            pendingWorkoutEnd = nil
            pendingWorkoutRoute = nil
            pendingWorkoutWasGps = false
            workoutFinishState = .failed(WorkoutFinishError.insufficientEvidence.localizedDescription)
            return .failure(.insufficientEvidence)
        }
        let end = pendingWorkoutEnd ?? Date()
        // ActiveWorkout already maintains these values exactly as canonical same-second samples
        // are appended or replaced. Reuse them instead of allocating and scanning the full
        // three-hour sample array twice on the main actor during Finish.
        let avg = samples.isEmpty ? nil : w.avgHr
        let peak = samples.isEmpty ? nil : w.peakHr
        let strain = samples.count >= 2
            ? StrainScorerV2.strain(samples, maxHR: Double(profile.hrMax), mode: .activity) : nil
        // Estimate calories from the captured HR window (same Keytel/Harris–Benedict model the
        // auto-detector uses) so a manual session shows energy too, not just duration/strain. (#117)
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax), restingHR: nil).0
            : 0
        let startTs = Int(w.start.timeIntervalSince1970)
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            // GPS distance rides the shared row so the Workouts list / detail show it like any other
            // distance workout; the polyline itself is persisted alongside in RouteStore (the shared
            // WorkoutRow has no route column on Apple). Only a real route sets distance , honest ",".
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil,
            strainVersion: strain == nil ? nil : 2)
        guard let store = await repo.storeHandle() else {
            workoutFinishState = .failed(WorkoutFinishError.storeUnavailable.localizedDescription)
            return .failure(.storeUnavailable)
        }
        do {
            _ = try await store.upsertWorkouts([row], deviceId: deviceId)
            let readBack = try await store.workouts(deviceId: deviceId, from: row.startTs,
                                                    to: row.startTs, limit: 10)
                .first(where: { $0.startTs == row.startTs && $0.sport == row.sport })
            guard let saved = readBack else {
                workoutFinishState = .failed(WorkoutFinishError.readBackMissing.localizedDescription)
                return .failure(.readBackMissing)
            }
            if let route {
                RouteStore.store(route, startTs: saved.startTs, sport: saved.sport)
                guard RouteStore.load(startTs: saved.startTs, sport: saved.sport) == route else {
                    workoutFinishState = .failed(WorkoutFinishError.readBackMissing.localizedDescription)
                    return .failure(.readBackMissing)
                }
            }
            _ = await repo.refresh(.currentDay)
            lastWorkout = saved
            ActiveWorkoutPersistence.clear()
            ActiveGpsWorkoutPersistence.clear()
            activeWorkout = nil
            releaseWorkoutRealtimeHR()
            activeWorkoutIsGps = false
            workoutSnapshotDurabilityFailed = false
            gpsSnapshotDurabilityFailed = false
            gpsHadTerminatedGap = false
            refreshWorkoutDurabilityWarning()
            pendingWorkoutSnapshot = nil
            pendingWorkoutEnd = nil
            pendingWorkoutRoute = nil
            pendingWorkoutWasGps = false
            workoutFinishState = .saved(saved)
            emitWorkoutsTrace(WorkoutsTrace.sessionLine(
                event: "end", sportKey: WorkoutSource.traceSportKey(w.sport), hrSamples: samples.count,
                durationSec: Int(end.timeIntervalSince(w.start)),
                gpsPoints: wasGps ? gpsRecorder.pointCount : nil))
            buzz(loops: 2)
            return .success(saved)
        } catch {
            let failure = WorkoutFinishError.persistenceFailed(error.localizedDescription)
            workoutFinishState = .failed(failure.localizedDescription)
            return .failure(failure)
        }
    }

    /// Append the current smoothed `bpm` to the active workout and advance its O(1) running strain
    /// accumulator. Called from the direct-HR path (or the R-R fallback when direct HR is absent); a
    /// no-op when no workout is running. No growing-window rescan occurs at the ~1 Hz live cadence.
    private func captureWorkoutSample() {
        guard pendingWorkoutSnapshot == nil, let w = activeWorkout, let hr = bpm else { return }
        let sample = HRSample(ts: Int(Date().timeIntervalSince1970), bpm: hr)
        guard w.ingest(sample) else { return }
        // Re-snapshot the durable session so a kill keeps the latest accumulated HR window (#529).
        persistActiveWorkout()
    }

    /// Drop the smoothing window and blank the hero number so a resume / re-attach shows ","
    /// until a genuinely fresh sample arrives, instead of republishing the stale pre-gap median.
    /// Called on Live-tab entry / manual Start HR (see `startRealtimeHR`), NOT on the 30s keep-alive
    /// re-arm , so steady-state smoothing is untouched. Fixes #46 (HR jumped to a stale ~100 on
    /// reopen, then "slowly came back down" as fresh low samples refilled the window).
    func resetSmoothing() {
        hrWindow.removeAll()
        bpm = nil
    }

    /// The unit-tested `StressOnsetDetector` decides whether to offer a 60-s guided breath. On a fresh,
    /// non-metabolic HRV dip while the user is still, it fires a single confirming buzz and posts a
    /// passive nudge to `stressNudgeCenter`. The detector carries replay-safe state (de-dup + slow
    /// baseline + rate limit), persisted via `BiofeedbackPrefs` so a relaunch can't re-fire. Honest /
    /// non-clinical: "stress" is an autonomic proxy vs the user's own baseline, never a diagnosis.
    private func evaluateStress(_ packet: [Int]) {
        let fresh = packet.filter { $0 > 300 && $0 < 2000 }   // plausible R-R (30–200 bpm)
        guard !fresh.isEmpty else { return }
        rrBuf.append(contentsOf: fresh)
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }

        // Inert unless the master toggle is on; the engine owns every gate (auto-nudge, exercise gate,
        // quiet hours, rate limit, edge).
        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled, live.bonded, live.worn else { return }
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: bpm.map(Double.init),
            recentMotionG: nil,   // wrist gravity is offloaded + lags live; the resting-HR band is the gate
            sessionActive: stressNudgeCenter.pending != nil,   // never stack a fresh nudge over a live one
            state: stressState,
            config: cfg,
            nowSec: Int(Date().timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        guard decision.shouldNudge else { return }
        if canBuzz { buzz(loops: UInt8(clamping: decision.buzzLoops)) }
        stressNudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        live.append(log: "Stress check-in , HRV dipped while still")
    }

    /// Whether the encrypted channel is up so a confirming buzz can actually fire (the command
    /// characteristic is gated on bond; an un-encrypted live-HR-only link can't buzz).
    private var canBuzz: Bool { live.bonded && live.encryptedBond }

    /// Start scanning for the strap. When no model is given, use the one the user
    /// picked (persisted under "selectedWhoopModel"), so every scan entry point ,
    /// Live, onboarding, the menu bar, Settings , honours the same choice.
    func scan(model: WhoopModel? = nil) {
        let chosen = model
            ?? UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:))
            ?? .whoop4
        ble.connect(model: chosen)
    }
    func disconnect() { ble.disconnect() }
    /// Device Command Center entry points. Keep SwiftUI out of BLE internals so command policy stays
    /// testable and every surface uses the same acknowledged production paths.
    func syncActiveDevice() { ble.syncNow() }
    func testDeviceVibration() { buzzStrapOnce() }
    func refreshDeviceBattery() { getBattery() }
    func refreshDeviceLink() { scan() }
    /// Restart the connected strap (user-initiated, confirmation-gated in DevicesView). Non-destructive —
    /// the strap keeps its data and re-advertises after boot; NOOP auto-reconnects. See BLEManager.rebootStrap().
    func rebootStrap() { ble.rebootStrap() }
    /// Send one WHOOP 4.0 reboot-probe candidate (Test Centre → Connection, 4.0 only). Confirmation-gated
    /// in DevicesView; finds the real 4.0 reboot frame when the production one is ignored (#235).
    func rebootProbe(_ variant: RebootProbeVariant) { ble.rebootProbe(variant) }

    /// Drop the current strap and clear bond state so a newly-picked strap model connects fresh
    /// (lets a user with both a WHOOP 4 and a 5/MG switch between them).
    func prepareStrapSwitch() { ble.prepareForModelSwitch() }

    // MARK: - Add-a-device wizard (WHOOP present-scan + register/activate)
    //
    // Thin pass-throughs over BLEManager's EXISTING public present-scan surface so the wizard never
    // references BLEManager directly (mirrors `scan()` / `disconnect()`). The wizard observes
    // `ble.discoveredWhoops` for the WHOOP families and runs its own `StandardHRSource` for generic
    // straps , see AddDeviceWizard.

    /// The straps surfaced by the WHOOP present-scan (`scanForWhoops`), for the wizard's live list.
    /// Empty until a present-scan has discovered something; refreshed in place as RSSI updates.
    var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] { ble.discoveredWhoops }

    /// True when the selected/connected strap is a WHOOP 5/MG. A thin window onto `BLEManager.isWhoop5`
    /// (its `selectedModel` is private) so a view can branch on the strap generation without reaching into
    /// the BLE layer. #864: the Smart-alarm card uses this to give a 5/MG owner the honest "saved but NOT
    /// armed until Experimental is on" copy, instead of hardcoding WHOOP 4.0. Mirrors the Android
    /// `LiveState.whoop5Detected` field the equivalent screen reads.
    var whoop5Detected: Bool { ble.isWhoop5 }

    /// Point the WHOOP scan at a specific family, then present nearby straps WITHOUT auto-connecting.
    /// `prepareForModelSwitch()` first clears any sticky bond/connection so the engine is idle, then
    /// `connect(model:)` selects the family + installs its framing (it sets the engine's private
    /// `selectedModel`, which `scanForWhoops()` scans for), and the immediate `scanForWhoops()` takes
    /// over the central in present-mode (it `stopScan()`s the connect's scan and re-arms a duplicate-
    /// allowing present scan). The persisted `selectedWhoopModel` is updated too, so a later real
    /// connect to the chosen strap targets the right family. All via existing public methods.
    func presentWhoopScan(model: WhoopModel) {
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        ble.prepareForPresentScan(model: model) // idle for a family switch, but KEEP a live same-family bond (#74)
        ble.connect(model: model)             // select the family (sets engine selectedModel + framing)
        ble.scanForWhoops()                   // take over the central, present nearby straps only
    }

    /// End the WHOOP present-scan (idempotent). Call on leaving the wizard's pick step / on dismiss.
    func stopWhoopScan() { ble.stopWhoopScan() }

    /// Register a paired device and (optionally) make it the active one. The Add-a-device wizard's
    /// single write path: `add` upserts the row, and when `makeActive` is true `setActive` promotes it
    /// (the SourceCoordinator reacts to the active-device change and connects). No-op if the registry
    /// hasn't been wired yet (pre store-open) , the wizard is only reachable once it has.
    func registerDevice(_ device: PairedDevice, makeActive: Bool) {
        guard deviceRegistry != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.sourceTransitionFence.runThrowing { @MainActor [weak self] in
                    guard let self, let registry = self.deviceRegistry else {
                        throw AppModelSourceTransitionError.registryUnavailable
                    }
                    let oldId = registry.activeDeviceId
                    try registry.add(device)
                    if makeActive {
                        try await self.performSourceTransition(
                            to: device.id, from: oldId, kind: .selectExisting)
                    }
                }
                if makeActive { self.schedulePostCommitSourceWork(targetDeviceId: device.id) }
            } catch {
                self.live.append(log: "Device registration failed closed: \(error)")
            }
        }
    }

    // MARK: - Oura adopt (factory-reset-and-adopt)

    /// The live adopt outcome of the active Oura ring, mirrored off the coordinator's live `OuraLiveSource`
    /// so the Add-device wizard can drive its "Taking over your ring" step to success or an honest Failed
    /// WITHOUT reaching into the BLE layer. nil when no Oura source is live or no adopt is in flight. PARITY:
    /// the Android wizard observes the same coarse outcome to leave its Adopting step.
    @Published private(set) var ouraAdoptPhase: OuraLiveSource.AdoptPhase = .idle
    /// The active Oura ring's honest needs-pairing message (mirrored off the live source), surfaced verbatim
    /// on the wizard's Failed step. nil when the ring is fine or no Oura source is live.
    @Published private(set) var ouraNeedsPairing: String?
    /// Combine subscriptions mirroring the live Oura source's `adoptPhase` / `needsPairing` into the two
    /// published properties above. Re-bound whenever the active Oura source changes.
    private var ouraAdoptCancellables = Set<AnyCancellable>()

    /// Take over a factory-reset Oura ring: grant the coordinator explicit adopt consent for THIS ring (so
    /// its live session may run the one-time key install, s3.2), register it active (which starts that live
    /// session), then begin mirroring its adopt outcome for the wizard. The irreversible-consent gate has
    /// ALREADY been passed in the wizard (the consent tick + the "Take over this ring?" confirm); this is the
    /// commit. Never prompts to make-active (the takeover IS the user's new active source).
    func adoptOuraRing(_ device: PairedDevice) {
        sourceCoordinator?.requestOuraAdopt(deviceId: device.id)
        // Reset the mirror so a previous attempt's outcome never leaks into this one.
        ouraAdoptPhase = .idle
        ouraNeedsPairing = nil
        registerDevice(device, makeActive: true)
        bindOuraAdoptMirror()
    }

    /// (Re)bind the adopt-outcome mirror to whichever `OuraLiveSource` the coordinator has live now and on
    /// every later swap. `flatMap` switches to the current source's `adoptPhase` (defaulting to `.idle` when
    /// there is no source), so the published value always tracks the live source without leaking subscriptions.
    private func bindOuraAdoptMirror() {
        ouraAdoptCancellables.removeAll()
        guard let coordinator = sourceCoordinator else { return }
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<OuraLiveSource.AdoptPhase, Never> in
                source?.$adoptPhase.eraseToAnyPublisher()
                    ?? Just(.idle).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraAdoptPhase = $0 }
            .store(in: &ouraAdoptCancellables)
        coordinator.$ouraSource
            .flatMap { source -> AnyPublisher<String?, Never> in
                source?.$needsPairing.eraseToAnyPublisher()
                    ?? Just(nil).eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.ouraNeedsPairing = $0 }
            .store(in: &ouraAdoptCancellables)
    }

    /// How many on-screen surfaces currently want the realtime HR stream (the Live tab and the
    /// in-exercise LiveWorkoutView, which can be open at the same time , the workout sheet sits over
    /// Live, or is reached straight from the Workouts tab without Live ever appearing). The stream
    /// stays armed while ANY of them is visible, so a second surface arming it never disarms it out
    /// from under the first (#681 , a WHOOP 5/MG manual workout started without first opening Live got
    /// no live HR, so every sample was dropped and the session was silently discarded). Ref-counted to
    /// match Android's `realtimeWanters` (AppViewModel.requestRealtimeHr/releaseRealtimeHr).
    private var realtimeWanters = 0
    /// A recording session owns one realtime lease independently of whichever screen is visible. This
    /// keeps WHOOP 5/MG HR armed while the phone is locked or the live-workout sheet is closed.
    private var workoutOwnsRealtimeHR = false

    private func acquireWorkoutRealtimeHR() {
        guard !workoutOwnsRealtimeHR else { return }
        workoutOwnsRealtimeHR = true
        startRealtimeHR()
    }

    private func releaseWorkoutRealtimeHR() {
        guard workoutOwnsRealtimeHR else { return }
        workoutOwnsRealtimeHR = false
        stopRealtimeHR()
    }

    /// A surface that shows live HR appeared. Arms the realtime stream on the 0→1 edge , and ONLY on
    /// that edge blanks the stale smoothing window (#46) so a resume shows "," until a fresh sample
    /// lands, never re-clearing an already-live window when a second concurrent HR surface opens. The
    /// keep-alive re-arm goes through `ble.startRealtime()` directly, NOT here, so steady-state is
    /// untouched. Each surface must balance this with exactly one `stopRealtimeHR()` on disappear.
    func startRealtimeHR() {
        if realtimeWanters == 0 {
            resetSmoothing()
            ble.startRealtime()
        }
        realtimeWanters += 1
    }
    /// A live-HR surface went away. Stops the realtime stream only when the last one leaves (1→0 edge);
    /// the lightweight 0x2A37 HR keeps recording regardless. Clamped at 0 so an unbalanced extra stop
    /// can't drive the count negative and wedge the stream off.
    func stopRealtimeHR() {
        realtimeWanters = max(0, realtimeWanters - 1)
        if realtimeWanters == 0 { ble.stopRealtime() }
    }

    /// Re-issue the BLE realtime arm WITHOUT touching the ref-count , used when a fresh
    /// connection/bond lands while a surface is already showing live HR (Apple's `ble.startRealtime()`
    /// must be re-sent on a new connection). A no-op when nothing wants the stream, so a stray
    /// connection event can't arm it behind a closed Live tab. Mirrors that Android re-arms via its
    /// own keep-alive rather than re-calling `requestRealtimeHr` on reconnect.
    func rearmRealtimeIfWanted() {
        guard realtimeWanters > 0 else { return }
        ble.startRealtime()
    }
    /// Ask the strap for a fresh battery reading.
    func getBattery() { ble.refreshBattery() }

    /// Fire a haptic buzz on the strap. patternId=2 is the graduated buzz confirmed on-device;
    /// `loops` sets the length. Used by scheduled cues (coach zones, moment marks, biofeedback).
    /// Requires a bonded connection , no-op otherwise (the command characteristic is gated on bond).
    /// For a user-facing "buzz the strap now" action use `buzzStrapOnce()` instead (#921).
    func buzz(loops: UInt8 = 2) {
        ble.send(.runHapticsPattern, payload: [2, loops, 0, 0, 0])
    }

    /// One-shot user buzz (#921): the on-device-confirmed pattern (patternId=2, 3 loops) followed by
    /// RUN_ALARM, both written acknowledged. A bare RUN_HAPTICS_PATTERN write can be silently ignored
    /// (WHOOP 4.0 via the Siri shortcut) or dropped unacked on a busy link, so the Live "Buzz strap"
    /// button and the Buzz Strap App Intent both route through this single sequence.
    func buzzStrapOnce() {
        ble.buzzStrapOnce()
    }

    /// Fire a specific preset haptic pattern (patternId 0–6 on Harvard; loops sets length).
    /// Used by the notification-pattern picker and coaching features.
    func buzz(pattern: UInt8, loops: UInt8 = 1) {
        ble.send(.runHapticsPattern, payload: [pattern, loops, 0, 0, 0])
    }

    /// Tell the strap to STOP an in-progress haptic pattern (#769). The biofeedback layers (Breathe /
    /// "Calm me" / resonance) schedule a stream of buzzes; cancelling the app-side DispatchWorkItems stops
    /// scheduling NEW pulses but cannot recall a pattern the strap is already mid-way through. If the link
    /// then drops mid-pattern, the strap's UI/haptic manager can be left wedged on that pattern with no app
    /// able to clear it. STOP_HAPTICS (cmd 122, payload [0x00]) is the documented, reversible clear for
    /// WHOOP 4.0.
    ///
    /// WHOOP 5/MG CAVEAT: the 5/MG buzz rides the maverick 0x13 path (a one-shot, not a sustained pattern),
    /// and we have NOT confirmed the 5/MG honours cmd 122 on that path. `send` does not allow-list 122 for
    /// the 5/MG family, so on a 5/MG this is a no-op (logged "skipped"), not a guessed write. So this is
    /// BEST-EFFORT: it reliably clears a wedged WHOOP 4.0; on a 5/MG the one-shot nature already limits the
    /// wedge, and we deliberately do not invent an unverified stop opcode. Safe to call always (no-op when
    /// unbonded or when the family doesn't accept it).
    func stopHaptics() {
        ble.send(.stopHaptics, payload: [0x00])
    }

    // MARK: - Wrist-buzz mirror notifications (PR #577 , iOS only)
    //
    // iOS can't keep the strap buzz silent in a pocket the way macOS surfaces it on screen, so a wrist
    // buzz the user might miss (a long sedentary stretch, the smart-alarm wake) is ALSO posted as a
    // local notification. macOS keeps routing to its dedicated Notifications screen and never calls
    // these , `#if os(iOS)` makes them no-ops there so that path is untouched. Both are gated on the
    // same `notif.masterEnabled` master switch the iOS Automations "Wrist alerts" toggle (PR #572) and
    // the SedentaryDetector read, so turning wrist alerts off silences these too.

    /// The master wrist-alerts gate (PR #572). One key, shared with the iOS Automations toggle and the
    /// SedentaryDetector, so all three honour the same switch.
    static let wristAlertsMasterKey = "notif.masterEnabled"

    /// Post the local notification mirroring the inactivity (sedentary) wrist nudge. Called right after
    /// `BLEManager.maybeBuzzInactivity` fires its buzz (see crossLaneNotes). `minutes` = the seated bout
    /// length the detector reported. No-op on macOS and when wrist alerts are off.
    static func postInactivity(minutes: Int) {
        #if os(iOS)
        let body = minutes > 0
            ? String(localized: "You've been seated for about \(minutes) min. Time to move.")
            : String(localized: "Time to move. You've been seated a while.")
        postWristAlert(identifier: "inactivity-nudge", title: String(localized: "Move reminder"), body: body)
        #endif
    }

    /// Post the local notification mirroring the smart-alarm wake buzz. Called from the
    /// `onSmartAlarmFired` hook. No-op on macOS and when wrist alerts are off.
    static func postSmartAlarm() {
        #if os(iOS)
        postWristAlert(identifier: "smart-alarm-wake", title: String(localized: "Smart alarm"),
                       body: String(localized: "Good morning. Your smart alarm just woke you."))
        #endif
    }

    #if os(iOS)
    /// Shared post path: gate on the wrist-alerts master, then deliver only if the OS already authorized
    /// notifications (no second system prompt , BatteryNotifier-style status-only check). A fresh
    /// identifier per category means a new alert replaces the old one rather than stacking.
    private static func postWristAlert(identifier: String, title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: wristAlertsMasterKey) else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            )
        }
    }
    #endif

    /// Compute the next fire date for the smart alarm, honouring the weekday selection.
    /// - `minutes`: target wake time, minutes since local midnight.
    /// - `weekdays`: Calendar weekday numbers (1 = Sun … 7 = Sat) the alarm may fire on. Empty = every
    ///   day. Days outside 1…7 are ignored.
    /// Returns the next strictly-future date matching the time on an enabled weekday, scanning today
    /// plus the next 7 days, or nil if no enabled weekday falls in that range. Pure + side-effect-free
    /// so it can be unit-tested against a fixed clock.
    nonisolated static func nextSmartAlarmDate(minutes: Int,
                                               weekdays: Set<Int>,
                                               from now: Date = Date(),
                                               calendar cal: Calendar = .current) -> Date? {
        SmartAlarmSchedule.nextDate(minutes: minutes, weekdays: weekdays, after: now, calendar: cal)
    }

    // MARK: - Physical inputs / wear automation

    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }   // debounce repeats
        lastDoubleTapAt = now
        live.append(log: "Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
    }

    /// Run a configured Mac action. In-app actions (buzz/moment) stay on-device; lock + shortcuts
    /// go through MacActions.
    func runMacAction(_ kind: MacActionKind, shortcut: String) {
        switch kind {
        case .none: break
        case .lockScreen:
            if !MacActions.lockScreen() {
                #if os(macOS)
                MacActions.runShortcut("Lock Screen")   // login.framework unavailable , fall back to a Shortcut
                #endif
                // iOS can't lock the device and .lockScreen isn't selectable there, so no stray Shortcut launch.
            }
        case .buzzBack: buzz(loops: 1)
        case .markMoment: markMoment()
        case .sleepMark: markSleep()
        case .hapticClock: ble.buzzTimeNow(is24h: Self.localeUses24HourClock)
        case .runShortcut: MacActions.runShortcut(shortcut)
        }
    }

    /// Whether the user's locale formats time on a 24-hour clock , drives the Haptic Clock's hour
    /// encoding (#460) so a double-tap buzzes the time the way the user reads it. Derived from the
    /// locale's "j" (hour) template: a 12-hour locale includes the AM/PM ("a") symbol.
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        return !fmt.contains("a")
    }

    /// Record a "moment" (double-tap marker) with a confirming buzz.
    func markMoment() { markMoment(at: Date()) }

    /// Record a "moment" at a specific time (used by the Siri/Shortcuts path, which captures the
    /// invocation time even though the app only drains the queue later when it becomes active).
    func markMoment(at date: Date) {
        moments.append(date)
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(loops: 1)
        live.append(log: "Moment marked")
    }

    /// #461: record a "sleep mark" , a bedtime / wake / mid-night tap. Stored like moments (survives
    /// relaunch) and written as a distinct, greppable "Sleep mark @ HH:mm" line into the strap log so it
    /// rides along in the shared log / raw export. A single buzz confirms it registered. No start/end
    /// smarts yet (Phase 1): marks are logged in sequence; pairing into sleep bounds comes later.
    func markSleep() { markSleep(at: Date()) }
    func markSleep(at date: Date) {
        sleepMarks.append(date)
        if sleepMarks.count > 500 { sleepMarks.removeFirst(sleepMarks.count - 500) }
        UserDefaults.standard.set(sleepMarks.map(\.timeIntervalSince1970), forKey: "sleepMarks")
        buzz(loops: 1)
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        live.append(log: "Sleep mark @ \(hhmm.string(from: date))")
        // Persistence parity with Android's `AppViewModel.markSleep` (#461): also upsert the TYPED
        // `sleep_mark` metric-series row that the Sleep screen reads back (SleepView.logMark writes the
        // same row when the user taps a button). A physical double-tap can't choose bedtime vs wake, so
        // it defaults to `.bedtime` , the boundary the gesture most naturally marks. Idempotent by
        // (deviceId, day, key) through the repo's live store handle: no new Repository API, no schema
        // change. The UserDefaults list + buzz + freetext log line above are unchanged.
        let mark = SleepMark(type: .bedtime, at: date)
        Task { [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return }
            _ = try? await store.upsertMetricSeries([mark.metricPoint], deviceId: self.repo.deviceId)
        }
    }

    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { MacActions.runShortcut(behavior.wristOnShortcut) }
        } else {
            #if os(macOS)
            // Auto-lock on wrist-off is a macOS-only affordance (the toggle is hidden on iOS, where a
            // third-party app can't lock the device). Guarding it here also stops a stray "Lock Screen"
            // Shortcut launch for any iOS user who toggled this on before it was gated off iPhone.
            if behavior.autoLockOnWristOff, !MacActions.lockScreen() { MacActions.runShortcut("Lock Screen") }
            #endif
            if !behavior.wristOffShortcut.isEmpty { MacActions.runShortcut(behavior.wristOffShortcut) }
        }
    }

    /// HR-zone haptic coaching: buzz when crossing into the top zone (ease off) or back to recovery.
    private func coachZone(_ hr: Int?) {
        guard behavior.zoneCoaching, live.bonded, live.worn, let hr, hr >= 30 else { return }
        let maxHR = Double(profile.hrMax)
        guard maxHR > 0 else { return }
        let pct = Double(hr) / maxHR
        let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
        defer { lastCoachZone = zone }
        guard lastCoachZone != -1, zone != lastCoachZone else { return }
        if zone == 5, lastCoachZone < 5 { buzz(loops: 3) }          // entered max , ease off
        else if zone <= 1, lastCoachZone > 1 { buzz(loops: 1) }     // recovered
    }

    /// Illness/strain early-warning (v5): the confounder-suppressed `IllnessSignalEngine`. For the last
    /// ~2 days vs a ~28-day personal baseline it z-scores resting HR, skin-temp deviation, HRV (negated)
    /// and respiration ORIENTED illness-ward, then the engine applies its minimum-corroboration gate,
    /// composite score, and , the differentiating part , same-day journal confounder suppression
    /// (alcohol / a hard-or-late workout / etc.) so a night out doesn't cry wolf. The journal context is
    /// read asynchronously, so this kicks a Task; the published `illnessSignal` + the `healthAlert`
    /// banner both come from the engine's single decision. On-device only, APPROXIMATE , not a diagnosis.
    private func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else {
            healthAlert = nil; illnessSignal = nil; illnessDistance = nil; return
        }
        Task { [weak self] in
            guard let self else { return }
            // Confounder tags from the recent journal (within the last ~2 days). Read once, off the
            // engine's hot path , the engine only needs presence flags, not the rows.
            let recentDays = Set(days.suffix(2).map(\.day))
            let journal = await self.repo.journalEntries(days: 7)
            var ctxAlcohol = false, ctxHardWorkout = false, ctxAlreadyUnwell = false
            for e in journal where e.answeredYes && recentDays.contains(e.day) {
                let q = e.question.lowercased()
                if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
                if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
                if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
            }
            self.applyIllnessSignal(days, alcohol: ctxAlcohol, hardOrLateWorkout: ctxHardWorkout,
                                    alreadyUnwell: ctxAlreadyUnwell)
        }
    }

    /// Run the `IllnessSignalEngine` from the day history + the journal-derived confounder context, then
    /// publish the result + the legacy `healthAlert` banner string (kept for the existing banner surface).
    private func applyIllnessSignal(_ days: [DailyMetric], alcohol: Bool,
                                    hardOrLateWorkout: Bool, alreadyUnwell: Bool) {
        let previous = healthAlert
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))    // ~28 days ending 3 days ago
        func mean(_ vals: [Double]) -> Double? { vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count) }
        func rm(_ kp: (DailyMetric) -> Double?) -> Double? { mean(recent.compactMap(kp)) }

        // Build each signal's illness-ward z against the personal baseline (Baselines.deviation). The
        // baseline is folded over the full pre-recent history; a trusted baseline (≥14 nights) is the
        // engine's gate for actually raising. Skin-temp is already a stored DEVIATION (°C), so it's
        // z-scored against a zero-centred personal spread; the others z-score the raw column.
        func signal(_ kp: (DailyMetric) -> Double?, cfgKey: String, illnessUp: Bool) -> (IllnessSignalEngine.SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z   // HRV drop is illness-ward → negate
            return (IllnessSignalEngine.SignalReading(zIllnessward: z), state.trusted)
        }

        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        // Skin-temp deviation: a stored °C delta. Build a small zero-centred state from its own recent
        // spread so a +0.6 °C reads as a meaningful z without needing a separate baseline column.
        var skin: (IllnessSignalEngine.SignalReading, Bool)? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            let z = recentSkin / 0.3     // ~0.3 °C ≈ one personal spread (matches skin_temp floorSpread)
            skin = (IllnessSignalEngine.SignalReading(zIllnessward: z), true)
        }

        let inputs = IllnessSignalEngine.Inputs(
            restingHR: rhr?.0, skinTemp: skin?.0, hrv: hrv?.0, respiration: resp?.0)

        // PARALLEL Mahalanobis distance on the SAME illness-ward z-vector (RHR up, HRV negated, skin-temp
        // up, respiration up). This NEVER gates the alert: the IllnessSignalEngine above remains the sole
        // fire gate. We compute it here only so the Heads-Up card can show a "how strong" confidence band
        // when the engine has already raised. nil where a reading is absent / not present (dropped from the
        // distance). correlation: nil = identity, validated to agree ~100% with the z-sum detector.
        func zIfPresent(_ r: (IllnessSignalEngine.SignalReading, Bool)?) -> Double? {
            guard let reading = r?.0, reading.present else { return nil }
            return reading.zIllnessward
        }
        let distanceFeatures = IllnessDistance.FeatureVector(
            restingHR: zIfPresent(rhr),
            rmssd: zIfPresent(hrv),       // hrv.zIllnessward is already the NEGATED HRV z
            skinTemp: zIfPresent(skin),
            respiration: zIfPresent(resp))
        illnessDistance = IllnessDistance.evaluate(features: distanceFeatures, correlation: nil)

        // baselineTrusted: require the HRV/RHR baselines to be trusted before the engine may raise.
        let trusted = (rhr?.1 ?? false) || (hrv?.1 ?? false)
        let context = IllnessSignalEngine.Context(
            alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout,
            alreadyUnwell: alreadyUnwell, baselineTrusted: trusted)

        // Caller-rendered phrases for the signals that fire (the engine surfaces only the firing ones).
        var labels: [String: String] = [:]
        if let r = rm({ $0.restingHr.map(Double.init) }), let b = mean(base.compactMap { $0.restingHr.map(Double.init) }), r > b {
            labels["restingHR"] = "RHR +\(Int((r - b).rounded()))"
        }
        if let r = rm({ $0.avgHrv }), let b = mean(base.compactMap { $0.avgHrv }), b > 0, r < b {
            labels["hrv"] = "HRV −\(Int(((1 - r / b) * 100).rounded()))%"
        }
        if let r = rm({ $0.skinTempDevC }), r > 0 {
            labels["skinTemp"] = "skin temp +\(String(format: "%.1f", r)) °C"
        }
        if let r = rm({ $0.respRateBpm }), let b = mean(base.compactMap { $0.respRateBpm }), r > b {
            labels["respiration"] = "respiration up"
        }

        let result = IllnessSignalEngine.evaluate(inputs, context: context, firedLabels: labels)
        illnessSignal = result
        // The amber banner string reflects the raised / already-unwell levels only (the calmer levels
        // surface in the Health hub's Heads-Up card, never as a scary banner).
        healthAlert = (result.level == .raised || result.level == .alreadyUnwell) ? result.copy : nil
        if let alert = healthAlert, previous == nil {
            IllnessNotifier.post(alert)
        }
    }

    /// Re-run the illness watch over the cached history. Called when the Automations toggle
    /// flips , the repo.$days sink only fires on data changes, so a flip would otherwise wait
    /// for the next refresh.
    func reevaluateIllness() {
        evaluateIllness(repo.days)
    }

    // MARK: - v5 skin-temp suite engines (cycle phase + body clock)
    //
    // Run in the analytics pass (IntelligenceEngine calls this after it persists the night's scores) so
    // the Health hub's skin-temp cards read a ready snapshot. Both are pure StrandAnalytics engines fed
    // from the merged daily history; cycle awareness is gated behind the opt-in flag (default OFF) and
    // never computes , let alone surfaces , until the user turns it on.

    /// UserDefaults key for the cycle-awareness opt-in (default OFF , the most sensitive health category,
    /// manual-first). The Settings toggle + the card's opt-in CTA both write this single key.
    static let cycleAwarenessKey = "noopCycleAwareness"
    var cycleAwarenessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.cycleAwarenessKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.cycleAwarenessKey) }
    }

    /// Recompute the v5 skin-temp suite snapshots (cycle phase + body clock) from the current history.
    /// Called from the analytics pass and when the cycle opt-in flips. Honest-nil throughout: cycle is
    /// nil unless opted in; circadian is nil unless a usable activity profile exists.
    func refreshV5Signals() async {
        await computeCyclePhase()
        await computeCircadianPhase()
    }

    /// Cycle-phase awareness from the nightly skin-temperature shift (+ luteal RHR rise / HRV drop). Each
    /// night is z-scored against the personal baseline, then `CyclePhaseEngine.classify` reads the run.
    /// Gated behind the opt-in flag; clears the published result the moment it's turned off.
    private func computeCyclePhase() async {
        guard cycleAwarenessEnabled else { cyclePhase = nil; cycleCurve = []; return }
        let days = repo.days
        guard let tempCfg = Baselines.metricCfg["skin_temp"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let hrvCfg = Baselines.metricCfg["hrv"] else { return }

        // The nightly absolute skin-temp mean isn't in repo.days (only the °C DEVIATION is), so z-score
        // the deviation against its own folded spread , a zero-centred personal baseline. RHR + HRV
        // z-score their raw columns. Oldest→newest.
        let sorted = days.sorted { $0.day < $1.day }
        let skinState = Baselines.foldHistory(sorted.map { $0.skinTempDevC }, cfg: tempCfg)
        let rhrState = Baselines.foldHistory(sorted.map { $0.restingHr.map(Double.init) }, cfg: rhrCfg)
        let hrvState = Baselines.foldHistory(sorted.map { $0.avgHrv }, cfg: hrvCfg)

        var nights: [CyclePhaseEngine.Night] = []
        var curve: [Double] = []
        for d in sorted {
            let tempZ = d.skinTempDevC.map { skinState.usable ? Baselines.deviation($0, state: skinState).z : $0 / 0.3 }
            let rhrZ = (rhrState.usable ? d.restingHr.map { Baselines.deviation(Double($0), state: rhrState).z } : nil)
            let hrvZ = (hrvState.usable ? d.avgHrv.map { Baselines.deviation($0, state: hrvState).z } : nil)
            nights.append(CyclePhaseEngine.Night(day: d.day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
            if let fused = CyclePhaseEngine.fusedIndex(tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ) { curve.append(fused) }
        }
        cyclePhase = CyclePhaseEngine.classify(nights, baselineUsable: skinState.usable)
        cycleCurve = curve
    }

    /// Body-clock phase estimate. Builds a coarse per-hour activity profile from the last ~14 days of
    /// downsampled HR buckets (HR amplitude is a usable rest/activity rhythm proxy when raw motion isn't
    /// to hand), then fits the cosinor. nil when there isn't enough to read.
    private func computeCircadianPhase() async {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 14 * 86_400
        let buckets = await repo.hrBuckets(from: from, to: now, bucketSeconds: 3_600)
        guard buckets.count >= 24 else { circadianPhase = nil; return }
        let tz = TimeZone.current.secondsFromGMT()
        // Pool HR by LOCAL hour-of-day → mean bpm per hour as the activity proxy (higher HR ≈ more active).
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { circadianPhase = nil; return }
        // Habitual wake from the most recent night's banked wake, falling back to a 07:00 default.
        let wakeHour = habitualWakeHour() ?? 7.0
        circadianPhase = CircadianEngine.estimatePhase(
            bins: bins, daysObserved: daySet.count, habitualWakeHour: wakeHour)
    }

    /// A coarse habitual wake hour (local) from the most recent banked sleep session's end time, for the
    /// circadian schedule-offset comparison. nil when no sleep is banked.
    private func habitualWakeHour() -> Double? {
        guard let last = repo.sleeps.last else { return nil }
        let tz = TimeZone.current.secondsFromGMT()
        let local = (last.endTs + tz) % 86_400
        return Double((local + 86_400) % 86_400) / 3_600.0
    }

    // MARK: - v5 local multi-device fusion adapter
    //
    // Assemble today's per-source values per metric and run `FusionResolver` so the "Your Data, Fused"
    // screen (FusedRecordView) can show the best-sourced number + provenance + agreement. This does NOT
    // touch the core resolvedSeries waterfall , it's an additive read that reuses the rows the store
    // already holds, exactly the seam the view's header documents.

    /// Build today's fused record (best signal per metric across every source, with agreement). Reads each
    /// declared-fusable metric's latest per-source daily value, runs the pure `FusionResolver`, and maps
    /// the result into the view's `FusedRecord`. Honest single-source degradation falls out of the engine
    /// (a one-WHOOP user gets `.single` agreement and `contributingSourceCount == 1`).
    func buildTodayFusedRecord() async -> FusedRecord {
        guard let store = await repo.storeHandle() else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }
        // The metrics surfaced, in importance-first display order, with a label + accent.
        let specs: [(key: String, label: String, accent: String?)] = [
            ("rhr", "Resting HR", nil),
            ("hrv", "HRV", nil),
            ("sleep_total_min", "Sleep", nil),
            ("steps", "Steps", nil),
            ("skin_temp", "Skin temp", nil),
            ("spo2", "Blood oxygen", nil),
        ]
        // Every source that could carry a value, mapped to its stored device id. (FusionSource.rawValue
        // IS the canonical source id, but the strap's real id is `deviceId`/`computed` , map explicitly.)
        let sources: [(FusionSource, String)] = [
            (.whoopImport, deviceId),
            (.noopComputed, deviceId + "-noop"),
            (.appleHealth, appleDeviceId),
            (.xiaomiBand, FusionSource.xiaomiBand.rawValue),
        ]

        let now = Date()
        let fromDay = Repository.dayString(now.addingTimeInterval(-3 * 86_400))
        let toDay = Repository.dayString(now.addingTimeInterval(86_400))

        // Read each independent source together, then pick the freshest per metric for the latest day.
        // Source order has no effect here because FusionResolver owns precedence explicitly.
        let rowsBySource = await withTaskGroup(
            of: (FusionSource, DailyMetric?).self,
            returning: [FusionSource: DailyMetric].self
        ) { group in
            for (source, id) in sources {
                group.addTask {
                    let rows = (try? await store.dailyMetrics(
                        deviceId: id,
                        from: fromDay,
                        to: toDay
                    )) ?? []
                    return (source, rows.sorted(by: { $0.day < $1.day }).last)
                }
            }
            var result: [FusionSource: DailyMetric] = [:]
            for await (source, latest) in group {
                if let latest { result[source] = latest }
            }
            return result
        }
        guard !rowsBySource.isEmpty else {
            return FusedRecord(rows: [], dayOwner: nil, contributingSourceCount: 0)
        }

        var fusedRows: [FusedRow] = []
        var contributingSources = Set<FusionSource>()
        for spec in specs {
            var inputs: [FusionInput] = []
            for (src, daily) in rowsBySource {
                if let v = Self.fusionColumn(key: spec.key, day: daily) {
                    inputs.append(FusionInput(source: src, value: v))
                    contributingSources.insert(src)
                }
            }
            guard let point = FusionResolver.resolve(metricKey: spec.key, inputs: inputs) else { continue }
            fusedRows.append(FusedRow(point: point, label: spec.label, accentHex: spec.accent))
        }

        // The day-owner = the highest-priority source that actually contributed (the scores' single owner).
        let owner = contributingSources.min(by: {
            MetricArbitrationPolicy.sourcePriority($0) < MetricArbitrationPolicy.sourcePriority($1)
        })
        return FusedRecord(rows: fusedRows, dayOwner: owner,
                           contributingSourceCount: contributingSources.count)
    }

    /// The DailyMetric column a fusion metric key maps to (mirrors Repository.dailyColumn for the keys
    /// the fused record surfaces). nil when the source row doesn't carry that metric.
    private static func fusionColumn(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "rhr":             return d.restingHr.map(Double.init)
        case "hrv":             return d.avgHrv
        case "sleep_total_min": return d.totalSleepMin
        case "steps":           return d.steps.map(Double.init)
        case "skin_temp":       return d.skinTempDevC
        case "spo2":            return d.spo2Pct
        default:                return nil
        }
    }

    /// Import a Whoop CSV export (.zip or folder) → on-device store, then refresh the dashboard.
    /// A picked import file made safe to read. On iOS the security-scoped , and possibly
    /// iCloud-placeholder , URL is coordinated and COPIED into the app's temp directory, so the
    /// importer reads a stable LOCAL file. That's what makes import work for iCloud Drive files (they
    /// arrive as un-downloaded placeholders that ZIPFoundation can't open in place) and removes the
    /// scoped-access timing fragility that blocked iPhone imports (#179). On macOS the picked URL is
    /// read in place. `cleanup()` removes the temp copy AND the original `Documents/Inbox/` copy that
    /// `UIDocumentPickerViewController(asCopy: true)` leaves behind , a multi-GB Apple Health
    /// `export.zip` parked there was the runaway "Documents & Data" growth in #590 (one import → the
    /// store rows AND a permanent ~19 GB Inbox duplicate the OS never reclaims). Sendable so it can
    /// cross the actor boundary.
    struct ImportFile: Sendable {
        let url: URL
        private let temp: URL?
        /// The picker's `asCopy:true` drop in `Documents/Inbox/`, deleted on cleanup so it can't
        /// accumulate. nil on macOS (the URL is read in place, nothing to reclaim).
        private let inboxOriginal: URL?
        init(url: URL, temp: URL?, inboxOriginal: URL? = nil) {
            self.url = url; self.temp = temp; self.inboxOriginal = inboxOriginal
        }
        func cleanup() {
            if let temp { try? FileManager.default.removeItem(at: temp) }
            if let inboxOriginal, Self.isInImportInbox(inboxOriginal) {
                try? FileManager.default.removeItem(at: inboxOriginal)
            }
        }

        /// Only ever delete files the picker placed in OUR app's `Documents/Inbox/` , never a
        /// user-chosen in-place file on macOS or an iCloud URL outside the sandbox. The guard keeps
        /// `cleanup()` from removing anything the user still owns.
        static func isInImportInbox(_ url: URL) -> Bool {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return false }
            let inbox = docs.appendingPathComponent("Inbox").standardizedFileURL.path
            let candidate = url.standardizedFileURL.path
            return candidate.hasPrefix(inbox + "/")
        }
    }

    /// Runs off the main actor (nonisolated) so copying a large export never blocks the UI; the
    /// caller holds the security scope (process-wide) for the duration.
    nonisolated static func materializeForImport(_ picked: URL) async throws -> ImportFile {
        #if os(iOS)
        let ext = picked.pathExtension.isEmpty ? "dat" : picked.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        var coordError: NSError?
        var ioError: Error?
        // .forUploading materialises an iCloud placeholder and gives a stable snapshot to copy from.
        NSFileCoordinator().coordinate(readingItemAt: picked, options: [.forUploading], error: &coordError) { readURL in
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: readURL, to: dst)
            } catch { ioError = error }
        }
        if let coordError { throw coordError }
        if let ioError { throw ioError }
        // The picked URL is the picker's own `asCopy:true` duplicate in Documents/Inbox; pass it
        // through so cleanup() can reclaim it (it's the original of `dst`, not a user file).
        return ImportFile(url: dst, temp: dst, inboxOriginal: picked)
        #else
        return ImportFile(url: picked, temp: nil)
        #endif
    }

    /// One-shot launch sweep of `Documents/Inbox/`: deletes any stale `asCopy:true` picker drops a
    /// previous build left behind before `cleanup()` reclaimed them (#590). Best-effort, off-main, and
    /// safe , `Inbox` only ever holds picker hand-offs, never user data. Skips files newer than 60 s so
    /// it can't race an import that's mid-flight at launch.
    nonisolated static func purgeImportInbox() {
        #if os(iOS)
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = docs.appendingPathComponent("Inbox")
        guard let items = try? fm.contentsOfDirectory(at: inbox,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }   // leave an in-flight hand-off alone
            try? fm.removeItem(at: item)
        }
        #endif
    }

    func importWhoop(url: URL) {
        beginImport(.whoop)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.whoop, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .whoopExport, url: local.url)
                let summary = try await WhoopImporter.importExport(url: local.url, into: store,
                                                                   deviceId: deviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                _ = await repo.refresh(.postImport)
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                finishImport(.whoop, summary: "Imported \(summary.recordCount) records\(span)")
            } catch {
                finishImport(.whoop, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    /// Import an Apple Health export (export.zip) , streams + aggregates per-day into the store
    /// under the `apple-health` source, then refreshes. Large exports take ~1–2 minutes.
    func importXiaomi(url: URL) {
        beginImport(.xiaomi)
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.xiaomi, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .xiaomiBand, url: local.url)
                let summary = try await XiaomiImporter.importExport(url: local.url, into: store,
                                                                    trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                _ = await repo.refresh(.postImport)
                let span: String
                if let a = summary.earliest, let b = summary.latest {
                    let f = DateFormatter(); f.dateFormat = "MMM yyyy"
                    span = " · \(f.string(from: a))-\(f.string(from: b))"
                } else { span = "" }
                let days = summary.countsByCategory["days"] ?? 0
                let sleeps = summary.countsByCategory["sleepSessions"] ?? 0
                finishImport(.xiaomi, summary: "Imported \(days) days · \(sleeps) sleeps\(span)")
            } catch {
                finishImport(.xiaomi, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    func importAppleHealth(url: URL) {
        beginImport(.appleHealth)
        // FIX 2(c): run the parse+writes at `.utility` so a large Apple Health import yields to UI
        // rendering instead of inheriting the user-initiated QoS of the calling tap , the import's bulk
        // work was contending with the main actor and contributing to the transient post-import lag.
        Task(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let store = await repo.storeHandle() else {
                    finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                    return
                }
                let local = try await Self.materializeForImport(url)
                defer { local.cleanup() }
                emitImportFileMeta(kind: .appleHealth, url: local.url)
                let summary = try await AppleHealthImport.importExport(url: local.url, into: store,
                                                                       deviceId: appleDeviceId, trace: importTraceSink())
                try? await store.checkpointWAL()   // reclaim the WAL a bulk import grew (#590)
                _ = await repo.refresh(.postImport)
                // #833/v7.7.2: an Apple Health import may write ONLY body-composition series (weight/body_fat/
                // lean_mass/bmi/vo2max), which live in metricSeries OUTSIDE refresh()'s diff over daily/sleep/
                // vitals, so refresh() may not bump `refreshSeq`. AppleHealthView's re-mount cache keys on
                // `refreshSeq`, so it would keep serving the pre-import snapshot. Explicitly drop the cache so
                // the next visit re-reads the freshly imported data. (refresh() alone is insufficient here.)
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                finishImport(.appleHealth, summary: "Imported \(summary.recordCount) records")
            } catch {
                finishImport(.appleHealth, summary: "Import failed: \(error)", failed: true)
            }
        }
    }

    // MARK: - Storage diagnostics (#590 , StorageView)

    /// A point-in-time snapshot of where the app's on-disk footprint is going, for the Storage screen.
    /// All sizes in bytes; `db` is nil only for an unopened/in-memory store.
    struct StorageReport: Equatable, Sendable {
        var db: Int64?
        var inbox: Int64
        var importTemp: Int64
        var historicalQuarantine: HistoricalQuarantineSummary
    }

    /// Gather the storage report off the main actor: the GRDB file (+ WAL/SHM) from the store, plus the
    /// `Documents/Inbox/` picker-drop directory and the import temp files this app writes.
    func storageReport() async -> StorageReport {
        let store = await repo.storeHandle()
        let db = await store?.databaseFileSizeBytes()
        let quarantine = (try? await store?.historicalQuarantineSummary())
            ?? HistoricalQuarantineSummary()
        let inbox = Self.inboxSizeBytes()
        let temp = Self.importTempSizeBytes()
        return StorageReport(
            db: db,
            inbox: inbox,
            importTemp: temp,
            historicalQuarantine: quarantine
        )
    }

    func historicalQuarantinedJobs() async -> [HistoricalQuarantinedJob] {
        guard let store = await repo.storeHandle() else { return [] }
        return (try? await store.historicalQuarantinedJobs()) ?? []
    }

    func historicalQuarantinedArchive(receiptId: String) async -> HistoricalQuarantinedArchive? {
        guard let store = await repo.storeHandle() else { return nil }
        return try? await store.historicalQuarantinedArchive(receiptId: receiptId)
    }

    @discardableResult
    func retryHistoricalQuarantinedJob(receiptId: String) async -> Bool {
        guard let store = await repo.storeHandle(),
              (try? await store.retryQuarantinedHistoricalMaterialization(receiptId: receiptId)) == true
        else { return false }
        ble.wakeHistoricalMaterializationForRecovery()
        return true
    }

    @discardableResult
    func discardHistoricalQuarantinedArchive(receiptId: String) async -> Bool {
        guard let store = await repo.storeHandle(),
              (try? await store.discardQuarantinedHistoricalArchive(receiptId: receiptId)) == true
        else { return false }
        try? await store.checkpointWAL()
        return true
    }

    /// Total bytes in `Documents/Inbox/` (the picker's `asCopy:true` drops). 0 on macOS / when absent.
    nonisolated static func inboxSizeBytes() -> Int64 {
        #if os(iOS)
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return 0 }
        return directorySizeBytes(docs.appendingPathComponent("Inbox"))
        #else
        return 0
        #endif
    }

    /// True for any scratch file/dir NOOP itself writes into the temp directory , import copies, the
    /// decompressed export.xml, exports, backups, raw captures: every one is prefixed `noop-`. #590: the
    /// import decompresses `export.xml` to a `noop-health-*` temp file (up to 8 GB), but a previous build
    /// only matched `noop-import-*`, so an interrupted import stranded multi-GB extractions the Storage
    /// screen never saw OR reclaimed. Matching the shared `noop-` prefix counts + sweeps them all and is
    /// future-proof. Safe: the temp dir is NOOP's private sandbox and the 60 s in-flight guard in
    /// `purgeImportTemp` protects a live import.
    nonisolated static func isNoopTempScratch(_ name: String) -> Bool { name.hasPrefix("noop-") }

    /// Total bytes of NOOP's own `noop-*` temp scratch (a crash mid-import can strand a multi-GB one).
    /// Recurses into directories (the Xiaomi importer stages a `noop-xiaomi-*` folder).
    nonisolated static func importTempSizeBytes() -> Int64 {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// Sum every regular file under `dir` (one level , Inbox is flat). Best-effort; missing dir → 0.
    nonisolated private static func directorySizeBytes(_ dir: URL) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: []) else { return 0 }
        var total: Int64 = 0
        for item in items {
            let vals = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true { total += directorySizeBytes(item) }
            else { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// The Storage screen's "Clean up" action: purge the Inbox + stranded import temps, then truncate
    /// the WAL so the freed pages return to the OS. Returns a fresh report so the screen updates. Safe ,
    /// Inbox/temp hold only picker hand-offs + this app's own temp copies, never user data or live rows.
    @discardableResult
    func cleanUpStorage() async -> StorageReport {
        Self.purgeImportInbox()
        Self.purgeImportTemp()
        if let store = await repo.storeHandle() { try? await store.checkpointWAL() }
        return await storageReport()
    }

    /// Remove NOOP's stranded `noop-*` temp scratch (import copies, the multi-GB `noop-health-*`
    /// export.xml an interrupted import leaves behind , #590, exports, backups, raw captures). Mirrors
    /// `purgeImportInbox`'s 60 s in-flight guard so a concurrent import/export isn't disturbed.
    nonisolated static func purgeImportTemp() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for item in items where isNoopTempScratch(item.lastPathComponent) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: item)
        }
    }

    /// Handle a `noop://import-health` deep link (PR #581) , the HealthKit-free Shortcuts import for
    /// sideloaded installs. Ingests the Shortcut-built payload into the `apple-health` source (NEVER the
    /// strap , `ShortcutHealthImport` enforces the loop guard), then refreshes the dashboard. Surfaces
    /// the result on the Apple Health card like the file import does. The iOS `.onOpenURL` in StrandiOS/
    /// calls this; macOS never registers the scheme.
    func handleHealthImportURL(_ url: URL) {
        beginImport(.appleHealth)
        Task {
            guard let store = await repo.storeHandle() else {
                finishImport(.appleHealth, summary: "Couldn't open the local store.", failed: true)
                return
            }
            let outcome = await ShortcutHealthImport.ingest(url: url, into: store)
            switch outcome {
            case .imported(let days, let workouts):
                _ = await repo.refresh(.postImport)
                // #833/v7.7.2: the Shortcuts import writes body-composition series (e.g. weight) into
                // metricSeries, which sits OUTSIDE refresh()'s diff, so refresh() may leave `refreshSeq`
                // unchanged and AppleHealthView's re-mount cache would serve stale data. Drop the cache so the
                // next visit re-reads. (Same reasoning as the file-import path above.)
                repo.appleHealthCache = nil
                repo.appleHealthLoadedSeq = -1
                let w = workouts > 0 ? " · \(workouts) workouts" : ""
                finishImport(.appleHealth, summary: "Imported \(days) days\(w)")
            case .nothingToImport:
                finishImport(.appleHealth, summary: "Nothing new to import.")
            case .rejected(let reason):
                finishImport(.appleHealth, summary: reason, failed: true)
            }
        }
    }

    /// Marks a source as importing and clears only that source's old status text + failure flag.
    private func beginImport(_ source: DataSourceImportKind) {
        activeImportSource = source
        switch source {
        case .whoop:
            whoopImportSummary = nil
            whoopImportFailed = false
        case .appleHealth:
            appleHealthImportSummary = nil
            appleHealthImportFailed = false
        case .xiaomi:
            xiaomiImportSummary = nil
            xiaomiImportFailed = false
        }
    }

    /// Stores the completed import summary (and typed failure flag) on the matching source card.
    private func finishImport(_ source: DataSourceImportKind, summary: String, failed: Bool = false) {
        switch source {
        case .whoop:
            whoopImportSummary = summary
            whoopImportFailed = failed
        case .appleHealth:
            appleHealthImportSummary = summary
            appleHealthImportFailed = failed
        case .xiaomi:
            xiaomiImportSummary = summary
            xiaomiImportFailed = failed
        }
        activeImportSource = nil
    }
}
