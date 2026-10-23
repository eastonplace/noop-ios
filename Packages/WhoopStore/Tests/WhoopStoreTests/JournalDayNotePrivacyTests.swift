import XCTest
@testable import WhoopStore

final class JournalDayNotePrivacyTests: XCTestCase {
    func testNativeNotePrivacyRegistrationClearsOnlyItsNamespace() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-10-22"
        let expected = try await store.journalDayDetails(day: day)
        try await store.saveReviewedJournal([], expectedDatabaseInstanceId: store.databaseInstanceId(), dayDetails:
            .init(day: day, note: "Private native note", mood: 4, expected: expected))
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("journalDayNote"))

        try await store.deleteAllData(deviceId: "my-whoop")
        let afterImportDeletion = try await store.journalDayDetails(day: day)
        XCTAssertEqual(afterImportDeletion.note, "Private native note")
        XCTAssertEqual(afterImportDeletion.mood, 4)

        try await store.deleteAllData(deviceId: "noop-journal")
        let afterNativeDeletion = try await store.journalDayDetails(day: day)
        XCTAssertNil(afterNativeDeletion.note)
        XCTAssertEqual(afterNativeDeletion.mood, 4, "Mood remains under its existing independent privacy namespace")
        try await store.deleteAllData(deviceId: "noop-mood")
        let afterMoodDeletion = try await store.journalDayDetails(day: day)
        XCTAssertNil(afterMoodDeletion.mood)
    }
}
