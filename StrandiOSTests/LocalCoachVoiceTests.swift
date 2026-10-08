#if os(iOS)
import XCTest
@testable import NOOP

@MainActor
final class LocalCoachVoiceTests: XCTestCase {
    func testPermissionBridgeAcceptsBackgroundCallback() async {
        let allowed = await LocalCoachPermissionBridge.request { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(true)
            }
        }

        XCTAssertTrue(allowed)
    }
}
#endif
