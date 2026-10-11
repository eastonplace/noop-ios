import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// The time-in-zone split for a workout window: zones follow the profile's max heart rate (the person's own override,
/// else the age-derived estimate) and a long session is read whole.
@MainActor
final class WorkoutZoneMinutesTests: XCTestCase {
    private let start = 1_800_000_000

    private func steady(_ bpm: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    // MARK: Max heart rate

    func testOverrideWinsAndTanakaIsTheFallback() {
        XCTAssertEqual(ProfileStore.hrMax(age: 40, override: 0), 180)        // 208 - 0.7 x 40
        XCTAssertEqual(ProfileStore.hrMax(age: 40, override: 195), 195)
        XCTAssertEqual(ProfileStore.hrMax(age: 30, override: 0), 187)        // 208 - 21
    }

    func testANegativeOverrideIsNotAnOverride() {
        XCTAssertEqual(ProfileStore.hrMax(age: 40, override: -5), 180)
    }

    func testTheSavedOverrideIsReadFromTheProfilesOwnKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkoutZoneMinutesTests.\(UUID().uuidString)"))
        XCTAssertEqual(ProfileStore.storedHrMaxOverride(defaults), 0)
        defaults.set(172, forKey: "profile.hrMaxOverride")
        XCTAssertEqual(ProfileStore.storedHrMaxOverride(defaults), 172)
    }

    // MARK: Zones

    func testAgeAloneSetsTheZonesWhenThereIsNoOverride() throws {
        // 140 bpm at max 187 (age 30) is 75% of max: Zone 3.
        let minutes = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 30, hrMaxOverride: 0))
        XCTAssertEqual(minutes.count, 5)
        XCTAssertEqual(minutes[2], 10, accuracy: 0.01)
        XCTAssertEqual(minutes.reduce(0, +), 10, accuracy: 0.01)
    }

    func testAnOverrideMovesTheSameHeartRateIntoAHarderZone() throws {
        // The same 140 bpm against a max of 160 is 87.5%: Zone 4, not Zone 3.
        let minutes = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 30, hrMaxOverride: 160))
        XCTAssertEqual(minutes[3], 10, accuracy: 0.01)
        XCTAssertEqual(minutes[2], 0, accuracy: 0.01)
    }

    func testAgeIsIgnoredOnceThereIsAnOverride() throws {
        let young = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 20, hrMaxOverride: 160))
        let old = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 70, hrMaxOverride: 160))
        XCTAssertEqual(young, old)
    }

    func testNoSamplesAndNothingInAnyZoneAreNil() {
        XCTAssertNil(Repository.zoneMinutes(samples: [], age: 30, hrMaxOverride: 0))
        // 40 bpm is under Zone 1 for any plausible max: below-zone time is not zone time.
        XCTAssertNil(Repository.zoneMinutes(samples: steady(40, seconds: 120), age: 30, hrMaxOverride: 0))
    }

    func testAMissingAgeReadsAsThirty() throws {
        let unknown = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 0, hrMaxOverride: 0))
        let thirty = try XCTUnwrap(Repository.zoneMinutes(samples: steady(140, seconds: 600), age: 30, hrMaxOverride: 0))
        XCTAssertEqual(unknown, thirty)
    }

    // MARK: The read itself

    func testALongSessionIsReadWholeAndTheOverrideIsHonoured() async throws {
        // Three hours at one sample a second: well past the 8,000-sample default read.
        let seconds = 3 * 3_600
        XCTAssertGreaterThan(seconds, 8_000)
        XCTAssertLessThanOrEqual(seconds, Repository.workoutZoneSampleLimit)

        let deviceId = Repository.whoopSource
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        try await store.insert(Streams(hr: steady(140, seconds: seconds)), deviceId: deviceId)
        let repository = Repository(deviceId: deviceId)
        repository.setStoreForTesting(store)

        let byAge = await repository.workoutZoneMinutes(
            from: start, to: start + seconds, age: 30, hrMaxOverride: 0)
        let byOverride = await repository.workoutZoneMinutes(
            from: start, to: start + seconds, age: 30, hrMaxOverride: 160)

        let wanted = Double(seconds) / 60
        XCTAssertEqual(try XCTUnwrap(byAge).reduce(0, +), wanted, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(byAge)[2], wanted, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(byOverride)[3], wanted, accuracy: 1)
    }

    func testAnEmptyWindowReadsAsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let none = await repository.workoutZoneMinutes(from: start, to: start + 600, age: 30, hrMaxOverride: 0)
        XCTAssertNil(none)
        let backwards = await repository.workoutZoneMinutes(from: start + 600, to: start, age: 30, hrMaxOverride: 0)
        XCTAssertNil(backwards)
    }
}
