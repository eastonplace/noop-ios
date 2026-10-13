import XCTest
@testable import NOOP

final class RescoreBackgroundPolicyTests: XCTestCase {
    func testBackgroundPacingUsesTenSecondQuantumOneToOneRestAndThirtySecondCap() {
        let cases: [(work: Double, expectedRest: Double)] = [
            (9.999, 0),
            (10, 10),
            (12, 12),
            (31, 30),
        ]

        for testCase in cases {
            XCTAssertEqual(
                RescoreBackgroundPolicy.restSeconds(
                    afterWorkSeconds: testCase.work,
                    isBackground: true
                ),
                testCase.expectedRest,
                accuracy: 0.001
            )
        }

        XCTAssertEqual(
            RescoreBackgroundPolicy.restSeconds(
                afterWorkSeconds: 12,
                isBackground: false
            ),
            0
        )
    }

    func testBackgroundAdmissionSchedulesDurableWorkAndSkipsBackstop() {
        XCTAssertEqual(
            RescoreBackgroundPolicy.decide(
                isBackground: true,
                trigger: .durablePipeline,
                hasBackgroundGrant: false
            ),
            .runWithBackgroundFallback
        )
        XCTAssertEqual(
            RescoreBackgroundPolicy.decide(
                isBackground: true,
                trigger: .cadenceBackstop,
                hasBackgroundGrant: false
            ),
            .skip
        )
        XCTAssertEqual(
            RescoreBackgroundPolicy.decide(
                isBackground: true,
                trigger: .durablePipeline,
                hasBackgroundGrant: true
            ),
            .run
        )
        XCTAssertEqual(
            RescoreBackgroundPolicy.decide(
                isBackground: false,
                trigger: .cadenceBackstop,
                hasBackgroundGrant: false
            ),
            .run
        )
    }
}
