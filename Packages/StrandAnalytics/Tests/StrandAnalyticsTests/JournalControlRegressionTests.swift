import XCTest
@testable import StrandAnalytics

final class JournalControlRegressionTests: XCTestCase {
    func testUnansweredDaysAreNotControls() throws {
        var outcomes: [String: Double] = [:]
        var yes: Set<String> = []
        var no: Set<String> = []

        for index in 1...6 {
            let day = "yes-\(index)"
            yes.insert(day)
            outcomes[day] = Double(55 + index)
        }
        for index in 1...6 {
            let day = "no-\(index)"
            no.insert(day)
            outcomes[day] = Double(70 + index)
        }
        for index in 1...40 {
            outcomes["unanswered-\(index)"] = Double(20 + index % 3)
        }

        let effect = try XCTUnwrap(
            BehaviorInsights.effect(
                behaviorDays: yes,
                controlDays: no,
                outcomeByDay: outcomes,
                behavior: "Alcohol",
                outcome: "Recovery"
            )
        )

        XCTAssertEqual(effect.nWith, 6)
        XCTAssertEqual(effect.nWithout, 6)
        XCTAssertGreaterThan(effect.meanWithout, 60)
    }

    func testBehaviorWithNoExplicitNoDaysProducesNoEffect() {
        let outcomes = [
            "yes-1": 55.0,
            "yes-2": 56.0,
            "unanswered-1": 80.0,
            "unanswered-2": 82.0,
        ]

        XCTAssertNil(
            BehaviorInsights.effect(
                behaviorDays: ["yes-1", "yes-2"],
                controlDays: [],
                outcomeByDay: outcomes,
                behavior: "Late meal",
                outcome: "Recovery"
            )
        )
    }

    func testRankFailsClosedWhenCallerOmitsControls() {
        let outcomes = [
            "yes-1": 55.0,
            "yes-2": 56.0,
            "unanswered-1": 80.0,
            "unanswered-2": 82.0,
        ]

        let ranked = BehaviorInsights.rank(
            behaviors: ["Late meal": ["yes-1", "yes-2"]],
            controls: [:],
            outcomeByDay: outcomes,
            outcome: "Recovery"
        )

        XCTAssertTrue(ranked.isEmpty)
    }
}
