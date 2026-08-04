import Testing
@testable import NoopPhase34Core

private struct Row: Equatable { let day: String; let value: Int }

@Test func exactDayMergeClearsAuthoritativeMissingAndPreservesOtherDays() {
    let existing = [Row(day: "2026-08-01", value: 1), Row(day: "2026-08-02", value: 2)]
    let result = ExactDayCacheMerge.replacing(
        existing: existing,
        incoming: [],
        authoritativeKeys: ["2026-08-02"],
        key: \.day,
        areInIncreasingOrder: { $0.day < $1.day }
    )
    #expect(result == [Row(day: "2026-08-01", value: 1)])
}
