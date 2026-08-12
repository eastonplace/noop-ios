import Foundation

/// One append-only GPS journal record. `startsNewSegment` is durable so a process-termination gap can
/// never be reconstructed as a straight line between the last pre-termination fix and the first new fix.
struct ActiveGpsJournalPoint: Equatable, Sendable {
    let point: RouteMath.LatLng
    let startsNewSegment: Bool
}

/// Fixed-width codec for the active GPS journal. Every accepted point occupies 17 bytes:
/// one segment-boundary byte followed by little-endian latitude and longitude bit patterns.
enum ActiveGpsJournalCodec {
    static let bytesPerPoint = 1 + (MemoryLayout<UInt64>.size * 2)

    static func encodedByteCount(for pointCount: Int) -> Int? {
        guard pointCount >= 0 else { return nil }
        let result = pointCount.multipliedReportingOverflow(by: bytesPerPoint)
        return result.overflow ? nil : result.partialValue
    }

    static func encode(_ points: [ActiveGpsJournalPoint]) -> Data {
        var data = Data()
        data.reserveCapacity(points.count * bytesPerPoint)
        for record in points {
            data.append(record.startsNewSegment ? 1 : 0)
            var latitude = record.point.lat.bitPattern.littleEndian
            var longitude = record.point.lon.bitPattern.littleEndian
            withUnsafeBytes(of: &latitude) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &longitude) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data, count: Int) -> [ActiveGpsJournalPoint]? {
        guard count >= 0,
              let expectedBytes = encodedByteCount(for: count),
              data.count == expectedBytes else { return nil }
        if count == 0 { return [] }

        func readUInt64(at offset: Int) -> UInt64 {
            var value: UInt64 = 0
            withUnsafeMutableBytes(of: &value) { buffer in
                _ = data.copyBytes(to: buffer, from: offset..<(offset + MemoryLayout<UInt64>.size))
            }
            return UInt64(littleEndian: value)
        }

        var output: [ActiveGpsJournalPoint] = []
        output.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * bytesPerPoint
            let marker = data[offset]
            guard marker <= 1 else { return nil }
            let latitude = Double(bitPattern: readUInt64(at: offset + 1))
            let longitude = Double(bitPattern: readUInt64(at: offset + 1 + MemoryLayout<UInt64>.size))
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            output.append(ActiveGpsJournalPoint(
                point: RouteMath.LatLng(latitude, longitude),
                startsNewSegment: marker == 1
            ))
        }
        guard output.first?.startsNewSegment == true else { return nil }
        return output
    }
}

/// Durable, value-only companion to `ActiveWorkoutPersistence`.
///
/// Production stores a fixed-size metadata record in UserDefaults plus an append-only point journal in
/// Application Support. Normal location batches cross to one serial utility queue as only their new suffix.
/// Pending suffixes coalesce. Start/background flushes synchronously wait for the bounded pending suffix only.
enum ActiveGpsWorkoutPersistence {
    struct Snapshot: Codable, Equatable, Sendable {
        static let currentVersion = 2

        let version: Int
        let sessionID: UUID
        let workoutStartMs: Int64
        let segments: [[RouteMath.LatLng]]
        let distanceM: Double
        let rawFixCount: Int
        let recordingWasActive: Bool
        let hadTerminatedGap: Bool

        init(
            sessionID: UUID,
            workoutStartMs: Int64,
            segments: [[RouteMath.LatLng]],
            distanceM: Double,
            rawFixCount: Int,
            recordingWasActive: Bool,
            hadTerminatedGap: Bool
        ) {
            version = Self.currentVersion
            self.sessionID = sessionID
            self.workoutStartMs = workoutStartMs
            self.segments = segments.filter { !$0.isEmpty }
            self.distanceM = distanceM
            self.rawFixCount = rawFixCount
            self.recordingWasActive = recordingWasActive
            self.hadTerminatedGap = hadTerminatedGap
        }

        var acceptedPointCount: Int { segments.reduce(0) { $0 + $1.count } }

        var isValid: Bool {
            guard version == Self.currentVersion,
                  workoutStartMs > 0,
                  distanceM.isFinite,
                  distanceM >= 0,
                  rawFixCount >= acceptedPointCount,
                  segments.allSatisfy({ segment in
                      !segment.isEmpty && segment.allSatisfy {
                          $0.lat.isFinite && $0.lon.isFinite
                              && (-90...90).contains($0.lat) && (-180...180).contains($0.lon)
                      }
                  }) else { return false }
            let reconstructedDistance = segments.reduce(0.0) { $0 + RouteMath.totalMeters($1) }
            let tolerance = max(0.01, reconstructedDistance * 0.000_001)
            return abs(reconstructedDistance - distanceM) <= tolerance
        }
    }

    /// One incremental recorder checkpoint. `appendedPoints` contains only the new CoreLocation suffix.
    struct Checkpoint: Equatable, Sendable {
        let sessionID: UUID
        let workoutStartMs: Int64
        let appendedPoints: [ActiveGpsJournalPoint]
        let distanceM: Double
        let rawFixCount: Int
        let acceptedPointCount: Int
        let recordingWasActive: Bool
        let hadTerminatedGap: Bool

        var expectedBasePointCount: Int { acceptedPointCount - appendedPoints.count }

        var isValid: Bool {
            guard workoutStartMs > 0,
                  distanceM.isFinite,
                  distanceM >= 0,
                  acceptedPointCount >= appendedPoints.count,
                  rawFixCount >= acceptedPointCount,
                  appendedPoints.allSatisfy({
                      $0.point.lat.isFinite && $0.point.lon.isFinite
                          && (-90...90).contains($0.point.lat) && (-180...180).contains($0.point.lon)
                  }) else { return false }
            return expectedBasePointCount > 0 || appendedPoints.isEmpty
                || appendedPoints.first?.startsNewSegment == true
        }
    }

    struct JournalMetadata: Codable, Equatable, Sendable {
        static let currentVersion = 2

        let version: Int
        let generation: UUID
        let sessionID: UUID
        let workoutStartMs: Int64
        let distanceM: Double
        let rawFixCount: Int
        let acceptedPointCount: Int
        let recordingWasActive: Bool
        let hadTerminatedGap: Bool
        let checksum: UInt64

        init(checkpoint: Checkpoint, generation: UUID, checksum: UInt64) {
            version = Self.currentVersion
            self.generation = generation
            sessionID = checkpoint.sessionID
            workoutStartMs = checkpoint.workoutStartMs
            distanceM = checkpoint.distanceM
            rawFixCount = checkpoint.rawFixCount
            acceptedPointCount = checkpoint.acceptedPointCount
            recordingWasActive = checkpoint.recordingWasActive
            hadTerminatedGap = checkpoint.hadTerminatedGap
            self.checksum = checksum
        }
    }

    private struct LegacySnapshot: Codable {
        let version: Int
        let sessionID: UUID
        let workoutStartMs: Int64
        let encodedPolyline: String
        let distanceM: Double
        let rawFixCount: Int
        let acceptedPointCount: Int
        let recordingWasActive: Bool
        let hadTerminatedGap: Bool

        var migrated: Snapshot? {
            guard version == 1 else { return nil }
            let points = RouteMath.decode(encodedPolyline)
            guard points.count == acceptedPointCount else { return nil }
            let snapshot = Snapshot(
                sessionID: sessionID,
                workoutStartMs: workoutStartMs,
                segments: points.isEmpty ? [] : [points],
                distanceM: distanceM,
                rawFixCount: rawFixCount,
                recordingWasActive: recordingWasActive,
                hadTerminatedGap: hadTerminatedGap
            )
            return snapshot.isValid ? snapshot : nil
        }
    }

    static let defaultsKey = "noop.activeGpsWorkout.v1"
    static let metadataKey = "noop.activeGpsWorkout.v2.metadata"
    static let previousMetadataKey = "noop.activeGpsWorkout.v2.previousMetadata"
    private static let productionWriter = JournalWriter()

    @MainActor
    @discardableResult
    static func store(
        _ checkpoint: Checkpoint,
        synchronously: Bool = false,
        onCommit: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) -> Bool {
        let observer: (@Sendable (Bool) -> Void)?
        if let onCommit {
            observer = { committed in
                Task { @MainActor in onCommit(committed) }
            }
        } else {
            observer = nil
        }
        return productionWriter.store(checkpoint, synchronously: synchronously, onCommit: observer)
    }

    /// Direct JSON seam for isolated tests and v2 value round-trips. Production uses `JournalWriter`.
    @discardableResult
    static func store(_ snapshot: Snapshot, into defaults: UserDefaults) -> Bool {
        guard snapshot.isValid,
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return defaults.synchronize() && defaults.data(forKey: defaultsKey) == data
    }

    static func load(from defaults: UserDefaults = .standard) -> Snapshot? {
        if defaults === UserDefaults.standard {
            if let journaled = productionWriter.load() { return journaled }
            guard let legacy = decodeSnapshot(defaults.data(forKey: defaultsKey)) else { return nil }
            if productionWriter.replace(with: legacy) {
                defaults.removeObject(forKey: defaultsKey)
            }
            return legacy
        }
        return decodeSnapshot(defaults.data(forKey: defaultsKey))
    }

    @discardableResult
    static func flushPendingWrites() -> Bool {
        productionWriter.flush()
    }

    static func clear() {
        productionWriter.clear()
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: metadataKey)
        defaults.removeObject(forKey: previousMetadataKey)
    }

    private static func decodeSnapshot(_ data: Data?) -> Snapshot? {
        guard let data else { return nil }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.isValid {
            return snapshot
        }
        return (try? JSONDecoder().decode(LegacySnapshot.self, from: data))?.migrated
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
        case beforeMetadataCommit
    }

    /// Serial append writer. The lock protects admission/coalescing cursors only. File work stays on `queue`.
    final class JournalWriter: @unchecked Sendable {
        private struct Cursor: Equatable, Sendable {
            let sessionID: UUID
            let acceptedPointCount: Int
        }

        private struct Request: @unchecked Sendable {
            let epoch: UInt64
            let resetsJournal: Bool
            let basePointCount: Int
            let records: [ActiveGpsJournalPoint]
            let checkpoint: Checkpoint
        }

        private struct PendingRequest: @unchecked Sendable {
            var request: Request
            var observers: [(@Sendable (Bool) -> Void)]
        }

        private let queue = DispatchQueue(label: "com.noop.active-gps-journal", qos: .utility)
        private let queueKey = DispatchSpecificKey<UInt8>()
        private let lock = NSLock()
        private let defaults: UserDefaults
        private let directory: URL?
        private let faultInjector: @Sendable (JournalFaultPhase) throws -> Void
        private let automaticallyStartsAsyncWorker: Bool

        private var epoch: UInt64 = 0
        private var committedCursor: Cursor?
        private var pendingCursor: Cursor?
        private var pendingRequest: PendingRequest?
        private var asyncWorkerScheduled = false
        private var writeCount = 0
        private var totalEncodedPointCount = 0
        private var maxEncodedPointCount = 0

        init(
            defaults: UserDefaults = .standard,
            directory: URL? = try? ActiveGpsWorkoutPersistence.productionJournalDirectory(),
            automaticallyStartsAsyncWorker: Bool = true,
            faultInjector: @escaping @Sendable (JournalFaultPhase) throws -> Void = { _ in }
        ) {
            self.defaults = defaults
            self.directory = directory
            self.automaticallyStartsAsyncWorker = automaticallyStartsAsyncWorker
            self.faultInjector = faultInjector
            queue.setSpecific(key: queueKey, value: 1)
        }

        var debugWriteCount: Int {
            lock.withLock { writeCount }
        }

        var debugTotalEncodedPointCount: Int {
            lock.withLock { totalEncodedPointCount }
        }

        var debugMaxEncodedPointCount: Int {
            lock.withLock { maxEncodedPointCount }
        }

        @discardableResult
        func store(
            _ checkpoint: Checkpoint,
            synchronously: Bool,
            onCommit: (@Sendable (Bool) -> Void)? = nil
        ) -> Bool {
            guard checkpoint.isValid, directory != nil else {
                onCommit?(false)
                return false
            }

            let admitted: Bool
            let shouldSchedule: Bool
            lock.lock()
            let expectedBase = checkpoint.expectedBasePointCount
            let startsNewSession = pendingCursor?.sessionID != checkpoint.sessionID
            if startsNewSession {
                guard expectedBase == 0 else {
                    lock.unlock()
                    onCommit?(false)
                    return false
                }
                epoch &+= 1
                committedCursor = nil
                pendingCursor = Cursor(sessionID: checkpoint.sessionID, acceptedPointCount: 0)
                pendingRequest = nil
            }

            guard pendingCursor?.sessionID == checkpoint.sessionID,
                  pendingCursor?.acceptedPointCount == expectedBase else {
                lock.unlock()
                onCommit?(false)
                return false
            }

            let request = Request(
                epoch: epoch,
                resetsJournal: startsNewSession,
                basePointCount: expectedBase,
                records: checkpoint.appendedPoints,
                checkpoint: checkpoint
            )
            let observers = onCommit.map { [$0] } ?? []
            if var pending = pendingRequest, let merged = merge(pending.request, request) {
                pending.request = merged
                pending.observers.append(contentsOf: observers)
                pendingRequest = pending
            } else {
                pendingRequest = PendingRequest(request: request, observers: observers)
            }
            pendingCursor = Cursor(
                sessionID: checkpoint.sessionID,
                acceptedPointCount: checkpoint.acceptedPointCount
            )
            admitted = true
            shouldSchedule = automaticallyStartsAsyncWorker && !synchronously && !asyncWorkerScheduled
            if shouldSchedule { asyncWorkerScheduled = true }
            lock.unlock()

            if synchronously {
                let committed = flush()
                return committed && admitted
            }
            if shouldSchedule {
                queue.async { [self] in drainAsynchronously() }
            }
            return admitted
        }

        @discardableResult
        func replace(with snapshot: Snapshot) -> Bool {
            guard snapshot.isValid else { return false }
            let records = snapshot.segments.flatMap { segment in
                segment.enumerated().map {
                    ActiveGpsJournalPoint(point: $0.element, startsNewSegment: $0.offset == 0)
                }
            }
            return store(
                Checkpoint(
                    sessionID: snapshot.sessionID,
                    workoutStartMs: snapshot.workoutStartMs,
                    appendedPoints: records,
                    distanceM: snapshot.distanceM,
                    rawFixCount: snapshot.rawFixCount,
                    acceptedPointCount: snapshot.acceptedPointCount,
                    recordingWasActive: snapshot.recordingWasActive,
                    hadTerminatedGap: snapshot.hadTerminatedGap
                ),
                synchronously: true
            )
        }

        func load() -> Snapshot? {
            let snapshot = syncOnQueue { [self] in loadOnQueue() }
            if let snapshot {
                let cursor = Cursor(
                    sessionID: snapshot.sessionID,
                    acceptedPointCount: snapshot.acceptedPointCount
                )
                lock.withLock {
                    committedCursor = cursor
                    pendingCursor = cursor
                }
            }
            return snapshot
        }

        @discardableResult
        func flush() -> Bool {
            syncOnQueue { [self] in drainSynchronously() }
        }

        func clear() {
            lock.withLock {
                epoch &+= 1
                committedCursor = nil
                pendingCursor = nil
                pendingRequest = nil
            }
            syncOnQueue { [self] in
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.metadataKey)
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.previousMetadataKey)
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.defaultsKey)
                guard let directory else { return }
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )) ?? []
                for url in files where url.lastPathComponent.hasPrefix("active-gps-") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        private func merge(_ earlier: Request, _ later: Request) -> Request? {
            guard earlier.epoch == later.epoch,
                  earlier.checkpoint.sessionID == later.checkpoint.sessionID,
                  later.basePointCount == earlier.checkpoint.acceptedPointCount else { return nil }
            return Request(
                epoch: later.epoch,
                resetsJournal: earlier.resetsJournal,
                basePointCount: earlier.basePointCount,
                records: earlier.records + later.records,
                checkpoint: later.checkpoint
            )
        }

        private func takePending() -> PendingRequest? {
            lock.withLock {
                let pending = pendingRequest
                pendingRequest = nil
                return pending
            }
        }

        private func drainAsynchronously() {
            while let pending = takePendingOrStopAsyncWorker() {
                let committed = write(pending.request)
                pending.observers.forEach { $0(committed) }
                if !committed {
                    requeueFailedAndStopAsyncWorker(pending.request)
                    return
                }
            }
        }

        private func drainSynchronously() -> Bool {
            while let pending = takePending() {
                let committed = write(pending.request)
                pending.observers.forEach { $0(committed) }
                if !committed {
                    requeueFailed(pending.request)
                    return false
                }
            }
            return lock.withLock { pendingCursor == committedCursor }
        }

        private func requeueFailed(_ failed: Request) {
            lock.withLock {
                if let later = pendingRequest, let merged = merge(failed, later.request) {
                    pendingRequest = PendingRequest(request: merged, observers: later.observers)
                } else if pendingRequest == nil {
                    pendingRequest = PendingRequest(request: failed, observers: [])
                }
            }
        }

        /// Taking the final pending request and clearing the scheduled flag must be one lock operation.
        /// Otherwise a checkpoint can arrive after an empty read but before the flag clears and never schedule work.
        private func takePendingOrStopAsyncWorker() -> PendingRequest? {
            lock.withLock {
                guard let pending = pendingRequest else {
                    asyncWorkerScheduled = false
                    return nil
                }
                pendingRequest = nil
                return pending
            }
        }

        private func requeueFailedAndStopAsyncWorker(_ failed: Request) {
            lock.withLock {
                if let later = pendingRequest, let merged = merge(failed, later.request) {
                    pendingRequest = PendingRequest(request: merged, observers: later.observers)
                } else if pendingRequest == nil {
                    pendingRequest = PendingRequest(request: failed, observers: [])
                }
                asyncWorkerScheduled = false
            }
        }

        @discardableResult
        private func write(_ request: Request) -> Bool {
            guard isCurrent(request.epoch), let directory else { return false }
            lock.withLock {
                writeCount += 1
                totalEncodedPointCount += request.records.count
                maxEncodedPointCount = max(maxEncodedPointCount, request.records.count)
            }

            let previousMetadataData = defaults.data(forKey: ActiveGpsWorkoutPersistence.metadataKey)
            let previousPreviousMetadataData = defaults.data(
                forKey: ActiveGpsWorkoutPersistence.previousMetadataKey
            )
            var resetURL: URL?
            var appendedURL: URL?
            var rollbackByteCount: Int?
            var metadataCommitted = false

            do {
                let previous = previousMetadataData.flatMap {
                    try? JSONDecoder().decode(JournalMetadata.self, from: $0)
                }
                let generation: UUID
                let priorChecksum: UInt64
                let priorPointCount: Int
                if request.resetsJournal {
                    generation = UUID()
                    priorChecksum = Self.checksumSeed
                    priorPointCount = 0
                } else {
                    guard let previous,
                          previous.version == JournalMetadata.currentVersion,
                          previous.sessionID == request.checkpoint.sessionID,
                          previous.acceptedPointCount == request.basePointCount else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    generation = previous.generation
                    priorChecksum = previous.checksum
                    priorPointCount = previous.acceptedPointCount
                }

                try faultInjector(.beforeFileWrite)
                let suffixData = ActiveGpsJournalCodec.encode(request.records)
                let journalURL = directory.appendingPathComponent(
                    "active-gps-\(generation.uuidString.lowercased()).bin"
                )
                if request.resetsJournal {
                    try writeDurably(suffixData, to: journalURL)
                    resetURL = journalURL
                } else if !suffixData.isEmpty {
                    let expectedBytes = try journalByteCount(for: priorPointCount)
                    try appendDurably(suffixData, to: journalURL, truncatingTo: expectedBytes)
                    appendedURL = journalURL
                    rollbackByteCount = expectedBytes
                }

                let checksum = Self.checksum(suffixData, seed: priorChecksum)
                let metadata = JournalMetadata(
                    checkpoint: request.checkpoint,
                    generation: generation,
                    checksum: checksum
                )
                let metadataData = try JSONEncoder().encode(metadata)
                try faultInjector(.beforeMetadataCommit)
                guard isCurrent(request.epoch) else { throw CancellationError() }
                if let previousMetadataData {
                    defaults.set(previousMetadataData, forKey: ActiveGpsWorkoutPersistence.previousMetadataKey)
                } else {
                    defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.previousMetadataKey)
                }
                defaults.set(metadataData, forKey: ActiveGpsWorkoutPersistence.metadataKey)
                guard defaults.synchronize(),
                      defaults.data(forKey: ActiveGpsWorkoutPersistence.metadataKey) == metadataData else {
                    throw CocoaError(.fileWriteUnknown)
                }
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.defaultsKey)
                metadataCommitted = true
                lock.withLock {
                    committedCursor = Cursor(
                        sessionID: metadata.sessionID,
                        acceptedPointCount: metadata.acceptedPointCount
                    )
                }
                cleanupStaleJournals(
                    keeping: [metadata.generation, previous?.generation].compactMap { $0 }
                )
                return true
            } catch {
                if !metadataCommitted, let resetURL {
                    try? FileManager.default.removeItem(at: resetURL)
                }
                if !metadataCommitted, let appendedURL, let rollbackByteCount {
                    try? truncate(appendedURL, to: rollbackByteCount)
                }
                restoreDefaults(
                    metadata: previousMetadataData,
                    previousMetadata: previousPreviousMetadataData
                )
                NSLog("ActiveGpsWorkoutPersistence: journal write failed: \(error)")
                return false
            }
        }

        private func loadOnQueue() -> Snapshot? {
            if let current = loadMetadata(key: ActiveGpsWorkoutPersistence.metadataKey),
               let snapshot = load(metadata: current) {
                return snapshot
            }
            guard let previousData = defaults.data(forKey: ActiveGpsWorkoutPersistence.previousMetadataKey),
                  let previous = try? JSONDecoder().decode(JournalMetadata.self, from: previousData),
                  let snapshot = load(metadata: previous) else { return nil }
            defaults.set(previousData, forKey: ActiveGpsWorkoutPersistence.metadataKey)
            _ = defaults.synchronize()
            return snapshot
        }

        private func load(metadata: JournalMetadata) -> Snapshot? {
            guard metadata.version == JournalMetadata.currentVersion,
                  metadata.workoutStartMs > 0,
                  metadata.distanceM.isFinite,
                  metadata.distanceM >= 0,
                  metadata.rawFixCount >= metadata.acceptedPointCount,
                  let expectedBytes = ActiveGpsJournalCodec.encodedByteCount(
                    for: metadata.acceptedPointCount
                  ),
                  let directory else { return nil }
            let url = directory.appendingPathComponent(
                "active-gps-\(metadata.generation.uuidString.lowercased()).bin"
            )
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: expectedBytes),
                  data.count == expectedBytes,
                  Self.checksum(data) == metadata.checksum,
                  let records = ActiveGpsJournalCodec.decode(data, count: metadata.acceptedPointCount)
            else { return nil }

            var segments: [[RouteMath.LatLng]] = []
            for record in records {
                if record.startsNewSegment || segments.isEmpty {
                    segments.append([record.point])
                } else {
                    segments[segments.count - 1].append(record.point)
                }
            }
            let snapshot = Snapshot(
                sessionID: metadata.sessionID,
                workoutStartMs: metadata.workoutStartMs,
                segments: segments,
                distanceM: metadata.distanceM,
                rawFixCount: metadata.rawFixCount,
                recordingWasActive: metadata.recordingWasActive,
                hadTerminatedGap: metadata.hadTerminatedGap
            )
            return snapshot.isValid ? snapshot : nil
        }

        private func loadMetadata(key: String) -> JournalMetadata? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(JournalMetadata.self, from: data)
        }

        private func restoreDefaults(metadata: Data?, previousMetadata: Data?) {
            if let metadata {
                defaults.set(metadata, forKey: ActiveGpsWorkoutPersistence.metadataKey)
            } else {
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.metadataKey)
            }
            if let previousMetadata {
                defaults.set(previousMetadata, forKey: ActiveGpsWorkoutPersistence.previousMetadataKey)
            } else {
                defaults.removeObject(forKey: ActiveGpsWorkoutPersistence.previousMetadataKey)
            }
            _ = defaults.synchronize()
        }

        private func isCurrent(_ requestEpoch: UInt64) -> Bool {
            lock.withLock { epoch == requestEpoch }
        }

        private func writeDurably(_ data: Data, to url: URL) throws {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.synchronize()
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

        private func journalByteCount(for pointCount: Int) throws -> Int {
            guard let bytes = ActiveGpsJournalCodec.encodedByteCount(for: pointCount) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return bytes
        }

        private func cleanupStaleJournals(keeping generations: [UUID]) {
            guard let directory else { return }
            let keep = Set(generations.map { $0.uuidString.lowercased() })
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in files where url.lastPathComponent.hasPrefix("active-gps-") {
                guard !keep.contains(where: { url.lastPathComponent.contains($0) }) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }

        private func syncOnQueue<T>(_ operation: () -> T) -> T {
            if DispatchQueue.getSpecific(key: queueKey) != nil {
                return operation()
            }
            return queue.sync(execute: operation)
        }

        private static let checksumSeed: UInt64 = 14_695_981_039_346_656_037

        private static func checksum(_ data: Data, seed: UInt64 = checksumSeed) -> UInt64 {
            var value = seed
            for byte in data {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
            return value
        }
    }
}
