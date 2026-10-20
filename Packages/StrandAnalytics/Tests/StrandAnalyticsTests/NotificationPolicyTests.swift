import XCTest
@testable import StrandAnalytics

final class NotificationPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func candidate(_ id: String = "one", group: NotificationGroup = .chargeReminder,
                   attention: String? = nil, lane: NotificationLane = .proactive,
                   quality: NotificationQuality = .init(), observedAt: Date? = nil,
                   requiresRecovery: Bool = false) -> NotificationCandidate {
        NotificationCandidate(ruleID: group.rawValue, group: group, subjectID: "device",
            occurrenceID: id, attentionKey: attention ?? id, evidenceRevision: "g1",
            sourceContext: "canonical", logicalDay: "2027-01-15", observedAt: observedAt ?? now,
            generatedAt: now, expiresAt: now.addingTimeInterval(3600), quality: quality,
            lane: lane, destination: .device(id: "device"), genericTitle: "Device", genericBody: "Review",
            requiresRecoveryQualification: requiresRecovery)
    }
    func evaluate(_ candidates: [NotificationCandidate], modes: [NotificationGroup: NotificationDeliveryMode] = [.chargeReminder: .notify], history: [NotificationHistoryEntry] = [], context: NotificationContext? = nil) -> NotificationEvaluation {
        NotificationPolicy.evaluate(candidates: candidates,
            preferences: .init(modes: modes, quietHoursEnabled: false),
            context: context ?? .init(sourceContext: "canonical", logicalDay: "2027-01-15"),
            history: history, now: now)
    }
    func testNewGroupOffAndInAppNeverAuthorizesOS() {
        XCTAssertEqual(evaluate([candidate()], modes: [:]).decisions.first?.reason, .categoryOff)
        let result = evaluate([candidate()], modes: [.chargeReminder: .inApp])
        XCTAssertTrue(result.selected.isEmpty)
        XCTAssertEqual(result.inApp.count, 1)
    }
    func testInvalidEvidenceAndRecoveryGate() {
        let cases: [(NotificationQuality, NotificationReason)] = [
            (.init(hasRequiredInputs: false), .missingInput), (.init(hasFiniteValues: false), .invalidValue),
            (.init(sourceAccepted: false), .sourceChanged), (.init(modelAccepted: false), .modelMismatch),
            (.init(isHistoricalReplay: true), .historicalReplay), (.init(isFinal: false), .notFinal)]
        for (quality, reason) in cases {
            XCTAssertEqual(evaluate([candidate(quality: quality)]).decisions.first?.reason, reason)
        }
        XCTAssertEqual(evaluate([candidate(requiresRecovery: true)]).decisions.first?.reason, .dependencyUnqualified)
        XCTAssertEqual(evaluate([candidate(observedAt: now.addingTimeInterval(-1801))]).decisions.first?.reason, .staleMetric)
    }
    func testWorkoutSummaryWinsTargetCollision() {
        let result = evaluate([candidate("target", group: .strainTarget, attention: "workout:a"),
                               candidate("summary", group: .workoutSummary, attention: "workout:a")],
                              modes: [.strainTarget: .notify, .workoutSummary: .notify])
        XCTAssertEqual(result.selected.map(\.occurrenceID), ["summary"])
        XCTAssertEqual(result.decisions.filter { $0.reason == .coalesced }.count, 1)
    }
    func testAttentionDedupeSurvivesEvidenceRevision() {
        let history = [NotificationHistoryEntry(occurrenceID: "old", attentionKey: "shared", logicalDay: "2027-01-14", chargedAt: now.addingTimeInterval(-86400))]
        XCTAssertEqual(evaluate([candidate("new", attention: "shared")], history: history).decisions.first?.reason, .alreadyScheduled)
    }
    func testRollingBudgetAndGap() {
        let history = (0..<10).map { NotificationHistoryEntry(occurrenceID: "\($0)", attentionKey: "\($0)", logicalDay: "older", chargedAt: now.addingTimeInterval(-Double($0 + 1) * 12000)) }
        XCTAssertEqual(evaluate([candidate()], history: history).decisions.first?.reason, .budgetFull)
        let recent = [NotificationHistoryEntry(occurrenceID: "old", attentionKey: "old", logicalDay: "older", chargedAt: now.addingTimeInterval(-10799))]
        XCTAssertEqual(evaluate([candidate()], history: recent).decisions.first?.reason, .minimumGap)
    }
    func testActiveWorkoutSleepAndReminderYield() {
        XCTAssertEqual(evaluate([candidate()], context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", activeWorkout: true)).decisions.first?.reason, .activeWorkout)
        XCTAssertEqual(evaluate([candidate()], context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", sleeping: true)).decisions.first?.reason, .sleepInProgress)
        XCTAssertEqual(evaluate([candidate()], context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", explicitReminderDates: [now.addingTimeInterval(1799)])).decisions.first?.reason, .reminderNearby)
    }
    func testQuietHoursUseCurrentLocalTimeAndExplicitRemindersBypass() {
        let midnight = Date(timeIntervalSince1970: 1_800_057_600)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let atNight = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: midnight)!
        let c = NotificationCandidate(ruleID: "night", group: .chargeReminder, subjectID: "x", occurrenceID: "x", attentionKey: "x", evidenceRevision: "1", sourceContext: "canonical", logicalDay: "d", observedAt: atNight, generatedAt: atNight, expiresAt: atNight.addingTimeInterval(60), destination: .day(logicalDay: "d"), genericTitle: "Ready", genericBody: "Open")
        let result = NotificationPolicy.evaluate(candidates: [c], preferences: .init(modes: [.chargeReminder: .notify]), context: .init(sourceContext: "canonical", logicalDay: "d", timeZoneIdentifier: "UTC"), history: [], now: atNight)
        XCTAssertEqual(result.decisions.first?.reason, .quietHours)
        XCTAssertEqual(evaluate([candidate(lane: .explicitReminder)], context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", activeWorkout: true)).selected.count, 1)
    }
    func testEvidenceDayDoesNotFollowDashboardCarry() {
        XCTAssertEqual(evaluate([candidate()], context: .init(sourceContext: "canonical", logicalDay: "2027-01-16")).decisions.first?.reason, .historicalReplay)
    }
    func testRulesStableAcrossRevisionsAndDeviceScoped() {
        func fact(_ device: String, _ revision: String) -> NotificationRuleFact {
            .init(group: .chargeReminder, subjectID: device, episodeID: "episode", evidenceRevision: revision,
                  sourceContext: "canonical", logicalDay: "2027-01-15", observedAt: now, expiresAt: now.addingTimeInterval(600))
        }
        let a = NotificationRules.candidates(facts: [fact("a", "1")], now: now)[0]
        let revised = NotificationRules.candidates(facts: [fact("a", "2")], now: now)[0]
        let b = NotificationRules.candidates(facts: [fact("b", "1")], now: now)[0]
        XCTAssertEqual(a.occurrenceID, revised.occurrenceID)
        XCTAssertEqual(a.attentionKey, revised.attentionKey)
        XCTAssertNotEqual(a.attentionKey, b.attentionKey)
    }
    func testThreeCandidatePermutationsHaveStableCollisionOutcome() {
        func withPriority(_ original: NotificationCandidate, _ priority: Int) -> NotificationCandidate {
            NotificationCandidate(ruleID: original.ruleID, group: original.group, subjectID: original.subjectID,
                occurrenceID: original.occurrenceID, attentionKey: original.attentionKey, evidenceRevision: "1",
                sourceContext: original.sourceContext, logicalDay: original.logicalDay, observedAt: now,
                generatedAt: now, expiresAt: original.expiresAt, priority: priority, destination: original.destination,
                genericTitle: "Ready", genericBody: "Review")
        }
        let summary = withPriority(candidate("summary", group: .workoutSummary, attention: "workout"), 0)
        let target = withPriority(candidate("target", group: .strainTarget, attention: "workout"), 100)
        let other = withPriority(candidate("other", attention: "other"), 50)
        let permutations = [[summary, target, other], [summary, other, target], [target, summary, other],
                            [target, other, summary], [other, summary, target], [other, target, summary]]
        let modes: [NotificationGroup: NotificationDeliveryMode] = [.chargeReminder: .notify, .workoutSummary: .notify, .strainTarget: .notify]
        let baseline = evaluate(permutations[0], modes: modes)
        for permutation in permutations { XCTAssertEqual(evaluate(permutation, modes: modes), baseline) }
        XCTAssertEqual(baseline.decisions.first { $0.candidate.group == .strainTarget }?.reason, .coalesced)
        let fallback = evaluate([summary, target], modes: [.strainTarget: .notify])
        XCTAssertEqual(fallback.selected.map(\.occurrenceID), ["target"])
    }
    func testMissingExplicitScheduleAndEpisodeStaySilent() {
        let fact = NotificationRuleFact(group: .windDown, subjectID: "plan", episodeID: "", evidenceRevision: "1", sourceContext: "canonical", logicalDay: "2027-01-15", observedAt: now, expiresAt: now.addingTimeInterval(600))
        let result = evaluate(NotificationRules.candidates(facts: [fact], now: now), modes: [.windDown: .notify])
        XCTAssertEqual(result.decisions.first?.reason, .missingInput)
    }

    func testVisibleDestinationDoesNotCancelChosenFutureReminder() {
        let reminder = NotificationCandidate(ruleID: "windDown", group: .windDown, subjectID: "plan", occurrenceID: "future", attentionKey: "future", evidenceRevision: "1", sourceContext: "canonical", logicalDay: "2027-01-15", observedAt: now, generatedAt: now, expiresAt: now.addingTimeInterval(7200), lane: .explicitReminder, destination: .sleepPlan(logicalDay: "2027-01-15"), genericTitle: "Reminder", genericBody: "Review", scheduledAt: now.addingTimeInterval(3600))
        let context = NotificationContext(sourceContext: "canonical", logicalDay: "2027-01-15", visibleDestinations: [reminder.destination])
        let result = evaluate([reminder], modes: [.windDown: .notify], context: context)
        XCTAssertEqual(result.selected.map(\.occurrenceID), ["future"])
    }

    func testDailyBudgetUsesSubmissionDateNotEvidenceDayLabel() {
        let history = [NotificationHistoryEntry(occurrenceID: "a", attentionKey: "a", logicalDay: "different-a", chargedAt: now.addingTimeInterval(-4 * 3600)), NotificationHistoryEntry(occurrenceID: "b", attentionKey: "b", logicalDay: "different-b", chargedAt: now.addingTimeInterval(-7 * 3600))]
        let result = evaluate([candidate()], history: history, context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", timeZoneIdentifier: "UTC"))
        XCTAssertEqual(result.decisions.first?.reason, .budgetFull)
        let afterLocalMidnight = evaluate([candidate()], history: history, context: .init(sourceContext: "canonical", logicalDay: "2027-01-15", timeZoneIdentifier: "America/Los_Angeles"))
        XCTAssertEqual(afterLocalMidnight.selected.count, 1)
    }

}
