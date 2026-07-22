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
/// shrink, and the last already-persisted sample still matches at the persisted boundary. Any correction,
/// replacement session, or corrupt prefix rewrites atomically instead of splicing incompatible histories.
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
/// Production uses a tiny metadata record in UserDefaults plus an append-only binary sample journal in
/// Application Support. The public `Snapshot` API and isolated-UserDefaults test/migration seams remain
/// source-compatible. The first snapshot and background flush are synchronous; ordinary foreground writes
/// are latest-wins on one utility queue. Clear generation-invalidates pending work and removes both v2 and
/// legacy state, so a delayed checkpoint can never resurrect a finished workout.
enum ActiveWorkoutPersistence {
    struct Snapshot: Codable, Equatable, Sendable {
        var startSec: Int
        var sport: String
        var samples: [HRSample]
        var avgHr: Int
        var peakHr: Int
        var liveStrainState: LiveStrainState

        private enum CodingKeys: String, CodingKey {
            case startSec, sport, samples, avgHr, peakHr, liveStrainState, liveStrain
        }

        init(
            startSec: Int,
            sport: String,
            samples: [HRSample],
            avgHr: Int,
            peakHr: Int,
            liveStrainState: LiveStrainState
        ) {
            self.startSec = startSec
            self.sport = sport
            self.samples = samples
            self.avgHr = avgHr
            self.peakHr = peakHr
            self.liveStrainState = liveStrainState
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
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
            try values.encode(startSec, forKey: .startSec)
            try values.encode(sport, forKey: .sport)
            try values.encode(samples, forKey: .samples)
            try values.encode(avgHr, forKey: .avgHr)
            try values.encode(peakHr, forKey: .peakHr)
            try values.encode(liveStrainState, forKey: .liveStrainState)
        }
    }

    private struct JournalMetadata: Codable, Equatable, Sendable {
        static let currentVersion = 2

        let version: Int
        let startSec: Int
        let sport: String
        let sampleCount: Int
        let avgHr: Int
        let peakHr: Int
        let liveStrainState: LiveStrainState

        init(snapshot: Snapshot) {
            version = Self.currentVersion
            startSec = snapshot.startSec
            sport = snapshot.sport
            sampleCount = snapshot.samples.count
            avgHr = snapshot.avgHr
            peakHr = snapshot.peakHr
            liveStrainState = snapshot.liveStrainState
        }
    }

    static let defaultsKey = "noop.activeWorkout"
    static let metadataKey = "noop.activeWorkout.v2.metadata"
    private static let legacyWriter = SnapshotWriter()
    private static let productionWriter = ProductionJournalWriter()

    /// Reading the old growing Data value merely to ask whether it exists would copy/materialize it on the
    /// main actor. Cache only the existence bit and reset it after the ordered production clear completes.
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

    private static func sanitized(_ raw: Snapshot) -> Snapshot? {
        guard raw.startSec > 0 else { return nil }
        let samples = raw.samples.filter { $0.ts > 0 && (1...300).contains($0.bpm) }
        let state: LiveStrainState
        switch raw.liveStrainState {
        case .building(let readings, let coverage):
            state = .building(readings: max(0, readings), coverageSeconds: max(0, coverage))
        case .scored(let stored) where stored.isFinite:
            state = .scored(storedValue: min(100, max(0, stored)))
        case .scored:
            state = .building(readings: samples.count, coverageSeconds: 0)
        }
        return Snapshot(
            startSec: raw.startSec,
            sport: raw.sport,
            samples: samples,
            avgHr: max(0, raw.avgHr),
            peakHr: max(0, raw.peakHr),
            liveStrainState: state
        )
    }

    /// Normal foreground snapshots are latest-wins and only append their sample suffix. The first snapshot
    /// is synchronous so a kill immediately after Start cannot erase the session. Background/inactive calls
    /// also force an ordered write before iOS suspends the process.
    @MainActor
    static func store(_ snapshot: Snapshot, synchronously: Bool = false) {
        let isFirstSnapshot = !productionSnapshotEstablished
        if isFirstSnapshot { productionSnapshotEstablished = true }
        let applicationRequiresImmediateFlush = UIApplication.shared.applicationState != .active
        productionWriter.store(
            snapshot,
            synchronously: synchronously || isFirstSnapshot || applicationRequiresImmediateFlush
        )
    }

    /// Deterministic legacy/direct seam for isolated unit tests and old snapshot migrations.
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults) {
        guard let data = encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Isolated stress-test seam. It intentionally retains the previous full-snapshot writer so tests can
    /// exercise ordering against an independent UserDefaults suite without touching the app's health-data file.
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
                // One-time, ordered migration. Keep returning the already-decoded value even if the file
                // system is temporarily unavailable; the legacy key remains unless the v2 write succeeds.
                productionWriter.store(legacy, synchronously: true)
                return legacy
            }
            return nil
        }
        return decode(defaults.data(forKey: defaultsKey))
    }

    /// Production clear is ordered after and invalidation-safe against every pending journal write.
    @MainActor
    static func clear() {
        productionWriter.clear()
        legacyWriter.clear(from: .standard)
        productionSnapshotEstablished = false
    }

    /// Isolated-suite seam for legacy writer tests.
    static func clear(from defaults: UserDefaults) {
        legacyWriter.clear(from: defaults)
    }

    private static func productionJournalURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = applicationSupport.appendingPathComponent("NOOP", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("active-workout-samples-v2.bin", isDirectory: false)
    }

    private final class ProductionJournalWriter: @unchecked Sendable {
        private struct Pending: @unchecked Sendable {
            let snapshot: Snapshot
            let generation: UInt64
        }

        private let queue = DispatchQueue(label: "com.noop.active-workout-journal", qos: .utility)
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var pending: Pending?
        private var workerScheduled = false

        init() {
            queue.setSpecific(key: queueKey, value: 1)
        }

        func store(_ snapshot: Snapshot, synchronously: Bool) {
            let item: Pending
            lock.lock()
            generation &+= 1
            item = Pending(snapshot: snapshot, generation: generation)
            if synchronously {
                pending = nil
            } else {
                pending = item
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

        func load() -> Snapshot? {
            syncOnQueue { [self] in loadOnQueue() }
        }

        func clear() {
            lock.lock()
            generation &+= 1
            pending = nil
            lock.unlock()

            syncOnQueue {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: ActiveWorkoutPersistence.metadataKey)
                defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
                if let url = try? ActiveWorkoutPersistence.productionJournalURL() {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        func flush() {
            syncOnQueue { }
        }

        private func drain() {
            while true {
                let item: Pending?
                lock.lock()
                item = pending
                pending = nil
                if item == nil { workerScheduled = false }
                lock.unlock()

                guard let item else { return }
                writeIfCurrent(item)
            }
        }

        private func writeIfCurrent(_ item: Pending) {
            guard isCurrent(item.generation),
                  let clean = ActiveWorkoutPersistence.sanitized(item.snapshot),
                  let url = try? ActiveWorkoutPersistence.productionJournalURL()
            else { return }

            let defaults = UserDefaults.standard
            let metadata = loadMetadata(defaults)
            let persistedCount = metadata?.sampleCount ?? 0
            let persistedLast = readPersistedLastSample(
                url: url,
                count: persistedCount
            )
            let strategy = ActiveWorkoutJournalPlanner.strategy(
                persistedStartSec: metadata?.startSec,
                persistedSport: metadata?.sport,
                persistedCount: persistedCount,
                persistedLastSample: persistedLast,
                next: clean
            )

            do {
                switch strategy {
                case .rewrite:
                    try rewrite(samples: clean.samples, to: url)
                case .append(let fromIndex):
                    try append(
                        samples: clean.samples[fromIndex...],
                        persistedCount: fromIndex,
                        to: url
                    )
                }
            } catch {
                NSLog("ActiveWorkoutPersistence: journal write failed: \(error)")
                return
            }

            guard isCurrent(item.generation),
                  let metadataData = try? JSONEncoder().encode(JournalMetadata(snapshot: clean))
            else { return }
            defaults.set(metadataData, forKey: ActiveWorkoutPersistence.metadataKey)
            defaults.removeObject(forKey: ActiveWorkoutPersistence.defaultsKey)
        }

        private func loadOnQueue() -> Snapshot? {
            let defaults = UserDefaults.standard
            guard let metadata = loadMetadata(defaults),
                  metadata.version == JournalMetadata.currentVersion,
                  metadata.startSec > 0,
                  metadata.sampleCount >= 0,
                  let url = try? ActiveWorkoutPersistence.productionJournalURL()
            else { return nil }

            let samples: [HRSample]
            if metadata.sampleCount == 0 {
                samples = []
            } else {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      data.count >= metadata.sampleCount * ActiveWorkoutSampleJournalCodec.bytesPerSample
                else { return nil }
                samples = ActiveWorkoutSampleJournalCodec.decode(data, count: metadata.sampleCount)
                guard samples.count == metadata.sampleCount else { return nil }
            }

            return ActiveWorkoutPersistence.sanitized(Snapshot(
                startSec: metadata.startSec,
                sport: metadata.sport,
                samples: samples,
                avgHr: metadata.avgHr,
                peakHr: metadata.peakHr,
                liveStrainState: metadata.liveStrainState
            ))
        }

        private func loadMetadata(_ defaults: UserDefaults) -> JournalMetadata? {
            guard let data = defaults.data(forKey: ActiveWorkoutPersistence.metadataKey) else { return nil }
            return try? JSONDecoder().decode(JournalMetadata.self, from: data)
        }

        private func readPersistedLastSample(url: URL, count: Int) -> HRSample? {
            guard count > 0,
                  let handle = try? FileHandle(forReadingFrom: url)
            else { return nil }
            defer { try? handle.close() }
            let offset = UInt64((count - 1) * ActiveWorkoutSampleJournalCodec.bytesPerSample)
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

        private func rewrite(samples: [HRSample], to url: URL) throws {
            let data = ActiveWorkoutSampleJournalCodec.encode(samples)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        private func append(samples: ArraySlice<HRSample>, persistedCount: Int, to url: URL) throws {
            let expectedPrefixBytes = persistedCount * ActiveWorkoutSampleJournalCodec.bytesPerSample
            if !FileManager.default.fileExists(atPath: url.path) {
                guard persistedCount == 0 else {
                    try rewrite(samples: Array(samples), to: url)
                    return
                }
                try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }

            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(expectedPrefixBytes))
            try handle.seekToEnd()
            let suffix = ActiveWorkoutSampleJournalCodec.encode(samples)
            if !suffix.isEmpty { try handle.write(contentsOf: suffix) }
            try handle.synchronize()
        }

        private func isCurrent(_ requestGeneration: UInt64) -> Bool {
            lock.lock()
            let current = generation == requestGeneration
            lock.unlock()
            return current
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
