import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class PerformanceLifecycleOwnershipTests: XCTestCase {
    func testOptimizedLifecycleForwardsEveryTransitionToTheSingleAppModelOwner() {
        var received: [Bool] = []

        PerformanceLifecycleOwnership.apply(false) { received.append($0) }
        PerformanceLifecycleOwnership.apply(true) { received.append($0) }

        XCTAssertEqual(received, [false, true])
    }
}
#endif
