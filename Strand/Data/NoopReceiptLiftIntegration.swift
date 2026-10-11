import Foundation
import Combine
import ReceiptLiftFeature
import WhoopStore

/// Keeps a lifting session attached to its original NOOP source across source switches.
@MainActor
final class NoopReceiptLiftIntegration: ObservableObject {
    @Published private(set) var coordinator: ReceiptLiftCoordinator?
    @Published private(set) var owner: String?
    @Published private(set) var error: String?
    /// One-shot, once per process: a lift session that was in flight when NOOP last closed has just been
    /// restored from disk. The shell consumes it to re-present the workout without a tap.
    @Published private(set) var restoredSessionPending = false
    private var announcedRestoredSession = false
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var selecting = false
    private var selectedSourceOwner: HistoricalCursorScope?

    init(model: AppModel) {
        self.model = model
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
        guard !source.isEmpty, owner != source else { return }
        // A source switch must never reattribute an in-progress workout.
        guard coordinator?.hasActiveSession != true else { return }
        selecting = true
        defer {
            selecting = false
            if model.repo.deviceId != source {
                Task { [weak self] in await self?.selectCurrentSource() }
            }
        }
        guard let store = await model.repo.storeHandle() else {
            error = "Your workout log is unavailable. Try again when NOOP finishes opening its database."
            return
        }
        let sourceOwner: HistoricalCursorScope
        do { sourceOwner = try await store.receiptLiftSourceOwner(deviceId: source) }
        catch { self.error = "Couldn’t open this source’s workout log: \(error.localizedDescription)"; return }
        let demoState = Self.demoState()
        let feature = ReceiptLiftCoordinator(
            load: { if let demoState { return demoState }; return try await store.loadReceiptLiftState(sourceOwner: sourceOwner) },
            save: { [weak model] data, workouts in
                let payload = NoopReceiptLiftPayload.make(owner: source, workouts: workouts)
                try await store.saveReceiptLiftStateAndWorkout(sourceOwner: sourceOwner, data: data,
                    sessions: payload.sessions, sets: payload.sets, workouts: payload.workouts)
                if !workouts.isEmpty {
                    Task { @MainActor [weak model] in
                            guard let model, model.repo.deviceId == source else { return }
                            await model.intelligence.analyzeRecent(maxDays: 1, startOffset: 0, refreshRepository: true)
                            _ = await model.repo.refresh(.currentDay)
                    }
                }
            }, canStart: { [weak model] in model?.activeWorkout == nil })
        guard model.repo.deviceId == source else { return }
        owner = source
        selectedSourceOwner = sourceOwner
        coordinator = feature
        error = nil
        await feature.load()
        guard coordinator === feature else { return }
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
