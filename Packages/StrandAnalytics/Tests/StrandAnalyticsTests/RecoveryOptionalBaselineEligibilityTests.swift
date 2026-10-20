import XCTest
@testable import StrandAnalytics

/// Regression coverage for the WHOOP-only adaptation of upstream e7128ba7 and 0b729405.
/// The status-free overload is the target's existing score math; these cases pin which personal
/// states may reach that math and require the stored driver payloads and trace to agree with it.
final class RecoveryOptionalBaselineEligibilityTests: XCTestCase {
    private func baseline(_ mean: Double, _ spread: Double,
                          status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: mean, spread: spread,
                      nValid: status == .calibrating ? 0 : (status == .provisional ? 6 : 14),
                      nightsSinceUpdate: status == .stale ? 20 : 0, status: status)
    }

    private var hrv: BaselineState { baseline(50, 8) }

    // Expected eligibility is stated independently of BaselineState.usable. A stale state still
    // has enough historical nights, but the current contract explicitly excludes it.
    private func optionalStates(_ mean: Double, _ spread: Double)
        -> [(name: String, state: BaselineState?, eligible: Bool)] {
        [
            ("absent", nil, false),
            ("calibrating", baseline(mean, spread, status: .calibrating), false),
            ("provisional", baseline(mean, spread, status: .provisional), true),
            ("trusted", baseline(mean, spread, status: .trusted), true),
            ("stale", baseline(mean, spread, status: .stale), false),
        ]
    }

    private func score(rhrBase: BaselineState?, respBase: BaselineState?,
                       rhrValue: Double = 58, respValue: Double? = 14) -> Double? {
        RecoveryScorer.recovery(hrv: 55, rhr: rhrValue, resp: respValue,
                               hrvBaseline: hrv, rhrBaseline: rhrBase, respBaseline: respBase,
                               sleepPerf: 0.85, skinTempDev: 0.2)
    }

    func testUnusableRestingHRIsExactlyEquivalentToAnAbsentBaseline() {
        let states = [Baselines.foldHistory([], cfg: Baselines.restingHRCfg),
                      Baselines.foldHistory([0, 300], cfg: Baselines.restingHRCfg),
                      baseline(60, 4, status: .stale)]
        for state in states {
            XCTAssertFalse(state.usable)
            for value in [45.0, 58.0, 82.0] {
                XCTAssertEqual(score(rhrBase: state, respBase: baseline(16, 2), rhrValue: value)?.bitPattern,
                               score(rhrBase: nil, respBase: baseline(16, 2), rhrValue: value)?.bitPattern)
            }
        }
    }

    func testUnusableRespirationIsExactlyEquivalentToAnAbsentBaseline() {
        let states = [Baselines.foldHistory([], cfg: Baselines.respCfg),
                      Baselines.foldHistory([0, 100], cfg: Baselines.respCfg),
                      baseline(16, 2, status: .stale)]
        let values: [Double?] = [nil, 10, 14, 22]
        for state in states {
            XCTAssertFalse(state.usable)
            for value in values {
                XCTAssertEqual(score(rhrBase: baseline(60, 4), respBase: state, respValue: value)?.bitPattern,
                               score(rhrBase: baseline(60, 4), respBase: nil, respValue: value)?.bitPattern)
            }
        }
    }

    func testAllOptionalStatusAndValuePairsUseTheExistingScoreMath() {
        let respiratoryValues: [Double?] = [nil, 10, 14, 22]
        var cases = 0
        for rhrCase in optionalStates(60, 4) {
            for respCase in optionalStates(16, 2) {
                for rhrValue in [45.0, 58.0, 82.0] {
                    for respValue in respiratoryValues {
                        let expected = RecoveryScorer.recovery(
                            hrv: 55, rhr: rhrValue, resp: respValue,
                            hrvBaseline: RecoveryScorer.DriverBaseline(hrv),
                            rhrBaseline: rhrCase.eligible
                                ? rhrCase.state.map(RecoveryScorer.DriverBaseline.init) : nil,
                            respBaseline: respCase.eligible
                                ? respCase.state.map(RecoveryScorer.DriverBaseline.init) : nil,
                            sleepPerf: 0.85, skinTempDev: 0.2)
                        let actual = score(rhrBase: rhrCase.state, respBase: respCase.state,
                                           rhrValue: rhrValue, respValue: respValue)
                        XCTAssertEqual(actual?.bitPattern, expected?.bitPattern,
                                       "RHR=\(rhrCase.name), respiration=\(respCase.name)")
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 300)
        // Eligible non-neutral terms still participate; removing every optional term is not a fix.
        XCTAssertNotEqual(score(rhrBase: nil, respBase: nil)?.bitPattern,
                          score(rhrBase: baseline(60, 4), respBase: nil)?.bitPattern)
        XCTAssertNotEqual(score(rhrBase: nil, respBase: nil)?.bitPattern,
                          score(rhrBase: nil, respBase: baseline(16, 2))?.bitPattern)
    }

    func testDriverPayloadsOmitUnusableBaselinesAndPreserveEverySurvivingRow() {
        let respiratoryValues: [Double?] = [nil, 14]
        for rhrCase in optionalStates(60, 4) {
            for respCase in optionalStates(16, 2) {
                for value in respiratoryValues {
                    let actual = RecoveryScorer.chargeDrivers(
                        hrv: 55, rhr: 58, resp: value,
                        hrvBaseline: hrv, rhrBaseline: rhrCase.state, respBaseline: respCase.state,
                        sleepPerf: 0.85, skinTempDev: 0.2)
                    let expected = RecoveryScorer.chargeDrivers(
                        hrv: 55, rhr: 58, resp: value, hrvBaseline: hrv,
                        rhrBaseline: rhrCase.eligible ? rhrCase.state : nil,
                        respBaseline: respCase.eligible ? respCase.state : nil,
                        sleepPerf: 0.85, skinTempDev: 0.2)
                    // Equality includes the target's persisted term/value/baseline fields, ordering,
                    // marginal points and formatted rows, so presentation cannot silently drift.
                    XCTAssertEqual(actual, expected)
                    XCTAssertEqual(actual.contains { $0.term == .restingHR }, rhrCase.eligible)
                    XCTAssertEqual(actual.contains { $0.term == .resp }, respCase.eligible && value != nil)
                    XCTAssertTrue(actual.contains { $0.term == .hrv })
                    XCTAssertTrue(actual.contains { $0.term == .sleep })
                    XCTAssertTrue(actual.contains { $0.term == .skinTemp })
                }
            }
        }
    }

    func testTraceNamesExactlyTheOptionalTermsThatWereScored() {
        let respiratoryValues: [Double?] = [nil, 14]
        for rhrCase in optionalStates(60, 4) {
            for respCase in optionalStates(16, 2) {
                for value in respiratoryValues {
                    let actual = RecoveryScorer.recoveryTrace(
                        hrv: 55, rhr: 58, resp: value,
                        hrvBaseline: hrv, rhrBaseline: rhrCase.state, respBaseline: respCase.state,
                        sleepPerf: 0.85, skinTempDev: 0.2)
                    let expected = RecoveryScorer.recoveryTrace(
                        hrv: 55, rhr: 58, resp: value, hrvBaseline: hrv,
                        rhrBaseline: rhrCase.eligible ? rhrCase.state : nil,
                        respBaseline: respCase.eligible ? respCase.state : nil,
                        sleepPerf: 0.85, skinTempDev: 0.2)
                    XCTAssertEqual(actual.score?.bitPattern,
                                   score(rhrBase: rhrCase.state, respBase: respCase.state,
                                         respValue: value)?.bitPattern)
                    XCTAssertEqual(actual.trace, expected.trace)
                    XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge baseline rhr ") },
                                   rhrCase.eligible)
                    XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge term rhr ") },
                                   rhrCase.eligible)
                    XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge baseline resp ") },
                                   respCase.eligible)
                    XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge term resp ") },
                                   respCase.eligible && value != nil)
                    let dropped = actual.trace.first { $0.hasPrefix("charge nilTerm dropped=") } ?? ""
                    XCTAssertEqual(dropped.contains("rhr"), !rhrCase.eligible)
                    XCTAssertEqual(dropped.contains("resp"), !respCase.eligible || value == nil)
                }
            }
        }
    }

    func testDominantHRVGateStillControlsScoreDriversAndTrace() {
        for status in [BaselineStatus.calibrating, .stale] {
            let coldHrv = baseline(50, 8, status: status)
            for rhrCase in optionalStates(60, 4) {
                for respCase in optionalStates(16, 2) {
                    XCTAssertNil(RecoveryScorer.recovery(
                        hrv: 55, rhr: 58, resp: 14,
                        hrvBaseline: coldHrv, rhrBaseline: rhrCase.state, respBaseline: respCase.state,
                        sleepPerf: 0.85, skinTempDev: 0.2))
                    XCTAssertTrue(RecoveryScorer.chargeDrivers(
                        hrv: 55, rhr: 58, resp: 14,
                        hrvBaseline: coldHrv, rhrBaseline: rhrCase.state, respBaseline: respCase.state,
                        sleepPerf: 0.85, skinTempDev: 0.2).isEmpty)
                    let trace = RecoveryScorer.recoveryTrace(
                        hrv: 55, rhr: 58, resp: 14,
                        hrvBaseline: coldHrv, rhrBaseline: rhrCase.state, respBaseline: respCase.state,
                        sleepPerf: 0.85, skinTempDev: 0.2)
                    XCTAssertNil(trace.score)
                    XCTAssertEqual(trace.trace.count, 1)
                    XCTAssertTrue(trace.trace.first?.contains("hrvBaselineNotUsable") ?? false)
                }
            }
        }
    }
}
