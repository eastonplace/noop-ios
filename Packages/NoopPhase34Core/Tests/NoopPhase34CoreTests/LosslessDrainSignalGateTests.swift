import Foundation
import Testing
@testable import NoopPhase34Core

private actor ControlledDrainOperation {
    private var callCount = 0
    private var firstPassContinuation: CheckedContinuation<Void, Never>?

    func run() async -> Int {
        callCount += 1
        let value = callCount
        if value == 1 {
            await withCheckedContinuation { continuation in
                firstPassContinuation = continuation
            }
        }
        return value
    }

    func hasStarted() -> Bool { callCount > 0 }

    func releaseFirstPass() {
        firstPassContinuation?.resume()
        firstPassContinuation = nil
    }
}

@Test func explicitDrainCombinerAccumulatesEveryCoalescedPass() async {
    let operation = ControlledDrainOperation()
    let gate = LosslessDrainSignalGate<Int>(
        combine: { $0 + $1 },
        operation: { await operation.run() }
    )

    let first = Task { await gate.signal() }
    while !(await operation.hasStarted()) { await Task.yield() }

    let second = Task { await gate.signal() }
    while !(await gate.hasPendingDrainForTesting) { await Task.yield() }

    await operation.releaseFirstPass()

    #expect(await first.value == 3)
    #expect(await second.value == 3)
}
