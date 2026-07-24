import Foundation
import WhoopProtocol
import XCTest
@testable import NOOP

#if os(iOS)
final class ActiveWorkoutPersistenceTests: XCTestCase {
    private enum InjectedFailure: Error { case crash }

    private final class CommitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var committed: Bool?

        func record(_ value: Bool) {
            lock.lock()
            committed = value
            lock.unlock()
        }

        func value() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return committed
        }
    }

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

    private func freshJournalEnvironment() throws -> (UserDefaults, URL) {
        let defaults = freshDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-workout-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (defaults, directory)
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

    func testEncodedByteCountRejectsOverflow() {
        XCTAssertEqual(
            ActiveWorkoutSampleJournalCodec.encodedByteCount(for: 10),
            10 * ActiveWorkoutSampleJournalCodec.bytesPerSample
        )
        XCTAssertNil(ActiveWorkoutSampleJournalCodec.encodedByteCount(for: -1))
        XCTAssertNil(ActiveWorkoutSampleJournalCodec.encodedByteCount(for: Int.max))
    }

    func testBinaryJournalRoundTripsLargeSampleSetAtFixedWidth() {
        let samples = (0..<10_000).map {
            sample(1_700_000_000 + $0, 60 + ($0 % 140))
        }
        let encoded = ActiveWorkoutSampleJournalCodec.encode(samples)
        XCTAssertEqual(
            encoded.count,
            samples.count * ActiveWorkoutSampleJournalCodec.bytesPerSample
        )
        XCTAssertEqual(ActiveWorkoutSampleJournalCodec.decode(encoded), samples)
    }

    func testJournalPlannerAppendsOnlyNewSuffixForCompatibleSession() {
        let old = [sample(100, 100), sample(101, 110)]
        let next = snapshot(
            startSec: 90,
            sport: "Run",
            samples: old + [sample(102, 120), sample(103, 130)]
        )
        XCTAssertEqual(
            ActiveWorkoutJournalPlanner.strategy(
                persistedStartSec: 90,
                persistedSport: "Run",
                persistedCount: old.count,
                persistedLastSample: old.last,
                next: next
            ),
            .append(fromIndex: 2)
        )
    }

    func testJournalPlannerRewritesOnReplacementShrinkOrPrefixCorrection() {
        let original = [sample(100, 100), sample(101, 110)]
        XCTAssertEqual(
            ActiveWorkoutJournalPlanner.strategy(
                persistedStartSec: 90,
                persistedSport: "Run",
                persistedCount: original.count,
                persistedLastSample: original.last,
                next: snapshot(startSec: 91, sport: "Run", samples: original)
            ),
            .rewrite
        )
        XCTAssertEqual(
            ActiveWorkoutJournalPlanner.strategy(
                persistedStartSec: 90,
                persistedSport: "Run",
                persistedCount: original.count,
                persistedLastSample: original.last,
                next: snapshot(startSec: 90, sport: "Run", samples: [original[0]])
            ),
            .rewrite
        )
        XCTAssertEqual(
            ActiveWorkoutJournalPlanner.strategy(
                persistedStartSec: 90,
                persistedSport: "Run",
                persistedCount: original.count,
                persistedLastSample: original.last,
                next: snapshot(
                    startSec: 90,
                    sport: "Run",
                    samples: [original[0], sample(101, 125)]
                )
            ),
            .rewrite
        )
    }

    func testGenerationJournalCommitsMetadataPointerAndChecksum() throws {
        let (defaults, directory) = try freshJournalEnvironment()
        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(
            defaults: defaults,
            directory: directory
        )
        let value = snapshot()
        XCTAssertTrue(writer.store(value, synchronously: true))
        XCTAssertEqual(writer.load(), value)

        let metadataData = try XCTUnwrap(defaults.data(forKey: ActiveWorkoutPersistence.metadataKey))
        let metadata = try JSONDecoder().decode(
            ActiveWorkoutPersistence.JournalMetadata.self,
            from: metadataData
        )
        XCTAssertEqual(metadata.sampleCount, value.samples.count)
        XCTAssertFalse(metadata.generation.uuidString.isEmpty)
        let journal = directory.appendingPathComponent(
            "active-workout-\(metadata.generation.uuidString.lowercased()).bin"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testIncrementalCheckpointsPersistOnlyImmutableSuffixSegments() throws {
        let (defaults, directory) = try freshJournalEnvironment()
        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        let sessionID = UUID()
        var first = snapshot(samples: [sample(100, 110)], avgHr: 110, peakHr: 110)
        first.sessionID = sessionID
        var second = first
        second.samples.append(sample(101, 120))
        second.avgHr = 115
        second.peakHr = 120
        var third = second
        third.samples.append(sample(102, 130))
        third.avgHr = 120
        third.peakHr = 130

        XCTAssertTrue(writer.store(first, synchronously: true))
        XCTAssertTrue(writer.store(second, synchronously: true))
        XCTAssertTrue(writer.store(third, synchronously: true))
        XCTAssertEqual(writer.load(), third)

        let metadataData = try XCTUnwrap(defaults.data(forKey: ActiveWorkoutPersistence.metadataKey))
        let metadata = try JSONDecoder().decode(
            ActiveWorkoutPersistence.JournalMetadata.self,
            from: metadataData
        )
        XCTAssertEqual(metadata.segments.map(\.sampleCount), [1, 1, 1])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("active-workout-") && $0.pathExtension == "bin" }
        let storedBytes = try files.reduce(into: 0) { total, file in
            total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        XCTAssertEqual(storedBytes, 3 * ActiveWorkoutSampleJournalCodec.bytesPerSample)
    }

    func testAsynchronousCheckpointPublishesActualCommitFailure() throws {
        let (defaults, directory) = try freshJournalEnvironment()
        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(
            defaults: defaults,
            directory: directory,
            faultInjector: { phase in
                if phase == .beforeFileWrite { throw InjectedFailure.crash }
            }
        )
        let recorder = CommitRecorder()
        XCTAssertTrue(writer.store(snapshot(), synchronously: false, onCommit: recorder.record))
        writer.flush()
        XCTAssertEqual(recorder.value(), false)
        XCTAssertNil(writer.load())
    }

    func testSynchronousWriteReportsFailureBeforeCommitAndRelaunchKeepsPreviousGeneration() throws {
        for phase in [
            ActiveWorkoutPersistence.JournalFaultPhase.beforeFileWrite,
            .afterFileSync,
            .beforeMetadataCommit,
        ] {
            let (defaults, directory) = try freshJournalEnvironment()
            let initial = snapshot(samples: [sample(100, 110)], avgHr: 110, peakHr: 110)
            let replacement = snapshot(samples: [sample(100, 110), sample(101, 120)], avgHr: 115, peakHr: 120)
            let seed = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
            XCTAssertTrue(seed.store(initial, synchronously: true))

            let failing = ActiveWorkoutPersistence.ProductionJournalWriter(
                defaults: defaults,
                directory: directory,
                faultInjector: { if $0 == phase { throw InjectedFailure.crash } }
            )
            XCTAssertFalse(failing.store(replacement, synchronously: true), "phase: \(phase)")

            let relaunched = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
            XCTAssertEqual(relaunched.load(), initial, "phase: \(phase)")
            let generations = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("active-workout-") && $0.hasSuffix(".bin") }
            XCTAssertEqual(generations.count, 1, "failed generation leaked at phase: \(phase)")
        }
    }

    func testRelaunchUsesNewGenerationWhenProcessDiesAfterPointerSwap() throws {
        let (defaults, directory) = try freshJournalEnvironment()
        let initial = snapshot(samples: [sample(100, 110)], avgHr: 110, peakHr: 110)
        let replacement = snapshot(samples: [sample(100, 110), sample(101, 120)], avgHr: 115, peakHr: 120)
        let seed = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        XCTAssertTrue(seed.store(initial, synchronously: true))

        let failing = ActiveWorkoutPersistence.ProductionJournalWriter(
            defaults: defaults,
            directory: directory,
            faultInjector: { if $0 == .afterMetadataCommit { throw InjectedFailure.crash } }
        )
        XCTAssertFalse(failing.store(replacement, synchronously: true))

        let relaunched = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        XCTAssertEqual(relaunched.load(), replacement)
    }

    func testChecksumMismatchRecoversPreviousCommittedGeneration() throws {
        let (defaults, directory) = try freshJournalEnvironment()
        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        let initial = snapshot(samples: [sample(100, 110)], avgHr: 110, peakHr: 110)
        let replacement = snapshot(
            samples: [sample(100, 110), sample(101, 120)],
            avgHr: 115,
            peakHr: 120
        )
        XCTAssertTrue(writer.store(initial, synchronously: true))
        XCTAssertTrue(writer.store(replacement, synchronously: true))
        let metadataData = try XCTUnwrap(defaults.data(forKey: ActiveWorkoutPersistence.metadataKey))
        let metadata = try JSONDecoder().decode(
            ActiveWorkoutPersistence.JournalMetadata.self,
            from: metadataData
        )
        let journal = directory.appendingPathComponent(
            "active-workout-\(metadata.generation.uuidString.lowercased()).bin"
        )
        var bytes = try Data(contentsOf: journal)
        bytes[0] ^= 0xff
        try bytes.write(to: journal)

        let relaunched = ActiveWorkoutPersistence.ProductionJournalWriter(
            defaults: defaults,
            directory: directory
        )
        XCTAssertEqual(relaunched.load(), initial)
    }

    func testV3GenerationJournalMigratesToImmutableSuffixSegments() throws {
        struct V3Metadata: Codable {
            let version: Int
            let generation: UUID
            let sessionID: UUID
            let startSec: Int
            let sport: String
            let sampleCount: Int
            let checksum: UInt64
            let avgHr: Int
            let peakHr: Int
            let liveStrainState: LiveStrainState
        }
        func checksum(_ data: Data) -> UInt64 {
            data.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }

        let (defaults, directory) = try freshJournalEnvironment()
        let sessionID = UUID()
        let original = ActiveWorkoutPersistence.Snapshot(
            sessionID: sessionID, startSec: 100, sport: "Run", samples: [sample(101, 110)],
            avgHr: 110, peakHr: 110, liveStrainState: .building(readings: 1, coverageSeconds: 1)
        )
        let generation = UUID()
        let data = ActiveWorkoutSampleJournalCodec.encode(original.samples)
        try data.write(to: directory.appendingPathComponent("active-workout-\(generation.uuidString.lowercased()).bin"))
        defaults.set(try JSONEncoder().encode(V3Metadata(
            version: 3, generation: generation, sessionID: original.sessionID, startSec: original.startSec,
            sport: original.sport, sampleCount: original.samples.count, checksum: checksum(data),
            avgHr: original.avgHr, peakHr: original.peakHr, liveStrainState: original.liveStrainState
        )), forKey: ActiveWorkoutPersistence.metadataKey)

        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        XCTAssertEqual(writer.load(), original)
        var replacement = original
        replacement.samples.append(sample(102, 120))
        replacement.avgHr = 115
        replacement.peakHr = 120
        XCTAssertTrue(writer.store(replacement, synchronously: true))
        XCTAssertEqual(writer.load(), replacement)

        let metadata = try JSONDecoder().decode(
            ActiveWorkoutPersistence.JournalMetadata.self,
            from: try XCTUnwrap(defaults.data(forKey: ActiveWorkoutPersistence.metadataKey))
        )
        XCTAssertEqual(metadata.version, ActiveWorkoutPersistence.JournalMetadata.currentVersion)
        XCTAssertEqual(metadata.segments.map(\.sampleCount), [1, 1])
    }

    func testLegacyV2PairMigratesToGenerationJournalOnLoad() throws {
        struct LegacyMetadata: Codable {
            let version: Int
            let startSec: Int
            let sport: String
            let sampleCount: Int
            let avgHr: Int
            let peakHr: Int
            let liveStrainState: LiveStrainState
        }
        let (defaults, directory) = try freshJournalEnvironment()
        let value = snapshot()
        try ActiveWorkoutSampleJournalCodec.encode(value.samples).write(
            to: directory.appendingPathComponent(ActiveWorkoutPersistence.legacyJournalName)
        )
        let legacy = LegacyMetadata(
            version: 2,
            startSec: value.startSec,
            sport: value.sport,
            sampleCount: value.samples.count,
            avgHr: value.avgHr,
            peakHr: value.peakHr,
            liveStrainState: value.liveStrainState
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: ActiveWorkoutPersistence.metadataKey)

        let writer = ActiveWorkoutPersistence.ProductionJournalWriter(defaults: defaults, directory: directory)
        let migrated = try XCTUnwrap(writer.load())
        XCTAssertEqual(migrated.startSec, value.startSec)
        XCTAssertEqual(migrated.sport, value.sport)
        XCTAssertEqual(migrated.samples, value.samples)
        XCTAssertEqual(migrated.avgHr, value.avgHr)
        XCTAssertEqual(migrated.peakHr, value.peakHr)
        XCTAssertEqual(migrated.liveStrainState, value.liveStrainState)
        let migratedData = try XCTUnwrap(defaults.data(forKey: ActiveWorkoutPersistence.metadataKey))
        XCTAssertEqual(
            try JSONDecoder().decode(ActiveWorkoutPersistence.JournalMetadata.self, from: migratedData).version,
            ActiveWorkoutPersistence.JournalMetadata.currentVersion
        )
    }
}
#endif
