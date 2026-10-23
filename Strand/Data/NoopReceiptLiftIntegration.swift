import Foundation
import Combine
import ReceiptLiftFeature
import StrandAnalytics
import WhoopProtocol
import WhoopStore

extension UnitSystem {
    /// Lift stores pounds; the unit setting only changes how loads are drawn and stepped.
    var liftWeightUnit: LiftWeightUnit { self == .imperial ? .pounds : .kilograms }
}

/// Tells Lift the person's unit whenever the setting changes, for as long as the app runs. Lift's own view only follows the
/// setting while it is on screen, and Settings is reached by closing it, so a running session's Live Activity would keep
/// the old unit until Lift was reopened.
@MainActor
final class LiftWeightUnitFollower {
    private var observation: AnyCancellable?

    /// `apply` is called with the setting as it stands after any change to `defaults`; the receiver ignores a repeat.
    init(defaults: UserDefaults = .standard, apply: @escaping @MainActor (LiftWeightUnit) -> Void) {
        observation = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { _ in apply(Self.unit(in: defaults)) }
    }

    static func unit(in defaults: UserDefaults) -> LiftWeightUnit {
        (UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric).liftWeightUnit
    }
}

/// Keeps a lifting session attached to its original NOOP source across source switches.
@MainActor
final class NoopReceiptLiftIntegration: ObservableObject {
    @Published private(set) var coordinator: ReceiptLiftCoordinator?
    @Published private(set) var owner: String?
    @Published private(set) var notificationSourceContext: String?
    @Published private(set) var isNotificationSourceReady = false
    @Published private(set) var error: String?
    /// One-shot, once per process: a lift session that was in flight when NOOP last closed has just been
    /// restored from disk. The shell consumes it to re-present the workout without a tap.
    @Published private(set) var restoredSessionPending = false
    private var announcedRestoredSession = false
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var unitFollower: LiftWeightUnitFollower?
    private var selecting = false
    private var selectedSourceOwner: HistoricalCursorScope?

    init(model: AppModel) {
        self.model = model
        unitFollower = LiftWeightUnitFollower { [weak self] unit in self?.coordinator?.setWeightUnit(unit) }
        #if os(iOS)
        LocalCoachPlanAdapter.registerReceiptWriter(repo: model.repo) { [weak self] sourceOwner, transform in
            guard let self else { throw CancellationError() }
            try await self.saveCoachPlan(sourceOwner: sourceOwner, transform: transform)
        }
        #endif
    }

    #if os(iOS)
    private func saveCoachPlan(sourceOwner: HistoricalCursorScope,
                               transform: @MainActor (Data) throws -> Data?) async throws {
        guard let model else { throw CancellationError() }
        await selectCurrentSource()
        guard let feature = coordinator else {
            throw LocalCoachDataError.unavailable("Open Lift once, then retry saving your plan.")
        }
        try await feature.applyReviewedRoutineChange(validate: { [weak self, weak model, weak feature] in
            guard let self, let model, let feature,
                  self.coordinator === feature, self.selectedSourceOwner == sourceOwner,
                  model.repo.deviceId == sourceOwner.deviceId, !model.repo.verifiedExternalSurfaceFenced else {
                throw LocalCoachDataError.sourceChanged
            }
            guard model.activeWorkout == nil, !feature.hasActiveSession else {
                throw LocalCoachDataError.unavailable("Finish your active workout before saving a Coach plan.")
            }
        }, transform: transform)
    }
    #endif

    func selectCurrentSource() async {
        guard !selecting, let model else { return }
        let source = model.repo.deviceId
        guard !source.isEmpty else { return }
        let startingContext = model.repo.notificationSourceContext
        if startingContext != notificationSourceContext { isNotificationSourceReady = false }
        selecting = true
        defer {
            selecting = false
            if model.repo.deviceId != source || model.repo.notificationSourceContext != startingContext {
                Task { [weak self] in await self?.selectCurrentSource() }
            }
        }
        guard let store = await model.repo.storeHandle() else {
            error = "Your workout log is unavailable. Try again when NOOP finishes opening its database."
            return
        }
        guard model.repo.deviceId == source, model.repo.notificationSourceContext == startingContext else {
            isNotificationSourceReady = false
            return
        }
        let storageContext = startingContext
        let sourceOwner: HistoricalCursorScope
        do { sourceOwner = try await store.receiptLiftSourceOwner(deviceId: source) }
        catch { self.error = "Couldn’t open this source’s workout log: \(error.localizedDescription)"; return }
        let currentContext = model.repo.notificationSourceContext
        guard !currentContext.hasPrefix("unavailable:"), currentContext == storageContext,
              model.repo.deviceId == source else {
            isNotificationSourceReady = false
            return
        }
        if owner == source, notificationSourceContext == currentContext,
           selectedSourceOwner == sourceOwner, isNotificationSourceReady { return }
        isNotificationSourceReady = false
        // A restored database with the same device name cannot reuse the old captured store.
        if owner == source, notificationSourceContext != currentContext {
            coordinator?.discard()
            coordinator = nil
            observation = nil
        }
        // A switch to another device still cannot reattribute an active session.
        guard coordinator?.hasActiveSession != true else { return }
        let demoState = Self.demoState()
        let feature = ReceiptLiftCoordinator(
            load: { if let demoState { return demoState }; return try await store.loadReceiptLiftState(sourceOwner: sourceOwner) },
            save: { [weak model] data, workouts in
                let payload = NoopReceiptLiftPayload.make(owner: source, workouts: workouts)
                // Strength Strain rows are computed here and saved in the same transaction as the lift, so a lift
                // never exists without its muscular load. A body weight frozen with an earlier save is reused.
                let frozen = (try? await store.liftStrainBodyweights(
                    deviceId: source, liftSessionIds: workouts.map(\.id))) ?? [:]
                let profileKg = ProfileStore.storedWeightKg()
                let liftStrain = workouts.map {
                    StrengthStrainIntegration.computed(for: $0, frozen: frozen[$0.id], profileKg: profileKg)
                }
                try await store.saveReceiptLiftStateAndWorkout(sourceOwner: sourceOwner, data: data,
                    sessions: payload.sessions, sets: payload.sets, workouts: payload.workouts,
                    liftStrain: liftStrain)
                if !workouts.isEmpty {
                    Task { @MainActor [weak model] in
                        guard let model, model.repo.deviceId == source,
                              model.repo.notificationSourceContext == currentContext else { return }
                        await LiftStrainSaveFollowUp.run(
                            analyze: {
                                await model.intelligence.analyzeRecent(maxDays: 1, startOffset: 0, refreshRepository: true)
                            },
                            settle: { _ = await model.intelligence.settleLiftStrain() },
                            refresh: {
                                await model.repo.refreshLiveDayStrain(maxHR: Double(model.profile.hrMax))
                                _ = await model.repo.refresh(.currentDay)
                            })
                        guard model.repo.notificationSourceContext == currentContext else { return }
                        await NotificationCoordinator.shared.processPendingLiveWorkouts(repository: model.repo)
                    }
                }
            }, canStart: { [weak model] in model?.activeWorkout == nil },
            // Before load(): a restored session redraws its Live Activity as part of loading.
            weightUnit: UnitSystem.stored.liftWeightUnit)
        guard model.repo.deviceId == source, model.repo.notificationSourceContext == currentContext else {
            feature.discard(); return
        }
        feature.configureRoutineImport(parse: NoopReceiptLiftRoutineImportAdapter.parse) { [weak self, weak model, weak feature] in
            guard let self, let model, let feature,
                  self.coordinator === feature, self.selectedSourceOwner == sourceOwner,
                  model.repo.deviceId == source, model.repo.notificationSourceContext == currentContext,
                  !model.repo.verifiedExternalSurfaceFenced else { throw NoopRoutineImportSourceError.changed }
            guard model.activeWorkout == nil, !feature.hasActiveSession else { throw NoopRoutineImportSourceError.activeWorkout }
        }
        feature.strainProvider = Self.strainProvider(model: model, store: store)
        feature.setNotificationCompletionHandler { [weak model] start, end in
            guard let model, model.repo.notificationSourceContext == currentContext else { return }
            NotificationCoordinator.shared.registerLiveWorkout(startTs: Int(start.timeIntervalSince1970),
                sport: "Strength Training", endedAt: end, sourceContext: currentContext)
            Task { @MainActor [weak model] in
                guard let model else { return }
                await NotificationCoordinator.shared.processPendingLiveWorkouts(repository: model.repo)
            }
        }
        await feature.load()
        guard model.repo.deviceId == source, model.repo.notificationSourceContext == currentContext,
              feature.notificationRestorationComplete else {
            feature.discard()
            error = feature.saveError ?? "Your workout log is still loading. Reopen Lift to retry."
            return
        }
        owner = source
        selectedSourceOwner = sourceOwner
        notificationSourceContext = currentContext
        coordinator = feature
        isNotificationSourceReady = true
        error = nil
        observation = feature.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.replayDeferredWorkAfterLiftChange()
        }
        // `observation` attaches only after the load above, so nothing told observers that the restored
        // session now exists: the Resume Lift card stayed hidden until something unrelated re-rendered it.
        objectWillChange.send()
        if feature.hasActiveSession, !announcedRestoredSession {
            announcedRestoredSession = true
            restoredSessionPending = true
        }
    }

    func consumeRestoredSession() { restoredSessionPending = false }

    /// What Lift shows for Strain: the app's stored values, or (DEBUG) the simulator QA scenarios.
    static func strainProvider(model: AppModel, store: WhoopStore) -> any LiftStrainProviding {
        #if DEBUG
        if let demo = DemoLiftStrainProvider.requested() { return demo }
        #endif
        let repository = model.repo
        let source = repository.deviceId
        let sourceContext = repository.notificationSourceContext
        let readIds = repository.importedReadIds
        // An active workout can outlive a source selection. Its saved summaries keep their original
        // owner, while live values must stop until that exact repository/source context is current.
        let isCurrentSource: @MainActor @Sendable () -> Bool = { [weak model, weak repository] in
            guard let model, let repository else { return false }
            return model.repo === repository && repository.deviceId == source
                && repository.notificationSourceContext == sourceContext
        }
        let heartRateOwner = RealtimeHRLeaseOwner(model: model, consumer: .lift)
        return AppLiftStrainProvider(
            store: store,
            deviceId: { source },
            bpm: { [weak model] in isCurrentSource() ? model?.bpm : nil },
            startHR: { if isCurrentSource() { heartRateOwner.begin() } },
            stopHR: { heartRateOwner.end() },
            maxHR: { [weak model] in Double(model?.profile.hrMax ?? 190) },
            restingHR: { [weak model] in
                guard isCurrentSource() else { return StrainScorerV2.defaultRestingHR }
                let today = Repository.logicalDayKey(Date())
                return model?.repo.days.last(where: { $0.day == today })?.restingHr.map(Double.init)
                    ?? StrainScorerV2.defaultRestingHR
            },
            hrSamples: { from, to in
                guard await isCurrentSource() else { return [] }
                let samples = await Repository.hrSamples(store: store, sourceIds: readIds, from: from, to: to)
                guard await isCurrentSource() else { return [] }
                return samples
            },
            liveSourceIsCurrent: isCurrentSource)
    }

    /// Simulator QA only: `--demo-seed --noop-lift-demo <variant>` loads generated Lift data instead of the database's.
    /// What the person does afterwards is still saved to the database, so a relaunch without the flag restores it.
    private static func demoState() -> Data? {
        #if DEBUG && targetEnvironment(simulator)
        guard CommandLine.arguments.contains("--demo-seed"), let variant = ReceiptLiftDemo.requestedVariant else { return nil }
        return ReceiptLiftDemo.stateData(variant: variant)
        #else
        return nil
        #endif
    }

    /// Post-sync refresh work is parked while a lift is active. `objectWillChange` fires before the change
    /// lands, so check after it has: if the session just ended, the model replays what was parked. Cheap and
    /// rare: it only schedules anything while work is actually parked.
    private func replayDeferredWorkAfterLiftChange() {
        guard let model, model.hasDeferredSessionWork else { return }
        Task { @MainActor [weak model] in model?.replayDeferredSessionWorkIfIdle() }
    }

    func discardSource(_ source: String) {
        guard owner == source else { return }
        coordinator?.discard()
        coordinator = nil
        owner = nil
        selectedSourceOwner = nil
        notificationSourceContext = nil
        isNotificationSourceReady = false
        observation = nil
    }
}

enum NoopReceiptLiftPayload {
    struct Rows {
        var sessions: [LiftSessionRow] = []
        var sets: [LiftSetRow] = []
        var workouts: [WorkoutRow] = []
    }
    // Only map catalog labels that have an exact counterpart. Broad labels such as
    // shoulders and legs must not invent a more specific muscle attribution.
    static func muscle(_ label: String) -> LiftMuscle? {
        if let exact = LiftMuscle(rawValue: label) { return exact }
        switch label.lowercased() {
        case "pectorals": return .chest
        case "upper back": return .upperBack
        case "lower back", "spine": return .lowerBack
        case "quadriceps": return .quads
        case "abdominals": return .abs
        case "levator scapulae": return .neck
        default: return nil
        }
    }

    static func make(owner: String, workouts: [ReceiptLiftWorkout]) -> Rows {
        var result = Rows()
        for workout in workouts {
            let start = Int(workout.startedAt.timeIntervalSince1970)
            let end = Int(workout.endedAt.timeIntervalSince1970)
            result.sessions.append(LiftSessionRow(id: workout.id, deviceId: owner, startTs: start,
                endTs: end, sport: "Strength Training", programId: nil, programName: workout.title,
                sessionRpe: nil, note: nil))
            result.workouts.append(WorkoutRow(startTs: start, endTs: end, sport: "Strength Training",
                source: "manual", durationS: Double(max(0, end - start)), energyKcal: nil,
                avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: workout.title))
            result.sets += workout.sets.enumerated().map { index, set in
                LiftSetRow(id: set.id, deviceId: owner, sessionId: workout.id, ord: index,
                    exercise: set.exercise, primaryMuscle: muscle(set.muscleGroup),
                    secondaryMuscles: set.secondaryMuscles.compactMap(muscle), setIndex: set.setIndex,
                    weightKg: set.weightKg, reps: set.reps, rpe: set.rpe, isWarmup: set.isWarmup,
                    startTs: Int(set.completedAt.timeIntervalSince1970), endTs: Int(set.completedAt.timeIntervalSince1970), restSec: nil, note: set.note)
            }
        }
        return result
    }
}
