import CryptoKit
import Foundation
import GRDB
import NoopPhase34Core
import WhoopProtocol

/// Exact counts from one idempotent decoded-stream insert.
public struct HistoricalStreamInsertCounts: Codable, Equatable, Sendable {
    public let hr: Int
    public let rr: Int
    public let events: Int
    public let battery: Int
    public let spo2: Int
    public let skinTemp: Int
    public let resp: Int
    public let gravity: Int
    public let steps: Int
    public let sleepState: Int
    public let ppgHr: Int
    public let ppgWaveform: Int

    public init(
        hr: Int = 0,
        rr: Int = 0,
        events: Int = 0,
        battery: Int = 0,
        spo2: Int = 0,
        skinTemp: Int = 0,
        resp: Int = 0,
        gravity: Int = 0,
        steps: Int = 0,
        sleepState: Int = 0,
        ppgHr: Int = 0,
        ppgWaveform: Int = 0
    ) {
        self.hr = hr
        self.rr = rr
        self.events = events
        self.battery = battery
        self.spo2 = spo2
        self.skinTemp = skinTemp
        self.resp = resp
        self.gravity = gravity
        self.steps = steps
        self.sleepState = sleepState
        self.ppgHr = ppgHr
        self.ppgWaveform = ppgWaveform
    }

    public var total: Int {
        hr + rr + events + battery + spo2 + skinTemp + resp + gravity
            + steps + sleepState + ppgHr + ppgWaveform
    }

    var legacyCoreTuple: (
        hr: Int, rr: Int, events: Int, battery: Int,
        spo2: Int, skinTemp: Int, resp: Int, gravity: Int
    ) {
        (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
    }
}

/// Durable identity of the historical trim cursor. The lineage changes when the physical source changes;
/// the epoch changes when a device's recorded data is deleted; the scope separates trim protocols.
public struct HistoricalCursorScope: Codable, Equatable, Hashable, Sendable {
    public static let defaultTrimScope = "historical"

    public let deviceId: String
    public let lineage: String
    public let cursorEpoch: Int
    public let trimScope: String

    public init(
        deviceId: String = "",
        lineage: String,
        cursorEpoch: Int = 0,
        trimScope: String = HistoricalCursorScope.defaultTrimScope
    ) {
        self.deviceId = deviceId
        self.lineage = lineage
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
    }

    /// Convenience label for callers that use the shorter protocol term.
    public init(deviceId: String = "", lineage: String, epoch: Int, trimScope: String = HistoricalCursorScope.defaultTrimScope) {
        self.init(deviceId: deviceId, lineage: lineage, cursorEpoch: epoch, trimScope: trimScope)
    }

    public var epoch: Int { cursorEpoch }

    public var key: String {
        [deviceId, lineage, String(cursorEpoch), trimScope].joined(separator: "|")
    }
}

public typealias HistoricalDataCursorScope = HistoricalCursorScope
public typealias HistoricalDataCommitCursorScope = HistoricalCursorScope

/// Where the raw range evidence came from. `receivedFrames` means the exact bytes were supplied to
/// the fingerprint contract but were not retained in `rawBatch`.
public enum HistoricalRawRangeEvidenceSource: String, Codable, Equatable, Sendable {
    case retainedRawBatch
    case receivedFrames
    case unavailable
}

/// Range evidence that remains useful when a historical chunk decoded no physiological rows.
/// `minReceivedTs` and `maxReceivedTs` are capture/protocol range values, not inferred stream timestamps.
public struct HistoricalRawRangeEvidence: Codable, Equatable, Sendable {
    public let source: HistoricalRawRangeEvidenceSource
    public let minReceivedTs: Int?
    public let maxReceivedTs: Int?
    public let frameCount: Int
    public let byteCount: Int
    public let hasHistoryEnd: Bool

    public init(
        source: HistoricalRawRangeEvidenceSource,
        minReceivedTs: Int? = nil,
        maxReceivedTs: Int? = nil,
        frameCount: Int = 0,
        byteCount: Int = 0,
        hasHistoryEnd: Bool = false
    ) {
        self.source = source
        self.minReceivedTs = minReceivedTs
        self.maxReceivedTs = maxReceivedTs
        self.frameCount = max(0, frameCount)
        self.byteCount = max(0, byteCount)
        self.hasHistoryEnd = hasHistoryEnd
    }

    public static let none = HistoricalRawRangeEvidence(source: .unavailable)
}

/// Exact identity input for a historical commit.
///
/// Backfiller must derive the receipt fingerprint from these exact ordered frames, protocol metadata,
/// and the exact HISTORY_END frame. The journal must receive that fingerprint even when raw retention is
/// disabled. Do not build it from `Streams`; decoded streams are not a lossless replay identity.
public struct HistoricalReceivedFrameFingerprintInput: Codable, Equatable, Sendable {
    public let orderedFrames: [[UInt8]]
    public let protocolMetadata: Data
    public let historyEndFrame: Data
    public let minReceivedTs: Int?
    public let maxReceivedTs: Int?

    public init(
        orderedFrames: [[UInt8]],
        protocolMetadata: Data,
        historyEndFrame: Data,
        minReceivedTs: Int? = nil,
        maxReceivedTs: Int? = nil
    ) {
        self.orderedFrames = orderedFrames
        self.protocolMetadata = protocolMetadata
        self.historyEndFrame = historyEndFrame
        self.minReceivedTs = minReceivedTs
        self.maxReceivedTs = maxReceivedTs
    }

    public var rawRangeEvidence: HistoricalRawRangeEvidence {
        HistoricalRawRangeEvidence(
            source: .receivedFrames,
            minReceivedTs: minReceivedTs,
            maxReceivedTs: maxReceivedTs,
            frameCount: orderedFrames.count,
            byteCount: orderedFrames.reduce(0) { $0 + $1.count },
            hasHistoryEnd: true
        )
    }
}

public typealias HistoricalReceivedFrameIdentity = HistoricalReceivedFrameFingerprintInput
public typealias HistoricalDataCommitFingerprintInput = HistoricalReceivedFrameFingerprintInput

/// Optional grouping metadata supplied by a historical burst owner. It is stored with the receipt so a
/// restart can reconstruct burst boundaries without relying on in-memory Backfiller state.
public struct HistoricalDataCommitBurst: Codable, Equatable, Sendable {
    public let id: String
    public let sequence: Int
    public let isFinal: Bool

    public init(id: String, sequence: Int = 0, isFinal: Bool = false) {
        self.id = id
        self.sequence = sequence
        self.isFinal = isFinal
    }
}

/// Timestamp evidence attached to a commit. `droppedRecordCount` covers deterministic decoder-side
/// timestamp rejection; the row counts cover an explicit database heal run.
public struct HistoricalTimestampHeal: Codable, Equatable, Sendable {
    public let droppedRecordCount: Int
    public let rawRowsDeleted: Int
    public let computedRowsDeleted: Int
    public let didChange: Bool

    public init(
        droppedRecordCount: Int = 0,
        rawRowsDeleted: Int = 0,
        computedRowsDeleted: Int = 0,
        didChange: Bool? = nil
    ) {
        self.droppedRecordCount = max(0, droppedRecordCount)
        self.rawRowsDeleted = max(0, rawRowsDeleted)
        self.computedRowsDeleted = max(0, computedRowsDeleted)
        self.didChange = didChange ?? (droppedRecordCount > 0 || rawRowsDeleted > 0 || computedRowsDeleted > 0)
    }

    public init(timestampHeal result: WhoopStore.TimestampHealResult, droppedRecordCount: Int = 0) {
        self.init(
            droppedRecordCount: droppedRecordCount,
            rawRowsDeleted: result.rawRowsDeleted,
            computedRowsDeleted: result.computedRowsDeleted,
            didChange: result.didChange || droppedRecordCount > 0
        )
    }

    public static let none = HistoricalTimestampHeal()
    public var totalRowsDeleted: Int { rawRowsDeleted + computedRowsDeleted }
    public var requiresAnalysis: Bool { didChange || droppedRecordCount > 0 }
}

/// Raw capture status at the durable commit boundary. Raw capture is deliberately not part of the replay
/// fingerprint, so toggling capture between a lost ACK and a retry does not create a false conflict.
public enum HistoricalRawCaptureStatus: Codable, Equatable, Sendable {
    case captured(batchId: String)
    /// The packed bytes are the current product representation for a mapped record that has not been
    /// materialized into normalized streams yet. Raw pruning must retain this batch.
    case materializationRequired(batchId: String)
    case disabled
    case unavailable

    /// Phase1 compatibility label. New receipts use `.disabled` or `.unavailable` explicitly.
    public static var notCaptured: Self { .disabled }

    public var batchId: String? {
        switch self {
        case .captured(let batchId), .materializationRequired(let batchId): return batchId
        case .disabled, .unavailable: return nil
        }
    }

    public var hasCapture: Bool { batchId != nil }

    var storageValue: String {
        switch self {
        case .captured: return "captured"
        case .materializationRequired: return "materializationRequired"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable"
        }
    }

    static func fromStorage(_ value: String?, rawBatchId: String?) throws -> Self {
        switch value {
        case "captured":
            guard let rawBatchId, !rawBatchId.isEmpty else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            return .captured(batchId: rawBatchId)
        case "materializationRequired":
            guard let rawBatchId, !rawBatchId.isEmpty else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            return .materializationRequired(batchId: rawBatchId)
        case "disabled", "notCaptured", nil:
            guard rawBatchId == nil else { throw HistoricalDataCommitJournalError.invalidReceipt }
            return .disabled
        case "unavailable":
            guard rawBatchId == nil else { throw HistoricalDataCommitJournalError.invalidReceipt }
            return .unavailable
        default:
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
    }

    private enum CodingKeys: String, CodingKey { case type, batchId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "captured":
            let batchId = try container.decode(String.self, forKey: .batchId)
            guard !batchId.isEmpty else { throw HistoricalDataCommitJournalError.invalidReceipt }
            self = .captured(batchId: batchId)
        case "materializationRequired":
            let batchId = try container.decode(String.self, forKey: .batchId)
            guard !batchId.isEmpty else { throw HistoricalDataCommitJournalError.invalidReceipt }
            self = .materializationRequired(batchId: batchId)
        case "disabled": self = .disabled
        case "unavailable": self = .unavailable
        default: throw HistoricalDataCommitJournalError.invalidReceipt
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .captured(let batchId):
            guard !batchId.isEmpty else { throw HistoricalDataCommitJournalError.invalidReceipt }
            try container.encode("captured", forKey: .type)
            try container.encode(batchId, forKey: .batchId)
        case .materializationRequired(let batchId):
            guard !batchId.isEmpty else { throw HistoricalDataCommitJournalError.invalidReceipt }
            try container.encode("materializationRequired", forKey: .type)
            try container.encode(batchId, forKey: .batchId)
        case .disabled:
            try container.encode("disabled", forKey: .type)
        case .unavailable:
            try container.encode("unavailable", forKey: .type)
        }
    }
}

/// Durable drain watermark. `generation` orders receipts; the remaining fields prevent a consumer from
/// applying a watermark from a different database instance, device, lineage, epoch, or trim protocol.
public struct HistoricalDataCommitWatermark: Codable, Equatable, Sendable {
    public let generation: Int64
    public let databaseInstanceId: String
    public let deviceId: String
    public let lineage: String
    public let cursorEpoch: Int
    public let trimScope: String
    public let trim: Int

    public init(
        generation: Int64,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        trimScope: String,
        trim: Int,
        databaseInstanceId: String = ""
    ) {
        self.generation = generation
        self.databaseInstanceId = databaseInstanceId
        self.deviceId = deviceId
        self.lineage = lineage
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
        self.trim = trim
    }

    private enum CodingKeys: String, CodingKey {
        case generation, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generation = try container.decode(Int64.self, forKey: .generation)
        // Watermarks written before database-instance provenance existed remain decodable, but are
        // intentionally treated as untrusted by the scoped drain API.
        databaseInstanceId = try container.decodeIfPresent(String.self, forKey: .databaseInstanceId) ?? ""
        deviceId = try container.decode(String.self, forKey: .deviceId)
        lineage = try container.decode(String.self, forKey: .lineage)
        cursorEpoch = try container.decode(Int.self, forKey: .cursorEpoch)
        trimScope = try container.decode(String.self, forKey: .trimScope)
        trim = try container.decode(Int.self, forKey: .trim)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(databaseInstanceId, forKey: .databaseInstanceId)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(lineage, forKey: .lineage)
        try container.encode(cursorEpoch, forKey: .cursorEpoch)
        try container.encode(trimScope, forKey: .trimScope)
        try container.encode(trim, forKey: .trim)
    }
}

/// Raw capture that must become durable in the same SQLite transaction as decoded historical rows.
public struct HistoricalRawBatch: Equatable, Sendable {
    public let meta: RawBatchMeta
    public let frames: [[UInt8]]
    public let protocolMetadata: Data
    public let historyEndFrame: Data?

    public init(
        meta: RawBatchMeta,
        frames: [[UInt8]],
        protocolMetadata: Data = Data(),
        historyEndFrame: Data? = nil
    ) {
        self.meta = meta
        self.frames = frames
        self.protocolMetadata = protocolMetadata
        self.historyEndFrame = historyEndFrame
    }

    /// The raw batch can provide the exact identity input when retention is enabled. A Backfiller that
    /// disables retention must create `HistoricalReceivedFrameFingerprintInput` before dropping frames.
    public var fingerprintInput: HistoricalReceivedFrameFingerprintInput? {
        guard let historyEndFrame else { return nil }
        return HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame,
            minReceivedTs: meta.startTs,
            maxReceivedTs: meta.endTs
        )
    }
}

/// Durable boundary between one historical BLE chunk and every later analysis/publication phase.
public struct HistoricalDataCommitReceipt: Codable, Equatable, Sendable {
    public let receiptId: String
    public let generation: Int64
    public let databaseInstanceId: String
    public let deviceId: String
    public let trim: Int
    public let chunkEndUnix: Int
    public let committedAt: Int
    public let rawBatchId: String?
    public let insertedRows: HistoricalStreamInsertCounts

    /// Immutable received-frame identity. It covers exact ordered frames, protocol metadata, and HISTORY_END.
    /// Raw capture, commit time, and receipt UUID are excluded.
    public let fingerprint: String
    public let fingerprintVersion: Int
    public let lineage: String
    public let cursorEpoch: Int
    public let trimScope: String
    public let minDecodedTs: Int?
    public let maxDecodedTs: Int?
    public let touchedDays: [String]
    public let decodedRows: HistoricalStreamInsertCounts
    public let rawStatus: HistoricalRawCaptureStatus
    public let rawRange: HistoricalRawRangeEvidence
    public let burst: HistoricalDataCommitBurst?
    public let timestampHeal: HistoricalTimestampHeal
    public let timestampBuckets: [HistoricalTimestampBucket]
    public let recordedTimeZoneIdentifier: String
    public let explicitAffectedDays: [String]
    public let isFinal: Bool

    public init(
        receiptId: String,
        generation: Int64,
        databaseInstanceId: String,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        committedAt: Int,
        rawBatchId: String?,
        insertedRows: HistoricalStreamInsertCounts,
        fingerprint: String,
        fingerprintVersion: Int = 1,
        lineage: String? = nil,
        cursorEpoch: Int = 0,
        trimScope: String = HistoricalCursorScope.defaultTrimScope,
        minDecodedTs: Int? = nil,
        maxDecodedTs: Int? = nil,
        touchedDays: [String] = [],
        decodedRows: HistoricalStreamInsertCounts? = nil,
        rawStatus: HistoricalRawCaptureStatus? = nil,
        rawRange: HistoricalRawRangeEvidence? = nil,
        burst: HistoricalDataCommitBurst? = nil,
        timestampHeal: HistoricalTimestampHeal? = nil,
        timestampBuckets: [HistoricalTimestampBucket] = [],
        recordedTimeZoneIdentifier: String = TimeZone.current.identifier,
        explicitAffectedDays: [String] = [],
        isFinal: Bool = false
    ) {
        self.receiptId = receiptId
        self.generation = generation
        self.databaseInstanceId = databaseInstanceId
        self.deviceId = deviceId
        self.trim = trim
        self.chunkEndUnix = chunkEndUnix
        self.committedAt = committedAt
        self.insertedRows = insertedRows
        self.fingerprint = fingerprint
        self.fingerprintVersion = max(1, fingerprintVersion)
        self.lineage = lineage ?? "device:\(deviceId)"
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
        self.minDecodedTs = minDecodedTs
        self.maxDecodedTs = maxDecodedTs
        self.touchedDays = touchedDays
        self.decodedRows = decodedRows ?? insertedRows
        let resolvedRawStatus = rawStatus ?? (rawBatchId.map { .captured(batchId: $0) } ?? .disabled)
        self.rawStatus = resolvedRawStatus
        self.rawBatchId = resolvedRawStatus.batchId
        self.rawRange = rawRange ?? .none
        self.burst = burst
        self.timestampHeal = timestampHeal ?? .none
        self.timestampBuckets = timestampBuckets
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.explicitAffectedDays = explicitAffectedDays
        self.isFinal = isFinal
    }

    public var minDecodedTimestamp: Int? { minDecodedTs }
    public var maxDecodedTimestamp: Int? { maxDecodedTs }
    public var decodedCounts: HistoricalStreamInsertCounts { decodedRows }
    public var decodedCount: Int { decodedRows.total }
    public var insertedCount: Int { insertedRows.total }
    public var touchedDayKeys: [Int] {
        touchedDays.compactMap { Int($0.replacingOccurrences(of: "-", with: "")) }
    }
    public var rawCaptureStatus: HistoricalRawCaptureStatus { rawStatus }
    public var burstId: String? { burst?.id }
    public var timestampHeals: HistoricalTimestampHeal { timestampHeal }

    /// The receipt itself is the durable watermark. The cursor table stores the same generation so a
    /// drain can resume even when its last in-memory receipt was lost.
    public var durableWatermark: HistoricalDataCommitWatermark {
        HistoricalDataCommitWatermark(
            generation: generation,
            deviceId: deviceId,
            lineage: lineage,
            cursorEpoch: cursorEpoch,
            trimScope: trimScope,
            trim: trim,
            databaseInstanceId: databaseInstanceId
        )
    }

    public var watermark: HistoricalDataCommitWatermark { durableWatermark }

    func withFingerprint(_ fingerprint: String) -> HistoricalDataCommitReceipt {
        HistoricalDataCommitReceipt(
            receiptId: receiptId,
            generation: generation,
            databaseInstanceId: databaseInstanceId,
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix,
            committedAt: committedAt,
            rawBatchId: rawBatchId,
            insertedRows: insertedRows,
            fingerprint: fingerprint,
            fingerprintVersion: fingerprintVersion,
            lineage: lineage,
            cursorEpoch: cursorEpoch,
            trimScope: trimScope,
            minDecodedTs: minDecodedTs,
            maxDecodedTs: maxDecodedTs,
            touchedDays: touchedDays,
            decodedRows: decodedRows,
            rawStatus: rawStatus,
            rawRange: rawRange,
            burst: burst,
            timestampHeal: timestampHeal,
            timestampBuckets: timestampBuckets,
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
            explicitAffectedDays: explicitAffectedDays,
            isFinal: isFinal
        )
    }
}

public enum HistoricalDataCommitJournalError: Error, Equatable, Sendable {
    case invalidTrim
    case rawBatchDeviceMismatch
    case missingDatabaseIdentity
    case invalidReceipt
    case invalidFingerprint
    case invalidCursorScope
    case conflictingRawCaptureReplay
    case conflictingFingerprintReplay
}

private struct PackedHistoricalRawBatch: Sendable {
    let meta: RawBatchMeta
    let blob: Data
}

extension WhoopStore {
    /// Stable UUID created with the database. It changes only when a replacement database becomes active.
    public func databaseInstanceId() async throws -> String {
        try syncRead { db in
            try WhoopStore.databaseInstanceId(in: db)
        }
    }

    static func databaseInstanceId(in db: Database) throws -> String {
        guard let id = try String.fetchOne(
            db,
            sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1"
        ) else {
            throw HistoricalDataCommitJournalError.missingDatabaseIdentity
        }
        return id
    }

    /// Resolve the current registry lineage and cursor epoch. Sources that are not registered (for example
    /// package tests and one-off imports) still get a stable, device-scoped fallback.
    static func historicalCursorScope(
        deviceId: String,
        trimScope: String = HistoricalCursorScope.defaultTrimScope,
        requestedLineage: String? = nil,
        requestedCursorEpoch: Int? = nil,
        in db: Database
    ) throws -> HistoricalCursorScope {
        guard !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !trimScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoricalDataCommitJournalError.invalidCursorScope
        }
        if let requestedLineage,
           requestedLineage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw HistoricalDataCommitJournalError.invalidCursorScope
        }
        if let requestedCursorEpoch, requestedCursorEpoch < 0 {
            throw HistoricalDataCommitJournalError.invalidCursorScope
        }
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT historyLineage, historyCursorEpoch FROM pairedDevice WHERE id = ?",
            arguments: [deviceId]
        ) {
            let lineage: String? = row["historyLineage"]
            let epoch: Int? = row["historyCursorEpoch"]
            let currentLineage = lineage?.isEmpty == false ? lineage! : "device:\(deviceId)"
            let currentEpoch = max(0, epoch ?? 0)
            // A caller can omit the scope and let the transaction resolve it. If it supplies one,
            // every registry-backed component must still match the current physical-source fence.
            guard requestedLineage == nil || requestedLineage == currentLineage,
                  requestedCursorEpoch == nil || requestedCursorEpoch == currentEpoch else {
                throw HistoricalDataCommitJournalError.invalidCursorScope
            }
            return HistoricalCursorScope(
                deviceId: deviceId,
                lineage: currentLineage,
                cursorEpoch: currentEpoch,
                trimScope: trimScope
            )
        }
        return HistoricalCursorScope(
            deviceId: deviceId,
            lineage: requestedLineage ?? "device:\(deviceId)",
            cursorEpoch: requestedCursorEpoch ?? 0,
            trimScope: trimScope
        )
    }

    /// Atomically persist one historical chunk and its durable commit receipt.
    ///
    /// Replay identity is the required SHA-256 `fingerprint` supplied by Backfiller. V3 uses exact ordered
    /// historical data frames in their durable source scope. Retry-specific START/END envelope bytes and
    /// decoded `Streams` are evidence, not identity.
    public func commitHistoricalChunk(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int,
        fingerprint: String,
        fingerprintInput: HistoricalReceivedFrameFingerprintInput,
        rawCaptureStatus: HistoricalRawCaptureStatus? = nil,
        rawRange: HistoricalRawRangeEvidence? = nil,
        lineage: String? = nil,
        cursorEpoch: Int? = nil,
        trimScope: String = HistoricalCursorScope.defaultTrimScope,
        burst: HistoricalDataCommitBurst? = nil,
        timestampHeal: HistoricalTimestampHeal? = nil,
        recordedTimeZoneIdentifier: String = TimeZone.current.identifier,
        explicitAffectedDays: [String] = [],
        isFinal: Bool = false
    ) async throws -> HistoricalDataCommitReceipt {
        guard (0...Int(UInt32.max)).contains(trim) else {
            throw HistoricalDataCommitJournalError.invalidTrim
        }
        if let rawBatch, rawBatch.meta.deviceId != deviceId {
            throw HistoricalDataCommitJournalError.rawBatchDeviceMismatch
        }

        guard WhoopStore.isValidHistoricalFingerprint(fingerprint) else {
            throw HistoricalDataCommitJournalError.invalidFingerprint
        }
        if let rawBatch {
            // Raw metadata may use a fallback range when no incoming frame carries a timestamp. The
            // fingerprint input remains the exact received-frame range, including nil, so it must not
            // be required to equal the retained metadata range.
            let actualByteCount = rawBatch.frames.reduce(0) { $0 + $1.count }
            guard rawBatch.meta.frameCount == rawBatch.frames.count,
                  rawBatch.meta.byteSize == actualByteCount,
                  rawBatch.meta.startTs <= rawBatch.meta.endTs,
                  rawBatch.frames == fingerprintInput.orderedFrames,
                  rawBatch.protocolMetadata == fingerprintInput.protocolMetadata,
                  rawBatch.historyEndFrame == fingerprintInput.historyEndFrame else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
        }
        if let rawBatch, rawBatch.meta.batchId.isEmpty {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let effectiveFingerprint = fingerprint
        let effectiveRawStatus: HistoricalRawCaptureStatus
        let effectiveRawRange: HistoricalRawRangeEvidence
        if let rawBatch {
            let captured = HistoricalRawCaptureStatus.captured(batchId: rawBatch.meta.batchId)
            let required = HistoricalRawCaptureStatus.materializationRequired(batchId: rawBatch.meta.batchId)
            guard rawCaptureStatus == nil || rawCaptureStatus == captured || rawCaptureStatus == required else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            effectiveRawStatus = rawCaptureStatus ?? captured
            let retainedRange = HistoricalRawRangeEvidence(
                source: .retainedRawBatch,
                minReceivedTs: rawBatch.meta.startTs,
                maxReceivedTs: rawBatch.meta.endTs,
                frameCount: rawBatch.meta.frameCount,
                byteCount: rawBatch.meta.byteSize,
                hasHistoryEnd: rawBatch.historyEndFrame != nil
            )
            guard rawRange == nil || rawRange == retainedRange else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            effectiveRawRange = retainedRange
        } else {
            if rawCaptureStatus?.hasCapture == true {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            effectiveRawStatus = rawCaptureStatus ?? .disabled
            let receivedRange = fingerprintInput.rawRangeEvidence
            guard rawRange == nil || rawRange == receivedRange else {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
            effectiveRawRange = receivedRange
        }
        let effectiveHeal = timestampHeal ?? HistoricalTimestampHeal(
            droppedRecordCount: streams.droppedImplausible
        )
        let decodedRows = WhoopStore.decodedStreamCounts(streams)
        let timestamps = WhoopStore.decodedTimestamps(streams)
        guard TimeZone(identifier: recordedTimeZoneIdentifier) != nil else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let timestampBuckets = try WhoopStore.historicalTimestampBuckets(for: streams)
        let minDecodedTs = timestamps.min()
        let maxDecodedTs = timestamps.max()
        let touchedDays = WhoopStore.touchedDays(for: timestamps)
        let finalReceipt = isFinal || trim == Int(UInt32.max)

        // Packing and compression can be substantial for V20/V21. Prepare it on the store actor before
        // requesting the process-wide SQLite writer so Repository and HealthKit writes do not queue behind
        // CPU work that does not need a transaction.
        let preparedRawBlob: Data? = try rawBatch.map {
            try WhoopStore.zlibCompressWithLength(WhoopStore.packFrames($0.frames))
        }
        let prevalidatedScope: HistoricalCursorScope?
        if let lineage, let cursorEpoch {
            // Keep current-registry validation ahead of fingerprint validation. Apart from preserving the
            // typed fail-closed contract, this short read also freezes the exact scope used for the CPU-only
            // hash before the writer is requested. The transaction resolves it again below to close a
            // lineage-rotation race.
            prevalidatedScope = try syncRead { db in
                try WhoopStore.historicalCursorScope(
                    deviceId: deviceId,
                    trimScope: trimScope,
                    requestedLineage: lineage,
                    requestedCursorEpoch: cursorEpoch,
                    in: db
                )
            }
            let derivedFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
                input: fingerprintInput,
                scope: prevalidatedScope!,
                trim: trim
            )
            guard derivedFingerprint == effectiveFingerprint else {
                throw HistoricalDataCommitJournalError.invalidFingerprint
            }
        } else {
            prevalidatedScope = nil
        }

        return try syncWrite { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            let resolvedScope = try WhoopStore.historicalCursorScope(
                deviceId: deviceId,
                trimScope: trimScope,
                requestedLineage: lineage,
                requestedCursorEpoch: cursorEpoch,
                in: db
            )
            guard prevalidatedScope == nil || resolvedScope == prevalidatedScope else {
                throw HistoricalDataCommitJournalError.invalidCursorScope
            }
            if prevalidatedScope == nil {
                let derivedFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
                    input: fingerprintInput,
                    scope: resolvedScope,
                    trim: trim
                )
                guard derivedFingerprint == effectiveFingerprint else {
                    throw HistoricalDataCommitJournalError.invalidFingerprint
                }
            }

            if let existing = try WhoopStore.historicalDataCommitReceipt(
                databaseInstanceId: databaseInstanceId,
                scope: resolvedScope,
                trim: trim,
                fingerprintVersion: HistoricalFingerprintV3Payload.version,
                fingerprint: effectiveFingerprint,
                in: db
            ) {
                return existing
            }

            let scopedRawMeta = rawBatch?.meta.withHistoricalScope(
                lineage: resolvedScope.lineage,
                cursorEpoch: resolvedScope.cursorEpoch
            )
            let packedRawBatch: PackedHistoricalRawBatch?
            let existingRawBatchMatches: Bool?
            if rawBatch != nil, let scopedRawMeta {
                packedRawBatch = PackedHistoricalRawBatch(
                    meta: scopedRawMeta,
                    blob: preparedRawBlob!
                )
                existingRawBatchMatches = try WhoopStore.existingRawBatchMatches(
                    scopedRawMeta,
                    blob: packedRawBatch!.blob,
                    in: db
                )
                guard existingRawBatchMatches != false else {
                    throw HistoricalDataCommitJournalError.conflictingRawCaptureReplay
                }
            } else {
                packedRawBatch = nil
                existingRawBatchMatches = nil
            }

            // A closed physical scope may replay an already-committed receipt, but it cannot create a
            // new receipt after archive or re-pair froze its durable frontier.
            try WhoopStore.assertHistoricalScopeAcceptingIngest(resolvedScope, in: db)
            let insertedRows = try WhoopStore.insertDecodedStreams(
                streams,
                deviceId: deviceId,
                in: db
            )
            if let packedRawBatch, existingRawBatchMatches == nil {
                try WhoopStore.enqueueRawBatch(
                    packedRawBatch.meta,
                    blob: packedRawBatch.blob,
                    in: db
                )
            }

            let receiptId = UUID().uuidString
            let encodedDecodedRows = try JSONEncoder().encode(decodedRows)
            let encodedInsertedRows = try JSONEncoder().encode(insertedRows)
            let encodedTouchedDays = try JSONEncoder().encode(touchedDays)
            let encodedRawRange = try JSONEncoder().encode(effectiveRawRange)
            let encodedBurst = try burst.map { try JSONEncoder().encode($0) }
            let encodedTimestampHeal = try JSONEncoder().encode(effectiveHeal)
            let encodedTimestampBuckets = try JSONEncoder().encode(timestampBuckets)
            let encodedExplicitAffectedDays = try JSONEncoder().encode(explicitAffectedDays.sorted())
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim,
                     chunkEndUnix, committedAt, fingerprint, minDecodedTs, maxDecodedTs, touchedDaysJSON,
                     decodedRowsJSON, insertedRowsJSON, rawBatchId, rawStatus, burstJSON,
                     rawRangeJSON, timestampHealJSON, isFinal, fingerprintVersion,
                     timestampBucketsJSON, recordedTimeZoneIdentifier, explicitAffectedDaysJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receiptId, databaseInstanceId, deviceId, resolvedScope.lineage, resolvedScope.cursorEpoch,
                    resolvedScope.trimScope, trim, chunkEndUnix, committedAt, effectiveFingerprint,
                    minDecodedTs, maxDecodedTs, encodedTouchedDays, encodedDecodedRows, encodedInsertedRows,
                    effectiveRawStatus.batchId, effectiveRawStatus.storageValue, encodedBurst, encodedRawRange,
                    encodedTimestampHeal,
                    finalReceipt ? 1 : 0,
                    HistoricalFingerprintV3Payload.version,
                    encodedTimestampBuckets,
                    recordedTimeZoneIdentifier,
                    encodedExplicitAffectedDays,
                ])
            let generation = db.lastInsertedRowID
            try WhoopStore.setHistoricalCursor(
                resolvedScope,
                value: trim,
                watermarkGeneration: generation,
                in: db
            )

            return HistoricalDataCommitReceipt(
                receiptId: receiptId,
                generation: generation,
                databaseInstanceId: databaseInstanceId,
                deviceId: deviceId,
                trim: trim,
                chunkEndUnix: chunkEndUnix,
                committedAt: committedAt,
                rawBatchId: effectiveRawStatus.batchId,
                insertedRows: insertedRows,
                fingerprint: effectiveFingerprint,
                fingerprintVersion: HistoricalFingerprintV3Payload.version,
                lineage: resolvedScope.lineage,
                cursorEpoch: resolvedScope.cursorEpoch,
                trimScope: resolvedScope.trimScope,
                minDecodedTs: minDecodedTs,
                maxDecodedTs: maxDecodedTs,
                touchedDays: touchedDays,
                decodedRows: decodedRows,
                rawStatus: effectiveRawStatus,
                rawRange: effectiveRawRange,
                burst: burst,
                timestampHeal: effectiveHeal,
                timestampBuckets: timestampBuckets,
                recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
                explicitAffectedDays: explicitAffectedDays.sorted(),
                isFinal: finalReceipt
            )
        }
    }

    /// Scope-typed overload for callers that already own the lineage/epoch decision.
    public func commitHistoricalChunk(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int,
        scope: HistoricalCursorScope,
        fingerprint: String,
        fingerprintInput: HistoricalReceivedFrameFingerprintInput,
        rawCaptureStatus: HistoricalRawCaptureStatus? = nil,
        rawRange: HistoricalRawRangeEvidence? = nil,
        burst: HistoricalDataCommitBurst? = nil,
        timestampHeal: HistoricalTimestampHeal? = nil,
        isFinal: Bool = false
    ) async throws -> HistoricalDataCommitReceipt {
        guard scope.deviceId.isEmpty || scope.deviceId == deviceId else {
            throw HistoricalDataCommitJournalError.invalidCursorScope
        }
        return try await commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix,
            rawBatch: rawBatch,
            committedAt: committedAt,
            fingerprint: fingerprint,
            fingerprintInput: fingerprintInput,
            rawCaptureStatus: rawCaptureStatus,
            rawRange: rawRange,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope,
            burst: burst,
            timestampHeal: timestampHeal,
            isFinal: isFinal
        )
    }

    /// Ordered durable receipts. Supplying scope fields turns this into a restart-safe drain query for one
    /// physical source. Omitting them preserves the phase1 device-wide read for migration tooling.
    public func historicalDataCommitReceipts(
        deviceId: String,
        afterGeneration: Int64 = 0,
        limit: Int = 100,
        lineage: String? = nil,
        cursorEpoch: Int? = nil,
        trimScope: String? = nil
    ) async throws -> [HistoricalDataCommitReceipt] {
        guard limit > 0 else { return [] }
        return try syncRead { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            var sql = """
                SELECT generation, receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                       committedAt, rawBatchId, fingerprint, lineage, cursorEpoch, trimScope,
                       minDecodedTs, maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON,
                       rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal,
                       fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                       explicitAffectedDaysJSON
                FROM historicalDataCommitJournal
                WHERE databaseInstanceId = ? AND deviceId = ? AND generation > ?
                """
            var args: [DatabaseValueConvertible] = [databaseInstanceId, deviceId, afterGeneration]
            if let lineage {
                sql += " AND lineage = ?"
                args.append(lineage)
            }
            if let cursorEpoch {
                sql += " AND cursorEpoch = ?"
                args.append(cursorEpoch)
            }
            if let trimScope {
                sql += " AND trimScope = ?"
                args.append(trimScope)
            }
            sql += " ORDER BY generation ASC LIMIT ?"
            args.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                .map(WhoopStore.decodeHistoricalDataCommitReceipt)
        }
    }

    /// Drain receipts after a previously durable watermark without crossing its source scope.
    public func historicalDataCommitReceipts(
        deviceId: String,
        after watermark: HistoricalDataCommitWatermark?,
        limit: Int = 100
    ) async throws -> [HistoricalDataCommitReceipt] {
        guard let watermark else {
            return try await historicalDataCommitReceipts(deviceId: deviceId, limit: limit)
        }
        let currentDatabaseInstanceId = try await databaseInstanceId()
        guard !watermark.databaseInstanceId.isEmpty,
              watermark.databaseInstanceId == currentDatabaseInstanceId,
              watermark.deviceId == deviceId else {
            return []
        }
        return try await historicalDataCommitReceipts(
            deviceId: deviceId,
            afterGeneration: watermark.generation,
            limit: limit,
            lineage: watermark.lineage,
            cursorEpoch: watermark.cursorEpoch,
            trimScope: watermark.trimScope
        )
    }

    /// Latest durable watermark for a scoped historical drain.
    public func historicalDataCommitWatermark(
        deviceId: String,
        lineage: String? = nil,
        cursorEpoch: Int? = nil,
        trimScope: String = HistoricalCursorScope.defaultTrimScope
    ) async throws -> HistoricalDataCommitWatermark? {
        try syncRead { db -> HistoricalDataCommitWatermark? in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            let registryScope = try WhoopStore.historicalCursorScope(
                deviceId: deviceId,
                trimScope: trimScope,
                in: db
            )
            let resolvedLineage = lineage ?? registryScope.lineage
            let resolvedEpoch: Int
            if let cursorEpoch {
                resolvedEpoch = cursorEpoch
            } else if resolvedLineage == registryScope.lineage {
                // A lineage-only query for the current source must stay on the current deletion epoch.
                resolvedEpoch = registryScope.cursorEpoch
            } else {
                // A different lineage is ambiguous without its explicit epoch. Fail closed rather than
                // silently querying epoch zero and returning a stale watermark.
                return nil
            }
            let scope = HistoricalCursorScope(
                deviceId: deviceId,
                lineage: resolvedLineage,
                cursorEpoch: resolvedEpoch,
                trimScope: trimScope
            )
            guard let row = try Row.fetchOne(db, sql: """
                SELECT trim, watermarkGeneration
                FROM historicalCursor
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope]) else {
                return nil
            }
            let generation: Int64 = row["watermarkGeneration"]
            return HistoricalDataCommitWatermark(
                generation: generation,
                deviceId: scope.deviceId,
                lineage: scope.lineage,
                cursorEpoch: scope.cursorEpoch,
                trimScope: scope.trimScope,
                trim: row["trim"],
                databaseInstanceId: databaseInstanceId
            )
        }
    }

    private static func historicalDataCommitReceipt(
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        trim: Int,
        fingerprintVersion: Int,
        fingerprint: String,
        in db: Database
    ) throws -> HistoricalDataCommitReceipt? {
        let row = try Row.fetchOne(db, sql: """
            SELECT generation, receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                   committedAt, rawBatchId, fingerprint, lineage, cursorEpoch, trimScope,
                   minDecodedTs, maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON,
                   rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal,
                   fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                   explicitAffectedDaysJSON
            FROM historicalDataCommitJournal
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
              AND trimScope = ? AND trim = ? AND fingerprintVersion = ? AND fingerprint = ?
            """, arguments: [
                databaseInstanceId, scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope, trim,
                fingerprintVersion, fingerprint,
            ])
        return try row.map(WhoopStore.decodeHistoricalDataCommitReceipt)
    }

    private static func decodeHistoricalDataCommitReceipt(
        _ row: Row
    ) throws -> HistoricalDataCommitReceipt {
        let insertedRowsJSON: Data = row["insertedRowsJSON"]
        let insertedRows: HistoricalStreamInsertCounts
        do {
            insertedRows = try JSONDecoder().decode(HistoricalStreamInsertCounts.self, from: insertedRowsJSON)
        } catch {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }

        let decodedRowsJSON: Data? = row["decodedRowsJSON"]
        let decodedRows = decodedRowsJSON.flatMap {
            try? JSONDecoder().decode(HistoricalStreamInsertCounts.self, from: $0)
        } ?? insertedRows
        let touchedDaysJSON: Data? = row["touchedDaysJSON"]
        let touchedDays = touchedDaysJSON.flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } ?? []
        let burstJSON: Data? = row["burstJSON"]
        let burst = burstJSON.flatMap {
            try? JSONDecoder().decode(HistoricalDataCommitBurst.self, from: $0)
        }
        let rawRangeJSON: Data? = row["rawRangeJSON"]
        let rawRange: HistoricalRawRangeEvidence
        if let rawRangeJSON {
            do {
                rawRange = try JSONDecoder().decode(HistoricalRawRangeEvidence.self, from: rawRangeJSON)
            } catch {
                throw HistoricalDataCommitJournalError.invalidReceipt
            }
        } else {
            rawRange = .none
        }
        let timestampHealJSON: Data? = row["timestampHealJSON"]
        let timestampHeal = timestampHealJSON.flatMap {
            try? JSONDecoder().decode(HistoricalTimestampHeal.self, from: $0)
        } ?? .none
        let fingerprintVersion: Int = row["fingerprintVersion"] ?? 1
        let timestampBucketsJSON: Data? = row["timestampBucketsJSON"]
        let timestampBuckets = timestampBucketsJSON.flatMap {
            try? JSONDecoder().decode([HistoricalTimestampBucket].self, from: $0)
        } ?? []
        let recordedTimeZoneIdentifier: String = row["recordedTimeZoneIdentifier"] ?? "UTC"
        let explicitAffectedDaysJSON: Data? = row["explicitAffectedDaysJSON"]
        let explicitAffectedDays = explicitAffectedDaysJSON.flatMap {
            try? JSONDecoder().decode([String].self, from: $0)
        } ?? []
        let rawStatusString: String? = row["rawStatus"]
        let rawBatchId: String? = row["rawBatchId"]
        let rawStatus = try HistoricalRawCaptureStatus.fromStorage(rawStatusString, rawBatchId: rawBatchId)
        let rawEvidenceIsConsistent: Bool
        switch rawStatus {
        case .captured, .materializationRequired:
            rawEvidenceIsConsistent = rawRange.source == .retainedRawBatch
        case .disabled, .unavailable:
            rawEvidenceIsConsistent = rawRange.source != .retainedRawBatch
        }
        guard rawEvidenceIsConsistent else {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        let fingerprint: String = row["fingerprint"]
        guard WhoopStore.isValidHistoricalFingerprint(fingerprint)
                || (fingerprint.hasPrefix("legacy:") && fingerprint.count > "legacy:".count)
        else { throw HistoricalDataCommitJournalError.invalidReceipt }

        return HistoricalDataCommitReceipt(
            receiptId: row["receiptId"],
            generation: row["generation"],
            databaseInstanceId: row["databaseInstanceId"],
            deviceId: row["deviceId"],
            trim: row["trim"],
            chunkEndUnix: row["chunkEndUnix"],
            committedAt: row["committedAt"],
            rawBatchId: rawBatchId,
            insertedRows: insertedRows,
            fingerprint: fingerprint,
            fingerprintVersion: fingerprintVersion,
            lineage: row["lineage"],
            cursorEpoch: row["cursorEpoch"],
            trimScope: row["trimScope"],
            minDecodedTs: row["minDecodedTs"],
            maxDecodedTs: row["maxDecodedTs"],
            touchedDays: touchedDays,
            decodedRows: decodedRows,
            rawStatus: rawStatus,
            rawRange: rawRange,
            burst: burst,
            timestampHeal: timestampHeal,
            timestampBuckets: timestampBuckets,
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
            explicitAffectedDays: explicitAffectedDays,
            isFinal: (row["isFinal"] as Int) == 1
        )
    }

    private static func decodedStreamCounts(_ streams: Streams) -> HistoricalStreamInsertCounts {
        HistoricalStreamInsertCounts(
            hr: streams.hr.count,
            rr: streams.rr.count,
            events: streams.events.count,
            battery: streams.battery.count,
            spo2: streams.spo2.count,
            skinTemp: streams.skinTemp.count,
            resp: streams.resp.count,
            gravity: streams.gravity.count,
            steps: streams.steps.count,
            sleepState: streams.sleepState.count,
            ppgHr: streams.ppgHr.count,
            ppgWaveform: streams.ppgWaveform.count
        )
    }

    private static func decodedTimestamps(_ streams: Streams) -> [Int] {
        streams.hr.map(\.ts)
            + streams.rr.map(\.ts)
            + streams.events.map(\.ts)
            + streams.battery.map(\.ts)
            + streams.spo2.map(\.ts)
            + streams.skinTemp.map(\.ts)
            + streams.resp.map(\.ts)
            + streams.gravity.map(\.ts)
            + streams.steps.map(\.ts)
            + streams.sleepState.map(\.ts)
            + streams.ppgHr.map(\.ts)
            + streams.ppgWaveform.map(\.ts)
    }

    private static func touchedDays(for timestamps: [Int]) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return Set(timestamps.map { formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) })
            .sorted()
    }

    /// Hash exact ordered historical data-frame identity. START/END envelopes remain evidence only because
    /// WHOOP changes them across retries of the same flash cursor.
    public static func historicalReceivedFrameFingerprint(
        input: HistoricalReceivedFrameFingerprintInput,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int
    ) throws -> String {
        guard !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (0...Int(UInt32.max)).contains(trim),
              !input.historyEndFrame.isEmpty else {
            throw HistoricalDataCommitJournalError.invalidFingerprint
        }
        // Keep the source-compatible overload for unrelated callers. `chunkEndUnix` is no longer replay
        // identity. New production callers pass the transaction-resolved scope overload below.
        return try historicalReceivedFrameFingerprintV3(
            orderedFrames: input.orderedFrames,
            scope: HistoricalCursorScope(
                deviceId: deviceId,
                lineage: "device:\(deviceId)",
                cursorEpoch: 0,
                trimScope: HistoricalCursorScope.defaultTrimScope
            ),
            trim: trim
        )
    }

    public static func historicalReceivedFrameFingerprint(
        input: HistoricalReceivedFrameFingerprintInput,
        scope: HistoricalCursorScope,
        trim: Int
    ) throws -> String {
        try historicalReceivedFrameFingerprintV3(
            orderedFrames: input.orderedFrames,
            scope: scope,
            trim: trim
        )
    }

    /// Convenience form for Backfiller call sites that already hold the exact received-frame fields.
    public static func historicalReceivedFrameFingerprint(
        orderedFrames: [[UInt8]],
        protocolMetadata: Data,
        historyEndFrame: Data,
        minReceivedTs: Int? = nil,
        maxReceivedTs: Int? = nil,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int
    ) throws -> String {
        try historicalReceivedFrameFingerprint(
            input: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: orderedFrames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: minReceivedTs,
                maxReceivedTs: maxReceivedTs
            ),
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix
        )
    }

    /// Validate the on-disk fingerprint contract. New receipts always store a non-empty SHA-256 hex
    /// digest. The v35 migration uses an explicit `legacy:<receiptId>` marker only for v34 rows.
    static func isValidHistoricalFingerprint(_ fingerprint: String) -> Bool {
        let bytes = Array(fingerprint.utf8)
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}
