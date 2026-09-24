import Foundation
import GRDB
import WhoopProtocol

/// Select one verified WHOOP 5 transport for the complete scoring window. Keep raw
/// observations on disk, but never splice mixed-unit legacy or duplicate type-40 beats
/// into that train. Oura's red SpO2 beat train is diagnostic, not an extra heartbeat.
public enum RRReadPolicy {
    public static func priority(for source: RRSource) -> Int {
        switch source {
        case .whoop5Historical: return 800
        case .whoop5Standard: return 700
        case .whoop4Standard: return 650
        case .standardBLE: return 600
        case .whoop5Realtime: return 500
        case .whoop4Realtime: return 450
        case .ouraGreenQuality: return 400
        case .whoop4Historical: return 350
        case .ouraAmplitude, .ouraBare: return 300
        case .legacy: return 100
        case .ouraSpO2: return 50
        }
    }

    public static func source(from raw: String?) -> RRSource {
        RRSource(rawValue: raw ?? "") ?? .legacy
    }

    static func strictWhoop5(model: String?, brand: String?, tagged: Bool) -> Bool {
        if let brand, !brand.isEmpty, brand.lowercased() != "whoop" { return false }
        switch model?.lowercased() {
        case "4.0", "whoop 4.0": return false
        case "5.0", "5.0 mg", "5.0 / mg", "whoop 5.0", "whoop 5.0 / mg", "whoop mg", "mg": return true
        default: return tagged
        }
    }

    /// Both ordinary reads and the analysis snapshot use this exact query. Filtering
    /// happens before LIMIT, so redundant channels cannot consume the caller's cap.
    static func read(db: Database, deviceId: String, from: Int, to: Int, limit: Int) throws -> [RRInterval] {
        guard limit > 0 else { return [] }
        let registry = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?", arguments: [deviceId])
        let model: String? = registry?["model"]
        let brand: String? = registry?["brand"]
        let confirmed = strictWhoop5(model: model, brand: brand, tagged: false)
        let permitsWireEvidence = strictWhoop5(model: model, brand: brand, tagged: true)
        let tagged = !confirmed && permitsWireEvidence ? (try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ?
              AND source IN ('whoop5_historical', 'whoop5_standard_2a37', 'whoop5_realtime'))
            """, arguments: [deviceId]) ?? false) : false
        let strict = confirmed || tagged
        let predicate = strict ? """
            source = (SELECT source FROM rrInterval
              WHERE deviceId = :d AND ts >= :f AND ts <= :t
                AND source IN ('whoop5_historical', 'whoop5_standard_2a37')
              ORDER BY CASE source WHEN 'whoop5_historical' THEN 0 ELSE 1 END LIMIT 1)
            """ : "1"
        return try Row.fetchAll(db, sql: """
            SELECT ts, rrMs, source, sourceOrdinal FROM rrInterval
            WHERE deviceId = :d AND ts >= :f AND ts <= :t
              AND source <> 'oura_spo2' AND \(predicate)
            ORDER BY ts, sourceOrdinal, rrMs, seq LIMIT :lim
            """, arguments: ["d": deviceId, "f": from, "t": to, "lim": limit]).map { row in
                RRInterval(ts: row["ts"], rrMs: row["rrMs"], sourceOrdinal: row["sourceOrdinal"], source: source(from: row["source"]))
            }
    }
}
