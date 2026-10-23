#if os(iOS)
import Foundation
import XCTest
import NoopPhase34Core
@testable import NOOP

final class CoachBriefWidgetStoreTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "CoachBriefWidgetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }
    private func activate(_ context: String, in defaults: UserDefaults) throws -> VerifiedSinkToken {
        let epoch = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        return try XCTUnwrap(ActiveVerifiedSinkEpochStore.activate(contextId: context, epoch: epoch, defaults: defaults))
    }
    private func brief(_ token: VerifiedSinkToken, now: Date, calendar: Calendar) throws -> CoachBriefWidgetPayload {
        try XCTUnwrap(.init(epoch: token.epoch, contextID: token.contextId, generation: 1,
            logicalDay: WidgetLogicalDay.key(of: now, calendar: calendar), generatedAt: now,
            kind: .morning, text: "Today's completed brief."))
    }
    func testSourceTransitionHidesOldBriefEvenWhenContextNameIsReused() throws {
        let store = try defaults(), now = Date(), calendar = Calendar.current
        let first = try activate("source-a", in: store)
        let old = try brief(first, now: now, calendar: calendar)
        XCTAssertTrue(CoachBriefWidgetStore.save(old, defaults: store))
        XCTAssertNotNil(CoachBriefWidgetStore.load(defaults: store, now: now, calendar: calendar))
        _ = try activate("source-a", in: store)
        XCTAssertNil(CoachBriefWidgetStore.load(defaults: store, now: now, calendar: calendar))
        XCTAssertFalse(CoachBriefWidgetStore.save(old, defaults: store))
    }
    func testLogicalDayRolloverHidesBriefAndConsentClearRemovesProse() throws {
        let store = try defaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 3, minute: 59)))
        let token = try activate("a", in: store)
        XCTAssertTrue(CoachBriefWidgetStore.save(try brief(token, now: before, calendar: calendar), defaults: store))
        XCTAssertNotNil(CoachBriefWidgetStore.load(defaults: store, now: before, calendar: calendar))
        XCTAssertNil(CoachBriefWidgetStore.load(defaults: store, now: before.addingTimeInterval(60), calendar: calendar))
        XCTAssertTrue(CoachBriefWidgetStore.clear(defaults: store))
        XCTAssertNil(store.object(forKey: CoachBriefWidgetStore.storageKey))
        XCTAssertNil(store.object(forKey: CoachBriefWidgetStore.generationKey))
    }
    func testMalformedOrOversizedStoredDataFailsClosed() throws {
        let store = try defaults()
        _ = try activate("a", in: store)
        store.set(Data(repeating: 0x41, count: 9_000), forKey: CoachBriefWidgetStore.storageKey)
        XCTAssertNil(CoachBriefWidgetStore.load(defaults: store))
        store.set(Data("{broken".utf8), forKey: CoachBriefWidgetStore.storageKey)
        XCTAssertNil(CoachBriefWidgetStore.load(defaults: store))
    }
}
#endif
