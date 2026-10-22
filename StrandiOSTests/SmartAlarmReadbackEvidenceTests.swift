import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import NOOP

@MainActor
final class SmartAlarmReadbackEvidenceTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_792_620_000)
    private let wakeAt = Date(timeIntervalSince1970: 1_792_666_800)
    private let keys = ["smartAlarm.lastEvidence.v1", "alarm.lastReportedEpoch",
                        "alarm.lastReportedAt", "alarm.lastArmAt", "alarm.lastArmSentEpoch",
                        "alarm.lastArmDeviceID", "alarm.lastReportedDeviceID",
                        "alarm.lastArmRequestID", "alarm.lastReportedRequestID", "alarm.lastFiredAt",
                        "alarm.rejectStreak"]

    private func withEvidence(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(sentAt.timeIntervalSince1970, forKey: "alarm.lastArmAt")
        defaults.set(Int(wakeAt.timeIntervalSince1970), forKey: "alarm.lastArmSentEpoch")
        defaults.set("strap-A", forKey: "alarm.lastArmDeviceID")
        defaults.set("request-A", forKey: "alarm.lastArmRequestID")
        SmartAlarmEvidenceStore.save(.init(
            mode: .exactTime, trigger: .configured, decision: .wait,
            reason: "latestEndpointFailSafe", evaluatedAt: sentAt,
            inputObservedAt: nil, sleepSource: nil, sleepModelVersion: nil,
            forecastSource: nil, forecastModelVersion: nil,
            requestedWakeAt: wakeAt, windowEndpoint: wakeAt,
            strapReportedArmedAt: nil, observedStrapWakeAt: nil,
            actuation: .endpointArmed, evaluatorModelVersion: "test"))
        try body()
    }

    private func report(epoch: Int, at: Date? = nil, device: String = "strap-A",
                        request: String = "request-A") {
        let defaults = UserDefaults.standard
        defaults.set(epoch, forKey: "alarm.lastReportedEpoch")
        defaults.set((at ?? sentAt.addingTimeInterval(1)).timeIntervalSince1970,
                     forKey: "alarm.lastReportedAt")
        defaults.set(device, forKey: "alarm.lastReportedDeviceID")
        defaults.set(request, forKey: "alarm.lastReportedRequestID")
    }

    func testNoAlarmReadbackEndsPendingWithoutClaimingArmed() {
        withEvidence {
            report(epoch: 0)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testMismatchedReadbackEndsPendingWithoutClaimingArmed() {
        withEvidence {
            report(epoch: 1_792_670_400) // One hour after the requested 07:00 wake.
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testMissingReadbackStopsPendingAfterDeadline() {
        withEvidence {
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testMatchingReadbackFromAnotherStrapCannotConfirm() {
        withEvidence {
            report(epoch: 1_792_666_800, device: "strap-B")
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testDelayedPreviousRequestCannotConfirmCurrentArm() {
        withEvidence {
            report(epoch: 1_792_666_800, request: "request-old")
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testMatchingCurrentRequestConfirmsWithinTolerance() {
        withEvidence {
            report(epoch: 1_792_666_830)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt,
                           Date(timeIntervalSince1970: 1_792_666_830))
        }
    }

    func testCurrentNoAlarmReadbackRevokesEarlierConfirmation() {
        withEvidence {
            report(epoch: 1_792_666_800)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            report(epoch: 0, at: sentAt.addingTimeInterval(3))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testSourceChangeRevokesPreviousStrapConfirmation() {
        withEvidence {
            report(epoch: 1_792_666_800)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            UserDefaults.standard.set("strap-B", forKey: "alarm.lastArmDeviceID")
            UserDefaults.standard.set("request-B", forKey: "alarm.lastArmRequestID")
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(3))
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testMissingReadbackRemainsPendingBeforeDeadline() {
        withEvidence {
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .endpointArmed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testStaleRequestCannotRecordOrInvalidateNewArm() {
        withEvidence {
            let old = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            let current = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-B",
                targetEpoch: 1_792_666_800, sentAt: sentAt.addingTimeInterval(1))
            SmartAlarmEvidenceStore.beginReadback(old)
            SmartAlarmEvidenceStore.beginReadback(current)
            XCTAssertFalse(SmartAlarmEvidenceStore.recordReadback(
                epoch: 1_792_666_800, request: old, at: sentAt.addingTimeInterval(2)))
            SmartAlarmEvidenceStore.invalidateReadback(requestID: old.id)
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 0, request: current, at: sentAt.addingTimeInterval(3)))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "alarm.lastReportedEpoch"), 0)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "alarm.lastReportedDeviceID"), "strap-B")
        }
    }

    func testRetryRegistrationPreservesOriginalDeadlineAndObservedResult() {
        withEvidence {
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            SmartAlarmEvidenceStore.beginReadback(request)
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 0, request: request, at: sentAt.addingTimeInterval(1)))
            SmartAlarmEvidenceStore.beginReadback(request)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "alarm.lastReportedEpoch") as? Int, 0)
            XCTAssertEqual(UserDefaults.standard.double(forKey: "alarm.lastArmAt"),
                           1_792_620_000)
        }
    }

    func testOwnedLateReadbackPublishesAfterItsEvidenceIsStored() {
        withEvidence {
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            SmartAlarmEvidenceStore.beginReadback(request)
            let delivered = expectation(description: "Owned readback refresh event")
            let token = NotificationCenter.default.addObserver(
                forName: Notification.Name("noop.smartAlarm.readbackDidChange"), object: nil,
                queue: .main) { _ in
                    XCTAssertEqual(UserDefaults.standard.string(forKey: "alarm.lastReportedRequestID"),
                                   request.id.uuidString)
                    XCTAssertEqual(UserDefaults.standard.integer(forKey: "alarm.lastReportedEpoch"),
                                   1_792_666_800)
                    delivered.fulfill()
                }
            defer { NotificationCenter.default.removeObserver(token) }
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 1_792_666_800, request: request, at: sentAt.addingTimeInterval(12)))
            wait(for: [delivered], timeout: 0.1)
        }
    }

    private func adaptiveEvidence(evaluatedAt: Date) -> SmartAlarmEvidence {
        .init(mode: .sleepGoal, trigger: .dataRefresh, decision: .wakeNow,
              reason: "sleepGoalMet", evaluatedAt: evaluatedAt,
              inputObservedAt: evaluatedAt, sleepSource: "noop-live-stager",
              sleepModelVersion: "test", forecastSource: nil, forecastModelVersion: nil,
              requestedWakeAt: wakeAt, windowEndpoint: wakeAt.addingTimeInterval(60),
              strapReportedArmedAt: nil, observedStrapWakeAt: nil,
              actuation: .sentToConnectedStrap, evaluatorModelVersion: "test")
    }

    func testAdaptiveEvaluationBeforeArmBindsActualRequestAndConfirms() {
        withEvidence {
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt.addingTimeInterval(1))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 1_792_666_800, request: request, at: sentAt.addingTimeInterval(2)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(3))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armRequestID, request.id.uuidString)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armSentAt, request.sentAt)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.evaluatedAt, sentAt)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt, wakeAt)
        }
    }

    func testRepeatedAdaptiveEvaluationRetainsExistingRequestAndConfirmation() {
        withEvidence {
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt.addingTimeInterval(1))
            SmartAlarmEvidenceStore.beginReadback(request)
            var first = adaptiveEvidence(evaluatedAt: sentAt)
            first.armRequestID = request.id.uuidString
            first.armSourceID = request.sourceID
            first.armSentAt = request.sentAt
            SmartAlarmEvidenceStore.save(first)
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 1_792_666_800, request: request, at: sentAt.addingTimeInterval(2)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(3))
            // A repeated computation may have started before the original actuation completed.
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt.addingTimeInterval(0.5)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armRequestID, request.id.uuidString)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armSourceID, "strap-A")
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armSentAt, request.sentAt)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt, wakeAt)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .sentToConnectedStrap)
        }
    }

    func testLateAdaptiveConfirmationPreservesEarlyActuationForDedupe() {
        withEvidence {
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(
                epoch: 1_792_666_800, request: request, at: sentAt.addingTimeInterval(12)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(12))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt, wakeAt)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .sentToConnectedStrap)
        }
    }

    private func persistedEarlyWakeAttempted() throws -> Bool? {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "smartAlarm.lastEvidence.v1"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return record["earlyWakeAttempted"] as? Bool
    }

    private func persistedEarlyWakeSourceID() throws -> String? {
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "smartAlarm.lastEvidence.v1"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return record["earlyWakeSourceID"] as? String
    }

    func testMissingReadbackPreservesEarlyWakeAttemptWithoutClaimingArmed() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.readbackStatus, .unconfirmed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true,
                           "A missing readback must not permit another early buzz for this endpoint")
        }
    }

    func testNegativeReadbackPreservesLegacyEarlyWakeAttempt() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            let defaults = UserDefaults.standard
            let data = try XCTUnwrap(defaults.data(forKey: "smartAlarm.lastEvidence.v1"))
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "earlyWakeAttempted")
            legacy.removeValue(forKey: "earlyWakeSourceID")
            defaults.set(try JSONSerialization.data(withJSONObject: legacy),
                         forKey: "smartAlarm.lastEvidence.v1")
            report(epoch: 0)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.readbackStatus, .noAlarm)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
        }
    }

    private func endpointEvaluation(mode: SmartAlarmEvaluator.Mode,
                                    decision: SmartAlarmEvaluator.Decision,
                                    actuation: SmartAlarmEvidence.Actuation,
                                    evaluatedAt: Date,
                                    endpoint: Date? = nil) -> SmartAlarmEvidence {
        let endpoint = endpoint ?? wakeAt
        return .init(mode: mode, trigger: .dataRefresh, decision: decision,
                     reason: "currentEvaluation", evaluatedAt: evaluatedAt,
                     inputObservedAt: nil, sleepSource: nil, sleepModelVersion: nil,
                     forecastSource: nil, forecastModelVersion: nil,
                     requestedWakeAt: endpoint, windowEndpoint: endpoint,
                     strapReportedArmedAt: nil, observedStrapWakeAt: nil,
                     actuation: actuation, evaluatorModelVersion: "test")
    }

    func testWaitEvaluationRetainsCurrentConfirmedEndpointDelivery() {
        withEvidence {
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed, evaluatedAt: sentAt))
            report(epoch: 1_792_666_800)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(3)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(evidence?.evaluatedAt, sentAt.addingTimeInterval(3))
            XCTAssertEqual(evidence?.decision, .wait)
            XCTAssertEqual(evidence?.armRequestID, "request-A")
            XCTAssertEqual(evidence?.armSourceID, "strap-A")
            XCTAssertEqual(evidence?.actuation, .endpointArmed)
            XCTAssertEqual(evidence?.readbackStatus, .confirmed)
            XCTAssertEqual(evidence?.strapReportedArmedAt, wakeAt)
        }
    }

    func testUnavailableEvaluationRetainsCurrentPendingEndpointDelivery() {
        withEvidence {
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .inTheGreen, decision: .wait, actuation: .endpointArmed, evaluatedAt: sentAt))
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .inTheGreen, decision: .unavailable, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(1)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(evidence?.decision, .unavailable)
            XCTAssertEqual(evidence?.armRequestID, "request-A")
            XCTAssertEqual(evidence?.armSourceID, "strap-A")
            XCTAssertEqual(evidence?.actuation, .endpointArmed)
            XCTAssertEqual(evidence?.readbackStatus, .pending)
            XCTAssertNil(evidence?.strapReportedArmedAt)
        }
    }

    func testWaitEvaluationRetainsFailedEarlyWakeAttemptAndItsActualTarget() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            report(epoch: 0)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(3), endpoint: wakeAt.addingTimeInterval(60)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(evidence?.decision, .wait)
            XCTAssertEqual(evidence?.requestedWakeAt, wakeAt)
            XCTAssertEqual(evidence?.actuation, .failed)
            XCTAssertEqual(evidence?.readbackStatus, .noAlarm)
            XCTAssertEqual(evidence?.armRequestID, "request-A")
            XCTAssertNil(evidence?.strapReportedArmedAt)
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
        }
    }

    func testWaitEvaluationDoesNotInheritSupersededOwnerConfirmation() {
        withEvidence {
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed, evaluatedAt: sentAt))
            report(epoch: 1_792_666_800)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            UserDefaults.standard.set("request-B", forKey: "alarm.lastArmRequestID")
            UserDefaults.standard.set("strap-B", forKey: "alarm.lastArmDeviceID")
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(3)))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(evidence?.actuation, .notRequested)
            XCTAssertNil(evidence?.armRequestID)
            XCTAssertNil(evidence?.armSourceID)
            XCTAssertNil(evidence?.strapReportedArmedAt)
        }
    }

    func testNextEndpointDoesNotInheritEarlierWakeAttempt() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(3), endpoint: wakeAt.addingTimeInterval(86_400)))
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.armRequestID)
            XCTAssertNotEqual(try persistedEarlyWakeAttempted(), true)
        }
    }

    func testSameSourceEndpointRearmPreservesAttemptWithoutInheritingFailedReadback() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            report(epoch: 0)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(3))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                evaluatedAt: request.sentAt, endpoint: endpoint))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(evidence?.armRequestID, request.id.uuidString)
            XCTAssertEqual(evidence?.armSourceID, "strap-A")
            XCTAssertEqual(evidence?.armSentAt, request.sentAt)
            XCTAssertEqual(evidence?.requestedWakeAt, endpoint)
            XCTAssertEqual(evidence?.actuation, .endpointArmed)
            XCTAssertEqual(evidence?.readbackStatus, .pending)
            XCTAssertNil(evidence?.strapReportedArmedAt)
        }
    }

    func testSameSourceEndpointRearmDoesNotInheritEarlierConfirmation() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            report(epoch: 1_792_666_800)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(3))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                evaluatedAt: request.sentAt, endpoint: endpoint))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armRequestID, request.id.uuidString)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.readbackStatus, .pending)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testNewSourceEndpointRearmDoesNotInheritEarlierWakeAttempt() throws {
        try withEvidence {
            SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
            report(epoch: 0)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-B",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(3))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                evaluatedAt: request.sentAt, endpoint: endpoint))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(4))
            XCTAssertNotEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armRequestID, request.id.uuidString)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armSourceID, "strap-B")
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    private func persistAlreadyFailedLegacyEvidence(_ evidence: SmartAlarmEvidence) throws -> SmartAlarmEvidence {
        SmartAlarmEvidenceStore.save(evidence)
        let defaults = UserDefaults.standard
        let data = try XCTUnwrap(defaults.data(forKey: "smartAlarm.lastEvidence.v1"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "earlyWakeAttempted")
        legacy.removeValue(forKey: "earlyWakeSourceID")
        legacy["actuation"] = "failed"
        legacy["readbackStatus"] = "unconfirmed"
        defaults.set(try JSONSerialization.data(withJSONObject: legacy),
                     forKey: "smartAlarm.lastEvidence.v1")
        return try XCTUnwrap(SmartAlarmEvidenceStore.latest)
    }

    func testAlreadyFailedLegacyAdaptiveReadbackRetainsEarlyWakeAttempt() throws {
        try withEvidence {
            let decoded = try persistAlreadyFailedLegacyEvidence(adaptiveEvidence(evaluatedAt: sentAt))
            XCTAssertEqual(decoded.actuation, .failed)
            XCTAssertTrue(decoded.hasAttemptedEarlyWake,
                          "An upgrade must not permit another buzz after an earlier readback failed")
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testAlreadyFailedLegacyAttemptSurvivesSameSourceReplacementRequest() throws {
        try withEvidence {
            _ = try persistAlreadyFailedLegacyEvidence(adaptiveEvidence(evaluatedAt: sentAt))
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(11))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                evaluatedAt: request.sentAt, endpoint: endpoint))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(12))
            let evidence = SmartAlarmEvidenceStore.latest
            XCTAssertEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(evidence?.armRequestID, request.id.uuidString)
            XCTAssertEqual(evidence?.readbackStatus, .pending)
            XCTAssertEqual(evidence?.actuation, .endpointArmed)
            XCTAssertNil(evidence?.strapReportedArmedAt)
        }
    }

    func testFailedLegacyEndpointArmDoesNotInventEarlyWakeAttempt() throws {
        try withEvidence {
            let decoded = try persistAlreadyFailedLegacyEvidence(endpointEvaluation(
                mode: .sleepGoal, decision: .wakeNow, actuation: .endpointArmed, evaluatedAt: sentAt))
            XCTAssertFalse(decoded.hasAttemptedEarlyWake)
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
            XCTAssertNotEqual(try persistedEarlyWakeAttempted(), true)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.actuation, .failed)
        }
    }

    func testFailedLegacyTargetOutsideAdaptiveWindowDoesNotInventEarlyWakeAttempt() throws {
        for target in [wakeAt.addingTimeInterval(61), wakeAt.addingTimeInterval(-1_800)] {
            try withEvidence {
                var evidence = adaptiveEvidence(evaluatedAt: sentAt)
                evidence.requestedWakeAt = target
                let decoded = try persistAlreadyFailedLegacyEvidence(evidence)
                XCTAssertFalse(decoded.hasAttemptedEarlyWake)
                SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(10))
                XCTAssertNotEqual(try persistedEarlyWakeAttempted(), true)
            }
        }
    }

    private func saveDisconnectedQueuedEvaluation(decision: SmartAlarmEvaluator.Decision) throws {
        let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
            targetEpoch: 1_792_666_800, sentAt: sentAt)
        SmartAlarmEvidenceStore.beginReadback(request)
        SmartAlarmEvidenceStore.save(adaptiveEvidence(evaluatedAt: sentAt))
        XCTAssertTrue(SmartAlarmEvidenceStore.recordReadback(epoch: 0, request: request,
            at: sentAt.addingTimeInterval(1)))
        SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
        SmartAlarmEvidenceStore.invalidateReadback(requestID: request.id)
        SmartAlarmEvidenceStore.save(endpointEvaluation(
            mode: .sleepGoal, decision: decision, actuation: .queuedForReconnect,
            evaluatedAt: sentAt.addingTimeInterval(3), endpoint: wakeAt.addingTimeInterval(60)))
    }

    func testOfflineQueuedEvaluationRetainsAttemptSourceWithoutOldDelivery() throws {
        for decision in [SmartAlarmEvaluator.Decision.wait, .wakeNow] {
            try withEvidence {
                try saveDisconnectedQueuedEvaluation(decision: decision)
                let queued = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
                XCTAssertTrue(queued.hasAttemptedEarlyWake)
                XCTAssertEqual(try persistedEarlyWakeSourceID(), "strap-A")
                XCTAssertEqual(queued.actuation, .queuedForReconnect)
                XCTAssertNil(queued.armRequestID)
                XCTAssertNil(queued.armSourceID)
                XCTAssertNil(queued.readbackStatus)
                XCTAssertNil(queued.strapReportedArmedAt)
            }
        }
    }

    func testSameSourceReconnectAfterQueuedEvaluationRetainsAttemptOnly() throws {
        for decision in [SmartAlarmEvaluator.Decision.wait, .wakeNow] {
            try withEvidence {
                try saveDisconnectedQueuedEvaluation(decision: decision)
                let endpoint = wakeAt.addingTimeInterval(60)
                let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                    targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(4))
                SmartAlarmEvidenceStore.beginReadback(request)
                SmartAlarmEvidenceStore.save(endpointEvaluation(
                    mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                    evaluatedAt: request.sentAt, endpoint: endpoint))
                SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(5))
                let reconnected = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
                XCTAssertTrue(reconnected.hasAttemptedEarlyWake)
                XCTAssertEqual(try persistedEarlyWakeSourceID(), "strap-A")
                XCTAssertEqual(reconnected.armRequestID, request.id.uuidString)
                XCTAssertEqual(reconnected.armSourceID, "strap-A")
                XCTAssertEqual(reconnected.actuation, .endpointArmed)
                XCTAssertEqual(reconnected.readbackStatus, .pending)
                XCTAssertNil(reconnected.strapReportedArmedAt)
            }
        }
    }

    func testOfflineWaitAfterQueuedEvaluationRetainsAttemptWithoutOldDelivery() throws {
        try withEvidence {
            try saveDisconnectedQueuedEvaluation(decision: .wakeNow)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .notRequested,
                evaluatedAt: sentAt.addingTimeInterval(4), endpoint: wakeAt.addingTimeInterval(60)))
            let waiting = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
            XCTAssertTrue(waiting.hasAttemptedEarlyWake)
            XCTAssertEqual(try persistedEarlyWakeSourceID(), "strap-A")
            XCTAssertEqual(waiting.actuation, .notRequested)
            XCTAssertNil(waiting.armRequestID)
            XCTAssertNil(waiting.armSourceID)
            XCTAssertNil(waiting.strapReportedArmedAt)
        }
    }

    func testOfflineDifferentWindowOrModeClearsEarlierAttempt() throws {
        for (mode, endpoint) in [(SmartAlarmEvaluator.Mode.sleepGoal, wakeAt.addingTimeInterval(86_400)),
                                 (.inTheGreen, wakeAt.addingTimeInterval(60))] {
            try withEvidence {
                try saveDisconnectedQueuedEvaluation(decision: .wakeNow)
                SmartAlarmEvidenceStore.save(endpointEvaluation(
                    mode: mode, decision: .wait, actuation: .queuedForReconnect,
                    evaluatedAt: sentAt.addingTimeInterval(4), endpoint: endpoint))
                XCTAssertFalse(try XCTUnwrap(SmartAlarmEvidenceStore.latest).hasAttemptedEarlyWake)
                XCTAssertNil(try persistedEarlyWakeSourceID())
            }
        }
    }

    func testSourceScopedAttemptSuppressesDuplicateBeforeReplacementDeliveryIsBound() throws {
        try withEvidence {
            try saveDisconnectedQueuedEvaluation(decision: .wakeNow)
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(4))
            SmartAlarmEvidenceStore.beginReadback(request)
            let queued = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
            XCTAssertFalse(SmartAlarmEvidenceStore.isCurrentArm(queued))
            XCTAssertTrue(queued.matchesEarlyWakeAttempt(endpoint: endpoint, mode: .sleepGoal,
                                                         sourceID: "strap-A"))
            XCTAssertFalse(queued.matchesEarlyWakeAttempt(endpoint: endpoint, mode: .sleepGoal,
                                                          sourceID: "strap-B"))
            XCTAssertFalse(queued.matchesEarlyWakeAttempt(endpoint: endpoint, mode: .inTheGreen,
                                                          sourceID: "strap-A"))
            XCTAssertFalse(queued.matchesEarlyWakeAttempt(endpoint: endpoint.addingTimeInterval(86_400),
                                                          mode: .sleepGoal, sourceID: "strap-A"))
            XCTAssertNil(queued.armRequestID)
            XCTAssertNil(queued.readbackStatus)
            XCTAssertNil(queued.strapReportedArmedAt)
        }
    }

    func testDifferentSourceReconnectAfterQueuedEvaluationDoesNotInheritAttempt() throws {
        try withEvidence {
            try saveDisconnectedQueuedEvaluation(decision: .wakeNow)
            let endpoint = wakeAt.addingTimeInterval(60)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-B",
                targetEpoch: Int(endpoint.timeIntervalSince1970), sentAt: sentAt.addingTimeInterval(4))
            SmartAlarmEvidenceStore.beginReadback(request)
            SmartAlarmEvidenceStore.save(endpointEvaluation(
                mode: .sleepGoal, decision: .wait, actuation: .endpointArmed,
                evaluatedAt: request.sentAt, endpoint: endpoint))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(5))
            let reconnected = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
            XCTAssertFalse(reconnected.hasAttemptedEarlyWake)
            XCTAssertNil(try persistedEarlyWakeSourceID())
            XCTAssertEqual(reconnected.armRequestID, request.id.uuidString)
            XCTAssertEqual(reconnected.armSourceID, "strap-B")
            XCTAssertNil(reconnected.strapReportedArmedAt)
        }
    }

    #if os(iOS)
    private func nativeReadbackFrame(origin: UInt8, epoch: UInt32) -> [UInt8] {
        let payload: [UInt8] = [0x01, epoch == 0 ? 0 : 1, UInt8(truncatingIfNeeded: epoch),
            UInt8(truncatingIfNeeded: epoch >> 8), UInt8(truncatingIfNeeded: epoch >> 16),
            UInt8(truncatingIfNeeded: epoch >> 24), 0, 0, 0x04, 0, 0x20]
        return frameFromPayload([origin, 0x01] + payload, type: 36, seq: 0x29, cmd: 67)
    }

    private func bindNativeEvidence(to request: SmartAlarmReadbackRequest) throws {
        var evidence = try XCTUnwrap(SmartAlarmEvidenceStore.latest)
        evidence.armRequestID = nil
        evidence.armSourceID = nil
        evidence.armSentAt = nil
        SmartAlarmEvidenceStore.save(evidence)
        XCTAssertEqual(SmartAlarmEvidenceStore.latest?.armRequestID, request.id.uuidString)
    }

    func testNativeRouterOwnedZeroReadbackRecordsNegativeEvidence() throws {
        try withEvidence {
            let live = LiveState()
            live.logTailPersistence = DebouncedLogTailPersistence(
                tailLimit: 50, loadPersisted: { [] }, persist: { _ in })
            let router = FrameRouter(state: live)
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            router.registerAlarmReadback(request, sequence: 0x42)
            try bindNativeEvidence(to: request)
            let frame = nativeReadbackFrame(origin: 0x42, epoch: 0)
            XCTAssertTrue(parseFrame(frame, family: .whoop4).crcOK == true)
            router.handle(frame: frame)
            SmartAlarmEvidenceStore.refreshCorrelation()
            XCTAssertEqual(UserDefaults.standard.object(forKey: "alarm.lastReportedEpoch") as? Int, 0)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "alarm.lastReportedRequestID"),
                           request.id.uuidString)
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.readbackStatus, .noAlarm)
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
        }
    }

    func testNativeRouterUnregisteredOrWrongOriginCannotConfirm() throws {
        try withEvidence {
            let live = LiveState()
            live.logTailPersistence = DebouncedLogTailPersistence(
                tailLimit: 50, loadPersisted: { [] }, persist: { _ in })
            let router = FrameRouter(state: live)
            let unregistered = nativeReadbackFrame(origin: 0x42, epoch: 1_792_666_800)
            XCTAssertTrue(parseFrame(unregistered, family: .whoop4).crcOK == true)
            router.handle(frame: unregistered)
            XCTAssertNil(UserDefaults.standard.object(forKey: "alarm.lastReportedEpoch"))
            let request = SmartAlarmReadbackRequest(id: UUID(), sourceID: "strap-A",
                targetEpoch: 1_792_666_800, sentAt: sentAt)
            router.registerAlarmReadback(request, sequence: 0x42)
            try bindNativeEvidence(to: request)
            router.handle(frame: nativeReadbackFrame(origin: 0x43, epoch: 1_792_666_800))
            SmartAlarmEvidenceStore.refreshCorrelation(now: sentAt.addingTimeInterval(2))
            XCTAssertNil(UserDefaults.standard.object(forKey: "alarm.lastReportedEpoch"))
            XCTAssertNil(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt)
            // Rejecting the wrong response must not consume the real request's registration.
            router.handle(frame: nativeReadbackFrame(origin: 0x42, epoch: 1_792_666_800))
            SmartAlarmEvidenceStore.refreshCorrelation()
            XCTAssertEqual(SmartAlarmEvidenceStore.latest?.strapReportedArmedAt, wakeAt)
        }
    }
    #endif
}
