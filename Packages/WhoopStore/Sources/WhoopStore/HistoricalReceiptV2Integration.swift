// Repository integration for HistoricalDataCommitJournal.swift and Backfiller.swift.
// Replace v1 replay identity and UTC touched-day authority with this contract.

import CryptoKit
import Foundation
import NoopPhase34Core
import WhoopProtocol

extension WhoopStore {
    public static func historicalReceivedFrameFingerprintV2(
        orderedFrames: [[UInt8]],
        protocolMetadata: Data,
        historyEndFrame: Data,
        scope: HistoricalCursorScope,
        trim: Int
    ) throws -> String {
        guard (0...Int(UInt32.max)).contains(trim) else {
            throw HistoricalDataCommitJournalError.invalidTrim
        }
        let payload = try HistoricalFingerprintV2Payload(
            deviceLineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope,
            trim: UInt32(trim),
            orderedFrames: orderedFrames.map { Data($0) },
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame
        )
        return SHA256.hash(data: try payload.canonicalData())
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Range evidence is compressed by UTC bucket only. The recorded local time zone later maps each sample
    /// bucket to civil and physiological days. Empty/console-only chunks have no decoded timestamp bucket.
    public static func historicalTimestampBuckets(for streams: Streams) throws -> [HistoricalTimestampBucket] {
        try HistoricalTimestampBucketBuilder.buckets(from: phase34DecodedTimestamps(streams))
    }

    private static func phase34DecodedTimestamps(_ streams: Streams) -> [Int] {
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

    public static func historicalReceiptRequiresAnalysis(
        decodedRows: HistoricalStreamInsertCounts,
        explicitAffectedDays: [String],
        timestampHeal: HistoricalTimestampHeal
    ) -> Bool {
        // Insert counts and raw-range metadata do not own this decision. An exact replay can insert zero rows,
        // while a console-only chunk can carry a raw range without any scoreable physiological row.
        let storageHealChanged = timestampHeal.rawRowsDeleted > 0
            || timestampHeal.computedRowsDeleted > 0
            || (timestampHeal.didChange && timestampHeal.droppedRecordCount == 0)
        return decodedRows.total > 0
            || !explicitAffectedDays.isEmpty
            || storageHealChanged
    }
}

/*
Required `HistoricalDataCommitReceipt` fields:

    public let fingerprintVersion: Int             // 2 for new immutable-byte receipts
    public let timestampBuckets: [HistoricalTimestampBucket]
    public let recordedTimeZoneIdentifier: String
    public let explicitAffectedDays: [String]      // local Gregorian keys from an exact repair/edit owner

Rules:

- Do not use the existing `touchedDays` field as local day authority. At the audited Phase 2 head it is derived
  in UTC. Keep it only for legacy diagnostics or remove it after migration.
- A timestamp heal that deleted stored raw/computed rows must return exact local affected days. If that
  storage repair cannot prove them, create one low-priority `fullHistoryRepair` work item. Decoder-only
  `droppedRecordCount` is diagnostic and does not by itself create analysis work.
- `timestampBuckets` alone do not create work. Decoded rows, explicit days, or explicit heal duty do.
- Record `TimeZone.current.identifier` with the receipt in the same transaction. It is evidence, not replay
  identity. Travel can therefore split later work by recorded zone without changing idempotency.

Required commit ordering:

    1. Resolve HistoricalCursorScope inside the SQLite transaction.
    2. Build fingerprint v2 from exact immutable bytes and the resolved scope.
    3. Insert decoded rows.
    4. Persist optional raw capture.
    5. Persist receipt with decoded counts, timestamp buckets, recorded zone, and explicit affected days.
    6. Advance the scoped cursor using the inserted receipt generation.
    7. Commit.
    8. Publish only a durable receipt-generation watermark.
    9. Send trim ACK.

ACK is intentionally after the raw/cursor/receipt transaction. It must not wait for scoring, Repository, widget,
or HealthKit. Those later stages are crash-resumable from the durable receipt.

Fingerprint v2 excludes min/max decoded timestamps, receive-time range, capture preference, commit wall time,
parser output, recorded time zone, and repaired clock mapping. Those fields are evidence only.
*/
