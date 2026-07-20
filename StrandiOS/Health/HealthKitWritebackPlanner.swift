#if os(iOS)
import Foundation
import WhoopProtocol
import WhoopStore

/// Pure, throwing read planner for NOOP → HealthKit writeback. It mirrors Repository's active-first
/// identity union so a re-paired strap is never hidden behind the canonical `my-whoop` namespace.
enum HealthKitWritebackPlanner {
    struct SourcedHRBucket: Equatable {
        let sourceId: String
        let bucket: HRBucket
    }

    static func sleepSessions(
        store: WhoopStore,
        importedIds: [String],
        computedIds: [String],
        from: Int,
        to: Int,
        limit: Int = 200
    ) async throws -> [CachedSleepSession] {
        var merged: [Int: CachedSleepSession] = [:]
        for id in computedIds {
            for row in try await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)
            where merged[row.startTs] == nil {
                merged[row.startTs] = row
            }
        }
        var imported: [Int: CachedSleepSession] = [:]
        for id in importedIds {
            for row in try await store.sleepSessions(deviceId: id, from: from, to: to, limit: limit)
            where imported[row.startTs] == nil {
                imported[row.startTs] = row
            }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    static func dailyMetrics(
        store: WhoopStore,
        importedIds: [String],
        computedIds: [String],
        from: String,
        to: String
    ) async throws -> [DailyMetric] {
        var merged: [String: DailyMetric] = [:]
        for id in computedIds {
            for row in try await store.dailyMetrics(deviceId: id, from: from, to: to)
            where merged[row.day] == nil {
                merged[row.day] = row
            }
        }
        var imported: [String: DailyMetric] = [:]
        for id in importedIds {
            for row in try await store.dailyMetrics(deviceId: id, from: from, to: to)
            where imported[row.day] == nil {
                imported[row.day] = row
            }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.keys.sorted().compactMap { merged[$0] }
    }

    static func heartRateBuckets(
        store: WhoopStore,
        importedIds: [String],
        fromById: [String: Int],
        to: Int,
        bucketSeconds: Int = 60
    ) async throws -> [SourcedHRBucket] {
        var byTimestamp: [Int: SourcedHRBucket] = [:]
        for id in importedIds {
            let from = fromById[id] ?? 0
            for bucket in try await store.hrBuckets(
                deviceId: id, from: from, to: to, bucketSeconds: bucketSeconds
            ) where byTimestamp[bucket.ts] == nil {
                byTimestamp[bucket.ts] = SourcedHRBucket(sourceId: id, bucket: bucket)
            }
        }
        return byTimestamp.keys.sorted().compactMap { byTimestamp[$0] }
    }

    static func workouts(
        store: WhoopStore,
        importedIds: [String],
        computedIds: [String],
        from: Int,
        to: Int,
        limit: Int = 500,
        excludingSource: String
    ) async throws -> [WorkoutRow] {
        func naturalKey(_ row: WorkoutRow) -> String { "\(row.startTs):\(row.sport)" }

        var merged: [String: WorkoutRow] = [:]
        for id in computedIds {
            for row in try await store.workouts(deviceId: id, from: from, to: to, limit: limit)
            where row.source != excludingSource && merged[naturalKey(row)] == nil {
                merged[naturalKey(row)] = row
            }
        }
        var imported: [String: WorkoutRow] = [:]
        for id in importedIds {
            for row in try await store.workouts(deviceId: id, from: from, to: to, limit: limit)
            where row.source != excludingSource && imported[naturalKey(row)] == nil {
                imported[naturalKey(row)] = row
            }
        }
        for (key, row) in imported { merged[key] = row }
        return merged.values.sorted {
            $0.startTs == $1.startTs ? $0.sport < $1.sport : $0.startTs < $1.startTs
        }
    }
}
#endif
