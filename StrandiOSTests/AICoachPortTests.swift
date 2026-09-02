import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class AICoachPortTests: XCTestCase {
    private func engine() -> AICoachEngine {
        AICoachEngine(repo: Repository(deviceId: Repository.whoopSource))
    }

    func testConversationOnlyExpiresWhenLocalDayMovesForward() {
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: nil, todayEpochDay: 100))
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: 100, todayEpochDay: 100))
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: 100, todayEpochDay: 101))
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: 101, todayEpochDay: 100))
    }

    func testStoredTranscriptKeepsNewestFortyMessages() {
        let engine = engine()
        for index in 0..<45 {
            engine.appendMessage(ChatMessage(role: .user, text: "message-\(index)"))
        }

        XCTAssertEqual(engine.messages.count, AICoachEngine.maxStoredMessages)
        XCTAssertEqual(engine.messages.first?.text, "message-5")
        XCTAssertEqual(engine.messages.last?.text, "message-44")
    }

    func testDayLineIncludesSleepStagesAndNormalizedEfficiency() {
        let line = engine().dayLine(
            DailyMetric(
                day: "2026-09-02", totalSleepMin: 450, efficiency: 0.94,
                deepMin: 90, remMin: 120, lightMin: 240, disturbances: 3,
                restingHr: 52, avgHrv: 63, recovery: 78, strain: 64,
                exerciseCount: 1, strainVersion: 2
            )
        )

        XCTAssertTrue(line.contains("deep 1.5h"))
        XCTAssertTrue(line.contains("REM 2.0h"))
        XCTAssertTrue(line.contains("light 4.0h"))
        XCTAssertTrue(line.contains("eff 94%"))
    }

    func testDayLineKeepsMissingSleepFieldsMissing() {
        let line = engine().dayLine(
            DailyMetric(
                day: "2026-09-02", totalSleepMin: nil, efficiency: nil,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                exerciseCount: nil, strainVersion: nil
            )
        )

        XCTAssertTrue(line.contains("deep —"))
        XCTAssertTrue(line.contains("REM —"))
        XCTAssertTrue(line.contains("light —"))
        XCTAssertTrue(line.contains("eff —"))
    }

    func testImportedWholePercentDoesNotScaleTwice() {
        XCTAssertEqual(engine().efficiencyPercentOrDash(94), "94%")
        XCTAssertEqual(engine().efficiencyPercentOrDash(0.94), "94%")
        XCTAssertEqual(engine().efficiencyPercentOrDash(nil), "—")
    }
}
