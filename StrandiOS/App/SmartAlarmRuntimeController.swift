#if os(iOS)
import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications
import StrandAnalytics
import WhoopStore

/// Adaptive wake mode ownership is deliberately separate from persistence migration concerns. The
/// controller is now the only runtime, so `BehaviorStore.smartAlarmMode` mirrors the selected mode rather
/// than being pinned to exact time for a removed legacy lane.
@MainActor
final class SmartAlarmAdaptiveModeStore: ObservableObject {
    private static let modeKey = "smartAlarm.runtime.adaptiveMode"
    private static let migratedKey = "smartAlarm.runtime.adaptiveModeMigrated"

    private weak var legacy: BehaviorStore?
    private let defaults: UserDefaults

    @Published var mode: SmartAlarmEvaluator.Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            synchronizeBehaviorMode()
        }
    }

    init(legacy: BehaviorStore, defaults: UserDefaults = .standard) {
        self.legacy = legacy
        self.defaults = defaults
        let migrated = defaults.bool(forKey: Self.migratedKey)
        let stored = defaults.string(forKey: Self.modeKey).flatMap(SmartAlarmEvaluator.Mode.init(rawValue:))
        let resolved = migrated ? (stored ?? .exactTime) : legacy.smartAlarmMode
        mode = resolved
        defaults.set(resolved.rawValue, forKey: Self.modeKey)
        defaults.set(true, forKey: Self.migratedKey)
        synchronizeBehaviorMode()
    }

    func synchronizeBehaviorMode() {
        guard let legacy, !legacy.wakeAlarms.isEmpty, legacy.smartAlarmMode != mode else { return }
        legacy.smartAlarmMode = mode
    }
}

struct SmartAlarmRuntimeSnapshot: Codable, Equatable, Sendable {
    let enabled: Bool
    let mode: SmartAlarmEvaluator.Mode
    let minutes: Int
    let weekdays: [Int]
    /// Optional for backward-compatible decoding of existing single-alarm background payloads.
    let alarms: [WakeAlarm]?

    init(enabled: Bool, mode: SmartAlarmEvaluator.Mode, minutes: Int, weekdays: Set<Int>, alarms: [WakeAlarm]? = nil) {
        self.enabled = enabled
        self.mode = mode
        self.minutes = ((minutes % 1_440) + 1_440) % 1_440
        self.weekdays = weekdays.filter { (1...7).contains($0) }.sorted()
        self.alarms = alarms.map(WakeAlarmPlan.normalized)
    }

    var weekdaySet: Set<Int> { Set(weekdays) }
    var schedules: [WakeAlarm] {
        alarms ?? [WakeAlarm(id: WakeAlarmPersistence.legacyID, enabled: enabled,
                            minutes: minutes, weekdays: weekdaySet, mode: mode)]
    }
    func next(after now: Date, calendar: Calendar = .current) -> WakeAlarmPlan.Occurrence? {
        WakeAlarmPlan.next(in: schedules, after: now, calendar: calendar)
    }
    func mode(for endpoint: Date) -> SmartAlarmEvaluator.Mode {
        next(after: endpoint.addingTimeInterval(-1))?.alarm.mode ?? mode
    }
    var backupEntries: [WakeAlarmPlan.Backup] { WakeAlarmPlan.backups(for: schedules) }

}

/// Persisted payload for iOS's payload-less BGTask request. Without this, a late BG execution recomputed
/// "next alarm" from its actual run time and could evaluate the following recurrence instead of the endpoint
/// whose wake window scheduled the task.
struct SmartAlarmBackgroundRequest: Codable, Equatable, Sendable {
    let configurationID: UUID
    let endpoint: Date
    let enabled: Bool
    let modeRawValue: String
    let minutes: Int
    let weekdays: [Int]
    let alarms: [WakeAlarm]?

    init(configurationID: UUID, endpoint: Date, snapshot: SmartAlarmRuntimeSnapshot) {
        self.configurationID = configurationID
        self.endpoint = endpoint
        enabled = snapshot.enabled
        modeRawValue = snapshot.mode.rawValue
        minutes = snapshot.minutes
        weekdays = snapshot.weekdays
        alarms = snapshot.alarms
    }

    var snapshot: SmartAlarmRuntimeSnapshot? {
        guard let mode = SmartAlarmEvaluator.Mode(rawValue: modeRawValue) else { return nil }
        return SmartAlarmRuntimeSnapshot(
            enabled: enabled,
            mode: mode,
            minutes: minutes,
            weekdays: Set(weekdays),
            alarms: alarms
        )
    }
}

/// Small deterministic state machine used by the runtime and unit tests. Any configuration edge advances
/// the generation; asynchronous work may mutate BLE/notifications/evidence only while its token and exact
/// normalized snapshot are still current.
struct SmartAlarmRuntimeGeneration: Equatable, Sendable {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ token: UInt64, request: SmartAlarmRuntimeSnapshot,
                 current: SmartAlarmRuntimeSnapshot) -> Bool {
        token == value && request == current
    }
}

private struct SmartAlarmEvaluationComputation: Sendable {
    let evaluation: SmartAlarmEvaluator.Evaluation
    let observedAt: Date?
    let forecastAvailable: Bool
}

private struct SmartAlarmPersistedConfiguration: Codable, Equatable, Sendable {
    let id: UUID
    let snapshot: SmartAlarmRuntimeSnapshot
}

@MainActor
final class SmartAlarmRuntimeController: ObservableObject {
    static let backupBaseIdentifier = "smart-alarm-wake-backup"
    /// A strap clock ahead of the phone by up to this much still counts as "the armed alarm just fired".
    private static let firedSkewTolerance: TimeInterval = 30
    /// How long past the endpoint live data must keep arriving before we stop waiting for the strap's fire event.
    private static let passedGrace: TimeInterval = 5
    static func backupIdentifiers(configurationID: UUID, generation: UInt64? = nil) -> [String] {
        // A foreground/reconnect reconcile keeps the configuration but replaces its
        // async task. Its cancelled predecessor must only clean up its own requests.
        var generationBase = "\(backupBaseIdentifier)-\(configurationID.uuidString.lowercased())"
        if let generation { generationBase += "-g\(generation)" }
        return [generationBase] + (1...7).map { "\(generationBase)-d\($0)" }
    }

    private static func backupIdentifiers(snapshot: SmartAlarmRuntimeSnapshot,
                                          configurationID: UUID, generation: UInt64) -> [String] {
        let base = backupIdentifiers(configurationID: configurationID, generation: generation)[0]
        return snapshot.backupEntries.map { "\(base)-a\($0.suffix)" }
    }

    @Published private(set) var deliveryStatus = String(localized: "Off")
    @Published private(set) var backupStatus = String(localized: "Off")
    @Published private(set) var evidence: SmartAlarmEvidence?

    let modeStore: SmartAlarmAdaptiveModeStore

    private let model: AppModel
    private let behavior: BehaviorStore
    private var started = false
    private var strapHooksInstalled = false
    private var observedSnapshot: SmartAlarmRuntimeSnapshot?
    /// The one endpoint the strap currently holds. The firmware keeps a single alarm, so a later saved alarm
    /// only reaches the strap after this one has passed and we re-arm.
    private var armedEndpoint: Date?
    /// Endpoint known to have just fired; the next lookup starts after it even if the phone clock lags the strap.
    private var consumedEndpoint: Date?
    private var watchdogEndpoint: Date?
    private var generation = SmartAlarmRuntimeGeneration()
    private var configurationID: UUID
    private var cancellables = Set<AnyCancellable>()

    private var debounceTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var backupStatusTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var evidenceTask: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?

    init(model: AppModel, modeStore: SmartAlarmAdaptiveModeStore) {
        self.model = model
        behavior = model.behavior
        self.modeStore = modeStore
        let initialSnapshot = SmartAlarmRuntimeSnapshot(
            enabled: model.behavior.hasEnabledWakeAlarms,
            mode: modeStore.mode,
            minutes: model.behavior.smartAlarmMinutes,
            weekdays: model.behavior.smartAlarmWeekdays,
            alarms: model.behavior.wakeAlarms
        )
        configurationID = SmartAlarmRuntimeBackgroundScheduler.configurationID(for: initialSnapshot)
        // A BLE-restoration relaunch has no scene to run `.task`, so the strap hooks are live from construction.
        installStrapHooks()
    }

    deinit {
        debounceTask?.cancel()
        notificationTask?.cancel()
        backupStatusTask?.cancel()
        evaluationTask?.cancel()
        evidenceTask?.cancel()
        dailyTask?.cancel()
        endpointTask?.cancel()
    }

    /// Strap-driven edges: a reconnect re-arms the firmware alarm, and a strap-fired event correlates evidence,
    /// mirrors the wake on the phone, then reconciles the following firmware occurrence. These must exist for a
    /// Bluetooth-restoration relaunch that never builds a scene (and so never reaches `start()` from the UI), so
    /// `init` calls this. It has no launch-time side effects, unlike `start()`'s initial reconcile,
    /// and is idempotent.
    func installStrapHooks() {
        guard !strapHooksInstalled else { return }
        strapHooksInstalled = true

        model.live.$connectSettled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileImmediately(trigger: .bluetoothReconnect)
                }
            }
            .store(in: &cancellables)

        // The controller is the only alarm runtime.
        model.live.onSmartAlarmFired = { [weak self] in
            guard let self else { return }
            SmartAlarmEvidenceStore.refreshCorrelation()
            AppModel.postSmartAlarm()
            self.rearmAfterFire("strap-fired")
        }
    }

    /// Hand the strap's single alarm slot to the next saved alarm. Called when the strap reports a fire, when
    /// the in-process timer sees the endpoint pass, and when live data arrives after the endpoint passed.
    private func rearmAfterFire(_ event: String) {
        // Only an endpoint that is due may be skipped: a late or replayed event must not jump over a later alarm.
        if let armed = armedEndpoint, armed.timeIntervalSinceNow < Self.firedSkewTolerance {
            consumedEndpoint = armed
        }
        WakeAlarmChainReceipts.record(event, endpoint: armedEndpoint)
        reconcileImmediately(trigger: .configured)
    }

    /// The strap's BLE fire event is not seen on every model (no 5/MG fire event has been observed) and the timer in
    /// `scheduleEndpointRearm` cannot run while iOS has the app suspended. Any live sample after the endpoint
    /// wakes the app, so use it as the fallback signal that the armed alarm has passed.
    private func rearmIfEndpointPassed() {
        guard let armed = armedEndpoint, watchdogEndpoint != armed,
              Date() >= armed.addingTimeInterval(Self.passedGrace) else { return }
        watchdogEndpoint = armed
        rearmAfterFire("live-data-after-endpoint")
    }

    private func nextOccurrence(in snapshot: SmartAlarmRuntimeSnapshot, now: Date = Date()) -> WakeAlarmPlan.Occurrence? {
        WakeAlarmPlan.next(in: snapshot.schedules, afterFiring: consumedEndpoint, now: now)
    }

    func start() {
        guard !started else { return }
        started = true

        behavior.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.configurationMayHaveChanged()
                }
            }
            .store(in: &cancellables)

        modeStore.$mode
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.configurationMayHaveChanged() }
            }
            .store(in: &cancellables)

        installStrapHooks()

        NotificationCenter.default.publisher(for: SmartAlarmEvidenceStore.readbackDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshStatus() }
            }
            .store(in: &cancellables)

        model.ble.$connectedPeripheralUUID
            .combineLatest(model.live.$connected)
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshEvidence(for: self.currentEndpoint())
                }
            }
            .store(in: &cancellables)

        model.live.$heartRate
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.rearmIfEndpointPassed() }
            }
            .store(in: &cancellables)

        model.repo.$refreshSeq
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluateIfInsideWindow(trigger: .dataRefresh)
                }
            }
            .store(in: &cancellables)

        observedSnapshot = currentSnapshot
        reconcileImmediately(trigger: .configured)
        startDailyRearmLoop()
    }

    func handleForeground() {
        start()
        reconcileImmediately(trigger: .foreground)
    }

    func refreshStatus() {
        start()
        refreshEvidence(for: currentEndpoint())
        refreshBackupStatus()
    }

    /// Evaluate exactly the persisted endpoint that scheduled this background task. A stale request is never
    /// translated into another recurrence; it is discarded and the current configuration is reconciled.
    @discardableResult
    func handleBackgroundRefresh(_ request: SmartAlarmBackgroundRequest?) async -> Bool {
        start()
        guard let request,
              let requestedSnapshot = request.snapshot,
              request.configurationID == configurationID,
              requestedSnapshot == currentSnapshot,
              requestedSnapshot.enabled,
              requestedSnapshot.mode(for: request.endpoint) != .exactTime
        else {
            reconcileImmediately(trigger: .backgroundRefresh)
            return request != nil
        }

        let token = generation.value
        let succeeded = await evaluate(
            snapshot: requestedSnapshot,
            endpoint: request.endpoint,
            token: token,
            trigger: .backgroundRefresh
        )
        guard generation.accepts(token, request: requestedSnapshot, current: currentSnapshot),
              !Task.isCancelled else { return false }

        // A consumed request must not submit the SAME past window again. Keep the already-armed current
        // firmware endpoint untouched and queue the following recurrence's adaptive evaluation. The older
        // endpoint-only hook re-arms firmware after a confirmed strap fire; foreground/daily reconciliation
        // remains the belt-and-braces path when the process is alive.
        scheduleFollowingBackgroundRequest(
            after: max(Date(), request.endpoint),
            snapshot: requestedSnapshot
        )
        return succeeded
    }

    private var currentSnapshot: SmartAlarmRuntimeSnapshot {
        SmartAlarmRuntimeSnapshot(
            enabled: behavior.hasEnabledWakeAlarms,
            mode: behavior.smartAlarmMode,
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays,
            alarms: behavior.wakeAlarms
        )
    }

    private func configurationMayHaveChanged() {
        let snapshot = currentSnapshot
        guard snapshot != observedSnapshot else { return }
        observedSnapshot = snapshot
        configurationID = UUID()
        SmartAlarmRuntimeBackgroundScheduler.persistConfiguration(
            id: configurationID,
            snapshot: snapshot
        )
        schedule(snapshot)
    }

    private func schedule(_ snapshot: SmartAlarmRuntimeSnapshot) {
        cancelGenerationWork()
        let token = generation.advance()

        guard snapshot.enabled else {
            applyDisabled(snapshot: snapshot, token: token)
            return
        }

        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
            else { return }
            self.apply(snapshot: snapshot, token: token, trigger: .configured)
        }
    }

    func reconcileImmediately(trigger: SmartAlarmEvaluator.Trigger) {
        let snapshot = currentSnapshot
        observedSnapshot = snapshot
        cancelGenerationWork()
        let token = generation.advance()
        if snapshot.enabled {
            apply(snapshot: snapshot, token: token, trigger: trigger)
        } else {
            applyDisabled(snapshot: snapshot, token: token)
        }
    }

    private func cancelGenerationWork() {
        debounceTask?.cancel()
        notificationTask?.cancel()
        backupStatusTask?.cancel()
        evaluationTask?.cancel()
        evidenceTask?.cancel()
        endpointTask?.cancel()
        debounceTask = nil
        notificationTask = nil
        backupStatusTask = nil
        evaluationTask = nil
        evidenceTask = nil
        endpointTask = nil
    }

    private func applyDisabled(snapshot: SmartAlarmRuntimeSnapshot, token: UInt64) {
        guard generation.accepts(token, request: snapshot, current: currentSnapshot) else { return }
        armedEndpoint = nil
        model.ble.disableStrapAlarm()
        SmartAlarmRuntimeBackgroundScheduler.cancel()
        deliveryStatus = String(localized: "Off")
        backupStatus = String(localized: "Off")
        evidence = nil

        notificationTask = Task { @MainActor [weak self] in
            guard let self, !self.currentSnapshot.enabled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
            else { return }
            await self.removeAllBackupNotificationsIfCurrent(snapshot: snapshot, token: token)
        }
    }

    private func apply(
        snapshot: SmartAlarmRuntimeSnapshot,
        token: UInt64,
        trigger: SmartAlarmEvaluator.Trigger
    ) {
        guard generation.accepts(token, request: snapshot, current: currentSnapshot),
              let occurrence = nextOccurrence(in: snapshot)
        else {
            armedEndpoint = nil
            model.ble.disableStrapAlarm()
            removeAllBackupNotifications(snapshot: snapshot, token: token)
            SmartAlarmRuntimeBackgroundScheduler.cancel()
            deliveryStatus = String(localized: "Not armed · no enabled day")
            backupStatus = String(localized: "Not scheduled")
            return
        }

        let endpoint = occurrence.date
        let arm = model.ble.armStrapAlarm(at: endpoint)
        armedEndpoint = endpoint
        WakeAlarmChainReceipts.record(Self.receiptName(for: arm), endpoint: endpoint)
        persistEndpointEvidence(endpoint: endpoint, mode: occurrence.alarm.mode, arm: arm)
        updateDeliveryStatus(endpoint: endpoint, arm: arm, snapshot: snapshot)
        scheduleBackupNotifications(snapshot: snapshot, token: token)
        scheduleEvidenceRefresh(snapshot: snapshot, endpoint: endpoint, token: token)

        scheduleEndpointRearm(snapshot: snapshot, endpoint: endpoint, token: token)

        if snapshot.mode(for: endpoint) == .exactTime {
            SmartAlarmRuntimeBackgroundScheduler.cancel()
        } else {
            scheduleBackgroundRequest(endpoint: endpoint, snapshot: snapshot)
            let windowStart = endpoint.addingTimeInterval(
                -Double(SmartAlarmEvaluator.adaptiveWindowMinutes * 60)
            )
            if Date() >= windowStart {
                beginEvaluation(snapshot: snapshot, endpoint: endpoint, token: token, trigger: trigger)
            }
        }
    }

    private func scheduleEndpointRearm(snapshot: SmartAlarmRuntimeSnapshot, endpoint: Date, token: UInt64) {
        endpointTask?.cancel()
        endpointTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, endpoint.timeIntervalSinceNow + 1))) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
            else { return }
            self.rearmAfterFire("timer-endpoint-passed")
        }
    }

    private static func receiptName(for arm: BLEManager.AlarmCommandResult) -> String {
        switch arm {
        case .sentAwaitingReadback: return "armed"
        case .queuedForReconnect: return "queued-strap-not-ready"
        case .experimentalDisabled: return "not-armed-experimental-off"
        }
    }

    private func scheduleBackgroundRequest(
        endpoint: Date,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        let windowStart = endpoint.addingTimeInterval(
            -Double(SmartAlarmEvaluator.adaptiveWindowMinutes * 60)
        )
        SmartAlarmRuntimeBackgroundScheduler.schedule(
            windowStart: windowStart,
            endpoint: endpoint,
            snapshot: snapshot,
            configurationID: configurationID
        )
    }

    private func scheduleFollowingBackgroundRequest(
        after endpoint: Date,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        guard generation.accepts(generation.value, request: snapshot, current: currentSnapshot),
              let next = snapshot.next(after: endpoint.addingTimeInterval(1))?.date,
              snapshot.mode(for: next) != .exactTime
        else {
            SmartAlarmRuntimeBackgroundScheduler.cancel()
            return
        }
        scheduleBackgroundRequest(endpoint: next, snapshot: snapshot)
    }

    private func currentEndpoint(now: Date = Date()) -> Date? {
        let snapshot = currentSnapshot
        guard snapshot.enabled else { return nil }
        return nextOccurrence(in: snapshot, now: now)?.date
    }

    private func evaluateIfInsideWindow(trigger: SmartAlarmEvaluator.Trigger) {
        let snapshot = currentSnapshot
        guard snapshot.enabled, let endpoint = currentEndpoint(),
              snapshot.mode(for: endpoint) != .exactTime else { return }
        let windowStart = endpoint.addingTimeInterval(
            -Double(SmartAlarmEvaluator.adaptiveWindowMinutes * 60)
        )
        guard Date() >= windowStart else { return }
        evaluationTask?.cancel()
        let token = generation.value
        beginEvaluation(snapshot: snapshot, endpoint: endpoint, token: token, trigger: trigger)
    }

    private func beginEvaluation(snapshot: SmartAlarmRuntimeSnapshot, endpoint: Date,
                                 token: UInt64, trigger: SmartAlarmEvaluator.Trigger) {
        evaluationTask?.cancel()
        evaluationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.evaluate(
                snapshot: snapshot,
                endpoint: endpoint,
                token: token,
                trigger: trigger
            )
        }
    }

    private func evaluate(snapshot: SmartAlarmRuntimeSnapshot, endpoint: Date,
                          token: UInt64, trigger: SmartAlarmEvaluator.Trigger) async -> Bool {
        guard generation.accepts(token, request: snapshot, current: currentSnapshot),
              !Task.isCancelled else { return false }

        let now = Date()
        let windowStart = endpoint.addingTimeInterval(
            -Double(SmartAlarmEvaluator.adaptiveWindowMinutes * 60)
        )
        guard let store = await model.repo.storeHandle() else {
            guard generation.accepts(token, request: snapshot, current: currentSnapshot) else { return false }
            persistUnavailableEvidence(mode: snapshot.mode(for: endpoint), trigger: trigger, endpoint: endpoint,
                                       reason: "storeUnavailable", evaluatedAt: now)
            refreshEvidence(for: endpoint)
            return false
        }

        let deviceID = model.repo.deviceId
        let planningDay = Repository.localDayKey(endpoint)
        let needPoint = await model.repo.latestNoopSleepNeedV2(onOrBefore: planningDay)
        let needMinutes = needPoint?.value ?? RecoveryForecaster.defaultNeedHours * 60
        let needNights = needPoint == nil ? 0 : RecoveryForecaster.solidNeedNights
        let recentCharge = Array(model.intelligence.results.compactMap(\.recovery).reversed())
        let recentEffort = Array(model.intelligence.results.compactMap(\.strain).reversed())
        let todayEffort = model.intelligence.results.first?.strain
        let timeZoneOffset = TimeZone.current.secondsFromGMT()
        let from = Int(now.timeIntervalSince1970) - 18 * 3_600
        let to = Int(now.timeIntervalSince1970)

        let computation: SmartAlarmEvaluationComputation
        do {
            // `async let` is a structured child: cancelling `evaluationTask` now propagates into the
            // store read and prevents stale CPU work from surviving a configuration generation.
            async let child = Self.computeEvaluation(
                store: store,
                deviceID: deviceID,
                from: from,
                to: to,
                timeZoneOffset: timeZoneOffset,
                snapshot: snapshot,
                now: now,
                windowStart: windowStart,
                endpoint: endpoint,
                needMinutes: needMinutes,
                needNights: needNights,
                recentCharge: recentCharge,
                recentEffort: recentEffort,
                todayEffort: todayEffort
            )
            computation = try await child
        } catch is CancellationError {
            return false
        } catch {
            guard generation.accepts(token, request: snapshot, current: currentSnapshot) else { return false }
            persistUnavailableEvidence(mode: snapshot.mode(for: endpoint), trigger: trigger, endpoint: endpoint,
                                       reason: "analysisUnavailable", evaluatedAt: now)
            refreshEvidence(for: endpoint)
            return false
        }

        guard !Task.isCancelled,
              generation.accepts(token, request: snapshot, current: currentSnapshot)
        else { return false }

        var actuation: SmartAlarmEvidence.Actuation = .notRequested
        var requestedWake = endpoint
        var retainedArmEvidence: SmartAlarmEvidence?
        var startedAdaptiveArm = false
        if computation.evaluation.decision == .wakeNow {
            SmartAlarmEvidenceStore.refreshCorrelation()
            let previous = SmartAlarmEvidenceStore.latest
            let reuseEarlyWake: Bool
            if model.whoop5Detected {
                // Experimental WHOOP 5/MG has no owned WHOOP 4 readback transaction.
                reuseEarlyWake = previous?.actuation == .sentToConnectedStrap
            } else if let previous, let source = model.ble.connectedPeripheralUUID {
                reuseEarlyWake = previous.matchesEarlyWakeAttempt(
                    endpoint: endpoint, mode: snapshot.mode(for: endpoint), sourceID: source)
            } else {
                reuseEarlyWake = false
            }
            if previous?.windowEndpoint == endpoint,
               previous?.mode == snapshot.mode(for: endpoint),
               reuseEarlyWake {
                actuation = previous?.actuation ?? .notRequested
                requestedWake = previous?.requestedWakeAt ?? endpoint
                retainedArmEvidence = previous
            } else {
                let context: SmartAlarmEvaluator.ExecutionContext =
                    trigger == .backgroundRefresh ? .backgroundBestEffort : .foreground
                let linkReady = model.live.connected && model.live.bonded && model.live.encryptedBond
                switch SmartAlarmEvaluator.actuationPlan(
                    for: computation.evaluation,
                    linkReady: linkReady,
                    context: context
                ) {
                case .rearmEarlier:
                    let earlier = Date().addingTimeInterval(SmartAlarmEvaluator.actuationLeadSeconds)
                    switch model.ble.armStrapAlarm(at: earlier) {
                    case .sentAwaitingReadback:
                        actuation = .sentToConnectedStrap
                        requestedWake = earlier
                        startedAdaptiveArm = true
                        model.ble.buzzStrapOnce()
                    case .queuedForReconnect:
                        actuation = .queuedForReconnect
                    case .experimentalDisabled:
                        actuation = .experimentalDisabled
                    }
                case .queueForReconnect:
                    actuation = .queuedForReconnect
                case .none:
                    break
                }
            }
        }

        var evaluationEvidence = SmartAlarmEvidence(
            mode: snapshot.mode(for: endpoint),
            trigger: trigger,
            decision: computation.evaluation.decision,
            reason: computation.evaluation.reason,
            evaluatedAt: computation.evaluation.evaluatedAt,
            inputObservedAt: computation.observedAt,
            sleepSource: "noop-live-stager",
            sleepModelVersion: SleepPerformanceV2.modelVersion,
            forecastSource: computation.forecastAvailable ? "noop-recovery-forecast" : nil,
            forecastModelVersion: computation.forecastAvailable ? RecoveryForecaster.modelVersion : nil,
            requestedWakeAt: requestedWake,
            windowEndpoint: endpoint,
            strapReportedArmedAt: nil,
            observedStrapWakeAt: nil,
            actuation: actuation,
            evaluatorModelVersion: computation.evaluation.modelVersion
        )
        if let retainedArmEvidence {
            // Reusing an earlier actuation must retain its physical request, even though this
            // evaluation has new provenance. Correlation still validates the current source/request.
            evaluationEvidence.armRequestID = retainedArmEvidence.armRequestID
            evaluationEvidence.armSourceID = retainedArmEvidence.armSourceID
            evaluationEvidence.armSentAt = retainedArmEvidence.armSentAt
            evaluationEvidence.readbackStatus = retainedArmEvidence.readbackStatus
            evaluationEvidence.earlyWakeAttempted = retainedArmEvidence.hasAttemptedEarlyWake ? true : nil
            evaluationEvidence.earlyWakeSourceID = retainedArmEvidence.attemptedEarlyWakeSourceID
        }
        SmartAlarmEvidenceStore.save(evaluationEvidence)
        refreshEvidence(for: endpoint)
        if startedAdaptiveArm {
            scheduleEvidenceRefresh(snapshot: snapshot, endpoint: endpoint, token: token)
        }
        model.live.append(
            log: "Smart alarm: mode=\(snapshot.mode(for: endpoint).rawValue) decision=\(computation.evaluation.decision.rawValue) reason=\(computation.evaluation.reason) actuation=\(actuation.rawValue)"
        )
        return true
    }

    private nonisolated static func computeEvaluation(
        store: WhoopStore,
        deviceID: String,
        from: Int,
        to: Int,
        timeZoneOffset: Int,
        snapshot: SmartAlarmRuntimeSnapshot,
        now: Date,
        windowStart: Date,
        endpoint: Date,
        needMinutes: Double,
        needNights: Int,
        recentCharge: [Double],
        recentEffort: [Double],
        todayEffort: Double?
    ) async throws -> SmartAlarmEvaluationComputation {
        try Task.checkCancellation()
        let bundle = try await store.analysisDayBundle(
            deviceId: deviceID, from: from, to: to, limit: 200_000
        )
        try Task.checkCancellation()
        let sessions = SleepStager.detectSleep(
            hr: bundle.hr, rr: bundle.rr, resp: bundle.resp, gravity: bundle.gravity,
            tzOffsetSeconds: timeZoneOffset
        )
        try Task.checkCancellation()
        let bankedMinutes = sessions.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
            .map { session in
                session.stages
                    .filter { $0.stage != "wake" }
                    .reduce(0.0) { $0 + Double(max(0, $1.end - $1.start)) } / 60.0
            }
        let observedEpoch = [bundle.hr.last?.ts, bundle.rr.last?.ts,
                             bundle.resp.last?.ts, bundle.gravity.last?.ts]
            .compactMap { $0 }.max()
        let observedAt = observedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        try Task.checkCancellation()
        let forecast = bankedMinutes.flatMap { banked in
            RecoveryForecaster.forecast(
                recentCharge: recentCharge,
                recentEffort: recentEffort,
                todayEffort: todayEffort,
                plannedSleepHours: banked / 60,
                needHours: needMinutes / 60,
                needNights: needNights
            )
        }
        try Task.checkCancellation()
        let evaluation = SmartAlarmEvaluator.evaluate(.init(
            mode: snapshot.mode(for: endpoint),
            now: now,
            windowStart: windowStart,
            windowEnd: endpoint,
            bankedSleepMinutes: bankedMinutes,
            sleepNeedMinutes: needMinutes,
            recoveryForecastLow: forecast?.low,
            inputObservedAt: observedAt
        ))
        return SmartAlarmEvaluationComputation(
            evaluation: evaluation,
            observedAt: observedAt,
            forecastAvailable: forecast != nil
        )
    }

    private func scheduleBackupNotifications(snapshot: SmartAlarmRuntimeSnapshot, token: UInt64) {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            let operationID = self.configurationID
            let operationIdentifiers = Self.backupIdentifiers(snapshot: snapshot, configurationID: operationID, generation: token)

            let settings = await center.notificationSettings()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID,
                  snapshot.enabled
            else { return }

            var authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }

            guard authorized,
                  !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID,
                  snapshot.enabled
            else {
                // A superseded authorization task must never clear or publish over the newer generation.
                if self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                   operationID == self.configurationID {
                    self.backupStatus = authorized
                        ? String(localized: "Not scheduled")
                        : String(localized: "Unavailable · permission denied")
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Smart alarm")
            content.body = String(localized: "Backup wake: your smart alarm time is here.")
            content.sound = .default
            let existing = await center.pendingNotificationRequests()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID else { return }
            let oldAlarms = existing.filter { $0.identifier.hasPrefix(Self.backupBaseIdentifier) }
            let proposed = zip(snapshot.backupEntries, operationIdentifiers).map { entry, identifier in
                var components = DateComponents()
                components.weekday = entry.weekday
                components.hour = entry.minutes / 60
                components.minute = entry.minutes % 60
                return UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
            }
            let replacement = await WakeAlarmBackupReplacement.replace(
                existing: oldAlarms, proposed: proposed, otherCount: existing.count - oldAlarms.count,
                identifier: { $0.identifier },
                matches: { old, new in
                    guard let a = old.trigger as? UNCalendarNotificationTrigger,
                          let b = new.trigger as? UNCalendarNotificationTrigger else { return false }
                    return a.repeats == b.repeats && a.dateComponents.hour == b.dateComponents.hour
                        && a.dateComponents.minute == b.dateComponents.minute
                        && a.dateComponents.weekday == b.dateComponents.weekday
                },
                isCurrent: {
                    !Task.isCancelled && operationID == self.configurationID
                        && self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
                },
                remove: { center.removePendingNotificationRequests(withIdentifiers: $0) },
                add: { try await center.add($0) }
            )
            guard replacement == .scheduled else {
                if !Task.isCancelled, operationID == self.configurationID,
                   self.generation.accepts(token, request: snapshot, current: self.currentSnapshot) {
                    self.backupStatus = replacement == .insufficientCapacity
                        ? String(localized: "Not updated · too many reminders")
                        : String(localized: "Not all alarms scheduled")
                }
                return
            }

            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID,
                  snapshot.enabled
            else {
                center.removePendingNotificationRequests(withIdentifiers: operationIdentifiers)
                return
            }
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID
            else {
                center.removePendingNotificationRequests(withIdentifiers: operationIdentifiers)
                return
            }
            let keep = Set(operationIdentifiers)
            let superseded = pending.map(\.identifier).filter {
                $0.hasPrefix(Self.backupBaseIdentifier) && !keep.contains($0)
            }
            center.removePendingNotificationRequests(withIdentifiers: superseded)
            let installed = Set(pending.map(\.identifier))
            self.backupStatus = operationIdentifiers.allSatisfy(installed.contains)
                ? String(localized: "Scheduled for all enabled alarms")
                : String(localized: "Not all alarms scheduled")
        }
    }

    private func refreshBackupStatus() {
        backupStatusTask?.cancel()
        backupStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = self.currentSnapshot
            let token = self.generation.value
            let operationID = self.configurationID
            guard snapshot.enabled else {
                self.backupStatus = String(localized: "Off")
                return
            }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID else { return }
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral
            else {
                self.backupStatus = String(localized: "Unavailable · permission denied")
                return
            }
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  operationID == self.configurationID else { return }
            let currentIdentifiers = Set(Self.backupIdentifiers(snapshot: snapshot, configurationID: operationID, generation: token))
            let scheduled = !currentIdentifiers.isEmpty && currentIdentifiers.isSubset(of: Set(pending.map(\.identifier)))
            self.backupStatus = scheduled
                ? String(localized: "Scheduled for all enabled alarms")
                : String(localized: "Not all alarms scheduled")
        }
    }

    private func removeAllBackupNotifications(snapshot: SmartAlarmRuntimeSnapshot, token: UInt64) {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.removeAllBackupNotificationsIfCurrent(snapshot: snapshot, token: token)
        }
    }

    private func removeAllBackupNotificationsIfCurrent(
        snapshot: SmartAlarmRuntimeSnapshot,
        token: UInt64
    ) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled,
              generation.accepts(token, request: snapshot, current: currentSnapshot)
        else { return }
        let identifiers = pending.map(\.identifier).filter {
            $0.hasPrefix(Self.backupBaseIdentifier)
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func scheduleEvidenceRefresh(
        snapshot: SmartAlarmRuntimeSnapshot,
        endpoint: Date,
        token: UInt64
    ) {
        evidenceTask?.cancel()
        evidenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [250, 750, 1_500, 3_000, 4_500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled,
                      self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
                else { return }
                self.refreshEvidence(for: endpoint)
                if self.evidence?.readbackStatus == .confirmed { return }
            }
        }
    }

    private func refreshEvidence(for endpoint: Date?) {
        SmartAlarmEvidenceStore.refreshCorrelation()
        guard let endpoint,
              let latest = SmartAlarmEvidenceStore.latest,
              latest.windowEndpoint == endpoint,
              latest.mode == currentSnapshot.mode(for: endpoint)
        else {
            evidence = nil
            return
        }
        evidence = latest
        // WHOOP 5/MG has no owned WHOOP 4 readback transaction; retain its explicit experimental state.
        guard !model.whoop5Detected else { return }
        let currentSource = model.ble.connectedPeripheralUUID
        if !model.live.connected || latest.armSourceID != currentSource {
            deliveryStatus = String(localized: "Saved · waiting for strap")
        } else if latest.strapReportedArmedAt != nil, latest.readbackStatus == .confirmed {
            deliveryStatus = String(localized: "Armed on strap")
        } else {
            switch latest.readbackStatus {
            case .noAlarm:
                deliveryStatus = String(localized: "Not armed · strap reports no alarm")
            case .mismatch:
                deliveryStatus = String(localized: "Not armed · strap time differs")
            case .unconfirmed:
                deliveryStatus = String(localized: "Alarm not confirmed")
            case .pending:
                deliveryStatus = model.whoop5Detected
                    ? String(localized: "Experimental arm sent · unconfirmed")
                    : String(localized: "Arming…")
            case .confirmed:
                deliveryStatus = String(localized: "Alarm not confirmed")
            case nil:
                break
            }
        }
    }

    private func updateDeliveryStatus(
        endpoint: Date,
        arm: BLEManager.AlarmCommandResult,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        refreshEvidence(for: endpoint)
        if evidence?.strapReportedArmedAt != nil, evidence?.readbackStatus == .confirmed { return }
        if let readback = evidence?.readbackStatus,
           readback == .noAlarm || readback == .mismatch || readback == .unconfirmed { return }
        switch arm {
        case .queuedForReconnect:
            deliveryStatus = String(localized: "Saved · waiting for strap")
        case .experimentalDisabled:
            deliveryStatus = String(localized: "Not armed · Experimental required")
        case .sentAwaitingReadback:
            deliveryStatus = model.whoop5Detected
                ? String(localized: "Experimental arm sent · unconfirmed")
                : String(localized: "Arming…")
        }
        if snapshot.mode(for: endpoint) == .exactTime,
           model.whoop5Detected,
           !PuffinExperiment.isEnabled {
            deliveryStatus = String(localized: "Not armed · Experimental required")
        }
    }

    private func persistEndpointEvidence(
        endpoint: Date,
        mode: SmartAlarmEvaluator.Mode,
        arm: BLEManager.AlarmCommandResult
    ) {
        SmartAlarmEvidenceStore.refreshCorrelation()
        if model.whoop5Detected, let previous = SmartAlarmEvidenceStore.latest,
           previous.windowEndpoint == endpoint,
           previous.actuation == .sentToConnectedStrap {
            return
        }
        let actuation: SmartAlarmEvidence.Actuation
        switch arm {
        case .sentAwaitingReadback: actuation = .endpointArmed
        case .queuedForReconnect: actuation = .queuedForReconnect
        case .experimentalDisabled: actuation = .experimentalDisabled
        }
        SmartAlarmEvidenceStore.save(.init(
            mode: mode,
            trigger: .configured,
            decision: .wait,
            reason: "latestEndpointFailSafe",
            evaluatedAt: Date(),
            inputObservedAt: nil,
            sleepSource: nil,
            sleepModelVersion: nil,
            forecastSource: nil,
            forecastModelVersion: nil,
            requestedWakeAt: endpoint,
            windowEndpoint: endpoint,
            strapReportedArmedAt: nil,
            observedStrapWakeAt: nil,
            actuation: actuation,
            evaluatorModelVersion: SmartAlarmEvaluator.modelVersion
        ))
    }

    private func persistUnavailableEvidence(
        mode: SmartAlarmEvaluator.Mode,
        trigger: SmartAlarmEvaluator.Trigger,
        endpoint: Date,
        reason: String,
        evaluatedAt: Date
    ) {
        SmartAlarmEvidenceStore.save(.init(
            mode: mode,
            trigger: trigger,
            decision: .unavailable,
            reason: reason,
            evaluatedAt: evaluatedAt,
            inputObservedAt: nil,
            sleepSource: nil,
            sleepModelVersion: nil,
            forecastSource: nil,
            forecastModelVersion: nil,
            requestedWakeAt: endpoint,
            windowEndpoint: endpoint,
            strapReportedArmedAt: nil,
            observedStrapWakeAt: nil,
            actuation: .notRequested,
            evaluatorModelVersion: SmartAlarmEvaluator.modelVersion
        ))
    }

    private func startDailyRearmLoop() {
        dailyTask?.cancel()
        dailyTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let now = Date()
                guard let next = SmartAlarmSchedule.nextDailyRearm(
                    after: now,
                    calendar: .current
                ) else {
                    try? await Task.sleep(for: .seconds(3_600))
                    continue
                }
                let delay = max(1, next.timeIntervalSince(now))
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.reconcileImmediately(trigger: .foreground)
            }
        }
    }
}

@MainActor
enum SmartAlarmRuntimeBackgroundScheduler {
    static let bgTaskIdentifier = "com.noopapp.noop.smartalarm"
    static let requestKey = "smartAlarm.runtime.backgroundRequest"
    private static let configurationKey = "smartAlarm.runtime.configuration"

    static func schedule(
        windowStart: Date,
        endpoint: Date,
        snapshot: SmartAlarmRuntimeSnapshot,
        configurationID: UUID
    ) {
        let payload = SmartAlarmBackgroundRequest(
            configurationID: configurationID,
            endpoint: endpoint,
            snapshot: snapshot
        )
        guard persistRequest(payload) else {
            cancel()
            return
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: bgTaskIdentifier)
        request.earliestBeginDate = windowStart
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            clearRequest(ifMatching: payload)
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        UserDefaults.standard.removeObject(forKey: requestKey)
    }

    static func configurationID(
        for snapshot: SmartAlarmRuntimeSnapshot,
        defaults: UserDefaults = .standard
    ) -> UUID {
        if let data = defaults.data(forKey: configurationKey),
           let persisted = try? JSONDecoder().decode(SmartAlarmPersistedConfiguration.self, from: data),
           persisted.snapshot == snapshot {
            return persisted.id
        }
        let id = UUID()
        persistConfiguration(id: id, snapshot: snapshot, defaults: defaults)
        return id
    }

    static func persistConfiguration(
        id: UUID,
        snapshot: SmartAlarmRuntimeSnapshot,
        defaults: UserDefaults = .standard
    ) {
        let persisted = SmartAlarmPersistedConfiguration(id: id, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: configurationKey)
    }

    @discardableResult
    static func persistRequest(
        _ request: SmartAlarmBackgroundRequest,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let encoded = try? JSONEncoder().encode(request) else { return false }
        defaults.set(encoded, forKey: requestKey)
        guard defaults.synchronize(), defaults.data(forKey: requestKey) == encoded else {
            defaults.removeObject(forKey: requestKey)
            return false
        }
        return true
    }

    static func loadRequest(defaults: UserDefaults = .standard) -> SmartAlarmBackgroundRequest? {
        guard let data = defaults.data(forKey: requestKey) else { return nil }
        return try? JSONDecoder().decode(SmartAlarmBackgroundRequest.self, from: data)
    }

    static func clearRequest(
        ifMatching request: SmartAlarmBackgroundRequest?,
        defaults: UserDefaults = .standard
    ) {
        guard let request else { return }
        guard loadRequest(defaults: defaults) == request else { return }
        defaults.removeObject(forKey: requestKey)
    }
}
#endif
