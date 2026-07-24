import XCTest
@testable import OuraProtocol

final class OuraIBITimestampPolicyTests: XCTestCase {
    func testAnchoredBeatPersistsAtRingTimeDerivedUnixTimestamp() {
        XCTAssertEqual(
            OuraIBITimestampPolicy.decision(
                ringTimestamp: 123,
                anchoredUnixSeconds: 1_800_000_123
            ),
            .persist(unixSeconds: 1_800_000_123)
        )
    }

    func testUnanchoredBeatParksInsteadOfUsingDrainArrivalTime() {
        XCTAssertEqual(
            OuraIBITimestampPolicy.decision(
                ringTimestamp: 456,
                anchoredUnixSeconds: nil
            ),
            .park(ringTimestamp: 456)
        )
        XCTAssertEqual(
            OuraIBITimestampPolicy.decision(
                ringTimestamp: 456,
                anchoredUnixSeconds: 0
            ),
            .park(ringTimestamp: 456)
        )
    }
}
