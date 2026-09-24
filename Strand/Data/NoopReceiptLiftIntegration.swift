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
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private var selecting = false

    init(model: AppModel) { self.model = model }

    func selectCurrentSource() async {
        guard !selecting, let model else { return }
        let source = model.repo.deviceId
        guard !source.isEmpty, owner != source else { return }
        // A source switch must never reattribute an in-progress workout.
        guard coordinator?.hasActiveSession != true else { return }
        selecting = true
        defer { selecting = false }
        guard let store = await model.repo.storeHandle() else {
            error = "Your workout log is unavailable. Try again when NOOP finishes opening its database."
            return
        }
        let sourceOwner: HistoricalCursorScope
        do { sourceOwner = try await store.receiptLiftSourceOwner(deviceId: source) }
        catch { self.error = "Couldn’t open this source’s workout log: \(error.localizedDescription)"; return }
        let feature = ReceiptLiftCoordinator(
            load: { try await store.loadReceiptLiftState(sourceOwner: sourceOwner) },
            save: { data, workouts in
                let payload = NoopReceiptLiftPayload.make(owner: source, workouts: workouts)
                try await store.saveReceiptLiftStateAndWorkout(sourceOwner: sourceOwner, data: data,
                    sessions: payload.sessions, sets: payload.sets, workouts: payload.workouts)
                if !workouts.isEmpty {
                    await MainActor.run {
                        Task { @MainActor [weak model] in
                            guard let model, model.repo.deviceId == source else { return }
                            await model.intelligence.analyzeRecent(maxDays: 1, startOffset: 0, refreshRepository: true)
                            _ = await model.repo.refresh(.currentDay)
                        }
                    }
                }
            }, canStart: { [weak model] in model?.activeWorkout == nil })
        owner = source
        coordinator = feature
        error = nil
        await feature.load()
        observation = feature.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func discardSource(_ source: String) {
        guard owner == source else { return }
        coordinator?.discard()
        coordinator = nil
        owner = nil
        observation = nil
    }
}

private enum NoopReceiptLiftPayload {
    struct Rows {
        var sessions: [LiftSessionRow] = []
        var sets: [LiftSetRow] = []
        var workouts: [WorkoutRow] = []
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
                    exercise: set.exercise, primaryMuscle: nil, secondaryMuscles: [], setIndex: set.setIndex,
                    weightKg: set.weightKg, reps: set.reps, rpe: set.rpe, isWarmup: set.isWarmup,
                    startTs: Int(set.completedAt.timeIntervalSince1970), endTs: Int(set.completedAt.timeIntervalSince1970), restSec: nil, note: set.note)
            }
        }
        return result
    }
}
