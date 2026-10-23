#if os(iOS)
import Combine
import XCTest
@testable import NOOP

@MainActor
final class JournalVoiceTests: XCTestCase {
    func testFinishAcceptsFinalTranscriptAfterCaptureEnds() async {
        let capture = JournalCaptureDouble()
        let voice = JournalVoice(capture: capture)
        await voice.start()
        capture.emit(.transcript("I took", isFinal: false))
        voice.finish()

        XCTAssertEqual(voice.phase, .finishing)
        capture.emit(.transcript("I took creatine", isFinal: true))

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(voice.transcript, "I took creatine")
        XCTAssertNil(voice.errorText)
    }

    func testCancelErasesTranscriptAndRejectsLateCallbacks() async {
        let capture = JournalCaptureDouble()
        let voice = JournalVoice(capture: capture)
        await voice.start()
        capture.emit(.transcript("I took creatine", isFinal: false))
        voice.cancel()
        capture.emit(.transcript("I took caffeine", isFinal: true))

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(voice.transcript, "")
        XCTAssertNil(voice.errorText)
    }

    func testOldRecordingCannotOverwriteNewRecording() async {
        let capture = JournalCaptureDouble()
        let voice = JournalVoice(capture: capture)
        await voice.start()
        let oldCallback = capture.callbacks[0]
        voice.cancel()
        await voice.start()
        capture.emit(.transcript("Current entry", isFinal: false))
        oldCallback(.transcript("Old entry", isFinal: true))

        XCTAssertEqual(voice.phase, .recording)
        XCTAssertEqual(voice.transcript, "Current entry")
        voice.cancel()
    }

    func testPermissionDenialEndsRequestWithARecoverableMessage() async {
        let capture = JournalCaptureDouble()
        capture.startError = JournalVoiceFailure.speechPermissionDenied
        let voice = JournalVoice(capture: capture)
        await voice.start()

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(voice.transcript, "")
        XCTAssertNotNil(voice.errorText)
    }

    func testCancellationDuringPermissionRequestCannotStartRecordingLater() async {
        let capture = JournalCaptureDouble()
        capture.holdStart = true
        let voice = JournalVoice(capture: capture)
        let operation = Task { await voice.start() }
        while capture.startContinuation == nil { await Task.yield() }
        voice.cancel()
        capture.startContinuation?.resume()
        capture.startContinuation = nil
        await operation.value

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(voice.transcript, "")
    }

    func testFinalizationTimeoutKeepsPartialTextAndExplainsItNeedsReview() async {
        let capture = JournalCaptureDouble()
        let voice = JournalVoice(capture: capture, finalizationTimeout: .zero)
        await voice.start()
        capture.emit(.transcript("I took creatine", isFinal: false))
        let completed = expectation(description: "Finalization timeout returns to idle")
        let observation = voice.$phase.dropFirst().filter { $0 == .idle }.sink { _ in completed.fulfill() }
        voice.finish()
        await fulfillment(of: [completed], timeout: 2)
        observation.cancel()

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertEqual(voice.transcript, "I took creatine")
        XCTAssertNotNil(voice.errorText)
    }

    func testOversizedTranscriptIsBoundedAndEndsCapture() async {
        let capture = JournalCaptureDouble()
        let voice = JournalVoice(capture: capture)
        await voice.start()
        capture.emit(.transcript(String(repeating: "é", count: 4_001), isFinal: false))

        XCTAssertEqual(voice.phase, .idle)
        XCTAssertLessThanOrEqual(voice.transcript.utf8.count, 4_000)
        XCTAssertNotNil(voice.errorText)
    }
}

@MainActor
private final class JournalCaptureDouble: JournalVoiceCapture {
    var callbacks: [@MainActor @Sendable (JournalVoiceEvent) -> Void] = []
    var startError: Error?
    var holdStart = false
    var startContinuation: CheckedContinuation<Void, Never>?

    func start(receive: @escaping @MainActor @Sendable (JournalVoiceEvent) -> Void) async throws {
        callbacks.append(receive)
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if let startError { throw startError }
    }

    func emit(_ event: JournalVoiceEvent) { callbacks.last?(event) }
    func finish() {}
    func cancel() {}
}
#endif
