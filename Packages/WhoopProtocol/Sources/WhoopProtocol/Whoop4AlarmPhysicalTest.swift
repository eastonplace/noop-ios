import Foundation

/// Executes a temporary scheduled-alarm test without changing the saved wake preference.
/// Both observation hooks must be bounded: false means the observation deadline expired.
@MainActor
public enum Whoop4AlarmPhysicalTest {
    public struct Result: Equatable, Sendable {
        public let fireObserved: Bool
        public let restoreConfirmed: Bool
    }

    public static func run(
        testWake: Date,
        restoreWake: Date,
        arm: @MainActor (Date) -> Void,
        observeFire: @MainActor () async -> Bool,
        restoreConfirmed: @MainActor () async -> Bool
    ) async -> Result {
        arm(testWake)
        let fireObserved = await observeFire()
        // Restoration is unconditional, including when fire observation times out or returns after
        // cancellation. A successful test must never leave its temporary wake time on the strap.
        arm(restoreWake)
        let restorationObserved = await restoreConfirmed()
        return Result(fireObserved: fireObserved, restoreConfirmed: restorationObserved)
    }
}
