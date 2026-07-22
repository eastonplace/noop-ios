import Foundation
import WhoopProtocol
import XCTest
@testable import NOOP

#if os(iOS)
final class ActiveWorkoutPersistenceTests: XCTestCase {
    private func sample(_ timestamp: Int, _ bpm: Int) -> HRSample {
        HRSample(ts: timestamp, bpm: bpm)
    }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        sport: String = "Tennis",
        samples: [HRSample] = [
            HRSample(ts: 1_700_000_001, bpm: 120),
            HRSample(ts: 1_700_000_061, bpm: 145),
        ],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrainState: LiveStrainState = .scored(storedValue: 8.4)
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(
            startSec: startSec,
            sport: sport,
            samples: samples,
            avgHr: avgHr,
            peakHr: peakHr,
            liveStrainState: liveStrainState
        )
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot()
        XCTAssertEqual(
            ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original)),
            original
        )
    }

    func testRoundTripWithNoSamples() throws {
        let decoded = try XCTUnwrap(ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(
                samples: [],
                avgHr: 0,
                peakHr: 0,
                liveStrainState: .building(readings: 0, coverageSeconds: 0)
            ))
        ))
        XCTAssertTrue(decoded.samples.isEmpty)
        XCTAssertEqual(decoded.startSec, 1_700_000_000)
        XCTAssertEqual(decoded.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() throws {
        let decoded = try XCTUnwrap(ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training"))
        ))
        XCTAssertEqual(decoded.sport, "Traditional Strength Training")
    }

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
        let value = snapshot()
        ActiveWorkoutPersistence.store(value, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), value)
        ActiveWorkoutPersistence.clear(from: defaults)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testStoreOverwritesPreviousSnapshot() {
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.store(
            snapshot(samples: [sample(1_700_000_001, 120)], avgHr: 120, peakHr: 120),
            into: defaults
        )
        let later = snapshot(
            samples: [sample(1_700_000_001, 120), sample(1_700_000_061, 150)],
            avgHr: 135,
            peakHr: 150,
            liveStrainState: .scored(storedValue: 9.1)
        )
        ActiveWorkoutPersistence.store(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults), later)
    }

    func testCoalescedWriterKeepsNewestSnapshot() {
        let defaults = freshDefaults()
        for count in 1...200 {
            let samples = (0..<count).map {
                sample(1_700_000_001 + $0, 100 + ($0 % 60))
            }
            ActiveWorkoutPersistence.storeCoalesced(
                snapshot(
                    samples: samples,
                    avgHr: 130,
                    peakHr: 159,
                    liveStrainState: .building(readings: count, coverageSeconds: count)
                ),
                into: defaults
            )
        }
        ActiveWorkoutPersistence.flushPendingWrites()
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults)?.samples.count, 200)
    }

    func testSynchronousFlushSupersedesQueuedSnapshots() {
        let defaults = freshDefaults()
        for count in 1...50 {
            let samples = (0..<count).map {
                sample(1_700_000_001 + $0, 100 + ($0 % 60))
            }
            ActiveWorkoutPersistence.storeCoalesced(
                snapshot(
                    samples: samples,
                    avgHr: 130,
                    peakHr: 159,
                    liveStrainState: .building(readings: count, coverageSeconds: count)
                ),
                into: defaults
            )
        }
        let finalSamples = (0..<51).map {
            sample(1_700_000_001 + $0, 100 + ($0 % 60))
        }
        ActiveWorkoutPersistence.storeCoalesced(
            snapshot(
                samples: finalSamples,
                avgHr: 130,
                peakHr: 159,
                liveStrainState: .building(readings: 51, coverageSeconds: 51)
            ),
            into: defaults,
            synchronously: true
        )
        ActiveWorkoutPersistence.flushPendingWrites()
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults)?.samples.count, 51)
    }

    func testClearInvalidatesQueuedSnapshotAndPreventsResurrection() {
        let defaults = freshDefaults()
        for count in 1...100 {
            let samples = (0..<count).map {
                sample(1_700_000_001 + $0, 100 + ($0 % 60))
            }
            ActiveWorkoutPersistence.storeCoalesced(
                snapshot(
                    samples: samples,
                    avgHr: 130,
                    peakHr: 159,
                    liveStrainState: .building(readings: count, coverageSeconds: count)
                ),
                into: defaults
            )
        }
        ActiveWorkoutPersistence.clear(from: defaults)
        ActiveWorkoutPersistence.flushPendingWrites()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults))
    }

    func testDecodeNilEmptyAndGarbageAreNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    func testDecodeDropsOutOfRangeSamples() {
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),
            sample(1_700_000_002, 0),
            sample(1_700_000_003, 400),
            sample(0, 120),
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() throws {
        let decoded = try XCTUnwrap(ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(
                samples: [],
                avgHr: -5,
                peakHr: -9,
                liveStrainState: .scored(storedValue: -3)
            ))
        ))
        XCTAssertEqual(decoded.avgHr, 0)
        XCTAssertEqual(decoded.peakHr, 0)
        XCTAssertEqual(decoded.liveStrainState, .scored(storedValue: 0))
    }
}
#endif
