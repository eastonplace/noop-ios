import XCTest
@testable import ReceiptLiftFeature

private actor NotificationLoadGate {
    private var loadContinuation: CheckedContinuation<Data?, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func load() async -> Data? {
        await withCheckedContinuation { continuation in
            loadContinuation = continuation
            startedContinuation?.resume(); startedContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if loadContinuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func release(_ data: Data?) { loadContinuation?.resume(returning: data); loadContinuation = nil }
}

@MainActor
final class LiftNotificationRestorationTests: XCTestCase {
    func testDelayedActiveSessionRestoreIsNotTreatedAsEmptyReadyState() async throws {
        let session = LiftSession(id: UUID(), routineID: nil, title: "Restored", startedAt: Date(), endedAt: nil, sets: [])
        let envelope = LiftDataEnvelope(schemaVersion: 2, starterBankVersion: 1, userExercises: [], routines: [],
            scheduledWorkouts: [], sessions: [], activeSession: session, restTimerEndDate: nil,
            workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil,
            activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let gate = NotificationLoadGate()
        let coordinator = ReceiptLiftCoordinator(load: { await gate.load() }, save: { _, _ in }, canStart: { true })
        XCTAssertFalse(coordinator.notificationRestorationComplete)
        let loading = Task { await coordinator.load() }
        await gate.waitUntilStarted()
        XCTAssertFalse(coordinator.notificationRestorationComplete)
        await gate.release(data)
        await loading.value
        XCTAssertTrue(coordinator.notificationRestorationComplete)
        XCTAssertTrue(coordinator.hasActiveSession)
        coordinator.discard()
    }
    func testPlanEditBackRetainsExplicitTimeAndAdvancesSavedRevision() async throws {
        let coordinator = ReceiptLiftCoordinator(load: { nil }, save: { _, _ in }, canStart: { true })
        await coordinator.load()
        let date = Date().addingTimeInterval(86400)
        let original = coordinator.store.scheduleWorkout(routineID: UUID(), at: date, note: "", notificationTimeExplicit: true)
        var edited = original; edited.plannedAt = date.addingTimeInterval(3600)
        coordinator.store.updateScheduledWorkout(edited)
        edited.plannedAt = date
        coordinator.store.updateScheduledWorkout(edited)
        let restored = try XCTUnwrap(coordinator.notificationPlans.first)
        XCTAssertEqual(restored.plannedAt, date)
        XCTAssertTrue(restored.hasExplicitTime)
        XCTAssertEqual(restored.revision, 3)
        coordinator.discard()
    }
}
