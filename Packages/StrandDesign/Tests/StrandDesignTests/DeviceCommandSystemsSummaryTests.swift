import XCTest
@testable import StrandDesign

final class DeviceCommandSystemsSummaryTests: XCTestCase {
    func testNeutralRowsRemainUnknown() {
        let summary = DeviceCommandSystemsSummary(items: [
            .init(id: "ble", label: "BLE", value: "Waiting", tone: .neutral),
            .init(id: "sync", label: "Sync", value: "Waiting", tone: .neutral),
        ])

        XCTAssertEqual(summary.verified, 0)
        XCTAssertEqual(summary.attention, 0)
        XCTAssertEqual(summary.unknown, 2)
        XCTAssertFalse(summary.allVerified)
        XCTAssertEqual(summary.statusLabel, "2 unknown")
    }

    func testOnlyGoodRowsCountAsVerified() {
        let summary = DeviceCommandSystemsSummary(items: [
            .init(id: "ble", label: "BLE", value: "Connected", tone: .good),
            .init(id: "sync", label: "Sync", value: "Complete", tone: .good),
        ])

        XCTAssertEqual(summary.verified, 2)
        XCTAssertEqual(summary.attention, 0)
        XCTAssertEqual(summary.unknown, 0)
        XCTAssertTrue(summary.allVerified)
        XCTAssertEqual(summary.statusLabel, "Systems verified")
    }

    func testWarningsAndCriticalRowsCountAsAttention() {
        let summary = DeviceCommandSystemsSummary(items: [
            .init(id: "ble", label: "BLE", value: "Connected", tone: .good),
            .init(id: "battery", label: "Battery", value: "Low", tone: .warning),
            .init(id: "health", label: "Health", value: "Critical", tone: .critical),
            .init(id: "clock", label: "Clock", value: "Unknown", tone: .neutral),
        ])

        XCTAssertEqual(summary.verified, 1)
        XCTAssertEqual(summary.attention, 2)
        XCTAssertEqual(summary.unknown, 1)
        XCTAssertFalse(summary.allVerified)
        XCTAssertEqual(summary.statusLabel, "2 flagged")
    }

    func testEmptyInputDoesNotClaimNominalStatus() {
        let summary = DeviceCommandSystemsSummary(items: [])

        XCTAssertEqual(summary.total, 0)
        XCTAssertFalse(summary.allVerified)
        XCTAssertEqual(summary.statusLabel, "No systems")
    }
}
