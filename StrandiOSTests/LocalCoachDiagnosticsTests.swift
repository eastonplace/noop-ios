#if os(iOS)
import XCTest
@testable import NOOP

@MainActor
final class LocalCoachDiagnosticsTests: XCTestCase {
    func testReportExcludesConversationMemoryAndHealthValuesByDefault() {
        let coach = LocalCoachEngine.preview()
        let text = LocalCoachDiagnostics.report(coach: coach, title: "Button failed",
                                               steps: "Open Coach", expected: "Open the plan",
                                               actual: "Nothing happens", checks: [])
        XCTAssertTrue(text.contains("Button failed"))
        XCTAssertTrue(text.contains("No conversation, memory, health values"))
        for message in coach.messages { XCTAssertFalse(text.contains(message.text)) }
        for memory in coach.memories { XCTAssertFalse(text.contains(memory.text)) }
        XCTAssertFalse(text.contains(coach.snapshot.context))
        XCTAssertFalse(text.contains("preview-synthetic"))
    }

    func testLocalChecksUseDisposableStorageAndSkipModelClaimsInPreview() async {
        let checks = await LocalCoachDiagnostics.runLocalChecks(preview: true)
        XCTAssertTrue(checks.contains { $0.id == "storage" && $0.status == .passed })
        XCTAssertTrue(checks.contains { $0.id == "tools" && $0.status == .passed })
        XCTAssertTrue(checks.contains { $0.id == "model" && $0.status == .skipped })
    }

    func testSyntheticModelGenerationWhenAvailable() async throws {
        guard LocalCoachDiagnostics.modelAvailable else { throw XCTSkip("Apple Intelligence is unavailable in this test environment.") }
        let result = try await LocalCoachDiagnostics.testModel()
        XCTAssertEqual(result.status, .passed, result.detail)
    }

    func testReadinessCheckAcceptsPunctuationButRejectsDifferentAnswers() {
        for response in ["READY", "READY.", "\nReady!\n", "`READY`"] {
            XCTAssertTrue(LocalCoachDiagnostics.isReadyReply(response), response)
        }
        for response in ["", "NOT READY", "READY for your next request", "I am ready"] {
            XCTAssertFalse(LocalCoachDiagnostics.isReadyReply(response), response)
        }
    }
}
#endif
