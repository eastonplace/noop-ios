import Foundation
import GRDB

enum RRScoringFingerprint {
    /// Changes to provenance or quality affect scoring even when HR and R-R row
    /// counts do not move. Grouped aggregates are bounded to the full UTC hours used
    /// by RRReadPolicy; no raw beats cross the reader boundary.
    static let rrScoringFingerprintSQL = """
        SELECT source, COALESCE(tsSuspect, 0) AS quality,
               COUNT(*) AS c, MAX(ts) AS m, SUM(ts) AS timestamps,
               SUM(rrMs) AS intervals, SUM(seq) AS sequences,
               SUM(COALESCE(sourceOrdinal, -1)) AS ordinals
        FROM rrInterval
        WHERE deviceId = :d
          AND ts >= (:f / 3600) * 3600 AND ts < ((:t / 3600) + 1) * 3600
        GROUP BY source, COALESCE(tsSuspect, 0)
        ORDER BY source, quality
        """

    /// A change witness for the immutable-key raw store, not a cryptographic digest.
    /// Includes registry identity because it selects the family-specific read policy.
    /// Callers must bypass reuse if this read throws.
    static func read(db: Database, deviceId: String, from: Int, to: Int) throws -> String {
        let registry = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?",
                                       arguments: [deviceId])
        let model: String = registry?["model"] ?? ""
        let brand: String = registry?["brand"] ?? ""
        // Length prefixes keep registry strings unambiguous without relying on a delimiter ban.
        let family = try RRReadPolicy.scoringFamily(db: db, deviceId: deviceId)
        var parts = ["rr-v1", family.rawValue, "\(model.utf8.count):\(model)", "\(brand.utf8.count):\(brand)"]
        let rows = try Row.fetchAll(db, sql: Self.rrScoringFingerprintSQL,
                                   arguments: ["d": deviceId, "f": from, "t": to])
        for row in rows {
            let source: String = row["source"]
            let values: [Int64] = [row["quality"], row["c"], row["m"], row["timestamps"],
                                  row["intervals"], row["sequences"], row["ordinals"]]
            parts.append("\(source.utf8.count):\(source):" + values.map(String.init).joined(separator: ":"))
        }
        return parts.joined(separator: "|")
    }
}
