#if DEBUG && targetEnvironment(simulator) && os(iOS)
import XCTest
@testable import NOOP

@MainActor
final class CoachShellFixtureTests: XCTestCase {
    private let noRead: LocalCoachRead = { _, _, _ in
        XCTFail("The shell fixture must not read records.")
        return .init(text: "", evidence: [])
    }

    func testSelectionRequiresBothExplicitShellFlags() {
        for arguments in [[], ["--noop-coach-shell-qa"], ["--noop-coach-shell-fixture"],
                          ["--noop-coach-shell-qa", "--demo-coach-journal"]] {
            XCTAssertFalse(CoachShellFixture.isRequested(arguments: arguments))
        }
        XCTAssertTrue(CoachShellFixture.isRequested(arguments: ["--noop-coach-shell-qa", "--noop-coach-shell-fixture"]))
    }

    func testEmitsCumulativeTextAcrossSuspensionWithoutReadingRecords() async throws {
        var chunks: [String] = []
        var suspended = false
        let driver = CoachShellFixtureModelDriver(suspend: {
            XCTAssertEqual(chunks, ["REA"])
            suspended = true
            await Task.yield()
        })
        try await driver.stream(request(), tools: [], read: noRead, receive: { chunks.append($0) })
        XCTAssertTrue(suspended)
        XCTAssertEqual(chunks, ["REA", "READY"])
    }

    func testCancellationBeforeOrBetweenChunksPreventsFurtherOutput() async {
        for cancelBeforeStart in [true, false] {
            var chunks: [String] = []
            let driver = CoachShellFixtureModelDriver(suspend: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
            let task = Task {
                try await driver.stream(request(), tools: [], read: noRead, receive: { chunks.append($0) })
            }
            if cancelBeforeStart { task.cancel() }
            do {
                try await task.value
                XCTFail("A cancelled fixture must not complete.")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected cancellation error: \(error)")
            }
            XCTAssertEqual(chunks, cancelBeforeStart ? [] : ["REA"])
        }
    }

    func testRejectsAnyPromptOtherThanTheExactSoftwareCheck() async {
        for question in ["", "This is a software check. Reply with the single word READY. ", "How did I sleep?"] {
            let driver = CoachShellFixtureModelDriver(suspend: { XCTFail("An unsupported prompt must not start streaming.") })
            do {
                try await driver.stream(request(question), tools: [], read: noRead,
                                        receive: { _ in XCTFail("An unsupported prompt must not emit text.") })
                XCTFail("An unsupported prompt must be rejected.")
            } catch CoachShellFixture.Failure.unexpectedPrompt {
            } catch {
                XCTFail("Unexpected prompt error: \(error)")
            }
        }
    }

    private func request(_ question: String = "This is a software check. Reply with the single word READY.") -> LocalCoachRequest {
        .init(question: question, history: [], memories: [], style: "", customInstructions: "", context: "")
    }
}
#endif
