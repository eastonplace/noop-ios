import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// The strain target is the band of the recovery score as it is drawn.
@MainActor
final class RecoveryTargetBandTests: XCTestCase {
    /// The strain target is the band of the score as it is drawn: a 66.6 shown "67" and green earns the green day's
    /// 14 to 18, not the yellow one's, and 33.5 (drawn "34", yellow) earns the yellow day's.
    func testTheStrainTargetFollowsTheRoundedRecoveryBand() {
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 66.6), 14...18)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 66.5), 14...18)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 66.4), 10...14)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 33.5), 10...14)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 33.4), 4...10)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 0), 4...10)
        XCTAssertEqual(CoupledView.optimalStrainRange(recovery: 100), 14...18)
        XCTAssertNil(CoupledView.optimalStrainRange(recovery: nil))
        for score in stride(from: 0.0, through: 100.0, by: 0.5) {
            let band = RecoveryBands.band(for: score)
            let range = CoupledView.optimalStrainRange(recovery: score)
            XCTAssertEqual(range, band == .high ? 14...18 : band == .medium ? 10...14 : 4...10, "score \(score)")
        }
    }
}
