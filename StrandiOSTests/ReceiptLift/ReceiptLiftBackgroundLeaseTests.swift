import UIKit
import XCTest
@testable import ReceiptLiftFeature

/// iOS terminates the app when a background task is still open after its expiration handler returns, so the Lift save
/// lease must end inside the handler, not on a later actor turn.
@MainActor
final class ReceiptLiftBackgroundLeaseTests: XCTestCase {
    func testExpirationHandlerEndsTheLeaseBeforeItReturns() {
        let coordinator = ReceiptLiftCoordinator(load: { nil }, save: { _, _ in })
        var expiration: (@MainActor @Sendable () -> Void)?
        var ended: [UIBackgroundTaskIdentifier] = []
        let lease = UIBackgroundTaskIdentifier(rawValue: 7)
        coordinator.beginBackgroundTask = { _, handler in expiration = handler; return lease }
        coordinator.endBackgroundTask = { ended.append($0) }

        coordinator.applicationDidEnterBackground()
        expiration?()

        // Checked synchronously, with no await between the handler and the assertion.
        XCTAssertEqual(ended, [lease])
    }
}
