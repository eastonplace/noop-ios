import Foundation
import GRDB

// MARK: - v9 cache: generic long-format metric store
// The substrate for a metric explorer. Where MetricsCache / JournalWorkoutAppleCache use a
// WIDE column-per-metric layout (one table per source, typed nullable columns), this is the
// TALL/EAV counterpart: one row per (deviceId, day, key) with a single REAL `value`. Any scalar
// metric — whatever its origin — can be projected into this one table and read back uniformly by
// key, so the explorer can list/compare metrics without knowing each source's schema.
// Mirrors the established pattern exactly: Codable struct, idempotent ON CONFLICT upsert keyed by
// natural key, range-read accessors, all GRDB work via the actor's syncWrite/syncRead helpers.

/// One point in the long-format metric store. Natural key (deviceId, day, key).
public struct MetricPoint: Equatable, Codable, Sendable {
    public let day: String           // YYYY-MM-DD
    public let key: String           // metric identifier, e.g. "restingHr", "steps", "recovery"
    public let value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

extension WhoopStore {

    // MARK: - Upsert (idempotent by natural key; latest value wins on conflict)

    /// Upsert metric points. Natural key (deviceId, day, key). Returns rows changed.
    /// Idempotent: re-upserting the same (deviceId, day, key) updates `value` in place rather than
    /// creating a duplicate.
    @discardableResult
    public func upsertMetricSeries(_ rows: [MetricPoint], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO metricSeries
                        (deviceId, day, key, value)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO UPDATE SET
                        value = excluded.value
                    WHERE metricSeries.value IS NOT excluded.value
                    """, arguments: [deviceId, r.day, r.key, r.value])
                n += db.changesCount
            }
            return n
        }
    }

    /// Reconcile the complete set of `keys` in an inclusive day range. Existing rows absent from
    /// `rows` are deleted, unrelated keys and devices are untouched, and the operation is atomic.
    /// This is the metric-series equivalent of `reconcileDailyMetrics` and prevents derived shadow
    /// values from surviving after their raw inputs become invalid.
    @discardableResult
    public func reconcileMetricSeries(
        _ rows: [MetricPoint],
        deviceId: String,
        keys: [String],
        from: String,
        to: String
    ) async throws -> Int {
        let scopedKeys = Set(keys)
        guard !scopedKeys.isEmpty,
              isCanonicalMetricDay(from), isCanonicalMetricDay(to),
              from <= to else {
            throw MetricSeriesReconciliationError.invalidScope
        }
        var identities = Set<String>()
        for row in rows {
            guard scopedKeys.contains(row.key), isCanonicalMetricDay(row.day),
                  row.day >= from, row.day <= to,
                  row.value.isFinite,
                  identities.insert("\(row.key)\u{0}\(row.day)").inserted else {
                throw MetricSeriesReconciliationError.rowOutsideScope
            }
        }

        let desiredByKey = Dictionary(grouping: rows, by: \.key)
        return try syncWrite { db in
            var changed = 0
            for key in scopedKeys.sorted() {
                let desired = desiredByKey[key] ?? []
                let desiredDays = desired.map(\.day).sorted()
                if desiredDays.isEmpty {
                    try db.execute(sql: """
                        DELETE FROM metricSeries
                        WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                        """, arguments: [deviceId, key, from, to])
                } else {
                    let placeholders = Array(repeating: "?", count: desiredDays.count)
                        .joined(separator: ",")
                    try db.execute(sql: """
                        DELETE FROM metricSeries
                        WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                          AND day NOT IN (\(placeholders))
                        """, arguments: StatementArguments(
                            [deviceId, key, from, to] + desiredDays
                        ))
                }
                changed += db.changesCount
                for row in desired {
                    try db.execute(sql: """
                        INSERT INTO metricSeries (deviceId, day, key, value)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(deviceId, day, key) DO UPDATE SET value = excluded.value
                        WHERE metricSeries.value IS NOT excluded.value
                        """, arguments: [deviceId, row.day, row.key, row.value])
                    changed += db.changesCount
                }
            }
            return changed
        }
    }

    /// Delete every row for the supplied metric keys across all device namespaces in one transaction.
    /// Use this for privacy revocation, where stale or unregistered device ids must not retain data.
    @discardableResult
    public func deleteMetricSeriesGlobally(keys: [String]) async throws -> Int {
        let scopedKeys = Set(keys)
        guard !scopedKeys.isEmpty else {
            throw MetricSeriesReconciliationError.invalidScope
        }
        return try syncWrite { db in
            let orderedKeys = scopedKeys.sorted()
            let placeholders = Array(repeating: "?", count: orderedKeys.count)
                .joined(separator: ",")
            try db.execute(
                sql: "DELETE FROM metricSeries WHERE key IN (\(placeholders))",
                arguments: StatementArguments(orderedKeys)
            )
            return db.changesCount
        }
    }

    /// Delete rows for the supplied metric keys on exact civil days across all device namespaces.
    /// Sleep-boundary edits use this conservative invalidation because a restored or re-paired database
    /// can retain the derived observation under a namespace that is no longer in the active read set.
    @discardableResult
    public func deleteMetricSeriesGlobally(keys: [String], onDays days: [String]) async throws -> Int {
        let scopedKeys = Set(keys)
        let scopedDays = Set(days)
        guard !scopedKeys.isEmpty, !scopedDays.isEmpty,
              scopedDays.allSatisfy(isCanonicalMetricDay) else {
            throw MetricSeriesReconciliationError.invalidScope
        }
        return try syncWrite { db in
            let orderedKeys = scopedKeys.sorted()
            let orderedDays = scopedDays.sorted()
            let keyPlaceholders = Array(repeating: "?", count: orderedKeys.count)
                .joined(separator: ",")
            let dayPlaceholders = Array(repeating: "?", count: orderedDays.count)
                .joined(separator: ",")
            try db.execute(
                sql: """
                    DELETE FROM metricSeries
                    WHERE key IN (\(keyPlaceholders)) AND day IN (\(dayPlaceholders))
                    """,
                arguments: StatementArguments(orderedKeys + orderedDays)
            )
            return db.changesCount
        }
    }

    // MARK: - Reads

    /// Points for a single `key` on days in [from, to] (lexicographic YYYY-MM-DD compare),
    /// oldest day first. Served index-only by idx_metricSeries_device_key_day.
    public func metricSeries(deviceId: String, key: String, from: String, to: String) async throws -> [MetricPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, key, value FROM metricSeries
                WHERE deviceId = ? AND key = ? AND day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, key, from, to])
                .map { MetricPoint(day: $0["day"], key: $0["key"], value: $0["value"]) }
        }
    }

    /// Distinct metric keys present for a device, sorted ascending.
    public func metricKeys(deviceId: String) async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT key FROM metricSeries
                WHERE deviceId = ?
                ORDER BY key ASC
                """, arguments: [deviceId])
        }
    }

    /// Earliest and latest day for a given metric `key`, or nil if the key has no points.
    public func metricDays(deviceId: String, key: String) async throws -> (earliest: String, latest: String)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT MIN(day) AS earliest, MAX(day) AS latest FROM metricSeries
                WHERE deviceId = ? AND key = ?
                """, arguments: [deviceId, key]),
                let earliest: String = row["earliest"],
                let latest: String = row["latest"]
            else { return nil }
            return (earliest, latest)
        }
    }
}

private enum MetricSeriesReconciliationError: Error {
    case invalidScope
    case rowOutsideScope
}

/// Strict Gregorian `yyyy-MM-dd` validation before a destructive range is compared lexically.
private func isCanonicalMetricDay(_ day: String) -> Bool {
    let bytes = Array(day.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
    let positions = [0, 1, 2, 3, 5, 6, 8, 9]
    guard positions.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }
    let year = Int(bytes[0] - 48) * 1_000 + Int(bytes[1] - 48) * 100
        + Int(bytes[2] - 48) * 10 + Int(bytes[3] - 48)
    let month = Int(bytes[5] - 48) * 10 + Int(bytes[6] - 48)
    let dayOfMonth = Int(bytes[8] - 48) * 10 + Int(bytes[9] - 48)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: DateComponents(
        calendar: calendar, year: year, month: month, day: dayOfMonth
    )) else { return false }
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return components.year == year && components.month == month && components.day == dayOfMonth
}
