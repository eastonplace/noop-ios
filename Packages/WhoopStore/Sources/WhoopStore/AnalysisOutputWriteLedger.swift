import Foundation

/// Ephemeral receipts for the explicit derived-output transactions of one analysis pass.
/// Other callers do not receive this ledger and cannot have their input mutations acknowledged by it.
public final class AnalysisOutputWriteLedger: @unchecked Sendable {
    struct Transition {
        let generation: String
        let table: String
        let before: UInt64
        let after: UInt64
    }
    private let lock = NSLock()
    private var transitions: [Transition] = []

    public init() {}

    func record(generation: String, table: String, before: UInt64, after: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        transitions.append(.init(generation: generation, table: table, before: before, after: after))
    }

    func snapshot() -> [Transition] {
        lock.lock()
        defer { lock.unlock() }
        return transitions
    }
}
