import XCTest
import StrandDesign
import StrandAnalytics
import WhoopProtocol
@testable import NOOP

/// Time in zone: what a reading is credited, and that a workout restored from its readings lands on the same numbers as one
/// that counted them live.
final class PersonalZoneSecondsTests: XCTestCase {
    /// A maximum of 187: rest below 93.5, steady below 130.9, push above.
    private let thresholds = HRZoneStyle.Thresholds(hrMax: 187)
    private let t0 = 1_700_000_000

    private func sample(_ second: Int, _ bpm: Int) -> HRSample { HRSample(ts: t0 + second, bpm: bpm) }

    func testEachReadingIsCreditedTheSecondsSinceTheLastToItsOwnZone() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 80), thresholds: thresholds)   // the first credits nothing
        zones.append(sample(1, 80), thresholds: thresholds)   // rest +1
        zones.append(sample(2, 110), thresholds: thresholds)  // steady +1
        zones.append(sample(3, 150), thresholds: thresholds)  // push +1
        zones.append(sample(5, 150), thresholds: thresholds)  // push +2
        XCTAssertEqual(zones.seconds, [1, 1, 3])
        XCTAssertEqual(zones.total, 5)
    }

    func testAGapIsCreditedAtMostFiveSeconds() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 150), thresholds: thresholds)
        zones.append(sample(60, 150), thresholds: thresholds)  // the strap was quiet for a minute
        XCTAssertEqual(zones.seconds, [0, 0, PersonalZoneSeconds.maxCreditSeconds])
    }

    func testTheZoneBoundariesFollowTheWearersMaximum() {
        // 93 is rest and 94 is steady for a maximum of 187; 130 is steady and 131 is push.
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 93), thresholds: thresholds)
        zones.append(sample(1, 93), thresholds: thresholds)
        zones.append(sample(2, 94), thresholds: thresholds)
        zones.append(sample(3, 130), thresholds: thresholds)
        zones.append(sample(4, 131), thresholds: thresholds)
        XCTAssertEqual(zones.seconds, [1, 2, 1])
    }

    func testAPauseBreaksTheStretchSoTheFirstReadingAfterItCreditsNothing() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 150), thresholds: thresholds)
        zones.append(sample(1, 150), thresholds: thresholds)
        zones.breakStretch()
        zones.append(sample(600, 150), thresholds: thresholds)   // ten minutes later: nothing credited across the pause
        zones.append(sample(601, 150), thresholds: thresholds)
        XCTAssertEqual(zones.seconds, [0, 0, 2])
    }

    func testASecondReadingInTheSameSecondMovesWhatTheFirstWasCreditedToItsZone() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 80), thresholds: thresholds)
        zones.append(sample(3, 80), thresholds: thresholds)    // rest +3
        zones.append(sample(3, 150), thresholds: thresholds)   // replaces it: those 3 seconds are push
        XCTAssertEqual(zones.seconds, [0, 0, 3])
        zones.append(sample(3, 150), thresholds: thresholds)   // and again: nothing more
        XCTAssertEqual(zones.seconds, [0, 0, 3])
    }

    func testAnOutOfOrderReadingCreditsNothing() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(10, 150), thresholds: thresholds)
        zones.append(sample(5, 150), thresholds: thresholds)
        XCTAssertEqual(zones.total, 0)
    }

    // MARK: Restore parity

    /// Readings with repeated seconds, gaps, zone changes and two pauses.
    private func readings() -> [HRSample] {
        var result: [HRSample] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33)
        }
        var second = 0
        for _ in 0..<900 {
            second += [1, 1, 1, 2, 3, 7, 12][next() % 7]
            let bpm = 70 + next() % 110
            result.append(sample(second, bpm))
            if next() % 6 == 0 { result.append(sample(second, 70 + next() % 110)) }   // a second reading in the same second
        }
        return result
    }

    private func liveCounted(_ readings: [HRSample], pauses: WorkoutPauseLedger) -> PersonalZoneSeconds {
        var zones = PersonalZoneSeconds()
        var previous: HRSample?
        for reading in readings {
            // The live path drops readings stamped inside a pause and breaks the stretch when a pause opened between two.
            guard !pauses.isPausedSecond(reading.ts) else { continue }
            if let previous, pauses.separates(previous.ts, reading.ts) { zones.breakStretch() }
            zones.append(reading, thresholds: thresholds)
            previous = reading
        }
        return zones
    }

    func testARestoredWorkoutLandsOnTheSameNumbersAsOneCountedLive() {
        let all = readings()
        let first = all[all.count / 3].ts
        let second = all[2 * all.count / 3].ts
        var pauses = WorkoutPauseLedger()
        XCTAssertTrue(pauses.pause(at: Double(first) + 0.5))
        XCTAssertTrue(pauses.resume(at: Double(first) + 300.5))
        XCTAssertTrue(pauses.pause(at: Double(second) + 0.5))
        XCTAssertTrue(pauses.resume(at: Double(second) + 90.5))

        let live = liveCounted(all, pauses: pauses)
        // A restore starts from the readings the workout kept: one per second (the last of any repeated second), none paused.
        var canonical: [HRSample] = []
        for reading in all.sorted(by: { $0.ts < $1.ts }) {
            if canonical.last?.ts == reading.ts { canonical[canonical.count - 1] = reading } else { canonical.append(reading) }
        }
        let restored = PersonalZoneSeconds.compute(samples: pauses.activeSamples(canonical), pauses: pauses, thresholds: thresholds)
        XCTAssertEqual(restored.seconds, live.seconds)
        XCTAssertGreaterThan(live.total, 600, "the fixture is long enough to mean something")
    }

    func testAWorkoutWithoutPausesRestoresToTheSameNumbersToo() {
        let all = readings()
        let live = liveCounted(all, pauses: WorkoutPauseLedger())
        var canonical: [HRSample] = []
        for reading in all.sorted(by: { $0.ts < $1.ts }) {
            if canonical.last?.ts == reading.ts { canonical[canonical.count - 1] = reading } else { canonical.append(reading) }
        }
        XCTAssertEqual(PersonalZoneSeconds.compute(samples: canonical, pauses: WorkoutPauseLedger(), thresholds: thresholds).seconds,
                       live.seconds)
    }

    func testComputeTakesReadingsInAsTheLivePathDoes() {
        // A zero from a reconnect, a spike and a reading below any pulse are dropped; one without a timestamp too; a repeated
        // second keeps its last reading; and the order the readings arrive in does not matter.
        let noisy = [sample(6, 80), sample(0, 80), sample(1, 0), sample(3, 255), sample(4, 80), sample(4, 150), sample(5, 29),
                     HRSample(ts: 0, bpm: 80), sample(2, 80)]
        let clean = [sample(0, 80), sample(2, 80), sample(4, 150), sample(6, 80)]
        let expected = PersonalZoneSeconds.compute(samples: clean, pauses: WorkoutPauseLedger(), thresholds: thresholds)
        XCTAssertEqual(expected.seconds, [4, 0, 2])
        XCTAssertEqual(PersonalZoneSeconds.compute(samples: noisy, pauses: WorkoutPauseLedger(), thresholds: thresholds).seconds,
                       expected.seconds)
        XCTAssertEqual(PersonalZoneSeconds.canonical(noisy).map(\.ts), [t0, t0 + 2, t0 + 4, t0 + 6])
        XCTAssertEqual(PersonalZoneSeconds.canonical(noisy).map(\.bpm), [80, 80, 150, 80])
    }

    func testQuantizedSecondsRoundDownSoTheScreenChangesEveryFiveSeconds() {
        var zones = PersonalZoneSeconds()
        zones.append(sample(0, 150), thresholds: thresholds)
        for second in 1...7 { zones.append(sample(second, 150), thresholds: thresholds) }
        XCTAssertEqual(zones.seconds, [0, 0, 7])
        XCTAssertEqual(zones.quantized(step: 5), [0, 0, 5])
    }
}
