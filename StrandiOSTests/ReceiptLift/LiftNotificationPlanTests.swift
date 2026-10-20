import XCTest
@testable import ReceiptLiftFeature

final class LiftNotificationPlanTests: XCTestCase {
    func testOldPlanWithoutTimeProvenanceDoesNotBecomeReminder() throws {
        let json = """
        {"id":"33333333-3333-3333-3333-333333333333","routineID":"44444444-4444-4444-4444-444444444444","plannedAt":0,"note":"private"}
        """
        let old = try JSONDecoder().decode(ScheduledWorkout.self, from: Data(json.utf8))
        XCTAssertNil(old.notificationTimeExplicit)
        var edited = old
        edited.notificationTimeExplicit = true
        let saved = try JSONDecoder().decode(ScheduledWorkout.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(saved.notificationTimeExplicit, true)
        XCTAssertEqual(saved.id, old.id)
        XCTAssertEqual(saved.note, old.note)
    }
}
