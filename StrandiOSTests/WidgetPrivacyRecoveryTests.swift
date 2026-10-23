import Foundation
import NoopPhase34Core
import XCTest
@testable import NOOP

final class WidgetPrivacyRecoveryTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "WidgetPrivacyRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func brief(epoch: UInt64, now: Date) throws -> CoachBriefWidgetPayload {
        try XCTUnwrap(CoachBriefWidgetPayload(epoch: epoch, contextID: "source-a", generation: 1,
            logicalDay: WidgetLogicalDay.key(of: now), generatedAt: now,
            kind: .morning, text: "Private completed brief."))
    }

    func testRecoveryCannotReuseASurvivingBriefEpochAndRedisplayItsProse() throws {
        let defaults = try defaults(), now = Date()
        // The active record is damaged and other sink artifacts were already removed.
        // A surviving brief must still fence the new epoch, even for a reused context name.
        defaults.set(Data("broken".utf8), forKey: ActiveVerifiedSinkEpochStore.activeKey)
        defaults.set(try JSONEncoder().encode(brief(epoch: 1, now: now)), forKey: CoachBriefWidgetStore.storageKey)
        let next = try XCTUnwrap(ActiveSinkEpochRecovery.beginTransitionRecovering(defaults: defaults))
        XCTAssertGreaterThan(next, 1)
        _ = try XCTUnwrap(ActiveVerifiedSinkEpochStore.activate(contextId: "source-a", epoch: next, defaults: defaults))
        XCTAssertNil(CoachBriefWidgetStore.load(defaults: defaults, now: now))
    }

    func testRecoveryAlsoHonorsTheBriefGenerationFenceWhenItsPayloadIsMissing() throws {
        let defaults = try defaults()
        let record = VerifiedSinkGenerationRecord(epoch: 91, contextId: "source-a", generation: 3)
        defaults.set(try JSONEncoder().encode(record), forKey: CoachBriefWidgetStore.generationKey)
        XCTAssertEqual(ActiveSinkEpochRecovery.nextEpoch(defaults: defaults), 92)
    }

    func testBriefEpochOverflowFailsClosed() throws {
        let defaults = try defaults()
        defaults.set(try JSONEncoder().encode(brief(epoch: UInt64.max, now: Date())), forKey: CoachBriefWidgetStore.storageKey)
        XCTAssertNil(ActiveSinkEpochRecovery.beginTransitionRecovering(defaults: defaults))
    }

    func testPrivacyBoundaryRemovesBriefProseAndItsFence() throws {
        let defaults = try defaults()
        defaults.set(try JSONEncoder().encode(brief(epoch: 1, now: Date())), forKey: CoachBriefWidgetStore.storageKey)
        let record = VerifiedSinkGenerationRecord(epoch: 1, contextId: "source-a", generation: 1)
        defaults.set(try JSONEncoder().encode(record), forKey: CoachBriefWidgetStore.generationKey)
        ActiveSinkEpochRecovery.clearVerifiedWidgetState(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: CoachBriefWidgetStore.storageKey))
        XCTAssertNil(defaults.object(forKey: CoachBriefWidgetStore.generationKey))
    }
}
