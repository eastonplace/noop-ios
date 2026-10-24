import XCTest
@testable import StrandAnalytics

final class WakeAlarmBackupReplacementTests: XCTestCase {
    private struct Request: Equatable { let id: String; let minutes: Int }
    private enum Failure: Error { case rejected }

    @MainActor
    func testFailedReplacementRestoresWorkingTimesWithCurrentGenerationIDs() async {
        let old = [Request(id: "old-a", minutes: 420), Request(id: "old-b", minutes: 430)]
        let new = [Request(id: "new-a", minutes: 420), Request(id: "new-b", minutes: 430),
                   Request(id: "new-c", minutes: 440)]
        var pending = old
        var failedOnce = false
        let outcome = await WakeAlarmBackupReplacement.replace(
            existing: old, proposed: new, otherCount: 60, identifier: { $0.id },
            matches: { $0.minutes == $1.minutes }, isCurrent: { true },
            remove: { ids in pending.removeAll { ids.contains($0.id) } },
            add: { request in
                if request.id == "new-b", !failedOnce { failedOnce = true; throw Failure.rejected }
                pending.removeAll { $0.id == request.id }
                pending.append(request)
            })
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(Set(pending.map(\.id)), ["new-a", "new-b"])
        XCTAssertEqual(Set(pending.map(\.minutes)), [420, 430])
    }

    @MainActor
    func testCapacityFailurePreservesCompatibleBackupAndCancelsDeletedTime() async {
        let old = [Request(id: "old-a", minutes: 420), Request(id: "old-deleted", minutes: 430)]
        let new = [Request(id: "new-a", minutes: 420), Request(id: "new-c", minutes: 440)]
        var pending = old
        let outcome = await WakeAlarmBackupReplacement.replace(
            existing: old, proposed: new, otherCount: 63, identifier: { $0.id },
            matches: { $0.minutes == $1.minutes }, isCurrent: { true },
            remove: { ids in pending.removeAll { ids.contains($0.id) } },
            add: { pending.append($0) })
        XCTAssertEqual(outcome, .insufficientCapacity)
        XCTAssertEqual(pending, [new[0]])
        pending.removeAll { $0.id.hasPrefix("old-") }
        XCTAssertEqual(pending, [new[0]], "A late predecessor cleanup must not remove the current fallback")
    }

    @MainActor
    func testSupersededAddCleansOnlyOwnGenerationAndDoesNotRestoreOldRequests() async {
        let old = [Request(id: "old-a", minutes: 420)]
        let new = [Request(id: "new-a", minutes: 420)]
        var pending = old
        var current = true
        let outcome = await WakeAlarmBackupReplacement.replace(
            existing: old, proposed: new, otherCount: 63, identifier: { $0.id },
            matches: { $0.minutes == $1.minutes }, isCurrent: { current },
            remove: { ids in pending.removeAll { ids.contains($0.id) } },
            add: { request in
                pending.append(request)
                pending.append(Request(id: "newer-generation", minutes: 440))
                current = false
            })
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(pending, [Request(id: "newer-generation", minutes: 440)])
    }

    @MainActor
    func testSuccessfulReplacementInstallsAllCurrentTimesThenRemovesOldIDs() async {
        let old = [Request(id: "old-a", minutes: 420)]
        let new = [Request(id: "new-a", minutes: 420), Request(id: "new-b", minutes: 430)]
        var pending = old
        let outcome = await WakeAlarmBackupReplacement.replace(
            existing: old, proposed: new, otherCount: 0, identifier: { $0.id },
            matches: { $0.minutes == $1.minutes }, isCurrent: { true },
            remove: { ids in pending.removeAll { ids.contains($0.id) } },
            add: { pending.append($0) })
        XCTAssertEqual(outcome, .scheduled)
        XCTAssertEqual(pending, new)
    }
    @MainActor
    func testFailedReplacementAdoptsFallbackBeforePredecessorCleanupEvenWithSpareCapacity() async {
        let old = [Request(id: "old-a", minutes: 420)]
        let new = [Request(id: "new-a", minutes: 420), Request(id: "new-b", minutes: 430),
                   Request(id: "new-c", minutes: 450)]
        var pending = old
        var failedOnce = false
        let outcome = await WakeAlarmBackupReplacement.replace(
            existing: old, proposed: new, otherCount: 60, identifier: { $0.id },
            matches: { $0.minutes == $1.minutes }, isCurrent: { true },
            remove: { ids in pending.removeAll { ids.contains($0.id) } },
            add: { request in
                if !failedOnce { failedOnce = true; throw Failure.rejected }
                pending.append(request)
            })
        XCTAssertEqual(outcome, .failed)
        pending.removeAll { $0.id == "old-a" }
        XCTAssertEqual(pending, [new[0]], "Fallback must belong to this generation before old work cleans up")
    }
}
