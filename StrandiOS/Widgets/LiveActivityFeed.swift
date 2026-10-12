#if os(iOS)
import Foundation
import NoopPhase34Core

/// What the Live Activity is told, worked out in ONE place.
///
/// Three producers feed the activity: the app's own drive (every heart-rate reading and connectivity change), the verified
/// publication worker, and the HealthKit scoring publish. Each used to assemble the heart rate and the workout state on its
/// own, and they drifted: one left out the "ending" flag, so a publish arriving after End re-enabled the Pause button, and
/// another sent the passive heart rate during a workout, blanking the reading the workout still had. They all build through
/// here now, so a rule added to one is on every path.
///
/// The workout state is built by `workoutState()`, and the controller calls it when the write is about to be made, not when
/// the update was queued. Whatever else is queued ahead of it (a connectivity barrier waits its turn), the state it writes
/// is the state of that moment, and it carries the pause-edge count it was built at (`WorkoutLiveActivityState.
/// pauseEdgeGeneration`), so it can never mark an edge delivered that it was built before.
@MainActor
struct LiveActivityFeed {

    /// What the model holds at the moment the feed is read.
    struct Inputs {
        var workout: AppModel.ActiveWorkout?
        /// End was tried and the save is running or failed and is waiting for a retry.
        var finishPending: Bool
        var connected: Bool
        /// The heart rate outside a workout.
        var passiveBPM: Int?
    }

    private let inputs: () -> Inputs
    private let profile: ProfileStore
    private let projections: WorkoutLiveProjectionCache
    private let pauseEdgeGeneration: () -> Int
    private let workoutReading: Int?
    private let now: () -> Date

    init(inputs: @escaping () -> Inputs, profile: ProfileStore, projections: WorkoutLiveProjectionCache,
         pauseEdgeGeneration: @escaping () -> Int, workoutReading: Int? = nil, now: @escaping () -> Date = { Date() }) {
        self.inputs = inputs
        self.profile = profile
        self.projections = projections
        self.pauseEdgeGeneration = pauseEdgeGeneration
        self.workoutReading = workoutReading
        self.now = now
    }

    /// The feed for the app's live model. `connected` overrides the model's link state for a caller that has just been told
    /// of a change the model has not caught up with; `workoutReading` is a heart-rate reading in hand.
    static func current(model: AppModel, projections: WorkoutLiveProjectionCache, liveActivity: LiveActivityController,
                        connected: Bool? = nil, workoutReading: Int? = nil) -> LiveActivityFeed {
        LiveActivityFeed(
            inputs: {
                Inputs(workout: model.activeWorkout, finishPending: model.isWorkoutFinishPending,
                       connected: connected ?? model.live.connected, passiveBPM: model.bpm ?? model.live.heartRate)
            },
            profile: model.profile, projections: projections,
            pauseEdgeGeneration: { liveActivity.pauseEdgeGeneration }, workoutReading: workoutReading)
    }

    // MARK: What is sent

    var connected: Bool { inputs().connected }
    var workoutIsActive: Bool { inputs().workout != nil }

    /// A workout carries the last reading it took, connected or not; outside one the activity shows the passive reading
    /// only while the strap is connected (`LiveActivityHeartRate`).
    var bpm: Int? {
        let now = inputs()
        return LiveActivityHeartRate.value(
            workoutIsActive: now.workout != nil,
            workoutBPM: now.workout.flatMap { workoutReading ?? $0.currentBPM },
            connected: now.connected,
            passiveBPM: now.passiveBPM)
    }

    /// The app's own verdict that the strap has gone quiet, so the activity dims the reading when the app does. The same
    /// function the live screen asks, with the same exemptions (a paused workout, a pending finish). The state the activity
    /// is written with takes this verdict when it is built (`workoutState()`), never when an update was queued.
    var heartRateIsStale: Bool {
        let now = inputs()
        guard let workout = now.workout else { return false }
        return Self.heartRateIsStale(workout, finishPending: now.finishPending, at: self.now())
    }

    private static func heartRateIsStale(_ workout: AppModel.ActiveWorkout, finishPending: Bool, at date: Date) -> Bool {
        LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: workout.lastReadingAt, workoutStart: workout.start, isPaused: workout.isPaused,
            isEnding: workout.isEnding || finishPending, now: date)
    }

    /// The workout as the activity shows it, or nil when none is running. Built when called: the controller calls it when
    /// the write is made.
    func workoutState() -> WorkoutLiveActivityState? {
        let now = inputs()
        guard let workout = now.workout else { return nil }
        // Read the edge count BEFORE building: an edge raised after this is not in the state, and the stamp says so.
        let edges = pauseEdgeGeneration()
        var state = projections.state(workout: workout, profile: profile)
        state.isFinishing = now.finishPending
        // The quiet-strap verdict is taken here with the edge count: an update queued before the strap went quiet and
        // written after must not carry the old verdict while clearing the edge raised for the new one.
        state.heartRateIsStale = Self.heartRateIsStale(workout, finishPending: now.finishPending, at: self.now())
        state.pauseEdgeGeneration = edges
        return state
    }

    // MARK: The two ways in

    func update(_ liveActivity: LiveActivityController, recovery: Int?, effort: Double?,
                verifiedContextId: String?, verifiedProjectionGeneration: Int64?) {
        liveActivity.update(
            bpm: bpm, recovery: recovery, connected: connected, effort: effort,
            verifiedContextId: verifiedContextId, verifiedProjectionGeneration: verifiedProjectionGeneration,
            workoutIsActive: workoutIsActive,
            workout: workoutState())
    }

    func publishVerified(_ liveActivity: LiveActivityController, projection: VerifiedHealthProjection,
                         expectedActiveContextId: String, recovery: Int?,
                         effort: Double?) async throws -> ExternalSinkPublicationResult {
        try await liveActivity.publishVerified(
            projection: projection, expectedActiveContextId: expectedActiveContextId,
            bpm: bpm, recovery: recovery, connected: connected, effort: effort,
            workoutIsActive: workoutIsActive,
            workoutProjection: { self.workoutState() })
    }
}
#endif
