#if os(iOS)
import XCTest
import UIKit
@testable import NOOP

/// CORE-04 (engine half): a locked background launch (BLE restoration overnight) couldn't read the Coach files,
/// and the engine latched "settings unreadable" for the whole process. It now retries when protected data
/// becomes available, and latches only for a decode or version error.
@MainActor
final class LocalCoachUnlockRetryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCoachUnlock-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func engine(_ store: LocalCoachPersistence, center: NotificationCenter) -> LocalCoachEngine {
        LocalCoachEngine(data: nil, persistence: store, model: nil,
                         source: { .init(storageID: "a", dataSourceID: "a", revision: "1") },
                         notificationCenter: center)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testANoPermissionReadFollowedByASuccessfulReadLetsTheCoachOperate() async throws {
        let root = try directory()
        let store = LocalCoachPersistence(directory: root)
        var saved = LocalCoachPreferences()
        saved.usePersonalData = true
        try store.savePreferences(saved)
        let settings = root.appendingPathComponent("settings.json").path
        // Models a `.complete` file read before first unlock: the read is refused, the file is intact.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings) }

        let center = NotificationCenter()
        let coach = engine(store, center: center)
        XCTAssertNotNil(coach.errorText)
        XCTAssertFalse(coach.preferences.enabled)
        coach.addMemory(text: "Run three times a week", category: .goals)
        XCTAssertTrue(coach.memories.isEmpty, "a locked launch must not operate on default settings")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        await waitUntil { coach.preferences.enabled }

        XCTAssertEqual(coach.preferences, saved)
        XCTAssertNil(coach.errorText)
        coach.addMemory(text: "Run three times a week", category: .goals)
        XCTAssertEqual(coach.memories.count, 1, "canOperate stayed false after the unlock")
    }

    func testACorruptSettingsFileStaysLatchedAcrossUnlock() async throws {
        let root = try directory()
        let store = LocalCoachPersistence(directory: root)
        let settings = root.appendingPathComponent("settings.json")
        try Data("broken json".utf8).write(to: settings)

        let center = NotificationCenter()
        let coach = engine(store, center: center)
        XCTAssertNotNil(coach.errorText)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(coach.preferences.enabled)
        XCTAssertNotNil(coach.errorText)
        XCTAssertEqual(try Data(contentsOf: settings), Data("broken json".utf8), "the original file was kept")
    }

    func testOnlyPermissionErrorsCountAsLocked() {
        let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
        ])
        XCTAssertTrue(LocalCoachEngine.isAwaitingUnlock(noPermission))
        XCTAssertTrue(LocalCoachEngine.isAwaitingUnlock(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(LocalCoachEngine.isAwaitingUnlock(
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)))
        XCTAssertFalse(LocalCoachEngine.isAwaitingUnlock(LocalCoachPersistence.StoreError.unsupportedVersion(2)))
    }

    func testSettingsAreWrittenReadableAfterFirstUnlock() throws {
        let root = try directory()
        let store = LocalCoachPersistence(directory: root)
        try store.savePreferences(LocalCoachPreferences())
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("settings.json").path)
        // The simulator may not report a protection class; when it does, it must be the relaxed one.
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
        }
    }
}
#endif
