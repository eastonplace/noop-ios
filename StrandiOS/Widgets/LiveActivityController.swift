#if os(iOS)
import Foundation
// ActivityKit's generic Activity/ActivityContent bridge is not fully Sendable-annotated in the iOS 17
// SDK even though this controller serializes every mutation on MainActor. Keep that framework boundary
// pre-concurrency-scoped; NOOP-owned state remains under complete strict concurrency checking.
@preconcurrency import ActivityKit

struct WorkoutLiveActivityState {
    let sport: String
    let startedAt: Date
    let strain: Double?
    let strainBuilding: Bool
    let calories: Int?
    let hrTrace: [Int]
    let zoneSeconds: [Int]
}

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
///
/// ActivityKit mutations are reconciled by one coalescing task. Incoming HR callbacks only replace the
/// pending desired state; they never create an unbounded set of update/end tasks. The worker serializes
/// update, end, and mode-transition operations so an older async update cannot land after workout end.
@MainActor
final class LiveActivityController {
    private struct DriveInput {
        let bpm: Int?
        let recovery: Int?
        let connected: Bool
        let effort: Double?
        let verifiedContextId: String?
        let verifiedProjectionGeneration: Int64?
        let workoutIsActive: Bool
        let workoutProjection: () -> WorkoutLiveActivityState?
    }

    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    private var lastModeWasWorkout: Bool?

    /// Latest desired drive state. A new HR callback replaces this value while ActivityKit is busy;
    /// only the newest state is reconciled after the current mutation completes.
    private var pendingDrive: DriveInput?
    private var reconcileTask: Task<Void, Never>?

    /// The expensive workout projection (calories + time-in-zone rescan over the growing sample array)
    /// is supplied lazily and cached here. A long workout used to rebuild it before the existing ActivityKit
    /// throttle on every ~1 Hz HR emission, turning an otherwise O(1) live path back into O(n).
    private var cachedWorkoutState: WorkoutLiveActivityState?
    private var lastWorkoutProjectionAt: Date = .distantPast
    /// Last payload handed to ActivityKit. Equal payloads do not need another async bridge call every 2 s;
    /// a periodic heartbeat still refreshes the stale date for a quiet-but-healthy stream.
    private var lastContentState: NOOPActivityAttributes.ContentState?
    private static let verifiedGenerationKey = "noop.live-activity.verified-projection-generation"

    #if DEBUG
    private var component41QAMode = false
    #endif

    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while streaming, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end.
    private static let staleAfter: TimeInterval = 120
    private static let unchangedHeartbeatInterval: TimeInterval = 30

    /// Drive the activity from the latest live values. Calling this method is intentionally cheap: it
    /// stores the latest desired state and ensures one reconciliation task is running.
    ///
    /// - Parameter workoutIsActive: A cheap mode signal. Existing production call sites may omit it;
    ///   the controller then reads `LiveActivityWorkoutStatus`, while tests and future callers can inject it.
    /// - Parameter workout: A lazy expensive projection, evaluated only after mode and cadence gates pass.
    func update(
        bpm: Int?,
        recovery: Int?,
        connected: Bool,
        effort: Double? = nil,
        verifiedContextId: String? = nil,
        verifiedProjectionGeneration: Int64? = nil,
        workoutIsActive: Bool? = nil,
        workout: @autoclosure @escaping () -> WorkoutLiveActivityState? = nil
    ) {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif
        pendingDrive = DriveInput(
            bpm: bpm,
            recovery: recovery,
            connected: connected,
            effort: effort,
            verifiedContextId: verifiedContextId,
            verifiedProjectionGeneration: verifiedProjectionGeneration,
            workoutIsActive: workoutIsActive ?? LiveActivityWorkoutStatus.isActive,
            workoutProjection: workout
        )
        startReconcilerIfNeeded()
    }

    private func startReconcilerIfNeeded() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            await self?.drainPendingDrive()
        }
    }

    private func drainPendingDrive() async {
        while !Task.isCancelled, let input = pendingDrive {
            pendingDrive = nil
            await reconcile(input)
        }
        reconcileTask = nil
        // An input can arrive after the loop's final condition check but before the task clears itself.
        // The main actor makes this check/start atomic with respect to `update`.
        if pendingDrive != nil { startReconcilerIfNeeded() }
    }

    private func reconcile(_ input: DriveInput) async {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. Recover its actual content mode so
        // the first post-launch workout start/end can still trigger the required title-changing restart.
        if activity == nil, let existing = Activity<NOOPActivityAttributes>.activities.first {
            activity = existing
            lastModeWasWorkout = existing.content.state.isWorkout
            lastContentState = existing.content.state
            lastPush = .distantPast
        }

        // Opt-out and disconnect are lifecycle edges, not ordinary updates. They run through the same
        // serialized worker, preventing an older queued update from reviving content after the end.
        guard UnitPrefs.liveActivityEnabled(), input.connected else {
            await performEnd()
            return
        }
        guard input.bpm != nil else { return }

        let desiredModeIsWorkout = input.workoutIsActive
        var now = Date()
        guard LiveActivityPushPolicy.shouldPush(
            activityExists: activity != nil,
            currentModeIsWorkout: lastModeWasWorkout,
            desiredModeIsWorkout: desiredModeIsWorkout,
            lastPushedAt: lastPush,
            now: now
        ) else { return }

        // Activity attributes are immutable, so changing between generic Live HR and a named workout
        // requires an end/restart. Mode edges bypass the 2-second content throttle above. If a newer drive
        // input arrived while ActivityKit was ending, let the loop reconcile that newest state instead.
        if activity != nil,
           let lastModeWasWorkout,
           lastModeWasWorkout != desiredModeIsWorkout {
            await performEnd()
            guard !Task.isCancelled, pendingDrive == nil else { return }
            now = Date()
        }

        if desiredModeIsWorkout {
            if LiveActivityWorkoutProjectionPolicy.shouldRebuild(
                workoutIsActive: true,
                hasCachedWorkout: cachedWorkoutState != nil,
                lastBuiltAt: lastWorkoutProjectionAt,
                now: now
            ) {
                if let projection = input.workoutProjection() {
                    cachedWorkoutState = projection
                    lastWorkoutProjectionAt = now
                } else {
                    // The presence signal and projection should agree on the main actor. If a future caller
                    // violates that contract, stay ended/generic rather than publish contradictory workout UI.
                    cachedWorkoutState = nil
                    lastWorkoutProjectionAt = .distantPast
                    return
                }
            }
        } else {
            // Finish is an immediate cheap edge. Never let a ten-second cached projection keep the Lock
            // Screen in workout mode after `activeWorkout` has been cleared.
            cachedWorkoutState = nil
            lastWorkoutProjectionAt = .distantPast
        }

        let workoutState = desiredModeIsWorkout ? cachedWorkoutState : nil
        let state = NOOPActivityAttributes.ContentState(
            bpm: input.bpm,
            recovery: input.recovery,
            bonded: input.connected,
            effort: workoutState?.strain ?? input.effort,
            sport: workoutState?.sport,
            workoutStartedAt: workoutState?.startedAt,
            strainBuilding: workoutState?.strainBuilding,
            calories: workoutState?.calories,
            hrTrace: workoutState?.hrTrace,
            zoneSeconds: workoutState?.zoneSeconds
        )
        let staleDate = now.addingTimeInterval(Self.staleAfter)

        if let activity {
            let heartbeatElapsed = now.timeIntervalSince(lastPush)
            if state == lastContentState,
               heartbeatElapsed >= 0,
                heartbeatElapsed < Self.unchangedHeartbeatInterval {
                return
            }
            guard acceptsVerifiedGeneration(input) else { return }
            lastPush = now
            lastContentState = state
            lastModeWasWorkout = desiredModeIsWorkout
            // Await directly inside the single reconciliation worker. This serializes ActivityKit updates
            // and coalesces any HR callbacks that arrive while the bridge is suspended.
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
        } else {
            do {
                guard acceptsVerifiedGeneration(input) else { return }
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(
                        title: workoutState?.sport ?? String(localized: "Live HR")
                    ),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = now
                lastContentState = state
                lastModeWasWorkout = desiredModeIsWorkout
            } catch {
                resetCachedState()
            }
        }
    }

    /// Persist the verified generation immediately before the ActivityKit sink. Nil identity belongs to the
    /// ordinary live lane and remains compatible with pre-verification updates.
    private func acceptsVerifiedGeneration(_ input: DriveInput) -> Bool {
        guard let contextId = input.verifiedContextId,
              let generation = input.verifiedProjectionGeneration,
              let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else {
            return true
        }
        return VerifiedProjectionGenerationStore.acceptsAndRecord(
            contextId: contextId,
            generation: generation,
            defaults: defaults,
            key: Self.verifiedGenerationKey
        )
    }

    /// Explicit shutdown used by QA and any future lifecycle owner. Production drive calls normally reach
    /// `performEnd` through the reconciler. Cancelling and awaiting the worker prevents update-after-end.
    func end() async {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif
        pendingDrive = nil
        if let task = reconcileTask {
            task.cancel()
            await task.value
        }
        reconcileTask = nil
        await performEnd()
    }

    private func performEnd() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted and any rare duplicate.
        for existing in Activity<NOOPActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        resetCachedState()
    }

    private func resetCachedState() {
        activity = nil
        lastModeWasWorkout = nil
        cachedWorkoutState = nil
        lastWorkoutProjectionAt = .distantPast
        lastContentState = nil
        lastPush = .distantPast
    }

    #if DEBUG
    /// Simulator-only ActivityKit proof. It exercises the real extension and OS presentation while
    /// remaining impossible to invoke in Release or on a user's normal launch path.
    func startComponent41QA() async {
        guard authInfo.areActivitiesEnabled else { return }
        await end()
        component41QAMode = true
        let state = NOOPActivityAttributes.ContentState(
            bpm: 152,
            recovery: 78,
            bonded: true,
            effort: 6.8,
            sport: "Outdoor Run",
            workoutStartedAt: Date().addingTimeInterval(-2_734),
            strainBuilding: false,
            calories: 438,
            hrTrace: [88, 96, 108, 121, 115, 132, 146, 139, 152, 144, 158, 152],
            zoneSeconds: [180, 620, 1_180, 650, 104]
        )
        do {
            activity = try Activity.request(
                attributes: NOOPActivityAttributes(title: "Outdoor Run"),
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(7_200)
                ),
                pushType: nil
            )
            lastContentState = state
            lastPush = Date()
            lastModeWasWorkout = true
        } catch {
            resetCachedState()
        }
    }
    #endif
}
#endif
