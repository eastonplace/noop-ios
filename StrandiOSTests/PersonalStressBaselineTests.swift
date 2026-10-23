import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

final class PersonalStressBaselineTests: XCTestCase {
    private func scope(sourceIDs: [String] = ["active", "my-whoop"],
                       context: String = "database-a:profile-a", revision: Int = 1,
                       dataVersion: Int = 0, lineage: String = "active:epoch-1",
                       invalidationEpoch: UInt64 = 0, isFenced: Bool = false) -> StressReadScope {
        StressReadScope(sourceIDs: sourceIDs, sourceContext: context,
                        sourceLineage: lineage,
                        repositoryRevision: revision, dataVersion: dataVersion,
                        invalidationEpoch: invalidationEpoch, isFenced: isFenced)
    }

    func testReadIdentityChangesForEverySourceAndHistoryInvalidation() {
        let original = scope()
        XCTAssertNotEqual(original, scope(sourceIDs: ["other", "my-whoop"]))
        XCTAssertNotEqual(original, scope(sourceIDs: ["my-whoop", "active"]))
        XCTAssertNotEqual(original, scope(sourceIDs: []))
        XCTAssertNotEqual(original, scope(context: "database-b:profile-a"))
        XCTAssertNotEqual(original, scope(revision: 2))
        XCTAssertNotEqual(original, scope(dataVersion: 1))
        XCTAssertNotEqual(original, scope(lineage: "active:epoch-2"))
        XCTAssertNotEqual(original, scope(invalidationEpoch: 1))
        XCTAssertNotEqual(original, scope(isFenced: true))
    }

    func testForegroundTaskRestartsForPreferenceDateAndTimezoneChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 10, day: 22, hour: 12)))
        let original = ForegroundStressTaskKey(scope: scope(), personalBaseline: false, now: today, calendar: calendar)
        XCTAssertNotEqual(original, ForegroundStressTaskKey(scope: scope(), personalBaseline: true, now: today, calendar: calendar))
        XCTAssertNotEqual(original, ForegroundStressTaskKey(scope: scope(), personalBaseline: false,
            now: today.addingTimeInterval(86_400), calendar: calendar))
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        XCTAssertNotEqual(original, ForegroundStressTaskKey(scope: scope(), personalBaseline: false, now: today, calendar: calendar))
    }

    func testBuildingEstablishedAndStaleCopiesAreShortAndPlain() {
        let building = PersonalStressBaselineCopy(PersonalStressBaseline.resolve(dailyHR: [60, 60]))
        XCTAssertEqual(building.title, "Learning your normal · 2 of 4 days")
        XCTAssertEqual(building.detail, "Uses your last 30 days of daytime heart rate. Until then, today is compared with itself.")
        let one = PersonalStressBaselineCopy(PersonalStressBaseline.resolve(dailyHR: [60]))
        XCTAssertEqual(one.title, "Learning your normal · 1 of 4 days")
        let established = PersonalStressBaselineCopy(PersonalStressBaseline.resolve(dailyHR: Array(repeating: 60, count: 30)))
        XCTAssertEqual(established.title, "Compared with your normal from the last 30 days.")
        XCTAssertNil(established.detail)
        let values: [Double?] = Array(repeating: 60, count: 14) + Array(repeating: nil, count: 16)
        let stale = PersonalStressBaselineCopy(PersonalStressBaseline.resolve(dailyHR: values))
        XCTAssertEqual(stale.title, "Your normal is out of date. Wear your strap for a few days to refresh it.")
        XCTAssertNil(stale.detail)
        for copy in [building, one, established, stale] {
            let text = [copy.title, copy.detail ?? ""].joined(separator: " ").lowercased()
            for banned in ["lens", "ribbon", "covered", "quiet daytime", "hr only", "day-relative"] {
                XCTAssertFalse(text.contains(banned), "\(banned) in \(text)")
            }
        }
    }
}

@MainActor
final class PersonalStressBaselineRepositoryTests: XCTestCase {
    func testRepairedSourceAndCanonicalHistoryUseOneConsistentReference() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.adoptActiveDeviceId("active-strap")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 10, day: 22, hour: 12)))
        let midnight = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        var active: [HRSample] = []
        var canonical: [HRSample] = []
        for back in 1...4 {
            let hour = midnight - back * 86_400 + 9 * 3_600
            active += (0..<300).map { .init(ts: hour + $0, bpm: 60) }
            canonical += (0..<300).map { .init(ts: hour + $0, bpm: 80) }
        }
        canonical += (0..<300).map { .init(ts: midnight + 9 * 3_600 + $0, bpm: 75) }
        _ = try await store.insert(Streams(hr: active), deviceId: "active-strap")
        _ = try await store.insert(Streams(hr: canonical), deviceId: Repository.whoopSource)

        let first = try await repository.foregroundStressRead(now: now, calendar: calendar, personalBaseline: true)
        guard case .history(let activeBaseline) = first.baseline else { return XCTFail("Missing history") }
        XCTAssertEqual(activeBaseline.baseline, 60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(first.daytime.dayMean), 2, accuracy: 1e-9)

        repository.adoptActiveDeviceId("replacement-strap")
        let next = try await repository.foregroundStressRead(now: now, calendar: calendar, personalBaseline: true)
        guard case .history(let canonicalBaseline) = next.baseline else { return XCTFail("Missing history") }
        XCTAssertEqual(canonicalBaseline.baseline, 80, accuracy: 1e-9)
        XCTAssertNotEqual(first.scope, next.scope)
        XCTAssertLessThan(try XCTUnwrap(next.daytime.dayMean), 1.5)
    }

    func testFenceRaisedAndClearedDuringReadStillRejectsOldResult() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        do {
            _ = try await repository.foregroundStressReadForTesting(
                now: Date(), calendar: .current, personalBaseline: false,
                afterRead: {
                    repository.invalidateVerifiedExternalSurface()
                    repository.verifiedExternalSurfaceFenced = false
                })
            XCTFail("An intervening source fence must invalidate the read after it clears")
        } catch is CancellationError {}
    }

    func testSourceSwitchDuringReadRejectsOldResult() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        do {
            _ = try await repository.foregroundStressReadForTesting(
                now: Date(), calendar: .current, personalBaseline: false,
                afterRead: { repository.adoptActiveDeviceId("replacement-strap") })
            XCTFail("An old source's read must not publish after selection changes")
        } catch is CancellationError {}
    }

    func testDatabaseReplacementDuringReadRejectsOldResult() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        let replacement = try await WhoopStore.inMemory()
        do {
            _ = try await repository.foregroundStressReadForTesting(
                now: Date(), calendar: .current, personalBaseline: false,
                afterRead: { repository.setStoreForTesting(replacement) })
            XCTFail("A replaced database's result must not publish")
        } catch is CancellationError {}
    }

    func testFencedRepositoryRejectsForegroundRead() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(try await WhoopStore.inMemory())
        repository.invalidateVerifiedExternalSurface()
        do {
            _ = try await repository.foregroundStressRead(personalBaseline: true)
            XCTFail("A source transition must not return a successful stress read")
        } catch is CancellationError {}
    }

    func testCancelledForegroundRequestNeverReturnsAnEmptySuccess() async throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.foregroundStressRead(personalBaseline: true)
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not be published as missing stress data")
        } catch is CancellationError {}
    }
}
