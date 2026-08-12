// Copy into Packages/WhoopStore/Sources/WhoopStore.
// Full-history navigation metadata is an indexed aggregate, not a reason to hydrate every DailyMetric row.

import Foundation
import GRDB
import NoopPhase34Core

public enum RepositoryHistoryExtentStoreError: Error {
    case invalidStoredDay(String)
}

extension WhoopStore {
    public func repositoryHistoryExtent(
        importedDeviceIds: [String],
        computedDeviceIds: [String],
        appleDeviceIds: [String]
    ) async throws -> RepositoryHistoryExtent {
        try syncRead { db in
            let imported = try Self.distinctDaySummary(
                table: "dailyMetric",
                deviceIds: importedDeviceIds,
                in: db
            )
            let computed = try Self.distinctDaySummary(
                table: "dailyMetric",
                deviceIds: computedDeviceIds,
                in: db
            )
            let apple = try Self.distinctDaySummary(
                table: "appleDaily",
                deviceIds: appleDeviceIds,
                in: db
            )
            let minimum = [imported.minimum, computed.minimum, apple.minimum].compactMap { $0 }.min()
            let maximum = [imported.maximum, computed.maximum, apple.maximum].compactMap { $0 }.max()
            return RepositoryHistoryExtent(
                earliestDay: try minimum.map(Self.decodeCivilDay),
                latestDay: try maximum.map(Self.decodeCivilDay),
                importedDayCount: imported.count,
                computedDayCount: computed.count,
                appleDayCount: apple.count
            )
        }
    }

    private struct DistinctDaySummary {
        let minimum: String?
        let maximum: String?
        let count: Int
    }

    private static func distinctDaySummary(
        table: String,
        deviceIds: [String],
        in db: Database
    ) throws -> DistinctDaySummary {
        guard !deviceIds.isEmpty else {
            return DistinctDaySummary(minimum: nil, maximum: nil, count: 0)
        }
        // Table names are internal constants; values remain bound arguments.
        let placeholders = Array(repeating: "?", count: deviceIds.count).joined(separator: ",")
        let row = try Row.fetchOne(db, sql: """
            SELECT MIN(day) AS minimumDay, MAX(day) AS maximumDay,
                   COUNT(DISTINCT day) AS dayCount
            FROM \(table)
            WHERE deviceId IN (\(placeholders))
            """, arguments: StatementArguments(deviceIds))
        return DistinctDaySummary(
            minimum: row?["minimumDay"],
            maximum: row?["maximumDay"],
            count: row?["dayCount"] ?? 0
        )
    }

    private static func decodeCivilDay(_ key: String) throws -> CivilDay {
        do { return try CivilDay(key: key) }
        catch { throw RepositoryHistoryExtentStoreError.invalidStoredDay(key) }
    }
}
