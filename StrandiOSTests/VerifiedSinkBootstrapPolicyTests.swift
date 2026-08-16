import XCTest
@testable import NOOP

final class VerifiedSinkBootstrapPolicyTests: XCTestCase {
    func testMatchingTokenIsKept() {
        let token = VerifiedSinkToken(epoch: 8, contextId: "today-context")
        XCTAssertEqual(
            VerifiedSinkBootstrapPolicy.decide(
                activeToken: token,
                expectedContextId: "today-context",
                hasPendingTransition: false
            ),
            .keep
        )
    }

    func testPendingTransitionWinsBeforeTokenRepair() {
        let token = VerifiedSinkToken(epoch: 8, contextId: "old")
        XCTAssertEqual(
            VerifiedSinkBootstrapPolicy.decide(
                activeToken: token,
                expectedContextId: "new",
                hasPendingTransition: true
            ),
            .waitForPendingTransition
        )
    }

    func testClosedSourceClearsVisibleState() {
        XCTAssertEqual(
            VerifiedSinkBootstrapPolicy.decide(
                activeToken: nil,
                expectedContextId: "  ",
                hasPendingTransition: false
            ),
            .clearClosedSource
        )
    }

    func testMissingOrMismatchedTokenStartsActivation() {
        XCTAssertEqual(
            VerifiedSinkBootstrapPolicy.decide(
                activeToken: nil,
                expectedContextId: "new",
                hasPendingTransition: false
            ),
            .activate(contextId: "new")
        )

        XCTAssertEqual(
            VerifiedSinkBootstrapPolicy.decide(
                activeToken: VerifiedSinkToken(epoch: 2, contextId: "old"),
                expectedContextId: "new",
                hasPendingTransition: false
            ),
            .activate(contextId: "new")
        )
    }
}
