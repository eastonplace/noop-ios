#if DEBUG && targetEnvironment(simulator) && os(iOS)
import Foundation

/// A shell UI fixture only. Native live-model tests keep using the Apple model.
enum CoachShellFixture {
    enum Failure: Error { case unexpectedPrompt }

    static func isRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.contains("--noop-coach-shell-qa") && arguments.contains("--noop-coach-shell-fixture")
    }
}

@MainActor
struct CoachShellFixtureModelDriver: LocalCoachModelDriver {
    var availability: LocalCoachAvailability { .available }
    var contextCapacity: Int? { 4_096 }
    private let suspend: @MainActor @Sendable () async throws -> Void

    init(suspend: @escaping @MainActor @Sendable () async throws -> Void = { await Task.yield() }) {
        self.suspend = suspend
    }

    func stream(_ request: LocalCoachRequest, tools: [LocalCoachToolDescriptor],
                read: @escaping LocalCoachRead, receive: @escaping LocalCoachReceive) async throws {
        guard request.question == "This is a software check. Reply with the single word READY." else {
            throw CoachShellFixture.Failure.unexpectedPrompt
        }
        try Task.checkCancellation()
        receive("REA")
        try await suspend()
        try Task.checkCancellation()
        receive("READY")
    }
}
#endif
