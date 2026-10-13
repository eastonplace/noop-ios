#if os(iOS)
import Foundation
import NoopPhase34Core
// ActivityKit's generic Activity/ActivityContent bridge is not fully Sendable-annotated in the iOS 17
// SDK even though this controller serializes every mutation on MainActor. Keep that framework boundary
// pre-concurrency-scoped; NOOP-owned state remains under complete strict concurrency checking.
@preconcurrency import ActivityKit

struct WorkoutLiveActivityState {
    let sport: String
    /// The timer's anchor: the start moved forward by the pauses already over, so a clock counting up from it reads the
    /// time the workout ran.
    let startedAt: Date
    /// When the pause still open began; the Lock Screen clock freezes there. nil while the workout is running.
    var pausedAt: Date? = nil
    let strain: Double?
    let strainBuilding: Bool
    let calories: Int?
    let hrTrace: [Int]
    let zoneSeconds: [Int]
    var maxHR: Double? = nil
    /// The workout was ended and is saving (or failed and awaits a retry): the activity shows Pause unavailable.
    var isFinishing = false
    /// While a finish is pending, the moment the workout stopped counting: the clock stops there, because the retry saves
    /// a workout that ended then.
    var frozenAt: Date? = nil
    /// The app's verdict that the strap has gone quiet (`LiveWorkoutSignals.heartRateIsStale`) as of the moment this state was
    /// built, in the same breath as the edge count below. The controller reuses a state for up to ten seconds, so it asks
    /// again for every write it makes (`LiveActivityWorkoutStateCache`): what is written is the verdict of the write, which
    /// is also what keeps a write queued before the strap went quiet from clearing the edge raised for it.
    var heartRateIsStale = false
    /// How many pause edges the controller had counted when this state was built. A write carries the edges up to this
    /// count and no more, whenever it happens to run: a state built before an edge (and queued behind other work) can
    /// never mark that edge delivered (`PauseEdgeLatch`).
    var pauseEdgeGeneration = 0
}

enum LiveActivityPublicationError: Error {
    case unavailable
    case requestFailed
    case generationRejected
}

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private struct DriveInput: @unchecked Sendable {
        let bpm: Int?
        let recovery: Int?
        let connected: Bool
        let effort: Double?
        let verifiedContextId: String?
        let verifiedProjectionGeneration: Int64?
        let workoutIsActive: Bool
        /// The quiet-strap verdict (`LiveWorkoutSignals.heartRateIsStale`), asked when the write is made, never when the
        /// update was queued, and again on every write even when the cached workout state is reused. The activity cannot
        /// ask the clock itself.
        var heartRateIsStale: () -> Bool = { false }
        let workoutProjection: () -> WorkoutLiveActivityState?
        /// Traced with the write's result (`LiveActivityTrace`); never health values or a context.
        var source: LiveActivityDriveSource = .lifecycle
        var tokenState: LiveActivityDriveAdmission.TokenState?
        /// Why the health values were removed, when they were.
        var healthStripped: String?

        /// The same write without its health values, for the tokenless lane.
        func withoutHealth(because reason: String) -> DriveInput {
            DriveInput(
                bpm: bpm, recovery: nil, connected: connected, effort: nil, verifiedContextId: nil,
                verifiedProjectionGeneration: nil, workoutIsActive: workoutIsActive,
                heartRateIsStale: heartRateIsStale, workoutProjection: workoutProjection,
                source: source, tokenState: tokenState, healthStripped: reason)
        }
    }

    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    private let authInfo = ActivityAuthorizationInfo()
    private var lastModeWasWorkout: Bool?

    private lazy var serializedPublication = SerializedLiveActivityCommands<DriveInput>(
        validate: { [weak self] token in self?.isCurrentSinkToken(token) ?? false },
        perform: { [weak self] input, token in
            guard let self else { return .superseded }
            return try await self.reconcile(
                input,
                expectedActiveContextId: token?.contextId,
                expectedToken: token)
        },
        repairStale: { [weak self] in
            self?.traceLog.record("queue ended reason=stale-token")
            await self?.performEnd()
            if let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) {
                ActiveSinkEpochRecovery.clearLiveActivityGeneration(defaults: defaults)
            }
        })

    private var workoutStateCache = LiveActivityWorkoutStateCache()
    private var lastContentState: NOOPActivityAttributes.ContentState?
    /// The token states a drive has already been published without health for, so the Console says so once per process.
    private var loggedHealthStrips: Set<LiveActivityDriveAdmission.TokenState> = []
    /// Why the last write showed nothing, logged once until the reason changes or an activity starts. Heart rate drives the
    /// activity every second, so an unchanged reason is not logged again.
    private var lastLoggedExit: String?
    private let traceLog = LiveActivityTrace.shared
    /// Whether a new activity may be requested after the last one went away without the app ending it.
    private var restartPolicy = LiveActivityRestartPolicy()
    /// The activities whose `ended` state was seen, so a later `dismissed` reads as the system's end, not a person's.
    private var endObserved: Set<String> = []
    private var stateObserver: Task<Void, Never>?
    #if DEBUG
    private var component41QAMode = false
    #endif

    private static let staleAfter: TimeInterval = 120
    private static let unchangedHeartbeatInterval: TimeInterval = 30

    /// Raised when the workout was paused or resumed. Live updates coalesce, so this lives here rather than in the
    /// payload: whichever update runs next skips the push throttle and the projection cache, and the activity is
    /// rewritten with the new state at once. It counts edges rather than holding a flag, so a write already in flight
    /// when an edge arrives cannot clear it (`PauseEdgeLatch`).
    private var pauseEdges = PauseEdgeLatch()

    /// The workout's pause state just changed, or a surface asked for a state the workout was already in (a Lock Screen
    /// button that was out of date). The next update bypasses the throttle that spaces heart-rate pushes, and rewrites
    /// the activity even when the state it builds equals the last one this controller sent.
    /// The count of pause edges so far. A state stamps itself with this when it is built (`LiveActivityFeed`).
    var pauseEdgeGeneration: Int { pauseEdges.generation }

    func noteWorkoutPauseEdge() {
        pauseEdges.noteEdge()
        workoutStateCache.clear()
        lastContentState = nil
    }

    func update(
        source: LiveActivityDriveSource,
        bpm: Int?,
        recovery: Int?,
        connected: Bool,
        effort: Double? = nil,
        verifiedContextId: String? = nil,
        verifiedProjectionGeneration: Int64? = nil,
        workoutIsActive: Bool? = nil,
        heartRateIsStale: @autoclosure @escaping () -> Bool = false,
        workout: @autoclosure @escaping () -> WorkoutLiveActivityState? = nil
    ) {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif

        // Health values ride only under the token for their own context. Without it they are removed, never the drive:
        // a stale or unverified context shows no Recovery, and the activity (a workout above all) still starts.
        let admission = LiveActivityDriveAdmission.decide(
            recovery: recovery,
            effort: effort,
            verifiedContextId: verifiedContextId,
            verifiedProjectionGeneration: verifiedProjectionGeneration,
            activeToken: UserDefaults(suiteName: WidgetSnapshot.suiteName)
                .flatMap { ActiveVerifiedSinkEpochStore.activeToken(defaults: $0) })
        if admission.strippedHealth, loggedHealthStrips.insert(admission.tokenState).inserted {
            NSLog("NOOP LiveActivity: publishing without health, token: %@", admission.tokenState.rawValue)
        }
        let input = DriveInput(
            bpm: bpm,
            recovery: admission.recovery,
            connected: connected,
            effort: admission.effort,
            verifiedContextId: admission.verifiedContextId,
            verifiedProjectionGeneration: admission.verifiedProjectionGeneration,
            workoutIsActive: workoutIsActive ?? LiveActivityWorkoutStatus.isActive,
            heartRateIsStale: heartRateIsStale,
            workoutProjection: workout,
            source: source,
            tokenState: admission.tokenState,
            healthStripped: admission.strippedHealth ? "token-\(admission.tokenState.rawValue)" : nil
        )
        if connected {
            serializedPublication.setConnectivityAvailable(true)
            // A source transition closes the live lane until its sink is activated; the queue drops the write silently.
            if serializedPublication.lifecycleSubmissionsAreSuspended { trace(input, "dropped", "reason=suspended") }
            serializedPublication.submitLive(input, token: admission.token)
        } else {
            serializedPublication.submitConnectivityBarrier(input)
        }
    }

    private func reconcile(
        _ input: DriveInput,
        expectedActiveContextId: String? = nil,
        expectedToken: VerifiedSinkToken? = nil
    ) async throws -> ExternalSinkPublicationResult {
        // A drive behind the verified generation is written without its health values (below).
        var input = input
        var expectedToken = expectedToken
        // Barriers carry no workout state of their own; every drive says whether a workout is active.
        if input.source != .lifecycle { restartPolicy.noteDrive(workoutIsActive: input.workoutIsActive) }
        guard expectedActiveContextId == nil || expectedActiveContextId == input.verifiedContextId else {
            trace(input, "superseded", "reason=context-changed")
            return .superseded
        }
        if let expectedToken {
            guard input.verifiedContextId == expectedToken.contextId,
                  isCurrentSinkToken(expectedToken) else {
                trace(input, "superseded", "reason=token-changed")
                return .superseded
            }
        }
        guard authInfo.areActivitiesEnabled else {
            logExit("not shown, Live Activities are off for NOOP in iOS Settings")
            trace(input, "not-shown", "reason=activities-disabled")
            return .notApplicable
        }

        if activity == nil,
           let existing = Activity<NOOPActivityAttributes>.activities.first(where: {
               Self.disappearance($0.activityState) == nil
           }) {
            activity = existing
            lastModeWasWorkout = existing.content.state.isWorkout
            lastContentState = existing.content.state
            lastPush = .distantPast
            observeState(of: existing)
        }

        // An activity the app did not end is gone (the system could not render it, it went stale or ran out of time, or a
        // person swiped it away). Updating it does nothing, so drop it: the request below starts another when the
        // restart policy allows one.
        if let current = activity, let gone = Self.disappearance(current.activityState) {
            let cause = LiveActivityRestartPolicy.cause(of: gone, endObserved: endObserved.contains(current.id))
            restartPolicy.noteGone(cause, now: Date())
            NSLog("NOOP LiveActivity: %@ by the %@", gone.rawValue, cause.rawValue)
            trace(input, "gone", "state=\(gone.rawValue) cause=\(cause.rawValue) id=\(Self.shortId(current))")
            // An ended activity can stay on the Lock Screen, frozen; the one that replaces it must not appear beside it.
            if gone == .ended { await current.end(nil, dismissalPolicy: .immediate) }
            resetCachedState()
        }

        let enabled = UnitPrefs.liveActivityEnabled()
        guard WorkoutLiveActivityVisibility.shouldRemainVisible(
            enabled: enabled, connected: input.connected,
            workoutIsActive: input.workoutIsActive) else {
            logExit(enabled
                    ? "not shown, no workout and the strap is not connected"
                    : "not shown, the in-app Live Activity toggle is off")
            trace(input, "not-shown", enabled ? "reason=no-workout-strap-disconnected" : "reason=in-app-toggle-off")
            await performEnd()
            return .notApplicable
        }
        guard input.bpm != nil || input.workoutIsActive else {
            trace(input, "not-shown", "reason=no-heart-rate")
            return .notApplicable
        }

        let desiredModeIsWorkout = input.workoutIsActive
        var now = Date()
        let connectionChanged = lastContentState.map { $0.bonded != input.connected } ?? false
        guard connectionChanged || pauseEdges.isPending || LiveActivityPushPolicy.shouldPush(
            activityExists: activity != nil,
            currentModeIsWorkout: lastModeWasWorkout,
            desiredModeIsWorkout: desiredModeIsWorkout,
            lastPushedAt: lastPush,
            now: now
        ) else { return .alreadyCurrent }

        if activity != nil,
           let lastModeWasWorkout,
           lastModeWasWorkout != desiredModeIsWorkout {
            await performEnd()
            guard !Task.isCancelled else { return .alreadyCurrent }
            now = Date()
        }

        // Verified-generation ordering governs the health values only. A live drive whose generation is behind the one the
        // activity already carries (the app's verified surface refreshes only while it is in front) loses its health values,
        // never the write, so it can never block the activity, a workout's least of all. The verified worker's own
        // publication still reports superseded. Nothing below suspends before the ActivityKit call, so this check holds.
        if let token = expectedToken {
            switch LiveActivityDriveAdmission.generationVerdict(
                accepted: acceptsVerifiedGeneration(input, expectedActiveContextId: expectedActiveContextId, token: token),
                isVerifiedPublication: input.source == .worker) {
            case .keepHealth:
                break
            case .stripHealth:
                input = input.withoutHealth(because: "generation-behind")
                expectedToken = nil
            case .superseded:
                trace(input, "superseded", "reason=generation-behind")
                return .superseded
            }
        }

        // The projection is reused for up to ten seconds, but the quiet-strap verdict is asked again for this write.
        let workoutState: WorkoutLiveActivityState?
        switch workoutStateCache.stateForWrite(
            workoutIsActive: desiredModeIsWorkout, now: now,
            build: input.workoutProjection, heartRateIsStale: input.heartRateIsStale) {
        case .noWorkout: workoutState = nil
        case .state(let state): workoutState = state
        case .unavailable:
            trace(input, "not-shown", "reason=workout-state-unavailable")
            return .notApplicable
        }
        // The edges this write carries are the ones its workout state was BUILT with, not the ones counted by the time it
        // runs: a state built before a pause edge and queued behind other work must not mark that edge delivered. A write
        // with no workout state carries whatever has been counted (nothing below suspends until the write itself).
        let edgesCarried = workoutState?.pauseEdgeGeneration ?? pauseEdges.generation
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
            zoneSeconds: workoutState?.zoneSeconds,
            maxHR: workoutState?.maxHR,
            isPaused: workoutState.map { $0.pausedAt != nil },
            pausedAt: workoutState?.pausedAt,
            isFinishing: workoutState.flatMap { $0.isFinishing ? true : nil },
            frozenAt: workoutState?.frozenAt,
            heartRateIsStale: workoutState.flatMap { $0.heartRateIsStale ? true : nil }
        )
        let staleDate = now.addingTimeInterval(Self.staleAfter)

        if let activity {
            let heartbeatElapsed = now.timeIntervalSince(lastPush)
            if state == lastContentState,
               heartbeatElapsed >= 0,
               heartbeatElapsed < Self.unchangedHeartbeatInterval {
                if let expectedToken,
                   !recordVerifiedGeneration(input, token: expectedToken) { return .superseded }
                // The activity already shows exactly this state, so an edge it was built after has been carried.
                pauseEdges.delivered(builtAt: edgesCarried)
                return .alreadyCurrent
            }
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
            if let expectedToken,
               !recordVerifiedGeneration(input, token: expectedToken) {
                trace(input, "superseded", "reason=generation-record")
                return .superseded
            }
            trace(input, "updated")
            lastPush = now
            lastContentState = state
            lastModeWasWorkout = desiredModeIsWorkout
            pauseEdges.delivered(builtAt: edgesCarried)
            return .published
        } else {
            switch restartPolicy.verdict(now: now) {
            case .allowed:
                break
            case .dismissedByPerson:
                logExit("not shown, dismissed on the Lock Screen until the next workout")
                trace(input, "not-shown", "reason=dismissed-by-person")
                return .notApplicable
            case .backoff:
                logExit("not shown, waiting before asking again after the system ended it")
                trace(input, "not-shown", "reason=restart-backoff")
                return .notApplicable
            case .exhausted:
                logExit("not shown, the system ended it too often during this workout")
                trace(input, "not-shown", "reason=restarts-exhausted")
                return .notApplicable
            }
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(
                        title: workoutState?.sport ?? String(localized: "Live HR")
                    ),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                NSLog("NOOP LiveActivity: started (%@)", desiredModeIsWorkout ? "workout" : "heart rate")
                lastLoggedExit = nil
                if let activity {
                    observeState(of: activity)
                    trace(input, "requested", "id=\(Self.shortId(activity)) state=\(activity.activityState)")
                } else {
                    trace(input, "requested")
                }
                if let expectedToken,
                   !recordVerifiedGeneration(input, token: expectedToken) {
                    trace(input, "ended", "reason=generation-record")
                    await performEnd()
                    return .superseded
                }
                lastPush = now
                lastContentState = state
                lastModeWasWorkout = desiredModeIsWorkout
                pauseEdges.delivered(builtAt: edgesCarried)
                return .published
            } catch {
                // ActivityKit refuses a request made from the background, among other reasons: say which.
                NSLog("NOOP LiveActivity: request failed (%@): %@",
                      desiredModeIsWorkout ? "workout" : "heart rate", String(describing: error))
                trace(input, "request-failed", "error=\(String(describing: error).prefix(120))")
                resetCachedState()
                throw LiveActivityPublicationError.requestFailed
            }
        }
    }

    func publishVerified(
        projection: VerifiedHealthProjection,
        expectedActiveContextId: String,
        bpm: Int?,
        recovery: Int?,
        connected: Bool,
        effort: Double?,
        workoutIsActive: Bool,
        heartRateIsStale: @escaping () -> Bool = { false },
        workoutProjection: @escaping () -> WorkoutLiveActivityState?
    ) async throws -> ExternalSinkPublicationResult {
        guard projection.contextId == expectedActiveContextId else { return .superseded }
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let token = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              token.contextId == projection.contextId else { return .superseded }
        serializedPublication.setConnectivityAvailable(connected)
        serializedPublication.activateLifecycleSubmissions()
        let input = DriveInput(
            bpm: bpm,
            recovery: recovery,
            connected: connected,
            effort: effort,
            verifiedContextId: projection.contextId,
            verifiedProjectionGeneration: projection.generation,
            workoutIsActive: workoutIsActive,
            heartRateIsStale: heartRateIsStale,
            workoutProjection: workoutProjection,
            source: .worker,
            tokenState: .match
        )
        return try await serializedPublication.submitVerified(input, token: token)
    }

    private func isCurrentSinkToken(_ token: VerifiedSinkToken) -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults) else { return false }
        return active == token
    }

    private func acceptsVerifiedGeneration(
        _ input: DriveInput,
        expectedActiveContextId: String? = nil,
        token: VerifiedSinkToken
    ) -> Bool {
        guard let contextId = input.verifiedContextId,
              let generation = input.verifiedProjectionGeneration,
              let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults) else { return false }
        guard expectedActiveContextId == nil || expectedActiveContextId == contextId,
              active == token else { return false }
        guard let data = defaults.data(forKey: ActiveVerifiedSinkEpochStore.liveActivityGenerationKey),
              let existing = try? JSONDecoder().decode(VerifiedSinkGenerationRecord.self, from: data) else {
            return true
        }
        guard existing.epoch == token.epoch, existing.contextId == contextId else { return false }
        return generation >= existing.generation
    }

    private func recordVerifiedGeneration(_ input: DriveInput, token: VerifiedSinkToken) -> Bool {
        guard let contextId = input.verifiedContextId,
              let generation = input.verifiedProjectionGeneration,
              let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else {
            return false
        }
        guard contextId == token.contextId else { return false }
        let result = ActiveVerifiedSinkEpochStore.commitIfCurrent(
            token: token,
            generation: generation,
            defaults: defaults,
            generationKey: ActiveVerifiedSinkEpochStore.liveActivityGenerationKey,
            writeAndReadBackPayload: { _ in true }
        )
        return result == .published || result == .alreadyCurrent
    }

    /// Suspend the tokenless live lane before a source transition. Connectivity
    /// callbacks cannot reopen this lifecycle gate.
    func suspendForSourceTransition() async {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif
        let input = DriveInput(
            bpm: nil,
            recovery: nil,
            connected: false,
            effort: nil,
            verifiedContextId: nil,
            verifiedProjectionGeneration: nil,
            workoutIsActive: false,
            workoutProjection: { nil }
        )
        _ = try? await serializedPublication.submitBarrier(input, suspendLifecycle: true)
    }

    /// Reopen lifecycle admission only for the App Group's active verified sink.
    /// The source-transition adapter calls this after activation is durable.
    func activateVerifiedSink(contextId: String, epoch: UInt64) -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults)
                == VerifiedSinkToken(epoch: epoch, contextId: contextId) else {
            return false
        }
        serializedPublication.activateLifecycleSubmissions()
        return true
    }

    func end() async {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif
        let input = DriveInput(
            bpm: nil,
            recovery: nil,
            connected: false,
            effort: nil,
            verifiedContextId: nil,
            verifiedProjectionGeneration: nil,
            workoutIsActive: false,
            workoutProjection: { nil }
        )
        serializedPublication.setConnectivityAvailable(false)
        _ = try? await serializedPublication.submitBarrier(input)
    }

    private func performEnd() async {
        for existing in Activity<NOOPActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        resetCachedState()
    }

    /// One trace line: source, mode, result, reason, token state and whether health was removed. Never a value or a context.
    private func trace(_ input: DriveInput, _ result: String, _ reason: String? = nil) {
        var line = "\(input.source.rawValue) \(input.workoutIsActive ? "workout" : "passive") \(result)"
        if let reason { line += " \(reason)" }
        if let tokenState = input.tokenState { line += " token=\(tokenState.rawValue)" }
        if let stripped = input.healthStripped { line += " health=stripped(\(stripped))" }
        traceLog.record(line)
    }

    private func logExit(_ reason: String) {
        guard reason != lastLoggedExit else { return }
        lastLoggedExit = reason
        NSLog("NOOP LiveActivity: %@", reason)
    }

    /// `ended` and `dismissed` are the states an activity cannot come back from; every other state is still showing.
    private static func disappearance(_ state: ActivityState) -> LiveActivityRestartPolicy.Disappearance? {
        switch state {
        case .ended: return .ended
        case .dismissed: return .dismissed
        default: return nil
        }
    }

    /// Enough of the activity's identifier to match it with the system's log. It carries nothing about the wearer.
    private static func shortId(_ activity: Activity<NOOPActivityAttributes>) -> String {
        String(activity.id.prefix(8))
    }

    /// Remembers whether the activity reported `ended` before it went, which tells a system end from a person's swipe.
    private func observeState(of activity: Activity<NOOPActivityAttributes>) {
        stateObserver?.cancel()
        let id = activity.id
        stateObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended {
                self?.endObserved.insert(id)
            }
        }
    }

    private func resetCachedState() {
        pauseEdges.reset()
        activity = nil
        stateObserver?.cancel()
        stateObserver = nil
        endObserved.removeAll()
        lastModeWasWorkout = nil
        workoutStateCache.clear()
        lastContentState = nil
        lastPush = .distantPast
    }

    #if DEBUG
    /// `paused` starts the fixture already paused (three minutes ago), for the Lock Screen's paused state.
    func startComponent41QA(paused: Bool = false) async {
        guard authInfo.areActivitiesEnabled else { return }
        await end()
        serializedPublication.setConnectivityAvailable(true)
        serializedPublication.activateLifecycleSubmissions()
        component41QAMode = true
        let state = NOOPActivityAttributes.ContentState(
            bpm: 152,
            recovery: 78,
            bonded: true,
            effort: 6.8,
            sport: "Outdoor Run",
            workoutStartedAt: Date().addingTimeInterval(-2_052),
            strainBuilding: false,
            calories: 438,
            hrTrace: [88, 96, 108, 121, 115, 132, 146, 139, 152, 144, 158, 152],
            zoneSeconds: [180, 620, 1_180, 650, 104],
            maxHR: 187,
            isPaused: paused ? true : nil,
            pausedAt: paused ? Date().addingTimeInterval(-180) : nil
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
