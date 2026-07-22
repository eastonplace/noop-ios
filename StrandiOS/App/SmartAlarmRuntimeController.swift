#if os(iOS)
import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications
import StrandAnalytics
import WhoopStore

/// Adaptive wake mode ownership is deliberately separate from `BehaviorStore.smartAlarmMode`.
/// `AppModel` still contains older exact-endpoint hooks, so its legacy field is pinned to `.exactTime`
/// while this store preserves the user's actual adaptive mode.
@MainActor
final class SmartAlarmAdaptiveModeStore: ObservableObject {
    private static let modeKey = "smartAlarm.runtime.adaptiveMode"
    private static let migratedKey = "smartAlarm.runtime.adaptiveModeMigrated"

    private weak var legacy: BehaviorStore?

    @Published var mode: SmartAlarmEvaluator.Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            pinLegacyEndpointOnly()
        }
    }

    init(legacy: BehaviorStore, defaults: UserDefaults = .standard) {
        self.legacy = legacy
        let migrated = defaults.bool(forKey: Self.migratedKey)
        let stored = defaults.string(forKey: Self.modeKey).flatMap(SmartAlarmEvaluator.Mode.init(rawValue:))
        let resolved = migrated ? (stored ?? .exactTime) : legacy.smartAlarmMode
        mode = resolved
        defaults.set(resolved.rawValue, forKey: Self.modeKey)
        defaults.set(true, forKey: Self.migratedKey)
        pinLegacyEndpointOnly()
    }

    func pinLegacyEndpointOnly() {
        guard let legacy, legacy.smartAlarmMode != .exactTime else { return }
        legacy.smartAlarmMode = .exactTime
    }
}

struct SmartAlarmRuntimeSnapshot: Equatable, Sendable {
    let enabled: Bool
    let mode: SmartAlarmEvaluator.Mode
    let minutes: Int
    let weekdays: [Int]

    init(enabled: Bool, mode: SmartAlarmEvaluator.Mode, minutes: Int, weekdays: Set<Int>) {
        self.enabled = enabled
        self.mode = mode
        self.minutes = ((minutes % 1_440) + 1_440) % 1_440
        self.weekdays = weekdays.filter { (1...7).contains($0) }.sorted()
    }

    var weekdaySet: Set<Int> { Set(weekdays) }
}

/// Persisted payload for iOS's payload-less BGTask request. Without this, a late BG execution recomputed
/// "next alarm" from its actual run time and could evaluate the following recurrence instead of the endpoint
/// whose wake window scheduled the task.
struct SmartAlarmBackgroundRequest: Codable, Equatable, Sendable {
    let endpoint: Date
    let enabled: Bool
    let modeRawValue: String
    let minutes: Int
    let weekdays: [Int]

    init(endpoint: Date, snapshot: SmartAlarmRuntimeSnapshot) {
        self.endpoint = endpoint
        enabled = snapshot.enabled
        modeRawValue = snapshot.mode.rawValue
        minutes = snapshot.minutes
        weekdays = snapshot.weekdays
    }

    var snapshot: SmartAlarmRuntimeSnapshot? {
        guard let mode = SmartAlarmEvaluator.Mode(rawValue: modeRawValue) else { return nil }
        return SmartAlarmRuntimeSnapshot(
            enabled: enabled,
            mode: mode,
            minutes: minutes,
            weekdays: Set(weekdays)
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

@MainActor
final class SmartAlarmRuntimeController: ObservableObject {
    static let backupBaseIdentifier = "smart-alarm-wake-backup"
    static var backupIdentifiers: [String] {
        [backupBaseIdentifier] + (1...7).map { "\(backupBaseIdentifier)-d\($0)" }
    }

    @Published private(set) var deliveryStatus = String(localized: "Off")
    @Published private(set) var backupStatus = String(localized: "Off")
    @Published private(set) var evidence: SmartAlarmEvidence?

    let modeStore: SmartAlarmAdaptiveModeStore

    private let model: AppModel
    private let behavior: BehaviorStore
    private var started = false
    private var observedSnapshot: SmartAlarmRuntimeSnapshot?
    private var generation = SmartAlarmRuntimeGeneration()
    private var cancellables = Set<AnyCancellable>()

    private var debounceTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var backupStatusTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var evidenceTask: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?

    init(model: AppModel, modeStore: SmartAlarmAdaptiveModeStore) {
        self.model = model
        behavior = model.behavior
        self.modeStore = modeStore
    }

    deinit {
        debounceTask?.cancel()
        notificationTask?.cancel()
        backupStatusTask?.cancel()
        evaluationTask?.cancel()
        evidenceTask?.cancel()
        dailyTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        modeStore.pinLegacyEndpointOnly()
        SmartAlarmRuntimeBackgroundScheduler.install(self)

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

        model.live.$connectSettled
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reconcileImmediately(trigger: .bluetoothReconnect)
                }
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
              requestedSnapshot == currentSnapshot,
              requestedSnapshot.enabled,
              requestedSnapshot.mode != .exactTime
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
            after: request.endpoint,
            snapshot: requestedSnapshot
        )
        return succeeded
    }

    private var currentSnapshot: SmartAlarmRuntimeSnapshot {
        SmartAlarmRuntimeSnapshot(
            enabled: behavior.smartAlarmEnabled,
            mode: modeStore.mode,
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays
        )
    }

    private func configurationMayHaveChanged() {
        modeStore.pinLegacyEndpointOnly()
        let snapshot = currentSnapshot
        guard snapshot != observedSnapshot else { return }
        observedSnapshot = snapshot
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
        debounceTask = nil
        notificationTask = nil
        backupStatusTask = nil
        evaluationTask = nil
        evidenceTask = nil
    }

    private func applyDisabled(snapshot: SmartAlarmRuntimeSnapshot, token: UInt64) {
        guard generation.accepts(token, request: snapshot, current: currentSnapshot) else { return }
        model.ble.disableStrapAlarm()
        removeBackupNotifications()
        SmartAlarmRuntimeBackgroundScheduler.cancel()
        deliveryStatus = String(localized: "Off")
        backupStatus = String(localized: "Off")
        evidence = nil

        notificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.currentSnapshot.enabled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
            else { return }
            self.removeBackupNotifications()
        }
    }

    private func apply(
        snapshot: SmartAlarmRuntimeSnapshot,
        token: UInt64,
        trigger: SmartAlarmEvaluator.Trigger
    ) {
        guard generation.accepts(token, request: snapshot, current: currentSnapshot),
              let endpoint = SmartAlarmSchedule.nextDate(
                minutes: snapshot.minutes,
                weekdays: snapshot.weekdaySet,
                after: Date(),
                calendar: .current
              )
        else {
            model.ble.disableStrapAlarm()
            removeBackupNotifications()
            SmartAlarmRuntimeBackgroundScheduler.cancel()
            deliveryStatus = String(localized: "Not armed · no enabled day")
            backupStatus = String(localized: "Not scheduled")
            return
        }

        let arm = model.ble.armStrapAlarm(at: endpoint)
        persistEndpointEvidence(endpoint: endpoint, mode: snapshot.mode, arm: arm)
        updateDeliveryStatus(endpoint: endpoint, arm: arm, snapshot: snapshot)
        scheduleBackupNotifications(snapshot: snapshot, token: token)
        scheduleEvidenceRefresh(snapshot: snapshot, endpoint: endpoint, token: token)

        if snapshot.mode == .exactTime {
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
            snapshot: snapshot
        )
    }

    private func scheduleFollowingBackgroundRequest(
        after endpoint: Date,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        guard generation.accepts(generation.value, request: snapshot, current: currentSnapshot),
              let next = SmartAlarmSchedule.nextDate(
                minutes: snapshot.minutes,
                weekdays: snapshot.weekdaySet,
                after: endpoint.addingTimeInterval(1),
                calendar: .current
              )
        else {
            SmartAlarmRuntimeBackgroundScheduler.cancel()
            return
        }
        scheduleBackgroundRequest(endpoint: next, snapshot: snapshot)
    }

    private func currentEndpoint(now: Date = Date()) -> Date? {
        let snapshot = currentSnapshot
        guard snapshot.enabled else { return nil }
        return SmartAlarmSchedule.nextDate(
            minutes: snapshot.minutes,
            weekdays: snapshot.weekdaySet,
            after: now,
            calendar: .current
        )
    }

    private func evaluateIfInsideWindow(trigger: SmartAlarmEvaluator.Trigger) {
        let snapshot = currentSnapshot
        guard snapshot.enabled, snapshot.mode != .exactTime,
              let endpoint = currentEndpoint() else { return }
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
            persistUnavailableEvidence(mode: snapshot.mode, trigger: trigger, endpoint: endpoint,
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

        let computation = await Task.detached(priority: .utility) {
            let bundle = try? await store.analysisDayBundle(
                deviceId: deviceID, from: from, to: to, limit: 200_000
            )
            let sessions = bundle.map {
                SleepStager.detectSleep(
                    hr: $0.hr, rr: $0.rr, resp: $0.resp, gravity: $0.gravity,
                    tzOffsetSeconds: timeZoneOffset
                )
            } ?? []
            let bankedMinutes = sessions.max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
                .map { session in
                    session.stages
                        .filter { $0.stage != "wake" }
                        .reduce(0.0) { $0 + Double(max(0, $1.end - $1.start)) } / 60.0
                }
            let observedEpoch = [bundle?.hr.last?.ts, bundle?.rr.last?.ts,
                                 bundle?.resp.last?.ts, bundle?.gravity.last?.ts]
                .compactMap { $0 }.max()
            let observedAt = observedEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
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
            let evaluation = SmartAlarmEvaluator.evaluate(.init(
                mode: snapshot.mode,
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
        }.value

        guard !Task.isCancelled,
              generation.accepts(token, request: snapshot, current: currentSnapshot)
        else { return false }

        var actuation: SmartAlarmEvidence.Actuation = .notRequested
        var requestedWake = endpoint
        if computation.evaluation.decision == .wakeNow {
            SmartAlarmEvidenceStore.refreshCorrelation()
            let previous = SmartAlarmEvidenceStore.latest
            if previous?.windowEndpoint == endpoint,
               previous?.actuation == .sentToConnectedStrap {
                actuation = .sentToConnectedStrap
                requestedWake = previous?.requestedWakeAt ?? endpoint
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

        SmartAlarmEvidenceStore.save(.init(
            mode: snapshot.mode,
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
        ))
        refreshEvidence(for: endpoint)
        model.live.append(
            log: "Smart alarm: mode=\(snapshot.mode.rawValue) decision=\(computation.evaluation.decision.rawValue) reason=\(computation.evaluation.reason) actuation=\(actuation.rawValue)"
        )
        return true
    }

    private func scheduleBackupNotifications(snapshot: SmartAlarmRuntimeSnapshot, token: UInt64) {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)

            let settings = await center.notificationSettings()
            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  snapshot.enabled
            else {
                center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)
                return
            }

            var authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }

            guard authorized,
                  !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  snapshot.enabled
            else {
                center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)
                self.backupStatus = authorized
                    ? String(localized: "Not scheduled")
                    : String(localized: "Unavailable · permission denied")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Smart alarm")
            content.body = String(localized: "Backup wake: your smart alarm time is here.")
            content.sound = .default
            let hour = snapshot.minutes / 60
            let minute = snapshot.minutes % 60

            do {
                if snapshot.weekdays.isEmpty {
                    let trigger = UNCalendarNotificationTrigger(
                        dateMatching: DateComponents(hour: hour, minute: minute),
                        repeats: true
                    )
                    try await center.add(UNNotificationRequest(
                        identifier: Self.backupBaseIdentifier,
                        content: content,
                        trigger: trigger
                    ))
                } else {
                    for weekday in snapshot.weekdays {
                        guard !Task.isCancelled,
                              self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
                        else { throw CancellationError() }
                        var components = DateComponents()
                        components.weekday = weekday
                        components.hour = hour
                        components.minute = minute
                        let trigger = UNCalendarNotificationTrigger(
                            dateMatching: components,
                            repeats: true
                        )
                        try await center.add(UNNotificationRequest(
                            identifier: "\(Self.backupBaseIdentifier)-d\(weekday)",
                            content: content,
                            trigger: trigger
                        ))
                    }
                }
            } catch {
                center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)
                if self.generation.accepts(token, request: snapshot, current: self.currentSnapshot) {
                    self.backupStatus = String(localized: "Not scheduled")
                }
                return
            }

            guard !Task.isCancelled,
                  self.generation.accepts(token, request: snapshot, current: self.currentSnapshot),
                  snapshot.enabled
            else {
                center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)
                return
            }
            self.backupStatus = String(localized: "Scheduled")
        }
    }

    private func refreshBackupStatus() {
        backupStatusTask?.cancel()
        backupStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = self.currentSnapshot
            guard snapshot.enabled else {
                self.backupStatus = String(localized: "Off")
                return
            }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral
            else {
                self.backupStatus = String(localized: "Unavailable · permission denied")
                return
            }
            let pending = await center.pendingNotificationRequests()
            let scheduled = pending.contains { $0.identifier.hasPrefix(Self.backupBaseIdentifier) }
            self.backupStatus = scheduled
                ? String(localized: "Scheduled")
                : String(localized: "Not scheduled")
        }
    }

    private func removeBackupNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers)
    }

    private func scheduleEvidenceRefresh(
        snapshot: SmartAlarmRuntimeSnapshot,
        endpoint: Date,
        token: UInt64
    ) {
        evidenceTask?.cancel()
        evidenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [250, 750, 1_500, 3_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled,
                      self.generation.accepts(token, request: snapshot, current: self.currentSnapshot)
                else { return }
                self.refreshEvidence(for: endpoint)
                if self.evidence?.strapReportedArmedAt != nil { return }
            }
        }
    }

    private func refreshEvidence(for endpoint: Date?) {
        SmartAlarmEvidenceStore.refreshCorrelation()
        guard let endpoint,
              let latest = SmartAlarmEvidenceStore.latest,
              latest.windowEndpoint == endpoint,
              latest.mode == currentSnapshot.mode
        else {
            evidence = nil
            return
        }
        evidence = latest
        if latest.strapReportedArmedAt != nil {
            deliveryStatus = String(localized: "Armed on strap")
        }
    }

    private func updateDeliveryStatus(
        endpoint: Date,
        arm: BLEManager.AlarmCommandResult,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        refreshEvidence(for: endpoint)
        if evidence?.strapReportedArmedAt != nil { return }
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
        if snapshot.mode == .exactTime,
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
        if let previous = SmartAlarmEvidenceStore.latest,
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
    private static let requestKey = "smartAlarm.runtime.backgroundRequest"
    private static weak var runtime: SmartAlarmRuntimeController?
    private static var registered = false

    static func install(_ runtime: SmartAlarmRuntimeController) {
        self.runtime = runtime
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let operation = Task { @MainActor in
                let request = Self.loadRequest()
                guard let runtime = Self.runtime, !Task.isCancelled else {
                    refreshTask.setTaskCompleted(success: false)
                    return
                }
                let succeeded = await runtime.handleBackgroundRefresh(request)
                guard !Task.isCancelled else { return }
                Self.clearRequest(ifMatching: request)
                refreshTask.setTaskCompleted(success: succeeded)
            }
            refreshTask.expirationHandler = { operation.cancel() }
        }
    }

    static func schedule(
        windowStart: Date,
        endpoint: Date,
        snapshot: SmartAlarmRuntimeSnapshot
    ) {
        let payload = SmartAlarmBackgroundRequest(endpoint: endpoint, snapshot: snapshot)
        if let encoded = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(encoded, forKey: requestKey)
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
