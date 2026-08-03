import Foundation
import GRDB
import WhoopProtocol

/// Exact counts from one idempotent decoded-stream insert.
///
/// This is deliberately broader than the legacy eight-field `insert` return tuple. A historical
/// receipt must account for every stream that reaches SQLite, including WHOOP 5 step, sleep-state,
/// and PPG rows that were previously persisted without an observable count.
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

/// Raw capture that must become durable in the same SQLite transaction as decoded historical rows.
public struct HistoricalRawBatch: Equatable, Sendable {
    public let meta: RawBatchMeta
    public let frames: [[UInt8]]

    public init(meta: RawBatchMeta, frames: [[UInt8]]) {
        self.meta = meta
        self.frames = frames
    }
}

/// Durable boundary between a historical BLE chunk and every later analysis/publication phase.
///
/// A receipt is emitted only after decoded rows, optional raw capture, `strap_trim`, and this journal row
/// commit together. `databaseInstanceId` and `deviceId` fence restore, deletion, and re-pair boundaries.
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

    public init(
        receiptId: String,
        generation: Int64,
        databaseInstanceId: String,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        committedAt: Int,
        rawBatchId: String?,
        insertedRows: HistoricalStreamInsertCounts
    ) {
        self.receiptId = receiptId
        self.generation = generation
        self.databaseInstanceId = databaseInstanceId
        self.deviceId = deviceId
        self.trim = trim
        self.chunkEndUnix = chunkEndUnix
        self.committedAt = committedAt
        self.rawBatchId = rawBatchId
        self.insertedRows = insertedRows
    }
}

public enum HistoricalDataCommitJournalError: Error, Equatable, Sendable {
    case invalidTrim
    case rawBatchDeviceMismatch
    case missingDatabaseIdentity
    case invalidReceipt
    case conflictingRawCaptureReplay
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

    /// Atomically persist one historical chunk and its durable commit receipt.
    ///
    /// Replay of the same `(databaseInstanceId, deviceId, trim)` returns the first receipt without
    /// reinserting data. A raw-capture mode change for an already committed trim fails closed instead of
    /// silently claiming that a batch was captured when it was not.
    public func commitHistoricalChunk(
        streams: Streams,
        deviceId: String,
        trim: Int,
        chunkEndUnix: Int,
        rawBatch: HistoricalRawBatch?,
        committedAt: Int
    ) async throws -> HistoricalDataCommitReceipt {
        guard (0...Int(UInt32.max)).contains(trim) else {
            throw HistoricalDataCommitJournalError.invalidTrim
        }
        if let rawBatch, rawBatch.meta.deviceId != deviceId {
            throw HistoricalDataCommitJournalError.rawBatchDeviceMismatch
        }

        let packedRawBatch: PackedHistoricalRawBatch?
        if let rawBatch {
            let packedFrames = WhoopStore.packFrames(rawBatch.frames)
            packedRawBatch = PackedHistoricalRawBatch(
                meta: rawBatch.meta,
                blob: try WhoopStore.zlibCompressWithLength(packedFrames)
            )
        } else {
            packedRawBatch = nil
        }

        return try syncWrite { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            let existingRawBatchMatches: Bool?
            if let packedRawBatch {
                existingRawBatchMatches = try WhoopStore.existingRawBatchMatches(
                    packedRawBatch.meta,
                    blob: packedRawBatch.blob,
                    in: db
                )
                guard existingRawBatchMatches != false else {
                    throw HistoricalDataCommitJournalError.conflictingRawCaptureReplay
                }
            } else {
                existingRawBatchMatches = nil
            }
            if let existing = try WhoopStore.historicalDataCommitReceipt(
                databaseInstanceId: databaseInstanceId,
                deviceId: deviceId,
                trim: trim,
                in: db
            ) {
                guard existing.rawBatchId == packedRawBatch?.meta.batchId else {
                    throw HistoricalDataCommitJournalError.conflictingRawCaptureReplay
                }
                return existing
            }

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
            try WhoopStore.setCursor("strap_trim", trim, in: db)

            let receiptId = UUID().uuidString
            let encodedCounts = try JSONEncoder().encode(insertedRows)
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                     committedAt, rawBatchId, insertedRowsJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receiptId,
                    databaseInstanceId,
                    deviceId,
                    trim,
                    chunkEndUnix,
                    committedAt,
                    packedRawBatch?.meta.batchId,
                    encodedCounts,
                ])

            return HistoricalDataCommitReceipt(
                receiptId: receiptId,
                generation: db.lastInsertedRowID,
                databaseInstanceId: databaseInstanceId,
                deviceId: deviceId,
                trim: trim,
                chunkEndUnix: chunkEndUnix,
                committedAt: committedAt,
                rawBatchId: packedRawBatch?.meta.batchId,
                insertedRows: insertedRows
            )
        }
    }

    /// Ordered durable receipts for one device. Later Phase 2 stages use this for restart-safe analysis.
    public func historicalDataCommitReceipts(
        deviceId: String,
        afterGeneration: Int64 = 0,
        limit: Int = 100
    ) async throws -> [HistoricalDataCommitReceipt] {
        guard limit > 0 else { return [] }
        return try syncRead { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            return try Row.fetchAll(db, sql: """
                SELECT generation, receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                       committedAt, rawBatchId, insertedRowsJSON
                FROM historicalDataCommitJournal
                WHERE databaseInstanceId = ? AND deviceId = ? AND generation > ?
                ORDER BY generation ASC
                LIMIT ?
                """, arguments: [databaseInstanceId, deviceId, afterGeneration, limit])
                .map(WhoopStore.decodeHistoricalDataCommitReceipt)
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

    private static func historicalDataCommitReceipt(
        databaseInstanceId: String,
        deviceId: String,
        trim: Int,
        in db: Database
    ) throws -> HistoricalDataCommitReceipt? {
        let row = try Row.fetchOne(db, sql: """
            SELECT generation, receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                   committedAt, rawBatchId, insertedRowsJSON
            FROM historicalDataCommitJournal
            WHERE databaseInstanceId = ? AND deviceId = ? AND trim = ?
            """, arguments: [databaseInstanceId, deviceId, trim])
        return try row.map(WhoopStore.decodeHistoricalDataCommitReceipt)
    }

    private static func decodeHistoricalDataCommitReceipt(
        _ row: Row
    ) throws -> HistoricalDataCommitReceipt {
        let encodedCounts: Data = row["insertedRowsJSON"]
        let insertedRows: HistoricalStreamInsertCounts
        do {
            insertedRows = try JSONDecoder().decode(HistoricalStreamInsertCounts.self, from: encodedCounts)
        } catch {
            throw HistoricalDataCommitJournalError.invalidReceipt
        }
        return HistoricalDataCommitReceipt(
            receiptId: row["receiptId"],
            generation: row["generation"],
            databaseInstanceId: row["databaseInstanceId"],
            deviceId: row["deviceId"],
            trim: row["trim"],
            chunkEndUnix: row["chunkEndUnix"],
            committedAt: row["committedAt"],
            rawBatchId: row["rawBatchId"],
            insertedRows: insertedRows
        )
    }
}
