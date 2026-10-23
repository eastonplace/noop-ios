import Foundation
import GRDB

extension WhoopStore {
    /// Merge measurements from an explicit file fragment. Missing values do not assert deletion;
    /// observed zero replaces a previous value. Keep computed scores and all other sources/days.
    /// Authoritative analysis continues to use `upsertDailyMetrics`, whose replacement contract is unchanged.
    @discardableResult
    public func mergeImportedDailyMetrics(_ days: [DailyMetric], deviceId: String) async throws -> Int {
        guard !deviceId.isEmpty,
              deviceId == deviceId.trimmingCharacters(in: .whitespacesAndNewlines),
              days.allSatisfy({ Self.isImportedMetricDay($0.day) }) else {
            throw ImportedDailyMetricMergeError.invalidScope
        }
        return try syncWrite { db in
            let columns = ["totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin",
                           "disturbances", "restingHr", "avgHrv", "exerciseCount", "spo2Pct",
                           "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir"]
            let names = (["deviceId", "day"] + columns).joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: columns.count + 2).joined(separator: ", ")
            let updates = columns.map {
                "\($0) = COALESCE(excluded.\($0), dailyMetric.\($0))"
            }.joined(separator: ", ")
            let changed = columns.map {
                "dailyMetric.\($0) IS NOT COALESCE(excluded.\($0), dailyMetric.\($0))"
            }.joined(separator: " OR ")
            let statement = try db.cachedStatement(sql: """
                INSERT INTO dailyMetric (\(names)) VALUES (\(placeholders))
                ON CONFLICT(deviceId, day) DO UPDATE SET \(updates) WHERE \(changed)
                """)
            var written = 0
            for row in days {
                try statement.execute(arguments: [deviceId, row.day, row.totalSleepMin, row.efficiency,
                    row.deepMin, row.remMin, row.lightMin, row.disturbances, row.restingHr, row.avgHrv,
                    row.exerciseCount, row.spo2Pct, row.skinTempDevC, row.respRateBpm, row.steps,
                    row.activeKcalEst, row.spo2Red, row.spo2Ir])
                written += db.changesCount
            }
            return written
        }
    }

    private static func isImportedMetricDay(_ day: String) -> Bool {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(bytes[$0]) }),
              let year = Int(day.prefix(4)), year > 0,
              let month = Int(day.dropFirst(5).prefix(2)),
              let dayOfMonth = Int(day.suffix(2)) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else {
            return false
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == dayOfMonth
    }
}

private enum ImportedDailyMetricMergeError: Error { case invalidScope }
