import Foundation
import Combine
import UserNotifications
import StrandAnalytics
import WhoopStore
#if os(iOS)
import UIKit
#endif

struct NotificationDeliveryRequest: Sendable {
    let identifier: String
    let title: String
    let body: String
    let candidate: NotificationCandidate
    var repeatingComponents: DateComponents? = nil
}

enum NotificationSubmissionError: Error, Equatable { case knownFailure, uncertain }

@MainActor
protocol NotificationCenterClient: AnyObject {
    func isAuthorized() async -> Bool
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> Set<String>
    func add(_ request: NotificationDeliveryRequest) async throws
    func remove(_ identifiers: [String], delivered: Bool)
    func removeDelivered(_ identifiers: [String])
    func identifiersContainingDetails() async -> Set<String>
}
extension NotificationCenterClient {
    func removeDelivered(_ identifiers: [String]) {}
    func identifiersContainingDetails() async -> Set<String> { [] }
}

@MainActor
final class SystemNotificationCenterClient: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }
    func pendingIdentifiers() async -> Set<String> { Set(await center.pendingNotificationRequests().map(\.identifier)) }
    func deliveredIdentifiers() async -> Set<String> { Set(await center.deliveredNotifications().map { $0.request.identifier }) }
    func add(_ request: NotificationDeliveryRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.interruptionLevel = .active
        // New advice uses normal interruption priority, never sound/time-sensitive/critical privileges.
        content.categoryIdentifier = NotificationCoordinator.supportsSnooze(request.candidate)
            ? "noop.notification.charge" : "noop.notification.open"
        content.userInfo = NotificationCoordinator.userInfo(for: request.candidate)
        content.userInfo["noopNotificationContainsDetails"] = request.body != request.candidate.genericBody
        content.userInfo["noopNotificationRepeating"] = request.repeatingComponents != nil
        let trigger: UNNotificationTrigger?
        if let components = request.repeatingComponents {
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        } else if let scheduled = request.candidate.scheduledAt {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: scheduled)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else { trigger = nil }
        do { try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)) }
        catch is CancellationError { throw NotificationSubmissionError.uncertain }
        catch { throw NotificationSubmissionError.knownFailure }
    }
    func identifiersContainingDetails() async -> Set<String> {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications().map(\.request)
        return Set((pending + delivered).filter { ($0.content.userInfo["noopNotificationContainsDetails"] as? Bool) == true }.map(\.identifier))
    }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    func remove(_ identifiers: [String], delivered: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        if delivered { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
    }
}

/// Sole owner of routine local requests. SQLite owns event/attention claims across processes;
/// this actor coordinates OS awaits and revalidates mutable choices after every boundary.
@MainActor
final class NotificationCoordinator: ObservableObject {
    static let shared = NotificationCoordinator(
        center: SystemNotificationCenterClient(), clock: Date.init,
        preferences: { NotificationPreferences.shared.snapshot },
        context: {
            productionContext(sourceContext: AppModel.shared?.repo.notificationSourceContext ?? "unavailable",
                  logicalDay: NotificationFactBuilder.dayKey(Date()),
                  activeWorkout: AppModel.shared?.activeWorkout != nil || AppModel.shared?.hasActiveReceiptLift?() == true || AppModel.shared?.notificationSessionsReady == false,
                  visibleDestinations: NavRouter.currentVisibleNotificationDestinations)
        },
        store: { await AppModel.shared?.repo.notificationDecisionStore() },
        dryRun: { NotificationPreferences.shared.dryRunEnabled },
        initialAuthorization: UserDefaults.standard.object(forKey: "notifications.lastAuthorization") as? Bool,
        authorizationChange: { previous, current in
            UserDefaults.standard.set(current, forKey: "notifications.lastAuthorization")
            if previous == false && current { NotificationPreferences.shared.bumpScheduleRevision() }
        })

    /// The current sources expose completed windows and unpaired marks, not a
    /// qualified live asleep/awake observation. Keep that uncertainty explicit.
    static func productionContext(sourceContext: String, logicalDay: String, activeWorkout: Bool,
                                  visibleDestinations: Set<NotificationDestination> = []) -> NotificationContext {
        .init(sourceContext: sourceContext, logicalDay: logicalDay, activeWorkout: activeWorkout,
              sleeping: nil, visibleDestinations: visibleDestinations)
    }

    @Published private(set) var setupStatus: String?
    @Published private(set) var lastEvaluation: NotificationEvaluation?
    @Published private(set) var inAppCandidates: [NotificationCandidate] = []
    private var dismissedInApp: Set<String> = []
    private struct LiveCompletion { let startTs: Int; let sport: String; let endedAt: Date; let source: String }
    private var liveCompletions: [String: LiveCompletion] = [:]
    private let center: NotificationCenterClient
    private let clock: () -> Date
    private let preferences: () -> NotificationPreferencesSnapshot
    private let context: () -> NotificationContext
    private let storeProvider: () async -> WhoopStore?
    private let dryRun: () -> Bool
    private var lastAuthorization: Bool?
    private let authorizationChange: (Bool?, Bool) -> Void
    private var revisions: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var scheduleGeneration = 0
    private var setupFailures: [String: String] = [:]
    private var explicitDates: [Date] = []
    private var repeatingComponents: [String: DateComponents] = [:]
    var workoutPlans: () -> [NotificationWorkoutPlan] = { [] }
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenterClient, clock: @escaping () -> Date,
         preferences: @escaping () -> NotificationPreferencesSnapshot,
         context: @escaping () -> NotificationContext,
         store: @escaping () async -> WhoopStore?, dryRun: @escaping () -> Bool,
         initialAuthorization: Bool? = nil, authorizationChange: @escaping (Bool?, Bool) -> Void = { _, _ in }) {
        self.center = center; self.clock = clock; self.preferences = preferences
        self.context = context; self.storeProvider = store; self.dryRun = dryRun
        self.lastAuthorization = initialAuthorization; self.authorizationChange = authorizationChange
    }

    func start() async {
        if observers.isEmpty {
            let legacy = ["battery-low", "battery-runtime", "battery-full", "illness-watch", "wind-down-nudge"]
                + (1...7).map { "wind-down-nudge-wd\($0)" }
            center.remove(legacy, delivered: true)
            for name in [Notification.Name.notificationPreferencesDidChange,
                         NSNotification.Name.NSSystemTimeZoneDidChange,
                         NSNotification.Name.NSCalendarDayChanged,
                         Notification.Name("noop.notificationJournalDidChange"),
                         Notification.Name("noop.notificationPlansDidChange")] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in await Self.shared.reconcileSchedules() }
                })
            }
            #if os(iOS)
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in await Self.shared.reconcileSchedules() }
            })
            #endif
        }
        registerCategories()
        await reconcile()
        await reconcileSchedules()
    }

    func process(facts: [NotificationRuleFact]) async {
        await process(candidates: NotificationRules.candidates(facts: facts, now: clock()))
    }

    func process(candidates: [NotificationCandidate]) async {
        for candidate in candidates { revisions[candidate.occurrenceID] = candidate.evidenceRevision }
        guard let store = await storeProvider() else { setupStatus = "Notification history is unavailable. Open the app after storage becomes available."; return }
        guard !context().sourceContext.hasPrefix("unavailable:") else {
            setupStatus = "Notifications will be checked when your current data source finishes loading."
            return
        }
        let authorized = await authorization()
        if !authorized { setupStatus = "Notifications are not allowed. Enable them in system Settings." }
        do {
            let rows = try await store.notificationRecords()
            // Reserved means add was never invoked; its own claim must not suppress a safe resume.
            let resuming = Set(rows.filter { $0.state == .reserved }.map(\.occurrenceID))
            let evaluationHistory = history(rows).filter { entry in
                !(resuming.contains(entry.occurrenceID) && candidates.contains { $0.occurrenceID == entry.occurrenceID })
            }
            for candidate in candidates {
                if let old = rows.first(where: { $0.occurrenceID == candidate.occurrenceID }),
                   old.evidenceRevision != candidate.evidenceRevision, old.state == .submitted {
                    center.remove([old.requestIdentifier], delivered: true)
                    try await store.withdrawNotification(occurrenceID: old.occurrenceID, now: clock())
                }
            }
            let evaluation = NotificationPolicy.evaluate(candidates: candidates, preferences: preferences(), context: currentContext(permissionGranted: authorized), history: evaluationHistory, now: clock())
            lastEvaluation = evaluation
            inAppCandidates.removeAll { $0.expiresAt <= clock() || $0.sourceContext != context().sourceContext || preferences().mode(for: $0.group) == .off }
            for candidate in evaluation.inApp where !dismissedInApp.contains(candidate.occurrenceID) {
                inAppCandidates.removeAll { $0.occurrenceID == candidate.occurrenceID }
                inAppCandidates.append(candidate)
            }
            for decision in evaluation.decisions {
                let dry = dryRun() && decision.candidate.lane == .proactive
                    && decision.candidate.group != .chargeReminder && decision.candidate.group != .batteryFull
                try await store.recordNotificationEvaluation(occurrenceID: decision.candidate.occurrenceID,
                    ruleID: decision.candidate.ruleID, evidenceRevision: decision.candidate.evidenceRevision,
                    disposition: decision.disposition.rawValue, reason: decision.reason.rawValue,
                    dryRun: dry, now: clock())
            }
            for candidate in evaluation.selected {
                if dryRun() && candidate.lane == .proactive && candidate.group != .chargeReminder && candidate.group != .batteryFull { continue }
                await submit(candidate, store: store)
            }
        } catch { setupStatus = "Notification history could not be read. Try again after reopening the app." }
    }

    private func authorization() async -> Bool {
        let allowed = await center.isAuthorized()
        let previous = lastAuthorization
        lastAuthorization = allowed
        if previous != allowed { authorizationChange(previous, allowed) }
        return allowed
    }

    private func currentContext(permissionGranted: Bool? = nil) -> NotificationContext {
        let current = context()
        let now = clock()
        var currentReminderDates = explicitDates
        for components in repeatingComponents.values {
            if let next = Calendar.current.nextDate(after: now, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) { currentReminderDates.append(next) }
            if let previous = Calendar.current.nextDate(after: now, matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .backward) { currentReminderDates.append(previous) }
        }
        return .init(sourceContext: current.sourceContext, logicalDay: current.logicalDay,
                     timeZoneIdentifier: current.timeZoneIdentifier, permissionGranted: permissionGranted ?? current.permissionGranted,
                     activeWorkout: current.activeWorkout, sleeping: current.sleeping,
                     visibleDestinations: current.visibleDestinations, explicitReminderDates: current.explicitReminderDates + currentReminderDates)
    }

    private func history(_ rows: [NotificationLedgerRecord], excluding: String? = nil) -> [NotificationHistoryEntry] {
        rows.compactMap { row in
            guard row.occurrenceID != excluding, let chargedAt = row.chargedAt else { return nil }
            return .init(occurrenceID: row.occurrenceID, attentionKey: row.attentionKey, logicalDay: row.logicalDay, chargedAt: chargedAt, isProactive: row.isProactive)
        }
    }

    private func remainsValid(_ candidate: NotificationCandidate, rows: [NotificationLedgerRecord], store: WhoopStore) async -> Bool {
        let family: String?
        switch candidate.ruleID {
        case "chargeReminder.battery", "chargeReminder.snoozed": family = "charge"
        case "batteryFull.battery": family = "full"
        default: family = nil
        }
        if let family {
            guard let episode = try? await store.notificationEpisode(deviceID: candidate.subjectID,
                family: family, observationIsActive: nil, now: clock()), episode == candidate.evidenceRevision else { return false }
            guard BatteryNotifier.permits(candidate) else { return false }
        }
        guard revisions[candidate.occurrenceID] == candidate.evidenceRevision else { return false }
        return !NotificationPolicy.evaluate(candidates: [candidate], preferences: preferences(), context: currentContext(), history: history(rows, excluding: candidate.occurrenceID), now: clock()).selected.isEmpty
    }

    private func submit(_ candidate: NotificationCandidate, store: WhoopStore) async {
        guard !inFlight.contains(candidate.occurrenceID) else { return }
        inFlight.insert(candidate.occurrenceID)
        defer { inFlight.remove(candidate.occurrenceID) }
        let identifier = Self.requestIdentifier(candidate.occurrenceID)
        do {
            // A known failure can reserve at most one retry. Never retry an unknown add outcome.
            for attempt in 0...1 {
                let rows = try await store.notificationRecords()
                guard await remainsValid(candidate, rows: rows, store: store), await authorization() else { return }
                guard await remainsValid(candidate, rows: rows, store: store) else { return }
                let claim = NotificationLedgerClaim(occurrenceID: candidate.occurrenceID, attentionKey: candidate.attentionKey,
                    ruleID: candidate.ruleID, sourceContext: candidate.sourceContext, evidenceRevision: candidate.evidenceRevision,
                    logicalDay: candidate.logicalDay, requestIdentifier: identifier, isProactive: candidate.lane == .proactive,
                    expiresAt: candidate.expiresAt, timeZoneIdentifier: currentContext().timeZoneIdentifier)
                guard case .claimed = try await store.claimNotification(claim, now: clock()) else { return }
                guard await remainsValid(candidate, rows: rows, store: store) else {
                    try await store.withdrawNotificationBeforeInvocation(occurrenceID: candidate.occurrenceID, now: clock()); return
                }
                guard try await store.markNotificationSubmitting(occurrenceID: candidate.occurrenceID, now: clock()) else { return }
                guard await remainsValid(candidate, rows: rows, store: store) else {
                    try await store.withdrawNotificationBeforeInvocation(occurrenceID: candidate.occurrenceID, now: clock(), acquiredSubmitGate: true); return
                }
                let permissionBeforeAdd = await authorization()
                guard permissionBeforeAdd, await remainsValid(candidate, rows: rows, store: store) else {
                    try await store.withdrawNotificationBeforeInvocation(occurrenceID: candidate.occurrenceID, now: clock(), acquiredSubmitGate: true); return
                }
                let detailed = preferences().showHealthDetails
                let request = NotificationDeliveryRequest(identifier: identifier, title: candidate.genericTitle,
                    body: detailed ? (candidate.detailBody ?? candidate.genericBody) : candidate.genericBody, candidate: candidate, repeatingComponents: repeatingComponents[candidate.occurrenceID])
                do {
                    try await center.add(request)
                } catch {
                    if let failure = error as? NotificationSubmissionError, failure == .knownFailure {
                        try await store.markNotificationFailed(occurrenceID: candidate.occurrenceID, now: clock(), reason: "platform_add_failed")
                        setupFailures[identifier] = "A reminder could not be scheduled. Check notification permissions and change its schedule to retry."
                        setupStatus = setupFailures.values.sorted().first
                        if attempt == 0 { continue }
                    } else {
                        let pending = await center.pendingIdentifiers()
                        let delivered = await center.deliveredIdentifiers()
                        try await store.reconcileNotifications(pending: pending, delivered: delivered, now: clock())
                        _ = try await retainSubmittedRequestIfValid(candidate, identifier: identifier,
                            detailed: detailed, store: store)
                    }
                    return
                }
                try await store.markNotificationSubmitted(occurrenceID: candidate.occurrenceID, now: clock())
                guard try await retainSubmittedRequestIfValid(candidate, identifier: identifier,
                    detailed: detailed, store: store) else { return }
                setupFailures[identifier] = nil
                setupStatus = setupFailures.values.sorted().first
                return
            }
        } catch {
            // Ledger failure after add is uncertain. Keep the durable submitting marker for restart reconciliation.
            setupStatus = "Notification status could not be saved. It will be checked when the app next opens."
        }
    }

    /// add can accept a request before reporting an uncertain result. Both outcomes
    /// must clean up a request that became obsolete across the platform await.
    private func retainSubmittedRequestIfValid(_ candidate: NotificationCandidate, identifier: String,
                                              detailed: Bool, store: WhoopStore) async throws -> Bool {
        let permission = await authorization()
        let currentRows = try await store.notificationRecords()
        guard permission, await remainsValid(candidate, rows: currentRows, store: store),
              detailed == preferences().showHealthDetails else {
            center.remove([identifier], delivered: true)
            // Withdrawal retains identity and any consumed attention. It does not
            // turn an uncertain add into a known failure or grant another retry.
            try await store.withdrawNotification(occurrenceID: candidate.occurrenceID, now: clock())
            return false
        }
        return true
    }

    func reconcile() async {
        // A store belongs to the source selected before it was opened. A replacement
        // during any await must not let that store remove the new source's requests.
        let source = context().sourceContext
        guard inFlight.isEmpty, !source.hasPrefix("unavailable:"),
              let store = await storeProvider(), context().sourceContext == source else { return }
        let pending = await center.pendingIdentifiers()
        guard context().sourceContext == source else { return }
        let delivered = await center.deliveredIdentifiers()
        guard context().sourceContext == source else { return }
        let details = await center.identifiersContainingDetails()
        guard context().sourceContext == source else { return }
        do {
            try await store.reconcileNotifications(pending: pending, delivered: delivered, now: clock())
            guard context().sourceContext == source else { return }
            let rows = try await store.notificationRecords()
            guard context().sourceContext == source else { return }
            let known = Set(rows.map(\.requestIdentifier))
            let orphans = (pending.union(delivered)).filter { $0.hasPrefix(Self.namespace) && !known.contains($0) }
            center.remove(Array(orphans), delivered: true)
            for row in rows where row.requestIdentifier.hasPrefix(Self.namespace) {
                guard context().sourceContext == source else { return }
                let obsolete = row.sourceContext != source || row.expiresAt <= clock()
                let group = NotificationGroup.allCases.first { row.ruleID.hasPrefix($0.rawValue) || row.ruleID == "noop." + $0.rawValue }
                let disabled = group.map { preferences().mode(for: $0) != .notify } ?? false
                if obsolete || disabled || (!preferences().showHealthDetails && details.contains(row.requestIdentifier)) {
                    center.remove([row.requestIdentifier], delivered: true)
                    try await store.withdrawNotification(occurrenceID: row.occurrenceID, now: clock())
                    guard context().sourceContext == source else { return }
                }
            }
            try await store.pruneNotificationDecisions(now: clock(), retentionDays: 30)
            guard context().sourceContext == source else { return }
        } catch {
            guard context().sourceContext == source else { return }
            setupStatus = "Notification status could not be checked. Open the app again to retry."
        }
    }

    func dismissInApp(occurrenceID: String) {
        dismissedInApp.insert(occurrenceID)
        inAppCandidates.removeAll { $0.occurrenceID == occurrenceID }
    }

    func registerLiveWorkout(startTs: Int, sport: String, endedAt: Date, sourceContext: String) {
        liveCompletions["\(startTs):\(sport)"] = .init(startTs: startTs, sport: sport, endedAt: endedAt, source: sourceContext)
    }
    func processPendingLiveWorkouts(repository: Repository) async {
        let source = repository.notificationSourceContext
        let now = clock()
        liveCompletions = liveCompletions.filter { $0.value.source == source && now.timeIntervalSince($0.value.endedAt) <= 3600 }
        let pending = Array(liveCompletions)
        for (id, event) in pending {
            let rows = await repository.workoutRows(from: event.startTs, to: event.startTs + 1, reconcileHR: false)
            guard source == repository.notificationSourceContext else { return }
            guard let row = rows.first(where: { $0.startTs == event.startTs && $0.sport == event.sport }),
                  let fact = NotificationFactBuilder.workout(row, source: source,
                    revision: "v2:\(repository.canonicalHealth.sourceGeneration)", now: clock(), isLiveCompletion: true) else { continue }
            await process(facts: [fact])
            liveCompletions[id] = nil
        }
    }

    func withdraw(occurrenceID: String) async {
        revisions[occurrenceID] = nil
        let identifier = Self.requestIdentifier(occurrenceID)
        center.remove([identifier], delivered: true)
        setupFailures[identifier] = nil
        setupStatus = setupFailures.values.sorted().first
        if let store = await storeProvider() { try? await store.withdrawNotification(occurrenceID: occurrenceID, now: clock()) }
    }

    static func supportsSnooze(_ candidate: NotificationCandidate) -> Bool {
        candidate.group == .chargeReminder && candidate.lane == .proactive
            && candidate.ruleID == "chargeReminder.battery"
    }

    /// A single requested charge reminder. The action cannot extend the original
    /// observation's usefulness or create a chain of repeated coaching notices.
    static func snoozeCandidate(_ original: NotificationCandidate, now: Date) -> NotificationCandidate? {
        let scheduled = now.addingTimeInterval(15 * 60)
        guard supportsSnooze(original), scheduled < original.expiresAt,
              now >= original.generatedAt else { return nil }
        return .init(ruleID: original.group.rawValue + ".snoozed", group: original.group,
            subjectID: original.subjectID, occurrenceID: original.occurrenceID + ":snooze",
            attentionKey: original.attentionKey + ":snooze", evidenceRevision: original.evidenceRevision,
            sourceContext: original.sourceContext, logicalDay: original.logicalDay,
            observedAt: original.observedAt, generatedAt: original.generatedAt, expiresAt: original.expiresAt,
            quality: original.quality, lane: .explicitReminder, destination: original.destination,
            genericTitle: original.genericTitle, genericBody: original.genericBody,
            scheduledAt: scheduled, freshnessLimit: original.freshnessLimit)
    }

    func snooze(_ original: NotificationCandidate) async {
        guard let reminder = Self.snoozeCandidate(original, now: clock()) else {
            if Self.supportsSnooze(original) {
                setupStatus = "This charge reminder can no longer be delayed. Open your device to check its current status."
            }
            return
        }
        guard let store = await storeProvider(),
              let rows = try? await store.notificationRecords(),
              let activeEpisode = try? await store.notificationEpisode(deviceID: original.subjectID,
                  family: "charge", observationIsActive: nil, now: clock()),
              activeEpisode == original.evidenceRevision,
              rows.contains(where: { $0.occurrenceID == original.occurrenceID
                  && $0.sourceContext == original.sourceContext && $0.evidenceRevision == original.evidenceRevision
                  && $0.state == .submitted }) else { return }
        await process(candidates: [reminder])
    }

    func journalReminderIfNeeded(_ candidate: NotificationCandidate, day: String,
                                 catalog: JournalCatalogStore, importedQuestions: [String],
                                 store: WhoopStore) async throws -> NotificationCandidate? {
        guard candidate.group == .journalCheckIn, candidate.sourceContext == context().sourceContext else { return nil }
        let incomplete = try await NotificationJournalEligibility.isIncomplete(day: day,
            catalog: catalog, importedQuestions: importedQuestions, store: store)
        guard candidate.sourceContext == context().sourceContext else { return nil }
        if incomplete { return candidate }
        await withdraw(occurrenceID: candidate.occurrenceID)
        return nil
    }

    nonisolated static let namespace = "noop.notifications."
    static func requestIdentifier(_ occurrenceID: String) -> String {
        namespace + Data(occurrenceID.utf8).base64EncodedString()
    }
    static func userInfo(for candidate: NotificationCandidate) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = ["noopNotificationVersion": 1,
            "noopNotificationOccurrence": candidate.occurrenceID,
            "noopNotificationGroup": candidate.group.rawValue,
            "noopNotificationSourceContext": candidate.sourceContext,
            "noopNotificationExpiresAt": candidate.expiresAt.timeIntervalSince1970]
        if let data = try? JSONEncoder().encode(candidate.destination), let text = String(data: data, encoding: .utf8) {
            payload["noopNotificationDestination"] = text
        }
        if supportsSnooze(candidate), let data = try? JSONEncoder().encode(candidate) {
            payload["noopNotificationSnoozeCandidate"] = String(decoding: data, as: UTF8.self)
        }
        return payload
    }
    private func registerCategories() {
        // Build inside the platform callback to avoid transferring UI objects across actors.
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let turnOff = UNNotificationAction(identifier: "noop.notification.turnOff", title: "Turn off this type", options: [])
            let category = UNNotificationCategory(identifier: "noop.notification.open", actions: [turnOff], intentIdentifiers: [], options: [])
            let snooze = UNNotificationAction(identifier: "noop.notification.snooze", title: "Remind me in 15 minutes", options: [])
            let charge = UNNotificationCategory(identifier: "noop.notification.charge", actions: [snooze, turnOff], intentIdentifiers: [], options: [])
            UNUserNotificationCenter.current().setNotificationCategories(existing.union([category, charge]))
        }
    }
}
@MainActor
extension NotificationCoordinator {
    func reconcileSchedules() async {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        await reconcile()
        guard generation == scheduleGeneration, let model = AppModel.shared else { return }
        let source = model.repo.notificationSourceContext
        let prefs = NotificationPreferences.shared
        let revision = prefs.scheduleRevision
        let now = clock()
        let calendar = Calendar.current
        var candidates: [NotificationCandidate] = []
        var repeats: [String: DateComponents] = [:]
        func appendRecurring(group: NotificationGroup, weekday: Int?, minute: Int, destination: (Date) -> NotificationDestination) {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = minute / 60; components.minute = minute % 60
            guard let date = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime,
                                               repeatedTimePolicy: .first, direction: .forward) else { return }
            let id = "\(weekday ?? 0):\(minute):\(calendar.timeZone.identifier)"
            let candidate = NotificationSchedulePlanner.candidate(group: group, id: id,
                scheduledAt: date, source: source, destination: destination(date), now: now,
                revision: revision, recurring: true)
            candidates.append(candidate)
            repeats[candidate.occurrenceID] = components
        }
        if WindDownNudge.isEnabled {
            if WindDownNudge.hasPerDayOverrides {
                for wakeWeekday in 1...7 {
                    appendRecurring(group: .windDown, weekday: WindDownNudge.nudgeWeekday(forWeekday: wakeWeekday),
                        minute: WindDownNudge.nudgeMinuteOfDay(forWeekday: wakeWeekday)) {
                        .sleepPlan(logicalDay: NotificationFactBuilder.dayKey($0))
                    }
                }
            } else {
                appendRecurring(group: .windDown, weekday: nil, minute: WindDownNudge.nudgeMinuteOfDay()) {
                    .sleepPlan(logicalDay: NotificationFactBuilder.dayKey($0))
                }
            }
        }
        if prefs.mode(for: .weeklyReview) == .notify {
            appendRecurring(group: .weeklyReview, weekday: prefs.weeklyReviewWeekday, minute: prefs.weeklyReviewMinutes) {
                let start = NotificationSchedulePlanner.previousCompleteWeekStart(now: $0, calendar: calendar)
                return .weeklyReview(weekStart: NotificationFactBuilder.dayKey(start))
            }
        }
        // Journal completion is occurrence-specific: calendar repeats cannot skip one completed
        // day. Keep seven days of generic one-shots, replenished on normal app execution.
        var journalStore: WhoopStore?
        var journalImportedQuestions: [String] = []
        let journalCatalog: JournalCatalogStore?
        if prefs.mode(for: .journalCheckIn) == .notify {
            journalStore = await storeProvider()
            guard journalStore != nil else {
                setupStatus = "Journal reminders will be checked when storage becomes available."
                return
            }
            let imported = await model.repo.importedJournalEntries()
            journalImportedQuestions = Array(Set(imported.map(\.question)))
            journalCatalog = JournalCatalogStore()
        } else { journalCatalog = nil }
        guard generation == scheduleGeneration, source == model.repo.notificationSourceContext,
              revision == prefs.scheduleRevision else { return }
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let key = NotificationFactBuilder.dayKey(day)
            if prefs.mode(for: .journalCheckIn) == .notify, prefs.journalWeekdays.contains(weekday),
               let date = NotificationSchedulePlanner.resolve(day: day, minute: prefs.journalMinutes), date > now,
               let journalStore, let journalCatalog {
                let candidate = NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: key,
                    scheduledAt: date, source: source, destination: .journal(logicalDay: key), now: now, revision: revision)
                let needed: NotificationCandidate?
                do {
                    needed = try await journalReminderIfNeeded(candidate, day: key, catalog: journalCatalog,
                        importedQuestions: journalImportedQuestions, store: journalStore)
                } catch {
                    setupStatus = "Journal completion could not be checked. Open the app again to retry."
                    return
                }
                guard generation == scheduleGeneration, source == model.repo.notificationSourceContext,
                      revision == prefs.scheduleRevision else { return }
                if let needed { candidates.append(needed) }
            }
        }
        if prefs.mode(for: .workoutPlan) == .notify {
            for plan in workoutPlans() where NotificationSchedulePlanner.shouldScheduleWorkout(hasExplicitTime: plan.hasExplicitTime, completedSessionID: plan.completedSessionID) {
                let date = plan.plannedAt.addingTimeInterval(-Double(prefs.workoutReminderLeadMinutes * 60))
                guard date > now, date < now.addingTimeInterval(7 * 86400) else { continue }
                candidates.append(NotificationSchedulePlanner.candidate(group: .workoutPlan, id: "\(plan.id):r\(plan.revision)",
                    scheduledAt: date, source: source, destination: .plannedWorkout(id: plan.id), now: now,
                    revision: revision, actionAt: plan.plannedAt))
            }
        }
        guard generation == scheduleGeneration, source == model.repo.notificationSourceContext,
              revision == prefs.scheduleRevision else { return }
        explicitDates = candidates.filter { preferences().mode(for: $0.group) == .notify }.compactMap(\.scheduledAt)
        let desired = Set(candidates.filter { preferences().mode(for: $0.group) == .notify }.map(\.occurrenceID))
        if let store = await storeProvider(), let records = try? await store.notificationRecords() {
            guard generation == scheduleGeneration, source == model.repo.notificationSourceContext,
                  revision == prefs.scheduleRevision else { return }
            for record in records where record.ruleID.hasSuffix(".scheduled") && !desired.contains(record.occurrenceID) {
                await withdraw(occurrenceID: record.occurrenceID)
            }
        }
        guard generation == scheduleGeneration, revision == prefs.scheduleRevision else { return }
        repeatingComponents = repeats
        await process(candidates: candidates)
        let pending = await center.pendingIdentifiers()
        if pending.filter({ $0.hasPrefix(Self.namespace) }).count > 24 {
            setupStatus = "More than 24 reminders are pending. Accepted reminders are preserved; shorten the schedule if setup fails."
        }
    }
}
