import GRDB
import WhoopProtocol

/// Forward-only annotation of existing R-R rows. The target's natural key, raw values,
/// receipts, and durable historical transaction remain unchanged.
/// Adapted from ryanbr/noop 2d0b01d8 (PolyForm Noncommercial 1.0.0).
public enum RRQualityMigration {
    public static let identifier = "v60-rr-quality-policy"

    static let whoop4LegacyChannelsSQL = """
        UPDATE rrInterval SET source = CASE srcChannel
          WHEN 8 THEN 'whoop4_historical'
          WHEN 9 THEN 'whoop4_realtime'
          WHEN 10 THEN 'whoop4_standard_2a37' END
        WHERE source = 'legacy' AND srcChannel IN (8, 9, 10)
        """

    /// Exact upstream evidence rule, adapted to the target's named source column.
    /// NULL means no rejection evidence. Existing quality annotations are never overwritten.
    static let whoop5RrFillFlagSQL = """
        UPDATE rrInterval SET tsSuspect = 1
        WHERE deviceId = :deviceId AND ts >= :fromTs AND ts <= :toTs
          AND rrMs = 500 AND source IN ('whoop5_historical', 'whoop5_standard_2a37')
          AND tsSuspect IS NULL
          AND EXISTS (SELECT 1 FROM hrSample h
                      WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)
        """

    static let whoop5RrFillMigrationSQL = """
        UPDATE rrInterval SET tsSuspect = 1
        WHERE rrMs = 500 AND source IN ('whoop5_historical', 'whoop5_standard_2a37')
          AND tsSuspect IS NULL
          AND EXISTS (SELECT 1 FROM hrSample h
                      WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)
        """

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            let columns = try Set(db.columns(in: "rrInterval").map(\.name))
            if !columns.contains("tsSuspect") {
                try db.alter(table: "rrInterval") { t in
                    t.add(column: "tsSuspect", .integer)
                }
            }
            // v57 already ran on existing installs. Translate the additional upstream
            // channels here without changing that old migration or guessing legacy provenance.
            if columns.contains("srcChannel") {
                try db.execute(sql: whoop4LegacyChannelsSQL)
            }
            try db.execute(sql: whoop5RrFillMigrationSQL)
        }
    }

    /// Runs inside the shared decoded-stream transaction, after both HR and R-R writes.
    /// HR-only batches matter: the corroborating HR second can arrive after its R-R beat.
    static func markKnownFill(in db: Database, streams: Streams, deviceId: String) throws {
        var first: Int?
        var last: Int?
        func include(_ ts: Int) {
            first = min(first ?? ts, ts)
            last = max(last ?? ts, ts)
        }
        for rr in streams.rr where rr.rrMs == 500
            && (rr.source == .whoop5Historical || rr.source == .whoop5Standard) {
            include(rr.ts)
        }
        for hr in streams.hr where hr.bpm < 100 { include(hr.ts) }
        guard let first, let last else { return }
        try db.execute(sql: whoop5RrFillFlagSQL,
                       arguments: ["deviceId": deviceId, "fromTs": first, "toTs": last])
    }
}
