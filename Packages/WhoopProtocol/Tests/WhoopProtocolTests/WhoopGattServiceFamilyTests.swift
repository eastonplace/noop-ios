import XCTest
@testable import WhoopProtocol

final class WhoopGattServiceFamilyTests: XCTestCase {
    func testUnsupportedFamiliesHaveNoConnectableDeviceFamily() {
        XCTAssertEqual(WhoopGattServiceFamily.unsupportedServiceUUIDStrings, [
            "11500001-6215-11ee-8c99-0242ac120002",
            "8a580001-2fe8-4796-9267-b87a2b0c8234",
            "59830001-5955-419b-bb8d-c8262926af23",
        ])
        for family in WhoopGattServiceFamily.unsupportedFamilies {
            XCTAssertFalse(family.isConnectable)
            XCTAssertNil(family.connectableDeviceFamily)
            XCTAssertEqual(family.characteristicUUIDStrings.count, 5)
            XCTAssertTrue(family.diagnosticUnsupportedMessage.contains(
                "will not connect or send commands"
            ))
        }
    }

    func testOnlyEstablishedFamiliesMapToProtocolFraming() {
        XCTAssertEqual(
            WhoopGattServiceFamily.whoop4.connectableDeviceFamily,
            .whoop4
        )
        XCTAssertEqual(
            WhoopGattServiceFamily.maverickGooseFD4B.connectableDeviceFamily,
            .whoop5
        )
        XCTAssertEqual(
            WhoopGattServiceFamily.maverickGooseFD4B.serviceUUIDString,
            DeviceFamily.whoop5.serviceUUIDString
        )
    }

    func testUnsupportedAdvertisementIsRejectedBeforeGatt() {
        let decision = whoopGattScanDecision(
            selectedServiceUUIDString: DeviceFamily.whoop5.serviceUUIDString,
            advertisedServiceUUIDStrings: [
                "8A580001-2FE8-4796-9267-B87A2B0C8234"
            ]
        )
        XCTAssertFalse(decision.shouldConnect)
        XCTAssertEqual(decision.unsupportedFamily, .monument)
    }

    func testSelectedAndOmittedServiceListsPreserveExistingConnectPath() {
        XCTAssertEqual(
            whoopGattScanDecision(
                selectedServiceUUIDString: DeviceFamily.whoop4.serviceUUIDString,
                advertisedServiceUUIDStrings: [DeviceFamily.whoop4.serviceUUIDString]
            ),
            WhoopGattScanDecision(shouldConnect: true)
        )
        XCTAssertEqual(
            whoopGattScanDecision(
                selectedServiceUUIDString: DeviceFamily.whoop4.serviceUUIDString,
                advertisedServiceUUIDStrings: []
            ),
            WhoopGattScanDecision(shouldConnect: true)
        )
    }

    func testUnknownDifferentServiceIsIgnoredWithoutInventingAFamily() {
        let decision = whoopGattScanDecision(
            selectedServiceUUIDString: DeviceFamily.whoop4.serviceUUIDString,
            advertisedServiceUUIDStrings: [
                "0000180d-0000-1000-8000-00805f9b34fb"
            ]
        )
        XCTAssertFalse(decision.shouldConnect)
        XCTAssertNil(decision.unsupportedFamily)
    }
}
