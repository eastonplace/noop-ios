import XCTest
@testable import NOOP

#if os(iOS)
/// Every drive of the Live Activity carries the verified surface, so a drive the token does not cover must lose its health
/// values, never the drive: otherwise an install without the App Group token never shows an activity at all.
final class LiveActivityDriveAdmissionTests: XCTestCase {
    private func decide(activeToken: VerifiedSinkToken?) -> LiveActivityDriveAdmission {
        LiveActivityDriveAdmission.decide(
            recovery: 70, effort: 12.4, verifiedContextId: "A", verifiedProjectionGeneration: 3,
            activeToken: activeToken)
    }

    private func assertPublishedWithoutHealth(_ admission: LiveActivityDriveAdmission,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(admission.strippedHealth, "published, with its health removed", file: file, line: line)
        XCTAssertNil(admission.token, "on the tokenless lane", file: file, line: line)
        XCTAssertNil(admission.recovery, "an unverified context never shows Recovery", file: file, line: line)
        XCTAssertNil(admission.effort, file: file, line: line)
        XCTAssertNil(admission.verifiedContextId, file: file, line: line)
        XCTAssertNil(admission.verifiedProjectionGeneration, file: file, line: line)
    }

    func testNoTokenPublishesWithoutHealthInsteadOfDropping() {
        let admission = decide(activeToken: nil)
        assertPublishedWithoutHealth(admission)
        XCTAssertEqual(admission.tokenState, .missing)
    }

    func testATokenForAnotherContextPublishesWithoutHealth() {
        let admission = decide(activeToken: VerifiedSinkToken(epoch: 4, contextId: "B"))
        assertPublishedWithoutHealth(admission)
        XCTAssertEqual(admission.tokenState, .mismatch)
    }

    func testAMatchingTokenKeepsTheTokenAndEveryHealthValue() {
        let token = VerifiedSinkToken(epoch: 4, contextId: "A")
        let admission = decide(activeToken: token)
        XCTAssertFalse(admission.strippedHealth)
        XCTAssertEqual(admission.tokenState, .match)
        XCTAssertEqual(admission.token, token)
        XCTAssertEqual(admission.recovery, 70)
        XCTAssertEqual(admission.effort, 12.4)
        XCTAssertEqual(admission.verifiedContextId, "A")
        XCTAssertEqual(admission.verifiedProjectionGeneration, 3)
    }

    /// The token alone is not enough: a context without a generation is not a verified write.
    func testAMatchingContextWithoutAGenerationIsNotVerified() {
        let admission = LiveActivityDriveAdmission.decide(
            recovery: 70, effort: nil, verifiedContextId: "A", verifiedProjectionGeneration: nil,
            activeToken: VerifiedSinkToken(epoch: 4, contextId: "A"))
        assertPublishedWithoutHealth(admission)
    }

    func testNoSurfaceIsTokenlessAndUnchanged() {
        for activeToken in [nil, VerifiedSinkToken(epoch: 4, contextId: "A")] {
            let admission = LiveActivityDriveAdmission.decide(
                recovery: nil, effort: nil, verifiedContextId: nil, verifiedProjectionGeneration: nil,
                activeToken: activeToken)
            XCTAssertFalse(admission.strippedHealth, "nothing to remove")
            XCTAssertNil(admission.token)
            XCTAssertNil(admission.recovery)
            XCTAssertNil(admission.effort)
            XCTAssertNil(admission.verifiedContextId)
            XCTAssertNil(admission.verifiedProjectionGeneration)
        }
    }
}
#endif
