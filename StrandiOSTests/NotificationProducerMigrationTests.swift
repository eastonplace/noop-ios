import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class NotificationProducerMigrationTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_800_360_000)

    private final class Center: NotificationCenterClient {
        var requests: [String: NotificationDeliveryRequest] = [:]
        var additions = 0
        var removed: Set<String> = []
        var failure: Error?
        var acceptsBeforeFailure = false
        var duringAdd: (@MainActor () async -> Void)?
        func isAuthorized() async -> Bool { true }
        func pendingIdentifiers() async -> Set<String> { Set(requests.keys) }
        func deliveredIdentifiers() async -> Set<String> { [] }
        func add(_ request: NotificationDeliveryRequest) async throws {
            additions += 1
            if let failure, !acceptsBeforeFailure { throw failure }
            requests[request.identifier] = request
            await duringAdd?()
            if let failure { throw failure }
        }
        func remove(_ identifiers: [String], delivered: Bool) async {
            removed.formUnion(identifiers)
            identifiers.forEach { requests[$0] = nil }
        }
    }

    private func coordinator(_ store: WhoopStore, _ center: Center) -> NotificationCoordinator {
        NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.chargeReminder: .notify, .batteryFull: .notify], quietHoursEnabled: false) },
            context: { NotificationCoordinator.productionContext(sourceContext: "source",
                logicalDay: NotificationFactBuilder.dayKey(self.now), activeWorkout: false) },
            store: { store }, dryRun: { false })
    }

    private func observe(_ pct: Int, runtime: Double? = nil, charging: Bool? = nil, device: String = "strap-a",
                         enabled: Bool = true, predictive: Bool = true,
                         store: WhoopStore, coordinator: NotificationCoordinator) async {
        await BatteryNotifier.observe(deviceID: device, sourceContext: "source", pct: pct, remainingHours: runtime,
            charging: charging, enabled: enabled, predictiveEnabled: predictive, now: now,
            store: store, coordinator: coordinator)
    }

    func testLowAndRuntimeCoalesceAndNewReadingDoesNotWithdrawGenericAlert() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, runtime: 6, store: store, coordinator: runtime)
        let first = try XCTUnwrap(center.requests.values.first?.candidate)
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(first.group, .chargeReminder)
        XCTAssertEqual(first.destination, .device(id: "strap-a"))
        // A restarted coordinator and missing/invalid runtime must keep the same episode.
        now = now.addingTimeInterval(60)
        await observe(11, runtime: .nan, store: store, coordinator: coordinator(store, center))
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.requests.values.first?.candidate.occurrenceID, first.occurrenceID)
        XCTAssertTrue(center.removed.isEmpty)
    }

    func testUnknownRuntimeAndChargingDoNotClearConcernMeasuredRecoveryRearms() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(40, runtime: 6, store: store, coordinator: runtime)
        let first = try XCTUnwrap(center.requests.values.first?.candidate)
        await runtime.snooze(first)
        await runtime.snooze(first)
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(center.additions, 2, "Repeated actions must not add another requested reminder")
        now = now.addingTimeInterval(60)
        await observe(40, charging: true, store: store, coordinator: runtime)
        await observe(40, runtime: -1, store: store, coordinator: runtime)
        let unchanged = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        XCTAssertEqual(first.evidenceRevision, unchanged)
        XCTAssertTrue(center.requests.isEmpty, "Confirmed charging cancels the action without rearming its episode")
        await observe(40, runtime: 36, store: store, coordinator: runtime)
        XCTAssertTrue(center.requests.isEmpty, "Recovery cancels both the original and user-requested reminder")
        now = now.addingTimeInterval(4 * 3600)
        await observe(40, runtime: 6, store: store, coordinator: runtime)
        XCTAssertNotEqual(center.requests.values.first?.candidate.occurrenceID, first.occurrenceID)
        XCTAssertEqual(center.additions, 3)
    }

    func testPercentageOnlyDeviceRearmsAtMeasuredRecoveryAndFullChargeWithdrawsBelow100() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, predictive: false, store: store, coordinator: runtime)
        let low = try XCTUnwrap(center.requests.values.first?.candidate)
        await observe(25, predictive: false, store: store, coordinator: runtime)
        XCTAssertTrue(center.requests.isEmpty)
        now = now.addingTimeInterval(4 * 3600)
        await observe(100, predictive: false, store: store, coordinator: runtime)
        let full = try XCTUnwrap(center.requests.values.first?.candidate)
        XCTAssertEqual(full.group, .batteryFull)
        XCTAssertNotEqual(full.attentionKey, low.attentionKey)
        XCTAssertFalse(NotificationCoordinator.supportsSnooze(full))
        await observe(99, predictive: false, store: store, coordinator: runtime)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertTrue(center.removed.contains(NotificationCoordinator.requestIdentifier(full.occurrenceID)))
        now = now.addingTimeInterval(4 * 3600)
        await observe(10, predictive: false, store: store, coordinator: runtime)
        let rearmed = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        XCTAssertNotNil(rearmed)
        XCTAssertNotEqual(rearmed, low.evidenceRevision)
        XCTAssertEqual(center.additions, 2, "Rearming must still respect the shared daily proactive budget")
    }

    func testDeviceEpisodesAreIndependentAndInvalidObservationsDoNotClearThem() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, device: "strap-a", store: store, coordinator: runtime)
        await observe(10, device: "strap-b", store: store, coordinator: runtime)
        let a = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        let b = try await store.notificationEpisode(deviceID: "strap-b", family: "charge", observationIsActive: nil, now: now)
        XCTAssertNotNil(a); XCTAssertNotNil(b); XCTAssertNotEqual(a, b)
        await observe(101, device: "strap-b", store: store, coordinator: runtime)
        await observe(25, device: "strap-a", store: store, coordinator: runtime)
        let clearedA = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        let unchangedB = try await store.notificationEpisode(deviceID: "strap-b", family: "charge", observationIsActive: nil, now: now)
        XCTAssertNil(clearedA)
        XCTAssertEqual(unchangedB, b)
    }

    func testChargeSnoozeRetainsExpiryIsSingleUseAndHasBoundedKnownFailureRetry() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, runtime: 6, store: store, coordinator: runtime)
        let original = try XCTUnwrap(center.requests.values.first?.candidate)
        let payload = NotificationCoordinator.userInfo(for: original)
        let encoded = try XCTUnwrap(payload["noopNotificationSnoozeCandidate"] as? String)
        let decoded = try JSONDecoder().decode(NotificationCandidate.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded, original)
        let snoozed = try XCTUnwrap(NotificationCoordinator.snoozeCandidate(original, now: now))
        XCTAssertEqual(snoozed.expiresAt, original.expiresAt)
        XCTAssertEqual(snoozed.scheduledAt, now.addingTimeInterval(900))
        XCTAssertEqual(snoozed.lane, .explicitReminder)
        XCTAssertFalse(NotificationCoordinator.supportsSnooze(snoozed))
        XCTAssertNil(NotificationCoordinator.snoozeCandidate(original, now: original.expiresAt.addingTimeInterval(-900)))
        XCTAssertNil(NotificationCoordinator.snoozeCandidate(original, now: original.expiresAt))
        center.failure = NotificationSubmissionError.knownFailure
        await runtime.snooze(original)
        await runtime.snooze(original)
        XCTAssertEqual(center.additions, 3, "Original plus at most two snooze add attempts")
        center.failure = nil
        await runtime.snooze(original)
        XCTAssertEqual(center.additions, 3, "A failed snooze must not reset its retry allowance")
    }

    func testSnoozeRequiresAcceptedOriginalAndRejectsSourceChangeAndExpiry() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, store: store, coordinator: runtime)
        let original = try XCTUnwrap(center.requests.values.first?.candidate)
        let otherSource = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.chargeReminder: .notify], quietHoursEnabled: false) },
            context: { .init(sourceContext: "other", logicalDay: NotificationFactBuilder.dayKey(self.now)) },
            store: { store }, dryRun: { false })
        await otherSource.snooze(original)
        XCTAssertEqual(center.additions, 1)
        await runtime.withdraw(occurrenceID: original.occurrenceID)
        await runtime.snooze(original)
        XCTAssertEqual(center.additions, 1)
        now = original.expiresAt
        await runtime.snooze(original)
        XCTAssertEqual(center.additions, 1)
        XCTAssertNotNil(runtime.setupStatus)
    }

    func testMeasuredRecoveryDuringSnoozeAddWithdrawsAcceptedRequest() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, store: store, coordinator: runtime)
        let original = try XCTUnwrap(center.requests.values.first?.candidate)
        center.duringAdd = {
            _ = try? await store.notificationEpisode(deviceID: original.subjectID, family: "charge",
                observationIsActive: false, now: self.now)
        }
        await runtime.snooze(original)
        let identifier = NotificationCoordinator.requestIdentifier(original.occurrenceID + ":snooze")
        XCTAssertEqual(center.additions, 2)
        XCTAssertNil(center.requests[identifier])
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first { $0.occurrenceID == original.occurrenceID + ":snooze" }?.state, .withdrawn)
    }

    func testNewerChargingObservationBeforeOlderProducerProcessesPreventsObsoleteSubmission() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await BatteryNotifier.observe(deviceID: "strap-a", sourceContext: "source", pct: 10,
            remainingHours: 6, charging: false, enabled: true, predictiveEnabled: true, now: now,
            store: store, coordinator: runtime, beforeProcess: {
                await self.observe(10, runtime: 6, charging: true, store: store, coordinator: runtime)
            })
        XCTAssertEqual(center.additions, 0)
        let active = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        XCTAssertNotNil(active, "Charging must not rearm the durable concern")
        let records = try await store.notificationRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testUnknownPacketCannotDiscardConfirmedChargingCancellationBeforeEpisodeRead() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store, center)
        await observe(10, runtime: 6, store: store, coordinator: runtime)
        let original = try XCTUnwrap(center.requests.values.first?.candidate)
        await runtime.snooze(original)
        XCTAssertEqual(center.requests.count, 2)
        await BatteryNotifier.observe(deviceID: "strap-a", sourceContext: "source", pct: 10,
            remainingHours: 6, charging: true, enabled: true, predictiveEnabled: true, now: now,
            store: store, coordinator: runtime, beforeEpisodeRead: {
                await self.observe(10, runtime: 6, charging: nil, store: store, coordinator: runtime)
            })
        XCTAssertTrue(center.requests.isEmpty, "The latest producer must finish a pending charging cancellation")
        XCTAssertEqual(center.additions, 2)
        let episode = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
        XCTAssertEqual(episode, original.evidenceRevision)
    }

    func testConfirmedChargingDuringAcceptedOrUncertainAddRemovesObsoleteWarningWithoutRearming() async throws {
        for uncertain in [false, true] {
            let store = try await WhoopStore.inMemory()
            let center = Center()
            let runtime = coordinator(store, center)
            center.acceptsBeforeFailure = true
            if uncertain { center.failure = NotificationSubmissionError.uncertain }
            center.duringAdd = {
                await self.observe(10, runtime: 6, charging: true, store: store, coordinator: runtime)
            }
            await observe(10, runtime: 6, charging: false, store: store, coordinator: runtime)
            XCTAssertEqual(center.additions, 1)
            XCTAssertTrue(center.requests.isEmpty)
            let rows = try await store.notificationRecords()
            XCTAssertEqual(rows.first?.state, .withdrawn)
            XCTAssertNotNil(rows.first?.chargedAt)
            let episode = try await store.notificationEpisode(deviceID: "strap-a", family: "charge", observationIsActive: nil, now: now)
            XCTAssertEqual(episode, rows.first?.evidenceRevision)
            center.failure = nil
            center.duringAdd = nil
            await observe(10, runtime: 6, store: store, coordinator: runtime)
            XCTAssertEqual(center.additions, 1, "Charging/unknown changes cannot rearm the same event")
        }
    }
}
