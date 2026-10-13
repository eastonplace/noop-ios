#if os(iOS)
import XCTest
import AppIntents
@testable import NOOP

@MainActor
final class LocalCoachIntentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> LocalCoachPendingRequestStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoachIntentTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return LocalCoachPendingRequestStore(directory: directory)
    }

    private func context(_ source: String = "source-a", personal: Bool = true,
                         enabled: Bool = true, fenced: Bool = false) -> LocalCoachPendingRequestStore.Context {
        .init(sourceID: source, enabled: enabled, usePersonalData: personal,
              memoryEnabled: true, isFenced: fenced)
    }

    func testColdLaunchConsumesEachRequestOnlyOnceInOrder() throws {
        let original = try store()
        try original.updateContext(context())
        let first = try original.enqueue("  Review my sleep  ", now: now)
        let second = try original.enqueue("Plan my training", now: now)
        let reopened = LocalCoachPendingRequestStore(directory: original.directory)
        try reopened.updateContext(context())
        XCTAssertEqual(try reopened.consume(now: now)?.id, first.id)
        XCTAssertEqual(try original.consume(now: now)?.id, second.id)
        XCTAssertNil(try reopened.consume(now: now))
        XCTAssertFalse(try original.hasPending(now: now))
        XCTAssertEqual(first.question, "Review my sleep")
        XCTAssertEqual(first.context?.sourceID, "source-a")
    }

    func testExpiryAndFutureDatesCannotReplay() throws {
        let queue = try store()
        _ = try queue.enqueue("Expired", now: now.addingTimeInterval(-LocalCoachPendingRequestStore.lifetime))
        XCTAssertNil(try queue.consume(now: now))
        _ = try queue.enqueue("Future", now: now.addingTimeInterval(120))
        XCTAssertNil(try queue.consume(now: now))
    }

    func testQueueIsBoundedAndDoesNotOverwriteAnExistingDraft() throws {
        let queue = try store()
        for index in 0..<LocalCoachPendingRequestStore.maximumRequests {
            _ = try queue.enqueue("Question \(index)", now: now)
        }
        XCTAssertThrowsError(try queue.enqueue("Overflow", now: now))
        XCTAssertEqual(try queue.consume(now: now)?.question, "Question 0")
        XCTAssertLessThanOrEqual(try Data(contentsOf: queue.fileURL).count,
                                 LocalCoachPendingRequestStore.maximumFileBytes)
    }

    func testRejectsEmptyOversizedAndControlCharacterQuestions() throws {
        let queue = try store()
        for question in [" \n\t ", String(repeating: "🧠", count: 1_001), "Hi\u{0000}there"] {
            XCTAssertThrowsError(try queue.enqueue(question, now: now))
        }
        XCTAssertFalse(try queue.hasPending(now: now))
    }

    func testSourceChangeClearsRequestsBeforeConsumption() throws {
        let queue = try store()
        try queue.updateContext(context())
        _ = try queue.enqueue("Source A question", now: now)
        try queue.updateContext(context("source-b"))
        XCTAssertNil(try queue.consume(now: now))
        XCTAssertNil(try LocalCoachPendingRequestStore(directory: queue.directory).consume(now: now))
    }

    func testConsentChangeClearsOldRequestsButAllowsNewEditableQuestions() throws {
        let queue = try store()
        try queue.updateContext(context())
        _ = try queue.enqueue("Private question", now: now)
        try queue.updateContext(context(personal: false))
        XCTAssertNil(try queue.consume(now: now))
        _ = try queue.enqueue("General training question", now: now)
        XCTAssertEqual(try queue.consume(now: now)?.context?.usePersonalData, false)
    }

    func testDisabledOrFencedCoachRejectsRequests() throws {
        let queue = try store()
        for scope in [context(enabled: false), context(fenced: true)] {
            try queue.updateContext(scope)
            XCTAssertThrowsError(try queue.enqueue("Question", now: now))
            XCTAssertNil(try queue.consume(now: now))
        }
    }

    func testFirstLaunchCanReviewUnscopedQuestionWithoutGrantingDataConsent() throws {
        let queue = try store()
        _ = try queue.enqueue("Help me plan a workout", now: now)
        try queue.updateContext(context(personal: false))
        let request = try XCTUnwrap(queue.consume(now: now))
        XCTAssertNil(request.context)
        XCTAssertEqual(request.question, "Help me plan a workout")
        XCTAssertNil(try queue.consume(now: now))
    }

    func testCorruptOrFutureSchemaFailsClosedWithoutOverwriting() throws {
        let queue = try store()
        for bytes in [Data("not json".utf8), Data("{\"version\":999,\"requests\":[]}".utf8)] {
            try bytes.write(to: queue.fileURL)
            XCTAssertThrowsError(try queue.consume(now: now))
            XCTAssertThrowsError(try queue.enqueue("New question", now: now))
            XCTAssertEqual(try Data(contentsOf: queue.fileURL), bytes)
        }
    }

    func testOversizedFileIsRejectedBeforeDecoding() throws {
        let queue = try store()
        let bytes = Data(repeating: 32, count: LocalCoachPendingRequestStore.maximumFileBytes + 1)
        try bytes.write(to: queue.fileURL)
        XCTAssertThrowsError(try queue.consume(now: now))
        XCTAssertEqual(try Data(contentsOf: queue.fileURL).count, bytes.count)
    }

    func testShortcutsStayWithinBudgetAndPreserveExistingActions() {
        XCTAssertEqual(NOOPShortcuts.appShortcuts.count, 10)
        XCTAssertTrue(AskLocalCoachIntent.openAppWhenRun)
        XCTAssertTrue(LocalCoachPlanIntent.openAppWhenRun)
        XCTAssertTrue(SyncStrapIntent.openAppWhenRun)
        XCTAssertTrue(BuzzStrapIntent.openAppWhenRun)
        XCTAssertFalse(LocalCoachShortcutPrompt.plan(.review).isEmpty)
    }

    func testCoachIntentsRequireAuthenticationOnTheLocalDevice() {
        let policies: [IntentAuthenticationPolicy] = [
            AskLocalCoachIntent.authenticationPolicy,
            LocalCoachMorningIntent.authenticationPolicy,
            LocalCoachEveningIntent.authenticationPolicy,
            LocalCoachWeeklyIntent.authenticationPolicy,
            LocalCoachActivityIntent.authenticationPolicy,
            LocalCoachSleepIntent.authenticationPolicy,
            LocalCoachPlanIntent.authenticationPolicy
        ]
        XCTAssertEqual(policies, Array(repeating: .requiresLocalDeviceAuthentication, count: 7))
    }

    func testInvalidPhotoHasActionableError() async {
        do {
            _ = try await LocalCoachAttachment.extractWorkoutText(from: Data("not an image".utf8))
            XCTFail("Invalid image should fail")
        } catch {
            XCTAssertEqual(error as? LocalCoachAttachmentError, .invalidImage)
        }
    }
}
#endif
