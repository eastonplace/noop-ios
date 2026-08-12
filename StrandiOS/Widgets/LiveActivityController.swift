#if os(iOS)
import Foundation
import NoopPhase34Core
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
        let workoutProjection: () -> WorkoutLiveActivityState?
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
            await self?.performEnd()
            if let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) {
                ActiveSinkEpochRecovery.clearLiveActivityGeneration(defaults: defaults)
            }
        })

    private var cachedWorkoutState: WorkoutLiveActivityState?
    private var lastWorkoutProjectionAt: Date = .distantPast
    private var lastContentState: NOOPActivityAttributes.ContentState?
    #if DEBUG
    private var component41QAMode = false
    #endif

    private static let staleAfter: TimeInterval = 120
    private static let unchangedHeartbeatInterval: TimeInterval = 30

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

        let token: VerifiedSinkToken? = {
            guard let contextId = verifiedContextId,
                  verifiedProjectionGeneration != nil,
                  let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
                  let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
                  active.contextId == contextId else { return nil }
            return active
        }()
        let carriesVerifiedHealth = recovery != nil
            || effort != nil
            || verifiedContextId != nil
            || verifiedProjectionGeneration != nil
        guard !carriesVerifiedHealth || token != nil else {
            // Never downgrade a health-bearing update into the tokenless live lane.
            // A stale source/context must wait for the matching verified generation.
            return
        }
        let input = DriveInput(
            bpm: bpm,
            recovery: recovery,
            connected: connected,
            effort: effort,
            verifiedContextId: verifiedContextId,
            verifiedProjectionGeneration: verifiedProjectionGeneration,
            workoutIsActive: workoutIsActive ?? LiveActivityWorkoutStatus.isActive,
            workoutProjection: workout
        )
        if connected {
            serializedPublication.setConnectivityAvailable(true)
            serializedPublication.submitLive(input, token: token)
        } else {
            serializedPublication.submitConnectivityBarrier(input)
        }
    }

    private func reconcile(
        _ input: DriveInput,
        expectedActiveContextId: String? = nil,
        expectedToken: VerifiedSinkToken? = nil
    ) async throws -> ExternalSinkPublicationResult {
        guard expectedActiveContextId == nil || expectedActiveContextId == input.verifiedContextId else {
            return .superseded
        }
        if let expectedToken {
            guard input.verifiedContextId == expectedToken.contextId,
                  isCurrentSinkToken(expectedToken) else { return .superseded }
        }
        guard authInfo.areActivitiesEnabled else { return .notApplicable }

        if activity == nil, let existing = Activity<NOOPActivityAttributes>.activities.first {
            activity = existing
            lastModeWasWorkout = existing.content.state.isWorkout
            lastContentState = existing.content.state
            lastPush = .distantPast
        }

        guard UnitPrefs.liveActivityEnabled(), input.connected else {
            await performEnd()
            return .notApplicable
        }
        guard input.bpm != nil else { return .notApplicable }

        let desiredModeIsWorkout = input.workoutIsActive
        var now = Date()
        guard LiveActivityPushPolicy.shouldPush(
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
                    cachedWorkoutState = nil
                    lastWorkoutProjectionAt = .distantPast
                    return .notApplicable
                }
            }
        } else {
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
            if let expectedToken {
                guard acceptsVerifiedGeneration(
                    input,
                    expectedActiveContextId: expectedActiveContextId,
                    token: expectedToken
                ) else { return .superseded }
            }
            if state == lastContentState,
               heartbeatElapsed >= 0,
               heartbeatElapsed < Self.unchangedHeartbeatInterval {
                if let expectedToken,
                   !recordVerifiedGeneration(input, token: expectedToken) { return .superseded }
                return .alreadyCurrent
            }
            await activity.update(ActivityContent(state: state, staleDate: staleDate))
            if let expectedToken,
               !recordVerifiedGeneration(input, token: expectedToken) { return .superseded }
            lastPush = now
            lastContentState = state
            lastModeWasWorkout = desiredModeIsWorkout
            return .published
        } else {
            do {
                if let expectedToken {
                    guard acceptsVerifiedGeneration(
                        input,
                        expectedActiveContextId: expectedActiveContextId,
                        token: expectedToken
                    ) else { return .superseded }
                }
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(
                        title: workoutState?.sport ?? String(localized: "Live HR")
                    ),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                if let expectedToken,
                   !recordVerifiedGeneration(input, token: expectedToken) {
                    await performEnd()
                    return .superseded
                }
                lastPush = now
                lastContentState = state
                lastModeWasWorkout = desiredModeIsWorkout
                return .published
            } catch {
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
            workoutProjection: workoutProjection
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

    private func resetCachedState() {
        activity = nil
        lastModeWasWorkout = nil
        cachedWorkoutState = nil
        lastWorkoutProjectionAt = .distantPast
        lastContentState = nil
        lastPush = .distantPast
    }

    #if DEBUG
    func startComponent41QA() async {
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
