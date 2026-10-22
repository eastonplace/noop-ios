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
        await run(armTest: { arm(testWake) }, observeFire: observeFire,
                  restore: { arm(restoreWake) }, restoreConfirmed: restoreConfirmed)
    }

    /// Separate phases let restoration recompute the next saved occurrence even when the temporary
    /// alarm and original schedule had the same date. Dates do not identify operation ownership.
    public static func run(
        armTest: @MainActor () -> Void,
        observeFire: @MainActor () async -> Bool,
        restore: @MainActor () -> Void,
        restoreConfirmed: @MainActor () async -> Bool
    ) async -> Result {
        armTest()
        let fireObserved = await observeFire()
        // Restoration is unconditional, including when fire observation times out or returns after
        // cancellation. A successful test must never leave its temporary wake time on the strap.
        restore()
        let restorationObserved = await restoreConfirmed()
        return Result(fireObserved: fireObserved, restoreConfirmed: restorationObserved)
    }
}
