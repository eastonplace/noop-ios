#if os(iOS)
import XCTest
@testable import NOOP

/// The shell can only put a cover on screen when nothing below it is presenting. `run` closes what is up, waits for the
/// system to say so, and presents; if something will not let go it is dismissed outright.
@MainActor
final class ShellModalCollapseTests: XCTestCase {
    func testWithNothingPresentedItPresentsAtOnceAndClearsNothing() {
        var cleared = false
        var presented = 0
        ShellModalCollapse.run(
            clearShellState: { cleared = true },
            isModalPresented: { false },
            forceDismiss: { XCTFail("nothing to force") },
            sleep: { _ in XCTFail("nothing to wait for") },
            then: { presented += 1 })
        XCTAssertFalse(cleared)
        XCTAssertEqual(presented, 1, "synchronously, so a cold start does not lose a frame")
    }

    func testItClearsThenWaitsUntilTheSystemReportsNothingThenPresentsOnce() async {
        var up = true
        var polls = 0
        var cleared = 0
        var presented = 0
        let done = expectation(description: "presented")
        ShellModalCollapse.run(
            clearShellState: { cleared += 1 },
            isModalPresented: { up },
            forceDismiss: { XCTFail("it let go on its own") },
            sleep: { _ in
                polls += 1
                if polls == 3 { up = false }
            },
            then: { presented += 1; done.fulfill() })
        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(presented, 0, "not before the modal has gone")
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(polls, 3)
        XCTAssertEqual(presented, 1)
    }

    func testAModalThatNeverLetsGoIsDismissedAfterThePatienceAndThenAirIsLeft() async {
        var up = true
        var order: [String] = []
        var slept: Duration = .zero
        let done = expectation(description: "presented")
        ShellModalCollapse.run(
            clearShellState: { order.append("clear") },
            isModalPresented: { up },
            forceDismiss: { order.append("force"); up = false },
            sleep: { slept += $0 },
            then: { order.append("present"); done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(order, ["clear", "force", "present"])
        XCTAssertGreaterThanOrEqual(slept, ShellModalCollapse.patience + ShellModalCollapse.settle)
    }
}
#endif
