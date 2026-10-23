import XCTest
import WhoopStore
@testable import NOOP

final class LiveDeviceEnrollmentPolicyTests: XCTestCase {
    private func device(brand: String, model: String = "fixture", kind: SourceKind = .liveBLE) -> PairedDevice {
        PairedDevice(id: "enrollment-fixture", brand: brand, model: model, nickname: "My band",
                     peripheralId: "00000000-0000-0000-0000-000000000001", sourceKind: kind,
                     capabilities: [.hr, .hrv], status: .paired, addedAt: 100, lastSeenAt: 101)
    }

    func testWhoopLiveBLEAdmissionPreservesTheOriginalDevicePayload() {
        for model in ["4.0", "5.0 MG", "WHOOP MG"] {
            let candidate = device(brand: "WHOOP", model: model)
            let unchanged = candidate

            XCTAssertTrue(LiveDeviceEnrollmentPolicy.permits(candidate))
            XCTAssertEqual(candidate, unchanged)
        }
    }

    func testWhoopBrandComparisonIsCaseInsensitive() {
        for brand in ["WHOOP", "whoop", "Whoop"] {
            XCTAssertTrue(LiveDeviceEnrollmentPolicy.permits(device(brand: brand)))
        }
    }

    func testOuraFTMSAndGenericNewLiveDevicesAreRejected() {
        let candidates = [
            device(brand: "Oura", kind: .oura),
            device(brand: "Gym equipment", kind: .ftms),
            device(brand: "Polar"),
            device(brand: "Garmin"),
            device(brand: "Amazfit", kind: .huami),
        ]
        for candidate in candidates {
            XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(candidate), candidate.brand)
        }
    }

    func testBrandAndSourceKindCannotBypassEachOther() {
        XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: "Oura", kind: .liveBLE)))
        XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: "WHOOP", kind: .oura)))
        XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: "WHOOP", kind: .ftms)))
        XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: "Polar", model: "WHOOP 4.0")))
        XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: " WHOOP ")))
    }

    func testHistoricalAndImportedRowsCannotUseNewLiveEnrollment() {
        for kind in SourceKind.allCases where kind != .liveBLE {
            XCTAssertFalse(LiveDeviceEnrollmentPolicy.permits(device(brand: "WHOOP", kind: kind)), kind.rawValue)
        }
    }
}
