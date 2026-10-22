import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepMemoInputTests: XCTestCase {
    private let start = 1_749_517_200
    private let duration = 90 * 60

    private func gravity(moving: Bool, shift: Int = 0) -> [GravitySample] {
        (0..<duration).map { second in
            // Both orientations sum to 1 g. Their vector difference is real motion.
            let active = moving && (30 * 60..<45 * 60).contains(second)
            let x = active && second.isMultiple(of: 2) ? 1.0 : 0.0
            return GravitySample(ts: start + shift + second, x: x, y: 0, z: 1 - x)
        }
    }

    private func hr(shift: Int = 0) -> [HRSample] {
        (0..<duration).map { HRSample(ts: start + shift + $0, bpm: 52 + ($0 / 60) % 3) }
    }

    func testDetectionCacheDoesNotAliasDifferentGravityAxesWithTheSameSum() {
        let still = gravity(moving: false)
        let moving = (0..<duration).map { second in
            let x = second.isMultiple(of: 2) ? 1.0 : 0.0
            return GravitySample(ts: start + second, x: x, y: 0, z: 1 - x)
        }
        XCTAssertFalse(SleepStager.detectSleep(hr: hr(), gravity: still).isEmpty)
        // Tracing runs the detector's live ladder, so this is an independent uncached result.
        let uncached = SleepStager.detectSleep(hr: hr(), gravity: moving, traceSink: { _ in })
        XCTAssertTrue(uncached.isEmpty, "sustained movement must change the detector's actual result")
        XCTAssertEqual(SleepStager.detectSleep(hr: hr(), gravity: moving), uncached,
                       "a warm cache must not replay a still night for a moving stream")
    }

    func testV1StagingCacheDoesNotReplayStillStagesForEqualSumMotion() {
        let still = SleepStager.stageSession(start: start, end: start + duration,
                                            grav: gravity(moving: false), hr: hr(), rr: [], resp: [])
        let shift = 86_400
        let expected = SleepStager.stageSession(start: start + shift, end: start + shift + duration,
                                               grav: gravity(moving: true, shift: shift),
                                               hr: hr(shift: shift), rr: [], resp: []).map {
            StageSegment(start: $0.start - shift, end: $0.end - shift, stage: $0.stage)
        }
        XCTAssertNotEqual(still, expected, "the motion burst must change the actual V1 hypnogram")
        XCTAssertEqual(SleepStager.stageSession(start: start, end: start + duration,
                                               grav: gravity(moving: true), hr: hr(), rr: [], resp: []), expected)
    }

    func testV2StagingCacheDoesNotReplayStillStagesForEqualSumMotion() {
        let still = SleepStagerV2.stageSession(start: start, end: start + duration,
                                              grav: gravity(moving: false), hr: hr(), rr: [], resp: [])
        let shift = 2 * 86_400
        let expected = SleepStagerV2.stageSession(start: start + shift, end: start + shift + duration,
                                                 grav: gravity(moving: true, shift: shift),
                                                 hr: hr(shift: shift), rr: [], resp: []).map {
            StageSegment(start: $0.start - shift, end: $0.end - shift, stage: $0.stage)
        }
        XCTAssertNotEqual(still, expected, "the motion burst must change the actual V2 hypnogram")
        XCTAssertEqual(SleepStagerV2.stageSession(start: start, end: start + duration,
                                                 grav: gravity(moving: true), hr: hr(), rr: [], resp: []), expected)
    }

    func testV2ClipsUnorderedPaddedStreamsWithoutDiscardingTheNight() {
        let shift = 3 * 86_400
        let nightStart = start + shift
        let nightEnd = nightStart + duration
        let coveredGravity = gravity(moving: true, shift: shift)
        let coveredHR = hr(shift: shift)
        let before = nightStart - 1_000
        let after = nightEnd + 1_000
        // An early row followed by a late block and the night is a legitimate out-of-order batch.
        // Binary searching it as if sorted discards the covered night before the existing defensive sort.
        let unorderedGravity = [GravitySample(ts: before, x: 0, y: 0, z: 1)]
            + Array(repeating: GravitySample(ts: after, x: 0, y: 0, z: 1), count: duration + 1)
            + coveredGravity
        let unorderedHR = [HRSample(ts: before, bpm: 60)]
            + Array(repeating: HRSample(ts: after, bpm: 60), count: duration + 1)
            + coveredHR
        let expected = SleepStagerV2.stageSession(
            start: nightStart, end: nightEnd,
            grav: unorderedGravity.sorted { $0.ts < $1.ts },
            hr: unorderedHR.sorted { $0.ts < $1.ts }, rr: [], resp: [])
        XCTAssertTrue(expected.contains { $0.stage == "wake" },
                      "the covered motion burst must survive clipping")
        XCTAssertEqual(SleepStagerV2.stageSession(start: nightStart, end: nightEnd,
                                                 grav: unorderedGravity, hr: unorderedHR, rr: [], resp: []), expected)
    }
}
