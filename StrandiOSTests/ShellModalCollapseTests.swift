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

    /// A Live Activity tap arrives twice (the link, and the app becoming active). The second request must not start a second
    /// wait: it would find the cover the first one presented, take it for something in the way, and dismiss it.
    func testASecondRequestDuringACollapseIsCoalescedAndDismissesNothing() async {
        var up = true
        var polls = 0
        var presented = 0
        var forced = 0
        let done = expectation(description: "presented")
        let first = ShellModalCollapse.run(
            clearShellState: {},
            isModalPresented: { up },
            forceDismiss: { forced += 1 },
            sleep: { _ in
                polls += 1
                if polls == 2 { up = false }
            },
            then: { presented += 1; done.fulfill() })
        XCTAssertTrue(first)
        XCTAssertTrue(ShellModalCollapse.isCollapsing)

        var secondCleared = false
        let second = ShellModalCollapse.run(
            clearShellState: { secondCleared = true },
            isModalPresented: { up },
            forceDismiss: { forced += 1 },
            sleep: { _ in XCTFail("the second request waits for nothing") },
            then: { XCTFail("the first collapse presents for both") })
        XCTAssertFalse(second)
        XCTAssertFalse(secondCleared, "it closes nothing a second time")

        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(forced, 0)
        XCTAssertFalse(ShellModalCollapse.isCollapsing, "the next request is a request again")
    }

    func testItStopsWaitingWithoutDismissingOnceWhatItWasPresentingIsUp() async {
        // The probe reports a modal throughout: from the second poll on it is the target cover itself.
        var targetIsUp = false
        var polls = 0
        let done = expectation(description: "finished")
        ShellModalCollapse.run(
            clearShellState: {},
            isSatisfied: { targetIsUp },
            isModalPresented: { true },
            forceDismiss: { XCTFail("it would tear down the cover it presented") },
            sleep: { _ in
                polls += 1
                if polls == 2 { targetIsUp = true }
            },
            then: { done.fulfill() })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(polls, 2, "no patience spent, no settle")
    }
}
#endif
