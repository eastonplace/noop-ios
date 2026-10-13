import XCTest
@testable import NOOP

/// Backup & Export carries the manual backup, the CSV export and the Shortcuts export as extra sections that only the
/// native list can place. Settings can render outside the sheet (a bare `SettingsView()` pushed into Today's stack by
/// Fitness Age's "Review profile" keeps the `.standard` presentation), so the choice of body must not depend on it.
@MainActor
final class BackupSyncPresentationTests: XCTestCase {
    func testBackupAndExportDrawsTheNativeListWhereverSettingsIsRendered() {
        XCTAssertTrue(BackupSyncView.usesNativeList(presentation: .standard, carriesExtraSections: true),
                      "outside the sheet the page must still show Export/Import Full Backup, Export CSV and the Shortcuts export")
        XCTAssertTrue(BackupSyncView.usesNativeList(presentation: .settingsDetail, carriesExtraSections: true))
    }

    func testBackupAndSyncAloneKeepsItsScaffoldOutsideTheSheet() {
        XCTAssertFalse(BackupSyncView.usesNativeList(presentation: .standard, carriesExtraSections: false))
        XCTAssertTrue(BackupSyncView.usesNativeList(presentation: .settingsDetail, carriesExtraSections: false))
    }
}
