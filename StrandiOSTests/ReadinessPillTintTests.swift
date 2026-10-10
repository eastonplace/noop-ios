import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// The Day screen's readiness pill wears the ring's recovery band, not the readiness engine's own tint.
@MainActor
final class ReadinessPillTintTests: XCTestCase {
    func testTheReadinessPillWearsTheRingsRecoveryBandAtEveryScore() {
        let levels: [ReadinessEngine.Level] = [.primed, .balanced, .strained, .rundown, .insufficient]
        for score in stride(from: 0.0, through: 100.0, by: 0.5) {
            for level in levels {
                XCTAssertEqual(CoupledView.readinessPillTint(recovery: score, level: level),
                               RecoveryBands.color(for: score), "score \(score), level \(level)")
            }
        }
    }

    func testAYellowThirtyFivePercentRingNeverGetsTheGreenBalancedPill() {
        let pill = CoupledView.readinessPillTint(recovery: 35, level: .balanced)
        XCTAssertEqual(pill, StrandPalette.recoveryMed)
        XCTAssertNotEqual(pill, StrandPalette.statusPositive)
    }

    func testWithNoRecoveryThePillFallsBackToTheReadinessTint() {
        XCTAssertEqual(CoupledView.readinessPillTint(recovery: nil, level: .balanced), StrandPalette.statusPositive)
        XCTAssertEqual(CoupledView.readinessPillTint(recovery: nil, level: .insufficient), StrandPalette.textTertiary)
    }
}
