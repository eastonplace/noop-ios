import Foundation
import UIKit
import WhoopProtocol

enum LiveStrainState: Codable, Equatable, Sendable {
    case building(readings: Int, coverageSeconds: Int)
    case scored(storedValue: Double)
}

/// Fixed-width binary codec for the production recovery journal. Each accepted one-second sample occupies
/// exactly 12 bytes (Int64 timestamp + Int32 bpm, little endian), so an ordinary foreground checkpoint can
/// append only the new suffix instead of JSON-encoding the entire growing workout every five seconds.
enum ActiveWorkoutSampleJournalCodec {
    static let bytesPerSample = MemoryLayout<Int64>.size + MemoryLayout<Int32>.size

    static func encodedByteCount(for sampleCount: Int) -> Int? {
        guard sampleCount >= 0 else { return nil }
        let result = sampleCount.multipliedReportingOverflow(by: bytesPerSample)
        return result.overflow ? nil : result.partialValue
    }

    static func encode(_ samples: ArraySlice<HRSample>) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * bytesPerSample)
        for sample in samples {
            var timestamp = Int64(sample.ts).littleEndian
            var bpm = Int32(sample.bpm).littleEndian
            withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &bpm) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func encode(_ samples: [HRSample]) -> Data {
        encode(samples[...])
    }

    static func decode(_ data: Data, count requestedCount: Int? = nil) -> [HRSample] {
        let available = data.count / bytesPerSample
        let count = min(available, max(0, requestedCount ?? available))
        guard count > 0 else { return [] }

        func read<T: FixedWidthInteger>(_ type: T.Type, offset: Int) -> T {
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { buffer in
                _ = data.copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<T>.size))
            }
            return T(littleEndian: value)
        }

        var samples: [HRSample] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * bytesPerSample
            let timestamp = read(Int64.self, offset: offset)
            let bpm = read(Int32.self, offset: offset + MemoryLayout<Int64>.size)
            guard timestamp > 0, timestamp <= Int64(Int.max), (1...300).contains(Int(bpm)) else { continue }
            samples.append(HRSample(ts: Int(timestamp), bpm: Int(bpm)))
        }
        return samples
    }
}

enum ActiveWorkoutJournalStrategy: Equatable {
    case rewrite
    case append(fromIndex: Int)
}

/// Pure append-safety decision. A production snapshot may append only when it is the same session, did not
/// shrink, and the last already-accepted sample still matches at the boundary. Any correction, replacement
/// session, or incompatible prefix rewrites atomically instead of splicing histories.
enum ActiveWorkoutJournalPlanner {
    static func strategy(
        persistedStartSec: Int?,
        persistedSport: String?,
        persistedCount: Int,
        persistedLastSample: HRSample?,
        next: ActiveWorkoutPersistence.Snapshot
    ) -> ActiveWorkoutJournalStrategy {
        guard persistedStartSec == next.startSec,
              persistedSport == next.sport,
              persistedCount >= 0,
              next.samples.count >= persistedCount
        else { return .rewrite }

        if persistedCount == 0 { return .append(fromIndex: 0) }
        guard next.samples.indices.contains(persistedCount - 1),
              persistedLastSample == next.samples[persistedCount - 1]
        else { return .rewrite }
        return .append(fromIndex: persistedCount)
    }
}

/// Durable persistence for an in-flight, manually-started workout.
///
/// Production uses a tiny metadata record in UserDefaults plus a binary sample journal in Application
/// Support. The first snapshot and background flush are synchronous; normal checkpoints immediately reduce
/// the growing source array to a small suffix before crossing to the utility writer, so the next HR append
/// cannot trigger copy-on-write of the full workout. Clear epoch-invalidates pending work and removes both v2
/// and legacy state, preventing a delayed checkpoint from resurrecting a finished session.
enum ActiveWorkoutPersistence {
    struct Snapshot: Codable, Equatable, Sendable {
        var sessionID: UUID
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrainState: LiveStrainState

        private enum CodingKeys: String, CodingKey {
            case sessionID, startSec, sport, samples, avgHr, peakHr, liveStrainState, liveStrain
        }

        init(
            sessionID: UUID = UUID(),
            startSec: Int,
            sport: String,
            samples: [HRSample],
            avgHr: Int,
            peakHr: Int,
            liveStrainState: LiveStrainState
        ) {
            self.sessionID = sessionID
            self.startSec = startSec
            self.sport = sport
            self.samples = samples
            self.avgHr = avgHr
            self.peakHr = peakHr
            self.liveStrainState = liveStrainState
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
            startSec = try values.decode(Int.self, forKey: .startSec)
            sport = try values.decode(String.self, forKey: .sport)
            samples = try values.decode([HRSample].self, forKey: .samples)
            avgHr = try values.decode(Int.self, forKey: .avgHr)
            peakHr = try values.decode(Int.self, forKey: .peakHr)
            if let state = try values.decodeIfPresent(LiveStrainState.self, forKey: .liveStrainState) {
                liveStrainState = state
            } else if let legacy = try values.decodeIfPresent(Double.self, forKey: .liveStrain), legacy > 0 {
                liveStrainState = .scored(storedValue: legacy)
            } else {
                liveStrainState = .building(readings: samples.count, coverageSeconds: 0)
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sessionID, forKey: .sessionID)
            try values.encode(startSec, forKey: .startSec)
            try values.encode(sport, forKey: .sport)
            try values.encode(samples, forKey: .samples)
            try values.encode(avgHr, forKey: .avgHr)
            try values.encode(peakHr, forKey: .peakHr)
            try values.encode(liveStrainState, forKey: .liveStrainState)
        }
    }

    struct JournalSegment: Codable, Equatable, Sendable {
        let generation: UUID
        let sampleCount: Int
        let checksum: UInt64
    }

    struct JournalMetadata: Codable, Equatable, Sendable {
        static let currentVersion = 5

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
        /// Version 4 records immutable journal suffixes. Version 3 decoded as one full-generation
        /// segment so an installed app can resume a workout without rewriting its existing journal.
        let segments: [JournalSegment]
        /// Version 5 uses one append-only immutable journal plus an in-metadata replaceable current-second
        /// tail. Keeping the tail out of the journal prevents normal same-second callback replacement from
        /// turning a five-second checkpoint into a full workout rewrite.
        let journalSampleCount: Int?
        let journalChecksum: UInt64?
        let tailSample: HRSample?

        private enum CodingKeys: String, CodingKey {
            case version, generation, sessionID, startSec, sport, sampleCount, checksum
            case avgHr, peakHr, liveStrainState, segments, journalSampleCount, journalChecksum, tailSample
        }

        init(
            generation: UUID,
            sessionID: UUID,
            startSec: Int,
            sport: String,
            sampleCount: Int,
            checksum: UInt64,
            avgHr: Int,
            peakHr: Int,
            liveStrainState: LiveStrainState,
            segments: [JournalSegment]? = nil,
            journalSampleCount: Int? = nil,
            journalChecksum: UInt64? = nil,
            tailSample: HRSample? = nil
        ) {
            version = Self.currentVersion
            self.generation = generation
            self.sessionID = sessionID
            self.startSec = startSec
            self.sport = sport
            self.sampleCount = sampleCount
            self.checksum = checksum
            self.avgHr = avgHr
            self.peakHr = peakHr
            self.liveStrainState = liveStrainState
            self.segments = segments ?? [JournalSegment(
                generation: generation,
                sampleCount: sampleCount,
                checksum: checksum
            )]
            self.journalSampleCount = journalSampleCount
            self.journalChecksum = journalChecksum
            self.tailSample = tailSample
        }

        init(snapshot: Snapshot, generation: UUID, checksum: UInt64) {
            self.init(
                generation: generation,
                sessionID: snapshot.sessionID,
                startSec: snapshot.startSec,
                sport: snapshot.sport,
                sampleCount: snapshot.samples.count,
                checksum: checksum,
                avgHr: snapshot.avgHr,
                peakHr: snapshot.peakHr,
                liveStrainState: snapshot.liveStrainState
            )
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let decodedVersion = try values.decode(Int.self, forKey: .version)
            let decodedGeneration = try values.decode(UUID.self, forKey: .generation)
            let decodedSampleCount = try values.decode(Int.self, forKey: .sampleCount)
            let decodedChecksum = try values.decode(UInt64.self, forKey: .checksum)
            version = decodedVersion
            generation = decodedGeneration
            sessionID = try values.decode(UUID.self, forKey: .sessionID)
            startSec = try values.decode(Int.self, forKey: .startSec)
            sport = try values.decode(String.self, forKey: .sport)
            sampleCount = decodedSampleCount
            checksum = decodedChecksum
            avgHr = try values.decode(Int.self, forKey: .avgHr)
            peakHr = try values.decode(Int.self, forKey: .peakHr)
            liveStrainState = try values.decode(LiveStrainState.self, forKey: .liveStrainState)
            segments = try values.decodeIfPresent([JournalSegment].self, forKey: .segments)
                ?? [JournalSegment(
                    generation: decodedGeneration,
                    sampleCount: decodedSampleCount,
                    checksum: decodedChecksum
                )]
            journalSampleCount = try values.decodeIfPresent(Int.self, forKey: .journalSampleCount)
            journalChecksum = try values.decodeIfPresent(UInt64.self, forKey: .journalChecksum)
            tailSample = try values.decodeIfPresent(HRSample.self, forKey: .tailSample)
        }
    }

    static let defaultsKey = "noop.activeWorkout"
    static let metadataKey = "noop.activeWorkout.v2.metadata"
    static let previousMetadataKey = "noop.activeWorkout.v2.previousMetadata"
    static let legacyJournalName = "active-workout-samples-v2.bin"
    private static let legacyWriter = SnapshotWriter()
    private static let productionWriter = ProductionJournalWriter()

    @MainActor private static var productionSnapshotEstablished =
        UserDefaults.standard.object(forKey: metadataKey) != nil
        || UserDefaults.standard.object(forKey: defaultsKey) != nil

    static func encode(_ snapshot: Snapshot) -> Data? {
        do {
            return try JSONEncoder().encode(snapshot)
        } catch {
            NSLog("ActiveWorkoutPersistence: encode failed: \(error)")
            return nil
        }
    }

    static func decode(_ data: Data?) -> Snapshot? {
        guard let data, !data.isEmpty else { return nil }
        let raw: Snapshot
        do {
            raw = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            NSLog("ActiveWorkoutPersistence: decode failed: \(error)")
            return nil
        }
        return sanitized(raw)
    }

    private static func normalizedState(_ state: LiveStrainState, sampleCount: Int) -> LiveStrainState {
        switch state {
        case .building(let readings, let coverage):
            return .building(readings: max(0, readings), coverageSeconds: max(0, coverage))
        case .scored(let stored) where stored.isFinite:
            return .scored(storedValue: min(100, max(0, stored)))
        case .scored:
            return .building(readings: sampleCount, coverageSeconds: 0)
        }
    }

    private static func sanitized(_ raw: Snapshot) -> Snapshot? {
        guard raw.startSec > 0 else { return nil }
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        return Snapshot(
            sessionID: raw.sessionID,
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrainState: normalizedState(raw.liveStrainState, sampleCount: samples.count)
        )
    }

    @MainActor
    @discardableResult
    static func store(
        _ snapshot: Snapshot,
        synchronously: Bool = false,
        onCommit: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) -> Bool {
        let isFirstSnapshot = !productionSnapshotEstablished
        let applicationRequiresImmediateFlush = UIApplication.shared.applicationState != .active
        let requiresSynchronousCommit = synchronously || isFirstSnapshot || applicationRequiresImmediateFlush
        let commitObserver: (@Sendable (Bool) -> Void)?
        if let onCommit {
            commitObserver = { committed in
                Task { @MainActor in
                    onCommit(committed)
                }
            }
        } else {
            commitObserver = nil
        }
        let accepted = productionWriter.store(
            snapshot,
            synchronously: requiresSynchronousCommit,
            onCommit: commitObserver
        )
        if isFirstSnapshot, requiresSynchronousCommit, accepted {
            productionSnapshotEstablished = true
        }
        return accepted
    }

    /// Deterministic legacy/direct seam for isolated unit tests and old snapshot migrations.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Isolated stress-test seam retaining the old full-snapshot writer so tests never touch health files.
    static func storeCoalesced(
        _ snapshot: Snapshot,
        into defaults: UserDefaults,
        synchronously: Bool = false
    ) {
        legacyWriter.store(snapshot, into: defaults, synchronously: synchronously)
    }

    static func flushPendingWrites() {
        productionWriter.flush()
        legacyWriter.flush()
    }

    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        if defaults === UserDefaults.standard {
            if let journaled = productionWriter.load() { return journaled }
            if let legacy = decode(defaults.data(forKey: defaultsKey)) {
                productionWriter.store(legacy, synchronously: true)
                return legacy
            }
            return nil
        }
        return decode(defaults.data(forKey: defaultsKey))
    }

    @MainActor
    static func clear() {
        productionWriter.clear()
        legacyWriter.clear(from: .standard)
        productionSnapshotEstablished = false
    }

    static func clear(from defaults: UserDefaults) {
        legacyWriter.clear(from: defaults)
    }

    private static func productionJournalDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = applicationSupport.appendingPathComponent("NOOP", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    enum JournalFaultPhase: CaseIterable, Sendable {
        case beforeFileWrite
        case afterFileSync
        case beforeMetadataCommit
        case afterMetadataCommit
    }

    final class ProductionJournalWriter: @unchecked Sendable {
        private struct Cursor: Sendable {
            let sessionID: UUID
            let startSec: Int
            let sport: String
            let acceptedCount: Int
            let lastSample: HRSample?
            let finalizedCount: Int
            let supportsReplaceableTail: Bool
        }

        private enum Mutation: @unchecked Sendable {
            case rewrite([HRSample])
            case appendFinalized(expectedCount: Int, expectedLast: HRSample?, suffix: [HRSample], tail: HRSample?)
        }

        private struct Request: @unchecked Sendable {
            let epoch: UInt64
            let snapshot: Snapshot
            let mutation: Mutation
        }

        private struct PendingAsync: @unchecked Sendable {
            var request: Request
            var observers: [(@Sendable (Bool) -> Void)]
        }

        private struct LegacyJournalMetadata: Codable {
            let version: Int
            let startSec: Int
            let sport: String
            let sampleCount: Int
            let avgHr: Int
            let peakHr: Int
            let liveStrainState: LiveStrainState
        }

        private let queue = DispatchQueue(label: "com.noop.active-workout-journal", qos: .utility)
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let lock = NSLock()
        private let defaults: UserDefaults
        private let directory: URL?
        private let faultInjector: @Sendable (JournalFaultPhase) throws -> Void
        private var epoch: UInt64 = 0
        // `pendingCursor` is only a suffix-planning hint. Recovery authority is always the metadata
        // pointer and `committedCursor`, which advance only after the generation file is durable.
        private var committedCursor: Cursor?
        private var pendingCursor: Cursor?
        private var pendingAsync: PendingAsync?
        private var asyncWorkerScheduled = false

        init(
            defaults: UserDefaults = .standard,
            directory: URL? = try? ActiveWorkoutPersistence.productionJournalDirectory(),
            faultInjector: @escaping @Sendable (JournalFaultPhase) throws -> Void = { _ in }
        ) {
            self.defaults = defaults
            self.directory = directory
            self.faultInjector = faultInjector
            queue.setSpecific(key: queueKey, value: 1)
        }

        /// Reduce the full value to a small suffix before returning to AppModel. A rewrite force-copies the
        /// samples (`filter` creates a new buffer); normal checkpoints retain only the ~five new samples.
        @discardableResult
        func store(
            _ snapshot: Snapshot,
            synchronously: Bool,
            onCommit: (@Sendable (Bool) -> Void)? = nil
        ) -> Bool {
            guard snapshot.startSec > 0, directory != nil else {
                onCommit?(false)
                return false
            }

            let request: Request
            lock.lock()
            let sameSession = pendingCursor?.sessionID == snapshot.sessionID
            if !sameSession {
                epoch &+= 1
                committedCursor = nil
                pendingCursor = nil
            }
            let requestEpoch = epoch
            let copied = snapshot.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
            let state = ActiveWorkoutPersistence.normalizedState(snapshot.liveStrainState, sampleCount: copied.count)
            let metadataSnapshot = Snapshot(
                sessionID: snapshot.sessionID,
                startSec: snapshot.startSec,
                sport: snapshot.sport,
                samples: [],
                avgHr: max(0, snapshot.avgHr),
                peakHr: max(0, snapshot.peakHr),
                liveStrainState: state
            )
            let finalizedCount = max(0, copied.count - 1)
            let tail = copied.last
            // A V3/V4 cursor has no replaceable metadata tail. Promote it synchronously once so a later
            // asynchronous V5 append can never be queued behind an incompatible rewrite.
            let requiresSynchronousMigration = pendingCursor?.sessionID == snapshot.sessionID
                && pendingCursor?.supportsReplaceableTail == false
            if let cursor = pendingCursor,
               cursor.supportsReplaceableTail,
               cursor.startSec == snapshot.startSec,
               cursor.sport == snapshot.sport,
               finalizedCount >= cursor.finalizedCount,
               (cursor.finalizedCount == 0 || copied[cursor.finalizedCount - 1] == cursor.lastSample) {
                let suffix = Array(copied[cursor.finalizedCount..<finalizedCount])
                request = Request(
                    epoch: requestEpoch,
                    snapshot: metadataSnapshot,
                    mutation: .appendFinalized(
                        expectedCount: cursor.finalizedCount,
                        expectedLast: cursor.lastSample,
                        suffix: suffix,
                        tail: tail
                    )
                )
            } else {
                request = Request(epoch: requestEpoch, snapshot: metadataSnapshot, mutation: .rewrite(copied))
            }
            pendingCursor = Cursor(
                sessionID: snapshot.sessionID,
                startSec: snapshot.startSec,
                sport: snapshot.sport,
                acceptedCount: copied.count,
                lastSample: finalizedCount > 0 ? copied[finalizedCount - 1] : nil,
                finalizedCount: finalizedCount,
                supportsReplaceableTail: true
            )
            lock.unlock()

            if synchronously || requiresSynchronousMigration {
                let committed = syncOnQueue { [self] in write(request) }
                onCommit?(committed)
                return committed
            } else {
                enqueueLatest(request, observer: onCommit)
                return true
            }
        }

        /// Normal checkpoints are latest-wins without losing the immutable suffix between them. Adjacent
        /// requests merge their suffixes into one bounded write; same-second changes only replace `tail`.
        private func enqueueLatest(_ request: Request, observer: (@Sendable (Bool) -> Void)?) {
            lock.lock()
            let observers = observer.map { [$0] } ?? []
            if var pending = pendingAsync,
               let merged = merge(pending.request, request) {
                pending.request = merged
                pending.observers.append(contentsOf: observers)
                pendingAsync = pending
            } else {
                pendingAsync = PendingAsync(request: request, observers: observers)
            }
            let shouldSchedule = !asyncWorkerScheduled
            if shouldSchedule { asyncWorkerScheduled = true }
            lock.unlock()
            if shouldSchedule {
                queue.async { [self] in drainLatest() }
            }
        }

        private func merge(_ earlier: Request, _ later: Request) -> Request? {
            guard earlier.epoch == later.epoch,
                  earlier.snapshot.sessionID == later.snapshot.sessionID,
                  earlier.snapshot.startSec == later.snapshot.startSec,
                  earlier.snapshot.sport == later.snapshot.sport
            else { return nil }
            guard case let .appendFinalized(expectedCount, expectedLast, earlierSuffix, _) = earlier.mutation,
                  case let .appendFinalized(laterExpectedCount, _, laterSuffix, laterTail) = later.mutation,
                  laterExpectedCount == expectedCount + earlierSuffix.count
            else { return nil }
            return Request(
                epoch: later.epoch,
                snapshot: later.snapshot,
                mutation: .appendFinalized(
                    expectedCount: expectedCount,
                    expectedLast: expectedLast,
                    suffix: earlierSuffix + laterSuffix,
                    tail: laterTail
                )
            )
        }

        private func drainLatest() {
            while true {
                let pending: PendingAsync?
                lock.lock()
                pending = pendingAsync
                pendingAsync = nil
                if pending == nil { asyncWorkerScheduled = false }
                lock.unlock()
                guard let pending else { return }
                let committed = write(pending.request)
                pending.observers.forEach { $0(committed) }
            }
        }

        func load() -> Snapshot? {
            let snapshot = syncOnQueue { [self] in loadOnQueue() }
            if let snapshot {
                let metadata = loadMetadata(defaults)
                let isV5 = metadata?.version == JournalMetadata.currentVersion
                let finalizedCount = isV5 ? (metadata?.journalSampleCount ?? 0) : snapshot.samples.count
                lock.lock()
                committedCursor = Cursor(
                    sessionID: snapshot.sessionID,
                    startSec: snapshot.startSec,
                    sport: snapshot.sport,
                    acceptedCount: snapshot.samples.count,
                    lastSample: finalizedCount > 0 ? snapshot.samples[finalizedCount - 1] : nil,
                    finalizedCount: finalizedCount,
                    supportsReplaceableTail: isV5
                )
                pendingCursor = committedCursor
                lock.unlock()
            }
            return snapshot
        }

        func clear() {
            lock.lock()
            epoch &+= 1
            committedCursor = nil
            pendingCursor = nil
            lock.unlock()

            syncOnQueue {
                defaults.removeObject(forKey: ActiveWorkoutPersistence.metadataKey)
                defaults.removeObject(forKey: ActiveWorkoutPersistence.previousMetadataKey)
                defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
                guard let directory else { return }
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for url in files where url.lastPathComponent.hasPrefix("active-workout-")
                    || url.lastPathComponent == ActiveWorkoutPersistence.legacyJournalName {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        func flush() {
            syncOnQueue { }
        }

        @discardableResult
        private func write(_ request: Request) -> Bool {
            guard isCurrent(request.epoch), directory != nil else { return false }
            var newGenerationURL: URL?
            var appendedURL: URL?
            var appendRollbackBytes: Int?
            var metadataCommitted = false

            do {
                let previous = loadMetadata(defaults)
                let generation: UUID
                let priorJournalCount: Int
                let priorJournalChecksum: UInt64
                let suffix: [HRSample]
                let tail: HRSample?
                let createsNewJournal: Bool
                switch request.mutation {
                case .rewrite(let samples):
                    generation = UUID()
                    priorJournalCount = 0
                    priorJournalChecksum = Self.checksumSeed
                    suffix = Array(samples.dropLast())
                    tail = samples.last
                    createsNewJournal = true
                case .appendFinalized(let expectedCount, let expectedLast, let samples, let currentTail):
                    guard let previous,
                          previous.version == JournalMetadata.currentVersion,
                          validateAppendOnlyPrefix(
                            next: request.snapshot,
                            expectedCount: expectedCount,
                            expectedLast: expectedLast,
                            metadata: previous
                          ) else {
                        invalidate(epoch: request.epoch)
                        return false
                    }
                    generation = previous.generation
                    priorJournalCount = previous.journalSampleCount ?? 0
                    priorJournalChecksum = previous.journalChecksum ?? Self.checksumSeed
                    suffix = samples
                    tail = currentTail
                    createsNewJournal = false
                }

                let suffixData = ActiveWorkoutSampleJournalCodec.encode(suffix)
                let count = priorJournalCount.addingReportingOverflow(suffix.count)
                guard !count.overflow else { return false }
                let journalCount = count.partialValue
                let journalChecksum = Self.checksum(suffixData, seed: priorJournalChecksum)
                let tailChecksum = tail.map {
                    Self.checksum(ActiveWorkoutSampleJournalCodec.encode([$0]), seed: journalChecksum)
                } ?? journalChecksum
                let totalSampleCount = journalCount + (tail == nil ? 0 : 1)
                let metadata = JournalMetadata(
                    generation: generation,
                    sessionID: request.snapshot.sessionID,
                    startSec: request.snapshot.startSec,
                    sport: request.snapshot.sport,
                    sampleCount: totalSampleCount,
                    checksum: tailChecksum,
                    avgHr: request.snapshot.avgHr,
                    peakHr: request.snapshot.peakHr,
                    liveStrainState: request.snapshot.liveStrainState,
                    segments: [JournalSegment(generation: generation, sampleCount: journalCount, checksum: journalChecksum)],
                    journalSampleCount: journalCount,
                    journalChecksum: journalChecksum,
                    tailSample: tail
                )
                try faultInjector(.beforeFileWrite)
                let generationURL = journalURL(for: generation)
                if createsNewJournal {
                    newGenerationURL = generationURL
                    try writeDurably(suffixData, to: generationURL)
                } else if !suffixData.isEmpty {
                    appendRollbackBytes = try journalByteCount(for: priorJournalCount)
                    appendedURL = generationURL
                    try appendDurably(suffixData, to: generationURL, truncatingTo: appendRollbackBytes!)
                }
                try faultInjector(.afterFileSync)
                guard isCurrent(request.epoch) else {
                    if let newGenerationURL {
                        try? FileManager.default.removeItem(at: newGenerationURL)
                    }
                    if let appendedURL, let appendRollbackBytes { try? truncate(appendedURL, to: appendRollbackBytes) }
                    return false
                }
                try faultInjector(.beforeMetadataCommit)
                let encoder = JSONEncoder()
                let metadataData = try encoder.encode(metadata)
                let previousMetadataData = try previous.map { try encoder.encode($0) }
                if let previousMetadataData {
                    defaults.set(previousMetadataData, forKey: ActiveWorkoutPersistence.previousMetadataKey)
                } else {
                    defaults.removeObject(forKey: ActiveWorkoutPersistence.previousMetadataKey)
                }
                defaults.set(metadataData, forKey: ActiveWorkoutPersistence.metadataKey)
                guard defaults.synchronize(),
                      defaults.data(forKey: ActiveWorkoutPersistence.metadataKey) == metadataData,
                      defaults.data(forKey: ActiveWorkoutPersistence.previousMetadataKey) == previousMetadataData
                else { throw CocoaError(.fileWriteUnknown) }
                defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
                metadataCommitted = true

                lock.lock()
                committedCursor = Cursor(
                    sessionID: metadata.sessionID,
                    startSec: metadata.startSec,
                    sport: metadata.sport,
                    acceptedCount: metadata.sampleCount,
                    lastSample: journalCount > 0 ? readPersistedLastSample(metadata: metadata) : nil,
                    finalizedCount: journalCount,
                    supportsReplaceableTail: true
                )
                lock.unlock()
                try faultInjector(.afterMetadataCommit)
                // Keep both metadata pointers' journal files. Metadata is O(1): one append-only file plus
                // one replaceable tail, so cleanup scans a bounded set instead of N suffix generations.
                cleanupStaleGenerations(keeping: metadata.segments.map(\.generation)
                    + (previous?.segments.map(\.generation) ?? []))
                return true
            } catch {
                if !metadataCommitted, let newGenerationURL {
                    try? FileManager.default.removeItem(at: newGenerationURL)
                }
                if !metadataCommitted, let appendedURL, let appendRollbackBytes {
                    try? truncate(appendedURL, to: appendRollbackBytes)
                }
                NSLog("ActiveWorkoutPersistence: journal write failed: \(error)")
                invalidate(epoch: request.epoch)
                return false
            }
        }

        private func validateAppendOnlyPrefix(
            next: Snapshot,
            expectedCount: Int,
            expectedLast: HRSample?,
            metadata current: JournalMetadata
        ) -> Bool {
            guard current.startSec == next.startSec,
                  current.sessionID == next.sessionID,
                  current.sport == next.sport,
                  current.journalSampleCount == expectedCount
            else { return false }
            if expectedCount == 0 { return true }
            return readPersistedLastSample(metadata: current) == expectedLast
        }

        private func loadOnQueue() -> Snapshot? {
            if let metadata = loadMetadata(defaults, key: ActiveWorkoutPersistence.metadataKey),
                  (3...JournalMetadata.currentVersion).contains(metadata.version),
                  metadata.startSec > 0,
                  metadata.sampleCount >= 0,
                  let snapshot = load(metadata: metadata) {
                return snapshot
            }
            if let previous = loadMetadata(defaults, key: ActiveWorkoutPersistence.previousMetadataKey),
               (3...JournalMetadata.currentVersion).contains(previous.version),
               previous.startSec > 0,
               previous.sampleCount >= 0,
               let snapshot = load(metadata: previous),
               let encoded = try? JSONEncoder().encode(previous) {
                defaults.set(encoded, forKey: ActiveWorkoutPersistence.metadataKey)
                _ = defaults.synchronize()
                return snapshot
            }

            // v2 used a shared mutable file plus metadata. Read only a self-consistent pair, then migrate
            // it through the v3 transaction before returning it to AppModel.
            guard let legacyData = defaults.data(forKey: ActiveWorkoutPersistence.metadataKey),
                  let legacy = try? JSONDecoder().decode(LegacyJournalMetadata.self, from: legacyData),
                  legacy.version == 2,
                  let directory
            else { return nil }
            let url = directory.appendingPathComponent(ActiveWorkoutPersistence.legacyJournalName)
            guard let expectedBytes = ActiveWorkoutSampleJournalCodec.encodedByteCount(
                for: legacy.sampleCount
            ),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count >= expectedBytes
            else { return nil }
            let samples = ActiveWorkoutSampleJournalCodec.decode(data, count: legacy.sampleCount)
            guard samples.count == legacy.sampleCount else { return nil }
            let snapshot = Snapshot(startSec: legacy.startSec, sport: legacy.sport, samples: samples,
                                    avgHr: legacy.avgHr, peakHr: legacy.peakHr,
                                    liveStrainState: legacy.liveStrainState)
            _ = write(Request(epoch: epoch, snapshot: snapshot, mutation: .rewrite(samples)))
            return ActiveWorkoutPersistence.sanitized(snapshot)
        }

        private func load(metadata: JournalMetadata) -> Snapshot? {
            if metadata.version == JournalMetadata.currentVersion {
                guard let journalCount = metadata.journalSampleCount,
                      let journalChecksum = metadata.journalChecksum,
                      journalCount >= 0,
                      metadata.sampleCount == journalCount + (metadata.tailSample == nil ? 0 : 1),
                      let expectedBytes = ActiveWorkoutSampleJournalCodec.encodedByteCount(for: journalCount),
                      let data = readJournalData(journalURL(for: metadata.generation), count: expectedBytes),
                      data.count == expectedBytes,
                      Self.checksum(data) == journalChecksum
                else { return nil }
                let decoded = ActiveWorkoutSampleJournalCodec.decode(data, count: journalCount)
                guard decoded.count == journalCount else { return nil }
                var samples = decoded
                if let tail = metadata.tailSample {
                    guard tail.ts > 0, (1...300).contains(tail.bpm) else { return nil }
                    samples.append(tail)
                }
                let fullChecksum = metadata.tailSample.map {
                    Self.checksum(ActiveWorkoutSampleJournalCodec.encode([$0]), seed: journalChecksum)
                } ?? journalChecksum
                guard fullChecksum == metadata.checksum else { return nil }
                return ActiveWorkoutPersistence.sanitized(Snapshot(
                    sessionID: metadata.sessionID,
                    startSec: metadata.startSec,
                    sport: metadata.sport,
                    samples: samples,
                    avgHr: metadata.avgHr,
                    peakHr: metadata.peakHr,
                    liveStrainState: metadata.liveStrainState
                ))
            }
            guard metadata.sampleCount >= 0,
                  Self.segmentSampleCount(metadata.segments) == metadata.sampleCount
            else { return nil }

            var samples: [HRSample] = []
            samples.reserveCapacity(metadata.sampleCount)
            var rollingChecksum = Self.checksumSeed
            for segment in metadata.segments {
                guard segment.sampleCount >= 0,
                      let expectedBytes = ActiveWorkoutSampleJournalCodec.encodedByteCount(
                        for: segment.sampleCount
                      ),
                      let data = try? Data(contentsOf: journalURL(for: segment.generation), options: .mappedIfSafe),
                      data.count == expectedBytes,
                      Self.checksum(data) == segment.checksum
                else { return nil }
                let decoded = ActiveWorkoutSampleJournalCodec.decode(data, count: segment.sampleCount)
                guard decoded.count == segment.sampleCount else { return nil }
                samples.append(contentsOf: decoded)
                rollingChecksum = Self.checksum(data, seed: rollingChecksum)
            }
            guard rollingChecksum == metadata.checksum else { return nil }
            guard samples.count == metadata.sampleCount else { return nil }

            return ActiveWorkoutPersistence.sanitized(Snapshot(
                sessionID: metadata.sessionID,
                startSec: metadata.startSec,
                sport: metadata.sport,
                samples: samples,
                avgHr: metadata.avgHr,
                peakHr: metadata.peakHr,
                liveStrainState: metadata.liveStrainState
            ))
        }

        private func loadMetadata(
            _ defaults: UserDefaults,
            key: String = ActiveWorkoutPersistence.metadataKey
        ) -> JournalMetadata? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(JournalMetadata.self, from: data)
        }

        private func journalURL(for generation: UUID) -> URL {
            directory!.appendingPathComponent("active-workout-\(generation.uuidString.lowercased()).bin")
        }

        private func writeDurably(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }

        private func journalByteCount(for sampleCount: Int) throws -> Int {
            guard let bytes = ActiveWorkoutSampleJournalCodec.encodedByteCount(for: sampleCount) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return bytes
        }

        private func appendDurably(_ data: Data, to url: URL, truncatingTo byteCount: Int) throws {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(byteCount))
            try handle.seek(toOffset: UInt64(byteCount))
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }

        private func truncate(_ url: URL, to byteCount: Int) throws {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(byteCount))
            try handle.synchronize()
        }

        private func readJournalData(_ url: URL, count: Int) -> Data? {
            if count == 0 { return Data() }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: count)
        }

        private func cleanupStaleGenerations(keeping: [UUID]) {
            guard let directory else { return }
            let keep = Set(keeping.map { $0.uuidString.lowercased() })
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.lastPathComponent.hasPrefix("active-workout-") {
                guard !keep.contains(where: { url.lastPathComponent.contains($0) }) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }

        private static let checksumSeed = UInt64(1_469_598_103_934_665_603)

        private static func segmentSampleCount(_ segments: [JournalSegment]) -> Int? {
            var total = 0
            for segment in segments {
                guard segment.sampleCount >= 0 else { return nil }
                let next = total.addingReportingOverflow(segment.sampleCount)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }

        private static func checksum(_ data: Data, seed: UInt64 = checksumSeed) -> UInt64 {
            data.reduce(seed) { hash, byte in
                (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
        }

        private func readPersistedLastSample(metadata: JournalMetadata) -> HRSample? {
            guard let segment = metadata.segments.last(where: { $0.sampleCount > 0 }) else { return nil }
            let url = journalURL(for: segment.generation)
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let byteOffset = ActiveWorkoutSampleJournalCodec.encodedByteCount(for: segment.sampleCount - 1)
            else { return nil }
            defer { try? handle.close() }
            let offset = UInt64(byteOffset)
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: ActiveWorkoutSampleJournalCodec.bytesPerSample),
                      data.count == ActiveWorkoutSampleJournalCodec.bytesPerSample
                else { return nil }
                return ActiveWorkoutSampleJournalCodec.decode(data, count: 1).first
            } catch {
                return nil
            }
        }

        private func isCurrent(_ requestEpoch: UInt64) -> Bool {
            lock.lock()
            let current = epoch == requestEpoch
            lock.unlock()
            return current
        }

        private func invalidate(epoch requestEpoch: UInt64) {
            lock.lock()
            if epoch == requestEpoch {
                epoch &+= 1
                committedCursor = nil
                pendingCursor = nil
            }
            lock.unlock()
        }

        private func syncOnQueue<T>(_ operation: () -> T) -> T {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                return operation()
            }
            return queue.sync(execute: operation)
        }
    }

    /// Previous full-JSON writer retained only for isolated UserDefaults tests and legacy migrations.
    private final class SnapshotWriter: @unchecked Sendable {
        private struct Pending: @unchecked Sendable {
            let key: ObjectIdentifier
            let snapshot: Snapshot
            let defaults: UserDefaults
            let generation: UInt64
        }

        private let queue = DispatchQueue(label: "com.noop.active-workout-persistence", qos: .utility)
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let lock = NSLock()
        private var generations: [ObjectIdentifier: UInt64] = [:]
        private var pendingByStore: [ObjectIdentifier: Pending] = [:]
        private var workerScheduled = false

        init() {
            queue.setSpecific(key: queueKey, value: 1)
        }

        func store(_ snapshot: Snapshot, into defaults: UserDefaults, synchronously: Bool) {
            let key = ObjectIdentifier(defaults)
            let item: Pending
            lock.lock()
            let nextGeneration = (generations[key] ?? 0) &+ 1
            generations[key] = nextGeneration
            item = Pending(
                key: key,
                snapshot: snapshot,
                defaults: defaults,
                generation: nextGeneration
            )
            if synchronously {
                pendingByStore.removeValue(forKey: key)
            } else {
                pendingByStore[key] = item
            }
            let shouldSchedule = !synchronously && !workerScheduled
            if shouldSchedule { workerScheduled = true }
            lock.unlock()

            if synchronously {
                syncOnQueue { [self] in writeIfCurrent(item) }
            } else if shouldSchedule {
                queue.async { [self] in drain() }
            }
        }

        func clear(from defaults: UserDefaults) {
            let key = ObjectIdentifier(defaults)
            lock.lock()
            generations[key] = (generations[key] ?? 0) &+ 1
            pendingByStore.removeValue(forKey: key)
            lock.unlock()

            syncOnQueue {
                defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
            }
        }

        func flush() {
            syncOnQueue { }
        }

        private func drain() {
            while true {
                let item: Pending?
                lock.lock()
                if let entry = pendingByStore.first {
                    item = entry.value
                    pendingByStore.removeValue(forKey: entry.key)
                } else {
                    item = nil
                    workerScheduled = false
                }
                lock.unlock()

                guard let item else { return }
                writeIfCurrent(item)
            }
        }

        private func writeIfCurrent(_ item: Pending) {
            guard let data = ActiveWorkoutPersistence.encode(item.snapshot) else { return }
            lock.lock()
            let isCurrent = generations[item.key] == item.generation
            lock.unlock()
            guard isCurrent else { return }
            item.defaults.set(data, forKey: ActiveWorkoutPersistence.defaultsKey)
        }

        private func syncOnQueue<T>(_ operation: () -> T) -> T {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                return operation()
            }
            return queue.sync(execute: operation)
        }
    }
}
