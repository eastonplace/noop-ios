#if os(iOS)
import Foundation

enum SmartAlarmBackgroundTerminalEvent: Equatable, Sendable {
    case success
    case failure
    case missingRuntime
    case missingRequest
    case malformedRequest
    case cancelled
    case expired
    case evaluationError

    var taskSucceeded: Bool { self == .success }
}

struct SmartAlarmBackgroundCompletionState: Equatable, Sendable {
    private(set) var terminalEvent: SmartAlarmBackgroundTerminalEvent?

    @discardableResult
    mutating func complete(_ event: SmartAlarmBackgroundTerminalEvent) -> Bool {
        guard terminalEvent == nil else { return false }
        terminalEvent = event
        return true
    }
}

/// Thread-safe completion ownership for `BGTask.setTaskCompleted(success:)`. The first terminal event wins;
/// expiration can therefore complete false immediately while a cancelled operation unwinds, and any late
/// success/failure callback is ignored rather than completing the system task twice.
final class SmartAlarmBackgroundCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var state = SmartAlarmBackgroundCompletionState()
    private let completion: @Sendable (Bool) -> Void

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func complete(_ event: SmartAlarmBackgroundTerminalEvent) -> Bool {
        lock.lock()
        let accepted = state.complete(event)
        lock.unlock()
        guard accepted else { return false }
        completion(event.taskSucceeded)
        return true
    }

    var terminalEvent: SmartAlarmBackgroundTerminalEvent? {
        lock.lock()
        let event = state.terminalEvent
        lock.unlock()
        return event
    }
}
#endif
