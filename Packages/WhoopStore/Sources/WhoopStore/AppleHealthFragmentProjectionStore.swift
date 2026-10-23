import Foundation
import GRDB

extension WhoopStore {
    /// Merge only days and fields present in an explicit XML import. A fragment cannot establish that
    /// a missing metric is empty. Preserve existing values, accept visible numeric zero, and leave
    /// unrelated daily fields/sources untouched. Both projections commit in one transaction.
    public func mergeAppleHealthImportProjections(
        appleDaily: [AppleDaily], dailyMetrics: [DailyMetric], deviceId: String
    ) async throws -> (appleWritten: Int, dailyWritten: Int) {
        try syncWrite { db in
            // Table/column names are fixed below; all source/day/value inputs are bound parameters.
            func statement(table: String, columns: [String]) throws -> Statement {
                let names = (["deviceId", "day"] + columns).joined(separator: ", ")
                let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
                let updates = columns.map {
                    "\($0) = COALESCE(excluded.\($0), \(table).\($0))"
                }.joined(separator: ", ")
                let changed = columns.map {
                    "\(table).\($0) IS NOT COALESCE(excluded.\($0), \(table).\($0))"
                }.joined(separator: " OR ")
                return try db.cachedStatement(sql: """
                    INSERT INTO \(table) (\(names)) VALUES (\(placeholders))
                    ON CONFLICT(deviceId, day) DO UPDATE SET \(updates) WHERE \(changed)
                    """)
            }
            let apple = try statement(table: "appleDaily", columns: [
                "steps", "activeKcal", "basalKcal", "vo2max", "avgHr", "maxHr", "walkingHr", "weightKg"
            ])
            let daily = try statement(table: "dailyMetric", columns: [
                "totalSleepMin", "deepMin", "remMin", "lightMin", "restingHr", "avgHrv",
                "spo2Pct", "respRateBpm", "steps"
            ])
            var appleWritten = 0, dailyWritten = 0
            for row in appleDaily {
                try apple.execute(arguments: [deviceId, row.day, row.steps, row.activeKcal, row.basalKcal,
                    row.vo2max, row.avgHr, row.maxHr, row.walkingHr, row.weightKg])
                appleWritten += db.changesCount
            }
            for row in dailyMetrics {
                try daily.execute(arguments: [deviceId, row.day, row.totalSleepMin, row.deepMin, row.remMin,
                    row.lightMin, row.restingHr, row.avgHrv, row.spo2Pct, row.respRateBpm, row.steps])
                dailyWritten += db.changesCount
            }
            return (appleWritten, dailyWritten)
        }
    }
}
