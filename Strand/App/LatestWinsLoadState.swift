
import Foundation

enum LatestWinsLoadTerminal: Equatable, Sendable {
    case loaded
    case empty
    case failed(String)
    case cancelled
}

/// Small request owner for screen-level asynchronous reads.
///
/// Each new request gets a strictly newer identifier. Only that request may publish a terminal state.
/// A cancelled or older task can finish, but it cannot overwrite a newer range or repository revision.
struct LatestWinsLoadState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case loading(requestID: UInt64)
        case loaded(requestID: UInt64)
        case empty(requestID: UInt64)
        case failed(requestID: UInt64, message: String)
        case cancelled(requestID: UInt64)
    }

    private(set) var currentRequestID: UInt64 = 0
    private(set) var phase: Phase = .idle

    @discardableResult
    mutating func begin() -> UInt64 {
        currentRequestID = currentRequestID == .max ? 1 : currentRequestID + 1
        phase = .loading(requestID: currentRequestID)
        return currentRequestID
    }

    func owns(_ requestID: UInt64) -> Bool {
        requestID == currentRequestID
    }

    @discardableResult
    mutating func finish(
        _ terminal: LatestWinsLoadTerminal,
        requestID: UInt64
    ) -> Bool {
        guard owns(requestID) else { return false }
        switch terminal {
        case .loaded:
            phase = .loaded(requestID: requestID)
        case .empty:
            phase = .empty(requestID: requestID)
        case .failed(let message):
            phase = .failed(requestID: requestID, message: message)
        case .cancelled:
            phase = .cancelled(requestID: requestID)
        }
        return true
    }

    var errorMessage: String? {
        guard case .failed(_, let message) = phase else { return nil }
        return message
    }
}
