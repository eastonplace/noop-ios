import Foundation
import GRDB

/// Actual anchored external-deletion evidence, retained with the sync journal. A hidden/empty read
/// is not deletion evidence. Scope is a sample type and the affected civil days/object timestamps.
public struct HealthKitProjectionDeletion: Codable, Equatable, Hashable, Sendable {
    public let sampleType: String
    public let fromDay: String
    public let toDay: String
    public let fromTimestamp: Int
    public let toTimestamp: Int

    public init(sampleType: String, fromDay: String, toDay: String,
                fromTimestamp: Int, toTimestamp: Int) {
        self.sampleType = sampleType
        self.fromDay = fromDay
        self.toDay = toDay
        self.fromTimestamp = fromTimestamp
        self.toTimestamp = toTimestamp
    }

    public func permitsMissingValue(key: String, day: String) -> Bool {
        day >= fromDay && day <= toDay && Self.metricKeys(for: sampleType).contains(key)
    }

    public static func metricKeys(for sampleType: String) -> Set<String> {
        switch sampleType {
        case "HKQuantityTypeIdentifierRestingHeartRate": return ["resting_hr"]
        case "HKQuantityTypeIdentifierHeartRate": return ["avg_hr", "max_hr"]
        case "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": return ["hrv"]
        case "HKQuantityTypeIdentifierOxygenSaturation": return ["spo2"]
        case "HKQuantityTypeIdentifierRespiratoryRate": return ["resp_rate"]
        case "HKQuantityTypeIdentifierStepCount": return ["steps"]
        case "HKQuantityTypeIdentifierActiveEnergyBurned": return ["active_kcal"]
        case "HKQuantityTypeIdentifierBasalEnergyBurned": return ["basal_kcal"]
        case "HKQuantityTypeIdentifierVO2Max": return ["vo2max"]
        case "HKQuantityTypeIdentifierBodyMass": return ["weight"]
        case "HKQuantityTypeIdentifierBodyFatPercentage": return ["body_fat"]
        case "HKQuantityTypeIdentifierLeanBodyMass": return ["lean_mass"]
        case "HKQuantityTypeIdentifierBodyMassIndex": return ["bmi"]
        case "HKCategoryTypeIdentifierSleepAnalysis":
            return ["asleep_min", "deep_min", "rem_min", "core_min", "awake_min", "in_bed_min"]
        default: return []
        }
    }
}

extension WhoopStore {
    /// Runs inside the same replacement transaction. Nil fields and absent metric points retain
    /// their old value unless a matching anchored deletion authorizes retraction. Present reads
    /// always replace the prior value, including a genuine numeric zero.
    static func preserveUnprovenHealthKitProjections(
        appleDaily: [AppleDaily], dailyMetrics: [DailyMetric], metricPoints: [MetricPoint],
        deviceId: String, fromDay: String, toDay: String,
        deletions: [HealthKitProjectionDeletion], db: Database
    ) throws -> (apple: [AppleDaily], daily: [DailyMetric], points: [MetricPoint]) {
        func oldRows(_ table: String) throws -> [String: Row] {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE deviceId = ? AND day >= ? AND day <= ?",
                arguments: [deviceId, fromDay, toDay])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["day"] as String, $0) })
        }
        func keep<T: DatabaseValueConvertible>(_ value: T?, old: Row?, column: String,
                                                key: String, day: String) -> T? {
            if let value { return value }
            if deletions.contains(where: { $0.permitsMissingValue(key: key, day: day) }) { return nil }
            return old.flatMap { $0[column] as T? }
        }
        let oldApple = try oldRows("appleDaily")
        let newApple = Dictionary(uniqueKeysWithValues: appleDaily.map { ($0.day, $0) })
        let apple = Set(oldApple.keys).union(newApple.keys).sorted().map { day in
            let n = newApple[day], old = oldApple[day]
            return AppleDaily(day: day,
                steps: keep(n?.steps, old: old, column: "steps", key: "steps", day: day),
                activeKcal: keep(n?.activeKcal, old: old, column: "activeKcal", key: "active_kcal", day: day),
                basalKcal: keep(n?.basalKcal, old: old, column: "basalKcal", key: "basal_kcal", day: day),
                vo2max: keep(n?.vo2max, old: old, column: "vo2max", key: "vo2max", day: day),
                avgHr: keep(n?.avgHr, old: old, column: "avgHr", key: "avg_hr", day: day),
                maxHr: keep(n?.maxHr, old: old, column: "maxHr", key: "max_hr", day: day),
                walkingHr: keep(n?.walkingHr, old: old, column: "walkingHr", key: "walking_hr", day: day),
                weightKg: keep(n?.weightKg, old: old, column: "weightKg", key: "weight", day: day))
        }
        let oldDaily = try oldRows("dailyMetric")
        let newDaily = Dictionary(uniqueKeysWithValues: dailyMetrics.map { ($0.day, $0) })
        let daily = Set(oldDaily.keys).union(newDaily.keys).sorted().map { day in
            let n = newDaily[day], old = oldDaily[day]
            return DailyMetric(day: day,
                totalSleepMin: keep(n?.totalSleepMin, old: old, column: "totalSleepMin", key: "asleep_min", day: day),
                efficiency: keep(n?.efficiency, old: old, column: "efficiency", key: "efficiency", day: day),
                deepMin: keep(n?.deepMin, old: old, column: "deepMin", key: "deep_min", day: day),
                remMin: keep(n?.remMin, old: old, column: "remMin", key: "rem_min", day: day),
                lightMin: keep(n?.lightMin, old: old, column: "lightMin", key: "core_min", day: day),
                disturbances: keep(n?.disturbances, old: old, column: "disturbances", key: "disturbances", day: day),
                restingHr: keep(n?.restingHr, old: old, column: "restingHr", key: "resting_hr", day: day),
                avgHrv: keep(n?.avgHrv, old: old, column: "avgHrv", key: "hrv", day: day),
                recovery: keep(n?.recovery, old: old, column: "recovery", key: "recovery", day: day),
                strain: keep(n?.strain, old: old, column: "strain", key: "strain", day: day),
                exerciseCount: keep(n?.exerciseCount, old: old, column: "exerciseCount", key: "exercise_count", day: day),
                spo2Pct: keep(n?.spo2Pct, old: old, column: "spo2Pct", key: "spo2", day: day),
                skinTempDevC: keep(n?.skinTempDevC, old: old, column: "skinTempDevC", key: "skin_temp_dev", day: day),
                respRateBpm: keep(n?.respRateBpm, old: old, column: "respRateBpm", key: "resp_rate", day: day),
                steps: keep(n?.steps, old: old, column: "steps", key: "steps", day: day),
                activeKcalEst: keep(n?.activeKcalEst, old: old, column: "activeKcalEst", key: "active_kcal_est", day: day),
                spo2Red: keep(n?.spo2Red, old: old, column: "spo2Red", key: "spo2_red", day: day),
                spo2Ir: keep(n?.spo2Ir, old: old, column: "spo2Ir", key: "spo2_ir", day: day),
                strainVersion: keep(n?.strainVersion, old: old, column: "strainVersion", key: "strain_version", day: day))
        }
        let pointIdentity = Set(metricPoints.map { $0.day + "\u{0}" + $0.key })
        let previous = try Row.fetchAll(db, sql: "SELECT day, key, value FROM metricSeries WHERE deviceId = ? AND day >= ? AND day <= ?",
            arguments: [deviceId, fromDay, toDay])
        var points = metricPoints
        for row in previous {
            let day: String = row["day"], key: String = row["key"]
            guard !pointIdentity.contains(day + "\u{0}" + key),
                  !deletions.contains(where: { $0.permitsMissingValue(key: key, day: day) }) else { continue }
            points.append(MetricPoint(day: day, key: key, value: row["value"]))
        }
        return (apple, daily, points)
    }
}
