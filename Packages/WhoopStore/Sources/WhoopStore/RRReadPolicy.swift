import Foundation
import GRDB
import WhoopProtocol

/// Keep raw observations on disk and select one scoring train before applying LIMIT.
/// WHOOP 4 uses one transport per complete UTC hour; WHOOP 5 uses one verified
/// transport for the complete requested window. Other devices keep their existing policy.
/// WHOOP 4 SQL adapted from ryanbr/noop 3472cd10 (PolyForm Noncommercial 1.0.0).
public enum RRReadPolicy {
    public static func priority(for source: RRSource) -> Int {
        switch source {
        case .whoop5Historical: return 800
        case .whoop5Standard: return 700
        // The conflict winner must agree with the WHOOP 4 read preference.
        case .whoop4Historical: return 680
        case .whoop4Realtime: return 670
        case .whoop4Standard: return 650
        case .standardBLE: return 600
        case .whoop5Realtime: return 500
        case .ouraGreenQuality: return 400
        case .ouraAmplitude, .ouraBare: return 300
        case .legacy: return 100
        case .ouraSpO2: return 50
        }
    }

    public static func source(from raw: String?) -> RRSource {
        RRSource(rawValue: raw ?? "") ?? .legacy
    }

    /// The write-conflict expression is derived from the same priority table.
    static func sqlPriority(ofColumn column: String) -> String {
        let arms = RRSource.allCases
            .map { "WHEN '\($0.rawValue)' THEN \(priority(for: $0))" }
            .joined(separator: " ")
        return "(CASE \(column) \(arms) ELSE \(priority(for: .legacy)) END)"
    }

    static func strictWhoop5(model: String?, brand: String?, tagged: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.lowercased() != "whoop" { return false }
        switch model?.lowercased() {
        case "4.0", "whoop 4.0": return false
        case "5.0", "5.0 mg", "5.0 / mg", "whoop 5.0", "whoop 5.0 / mg", "whoop mg", "mg": return true
        default: return tagged
        }
    }

    static func strictWhoop4(model: String?, brand: String?, tagged: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.lowercased() != "whoop" { return false }
        switch model?.lowercased() {
        case "4.0", "whoop 4.0": return true
        case "5.0", "5.0 mg", "5.0 / mg", "whoop 5.0", "whoop 5.0 / mg", "whoop mg", "mg": return false
        default: return tagged
        }
    }

    // Materialize the small hourly choice once. A correlated count per beat is
    // quadratic on dense overnight windows. Choice includes the full boundary hours;
    // the outer query alone applies the caller's exact inclusive time bounds and cap.
    static let whoop4ScoringSQL = """
        WITH whoop4HourChoice AS MATERIALIZED (
            SELECT ts / 3600 AS hour,
                   MIN(CASE source WHEN 'whoop4_historical' THEN 1
                                   WHEN 'whoop4_realtime' THEN 2
                                   WHEN 'whoop4_standard_2a37' THEN 3
                                   WHEN 'legacy' THEN 4 END) AS sourceChoice
            FROM rrInterval
            WHERE deviceId = :d
              AND ts >= (:f / 3600) * 3600 AND ts < ((:t / 3600) + 1) * 3600
              AND (tsSuspect IS NULL OR tsSuspect <> 1)
              AND source IN ('whoop4_historical', 'whoop4_realtime', 'whoop4_standard_2a37', 'legacy')
            GROUP BY ts / 3600
        )
        SELECT r.ts, r.rrMs, r.source, r.sourceOrdinal FROM rrInterval r
        JOIN whoop4HourChoice h ON h.hour = r.ts / 3600
        WHERE r.deviceId = :d AND r.ts >= :f AND r.ts <= :t
          AND r.source IN ('whoop4_historical', 'whoop4_realtime', 'whoop4_standard_2a37', 'legacy')
          AND ((r.source = 'whoop4_historical' AND h.sourceChoice = 1)
               OR (r.source = 'whoop4_realtime' AND h.sourceChoice = 2)
               OR (r.source = 'whoop4_standard_2a37' AND h.sourceChoice = 3)
               OR (r.source = 'legacy' AND h.sourceChoice = 4))
          AND (r.tsSuspect IS NULL OR r.tsSuspect <> 1)
        ORDER BY r.ts, r.sourceOrdinal, r.rrMs, r.seq LIMIT :lim
        """

    static let whoop5ScoringSQL = """
        SELECT ts, rrMs, source, sourceOrdinal FROM rrInterval
        WHERE deviceId = :d AND ts >= :f AND ts <= :t
          AND (tsSuspect IS NULL OR tsSuspect <> 1)
          AND source = (SELECT source FROM rrInterval
              WHERE deviceId = :d AND ts >= :f AND ts <= :t
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                AND source IN ('whoop5_historical', 'whoop5_standard_2a37')
              ORDER BY CASE source WHEN 'whoop5_historical' THEN 0 ELSE 1 END LIMIT 1)
        ORDER BY ts, sourceOrdinal, rrMs, seq LIMIT :lim
        """

    static let otherScoringSQL = """
        SELECT ts, rrMs, source, sourceOrdinal FROM rrInterval
        WHERE deviceId = :d AND ts >= :f AND ts <= :t
          AND source <> 'oura_spo2'
        ORDER BY ts, sourceOrdinal, rrMs, seq LIMIT :lim
        """

    enum ScoringFamily: String { case whoop4, whoop5, other }

    /// Shared with cache witnesses: an unknown owner's first verified tag may arrive
    /// outside the scoring window and still change how its existing rows are read.
    static func scoringFamily(db: Database, deviceId: String) throws -> ScoringFamily {
        let registry = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?", arguments: [deviceId])
        let model: String? = registry?["model"]
        let brand: String? = registry?["brand"]
        var whoop5 = strictWhoop5(model: model, brand: brand, tagged: false)
        var whoop4 = strictWhoop4(model: model, brand: brand, tagged: false)
        // Only unknown identity may use wire evidence. A known WHOOP 4 or another
        // brand must never be reclassified by a stray imported WHOOP 5 row.
        if !whoop5, !whoop4, strictWhoop5(model: model, brand: brand, tagged: true) {
            whoop5 = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ?
                  AND source IN ('whoop5_historical', 'whoop5_standard_2a37', 'whoop5_realtime'))
                """, arguments: [deviceId]) ?? false
            if !whoop5 {
                whoop4 = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ?
                      AND source IN ('whoop4_historical', 'whoop4_standard_2a37', 'whoop4_realtime'))
                    """, arguments: [deviceId]) ?? false
            }
        }
        return whoop5 ? .whoop5 : (whoop4 ? .whoop4 : .other)
    }

    /// Both ordinary reads and the analysis snapshot call this exact policy.
    static func read(db: Database, deviceId: String, from: Int, to: Int, limit: Int) throws -> [RRInterval] {
        guard limit > 0, from <= to else { return [] }
        let family = try scoringFamily(db: db, deviceId: deviceId)
        let sql: String
        switch family {
        case .whoop4: sql = whoop4ScoringSQL
        case .whoop5: sql = whoop5ScoringSQL
        case .other: sql = otherScoringSQL
        }
        return try Row.fetchAll(db, sql: sql,
                               arguments: ["d": deviceId, "f": from, "t": to, "lim": limit]).map { row in
            RRInterval(ts: row["ts"], rrMs: row["rrMs"], sourceOrdinal: row["sourceOrdinal"], source: source(from: row["source"]))
        }
    }
}
