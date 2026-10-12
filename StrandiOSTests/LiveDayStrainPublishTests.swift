import XCTest
import Combine
import WhoopStore
@testable import NOOP

/// UIP-3 (part 0): the 20 s live-Strain tick advanced the raw frontier every time, so the Repository
/// republished and every observer re-rendered while the shown number stayed the same.
@MainActor
final class LiveDayStrainPublishTests: XCTestCase {
    private func live(_ stored: Double, frontier: Int?, day: String? = "2026-10-12") -> ResolvedStrain {
        ResolvedStrain(day: day, storedValue: stored, version: 2, origin: .liveDayV2, sourceId: "my-whoop",
                       asOf: frontier.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                       rawFrontierTs: frontier)
    }

    private func persisted(_ stored: Double, frontier: Int) -> ResolvedStrain {
        ResolvedStrain(day: "2026-10-12", storedValue: stored, version: 2, origin: .computedDailyV2,
                       sourceId: "my-whoop-noop", rawFrontierTs: frontier)
    }

    func testTwoTicksWithTheSameShownStrainPublishOnce() {
        let repository = Repository(deviceId: Repository.whoopSource)
        var changes = 0
        let subscription = repository.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        repository.setLiveDayStrain(live(40.0, frontier: 1_000))
        let afterFirstTick = changes
        XCTAssertGreaterThan(afterFirstTick, 0)

        // Stored 40.0 and 40.1 both show as 8.4 on the 0...21 scale; only the frontier moved.
        repository.setLiveDayStrain(live(40.1, frontier: 1_020))
        XCTAssertEqual(changes, afterFirstTick, "an unchanged shown Strain republished the repository")
        XCTAssertEqual(repository.liveDayStrain?.rawFrontierTs, 1_000)

        // 41.0 shows as 8.6.
        repository.setLiveDayStrain(live(41.0, frontier: 1_040))
        XCTAssertGreaterThan(changes, afterFirstTick)
        XCTAssertEqual(repository.liveDayStrain?.storedValue, 41.0)
    }

    func testPublishRuleTracksWhatAPersonCanSee() {
        let held = live(40.0, frontier: 1_000)
        XCTAssertFalse(Repository.liveDayStrainNeedsPublish(current: nil, candidate: nil, persisted: nil))
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(current: nil, candidate: held, persisted: nil))
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(current: held, candidate: nil, persisted: nil))
        XCTAssertFalse(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: live(40.1, frontier: 1_020), persisted: nil))
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: live(41.0, frontier: 1_020), persisted: nil))
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: live(40.0, frontier: 1_020, day: "2026-10-13"), persisted: nil))
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: live(40.0, frontier: nil), persisted: nil),
            "losing the frontier changes whether live can win")
    }

    func testHeldFrontierIsRefreshedOnceAPersistedRowOvertakesIt() {
        let held = live(40.0, frontier: 1_000)
        let candidate = live(40.1, frontier: 1_020)
        XCTAssertFalse(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: candidate, persisted: persisted(39.0, frontier: 900)),
            "live still wins with its held frontier")
        XCTAssertTrue(Repository.liveDayStrainNeedsPublish(
            current: held, candidate: candidate, persisted: persisted(39.0, frontier: 1_010)),
            "the held frontier would let an older persisted row win")
    }
}
