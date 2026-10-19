import Foundation
import GRDB

// MARK: - Strength Strain storage (v59-lift-strain)
//
// The app computes a muscular load from the logged sets (StrandAnalytics `StrengthStrain`, which this package
// must not depend on, so the combine is injected). This file stores those loads and applies them, as ONE new
// step, on top of the heart-rate-only Strain every other writer keeps producing:
//
//   * `liftStrain`       what the app computed per lift session, plus what was applied.
//   * `liftStrainTarget` a snapshot of every stored value that was ever combined (workout row or day row).
//   * `liftStrainJob`    the durable, resumable one-time backfill.
//   * `liftStrainControl` the global internal kill switch (a missing row means enabled).
//
// The apply writes `strain` / `strainVersion` of a workout row or a computed day row, and nothing else: no
// calories, recovery, sleep, heart rate or detected workouts. It always updates the stored value, its target
// row and its liftStrain row in one transaction, and only when bits actually change.

// MARK: - Public types

/// Combines a heart-rate-only stored Strain (0...100) with a muscular load. Injected so WhoopStore does not
/// depend on StrandAnalytics.
public typealias LiftStrainCombine = @Sendable (_ hrStored: Double, _ muscularLoad: Double) -> Double

/// The day-level counterpart of ``LiftStrainCombine`` (A7): combines a day's heart-rate-only stored Strain with the
/// day's muscular load, and may know the day's parts (cardio, step and energy floors) so the floors stay
/// max-combined. `day` is the logical day key. Called inside the settle transaction: it must be synchronous and
/// must not touch the store. When absent the day settle uses ``LiftStrainCombine``, the stored-score inversion.
public typealias LiftStrainDayCombine = @Sendable (_ day: String, _ hrStored: Double, _ muscularLoad: Double) -> Double

public enum LiftStrainRowState: String, Sendable, Codable {
    /// Computed, never applied.
    case pending
    /// Applied: the stored value includes this lift's muscular load (or the load is 0).
    case applied
    /// Provisional: the workout has no heart-rate-scored Strain yet. Retried when its stored value changes.
    case notScored
    /// The lift's workout row no longer exists (deleted, merged away or re-keyed).
    case detached
}

public enum LiftStrainJobState: String, Sendable, Codable { case running, complete, reverted }

/// What the app computes for one lift session. Computed columns only.
public struct LiftStrainComputed: Equatable, Sendable {
    public let liftSessionId: String
    public let workoutStartTs: Int
    public let workoutSport: String
    public let dayKey: String
    public let formulaVersion: Int
    public let bodyweightKg: Double
    public let bodyweightIsDefault: Bool
    public let dose: Double
    public let volume: Double
    public let muscularLoad: Double
    public let workingSets: Int
    public let warmupSets: Int
    public let countedSets: Int
    public let skippedJSON: String
    public let unmappedSets: Int

    public init(liftSessionId: String, workoutStartTs: Int, workoutSport: String, dayKey: String,
                formulaVersion: Int, bodyweightKg: Double, bodyweightIsDefault: Bool,
                dose: Double, volume: Double, muscularLoad: Double,
                workingSets: Int, warmupSets: Int, countedSets: Int, skippedJSON: String, unmappedSets: Int) {
        self.liftSessionId = liftSessionId
        self.workoutStartTs = workoutStartTs
        self.workoutSport = workoutSport
        self.dayKey = dayKey
        self.formulaVersion = formulaVersion
        self.bodyweightKg = bodyweightKg
        self.bodyweightIsDefault = bodyweightIsDefault
        self.dose = dose
        self.volume = volume
        self.muscularLoad = muscularLoad
        self.workingSets = workingSets
        self.warmupSets = warmupSets
        self.countedSets = countedSets
        self.skippedJSON = skippedJSON
        self.unmappedSets = unmappedSets
    }
}

/// One `liftStrain` row, every column.
public struct LiftStrainRow: Equatable, Sendable {
    public let deviceId: String
    public let liftSessionId: String
    public let workoutStartTs: Int
    public let workoutSport: String
    public let dayKey: String
    public let formulaVersion: Int
    public let bodyweightKg: Double
    public let bodyweightIsDefault: Bool
    public let dose: Double
    public let volume: Double
    public let muscularLoad: Double
    public let workingSets: Int
    public let warmupSets: Int
    public let countedSets: Int
    public let skippedJSON: String
    public let unmappedSets: Int
    public let hrOnlyStrain: Double?
    public let combinedStrain: Double?
    public let appliedMuscularLoad: Double
    public let state: LiftStrainRowState
    public let computedAt: Int
    public let updatedAt: Int

    public init(deviceId: String, liftSessionId: String, workoutStartTs: Int, workoutSport: String,
                dayKey: String, formulaVersion: Int, bodyweightKg: Double, bodyweightIsDefault: Bool,
                dose: Double, volume: Double, muscularLoad: Double,
                workingSets: Int, warmupSets: Int, countedSets: Int, skippedJSON: String, unmappedSets: Int,
                hrOnlyStrain: Double?, combinedStrain: Double?, appliedMuscularLoad: Double,
                state: LiftStrainRowState, computedAt: Int, updatedAt: Int) {
        self.deviceId = deviceId
        self.liftSessionId = liftSessionId
        self.workoutStartTs = workoutStartTs
        self.workoutSport = workoutSport
        self.dayKey = dayKey
        self.formulaVersion = formulaVersion
        self.bodyweightKg = bodyweightKg
        self.bodyweightIsDefault = bodyweightIsDefault
        self.dose = dose
        self.volume = volume
        self.muscularLoad = muscularLoad
        self.workingSets = workingSets
        self.warmupSets = warmupSets
        self.countedSets = countedSets
        self.skippedJSON = skippedJSON
        self.unmappedSets = unmappedSets
        self.hrOnlyStrain = hrOnlyStrain
        self.combinedStrain = combinedStrain
        self.appliedMuscularLoad = appliedMuscularLoad
        self.state = state
        self.computedAt = computedAt
        self.updatedAt = updatedAt
    }

    static func decode(_ row: Row) -> LiftStrainRow {
        LiftStrainRow(
            deviceId: row["deviceId"],
            liftSessionId: row["liftSessionId"],
            workoutStartTs: row["workoutStartTs"],
            workoutSport: row["workoutSport"],
            dayKey: row["dayKey"],
            formulaVersion: row["formulaVersion"],
            bodyweightKg: row["bodyweightKg"],
            bodyweightIsDefault: (row["bodyweightIsDefault"] as Int? ?? 0) != 0,
            dose: row["dose"],
            volume: row["volume"],
            muscularLoad: row["muscularLoad"],
            workingSets: row["workingSets"],
            warmupSets: row["warmupSets"],
            countedSets: row["countedSets"],
            skippedJSON: row["skippedJSON"],
            unmappedSets: row["unmappedSets"],
            hrOnlyStrain: row["hrOnlyStrain"],
            combinedStrain: row["combinedStrain"],
            appliedMuscularLoad: row["appliedMuscularLoad"],
            state: LiftStrainRowState(rawValue: row["state"] as String? ?? "") ?? .pending,
            computedAt: row["computedAt"],
            updatedAt: row["updatedAt"]
        )
    }
}

public struct LiftStrainFrozenBodyweight: Equatable, Sendable {
    public let kg: Double
    public let isDefault: Bool
    public init(kg: Double, isDefault: Bool) { self.kg = kg; self.isDefault = isDefault }
}

/// One applied lift on a day, joined to its (still matching) workout. The M_day input.
public struct LiftStrainAppliedLoad: Equatable, Sendable {
    public let deviceId: String
    public let liftSessionId: String
    public let workoutStartTs: Int
    public let workoutEndTs: Int
    public let muscularLoad: Double
    public init(deviceId: String, liftSessionId: String, workoutStartTs: Int, workoutEndTs: Int,
                muscularLoad: Double) {
        self.deviceId = deviceId
        self.liftSessionId = liftSessionId
        self.workoutStartTs = workoutStartTs
        self.workoutEndTs = workoutEndTs
        self.muscularLoad = muscularLoad
    }
}

/// A computed day row that the apply has combined, with the heart-rate-only value it was built from.
public struct LiftStrainDayTarget: Equatable, Sendable {
    public let deviceId: String
    public let dayKey: String
    public let hrOnlyStrain: Double?
    public let writtenStrain: Double?
    public let writtenStrainVersion: Int?
    public init(deviceId: String, dayKey: String, hrOnlyStrain: Double?, writtenStrain: Double?,
                writtenStrainVersion: Int?) {
        self.deviceId = deviceId
        self.dayKey = dayKey
        self.hrOnlyStrain = hrOnlyStrain
        self.writtenStrain = writtenStrain
        self.writtenStrainVersion = writtenStrainVersion
    }
}

public struct LiftStrainApplyResult: Equatable, Sendable {
    public var rowsVisited = 0
    public var workoutWrites = 0
    public var dayWrites = 0
    public var applied = 0
    public var notScored = 0
    public var detached = 0
    public var conflicts = 0
    public init() {}
}

public struct LiftStrainJobRow: Equatable, Sendable {
    public let jobKey: String
    public let deviceId: String
    public let formulaVersion: Int
    public let state: LiftStrainJobState
    public let cursorDay: String?
    public let upperDay: String
    public let liftsApplied: Int
    public let liftsSkipped: Int
    public let daysApplied: Int
    public let conflicts: Int
    public let startedAt: Int
    public let completedAt: Int?
    public let refreshedAt: Int?

    public init(jobKey: String, deviceId: String, formulaVersion: Int, state: LiftStrainJobState,
                cursorDay: String?, upperDay: String, liftsApplied: Int, liftsSkipped: Int,
                daysApplied: Int, conflicts: Int, startedAt: Int, completedAt: Int?, refreshedAt: Int?) {
        self.jobKey = jobKey
        self.deviceId = deviceId
        self.formulaVersion = formulaVersion
        self.state = state
        self.cursorDay = cursorDay
        self.upperDay = upperDay
        self.liftsApplied = liftsApplied
        self.liftsSkipped = liftsSkipped
        self.daysApplied = daysApplied
        self.conflicts = conflicts
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.refreshedAt = refreshedAt
    }
}

/// One atomic backfill chunk: the computed rows of whole logical days, the days to settle, and the cursor.
public struct LiftStrainChunkInput: Equatable, Sendable {
    public let rows: [LiftStrainComputed]
    public let dayKeys: [String]
    public let lastDay: String
    public init(rows: [LiftStrainComputed], dayKeys: [String], lastDay: String) {
        self.rows = rows
        self.dayKeys = dayKeys
        self.lastDay = lastDay
    }
}

public enum LiftStrainVisit: Sendable {
    /// Live mode: every row whose stored state needs a visit.
    case dirty
    /// Backfill mode: exactly these rows.
    case sessions(deviceId: String, ids: [String])
}

/// What `rekeyManualWorkout` needs to settle the old and the new day in its own transaction (A6).
public struct LiftStrainRekeySettle: Sendable {
    public let canonicalComputedDeviceId: String
    /// The logical day key of the new workout's start. The old day comes from the lift rows and `oldDayKey`.
    public let newDayKey: String
    /// The logical day key of the old workout's start, when the caller knows it.
    public let oldDayKey: String?
    public let now: Int
    public let combine: LiftStrainCombine
    /// The day combine, when the caller knows the days' parts. Nil settles days with `combine`.
    public let dayCombine: LiftStrainDayCombine?

    public init(canonicalComputedDeviceId: String, newDayKey: String, oldDayKey: String? = nil, now: Int,
                combine: @escaping LiftStrainCombine, dayCombine: LiftStrainDayCombine? = nil) {
        self.canonicalComputedDeviceId = canonicalComputedDeviceId
        self.newDayKey = newDayKey
        self.oldDayKey = oldDayKey
        self.now = now
        self.combine = combine
        self.dayCombine = dayCombine
    }
}

extension DailyMetric {
    /// Same row with only `strain` replaced (every other field copied through the public init).
    public func replacingStrain(_ strain: Double?) -> DailyMetric {
        DailyMetric(
            day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
            remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
            avgHrv: avgHrv, recovery: recovery, strain: strain, exerciseCount: exerciseCount,
            spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: respRateBpm,
            steps: steps, activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir,
            strainVersion: strainVersion)
    }
}

/// Fitness Age and VO2max stay heart-rate only: both read Strain, so lift days are fed the value the
/// heart-rate analysis stored, not the value with logged sets added.
public enum LiftStrainFitnessAgeOverlay {
    /// For each day, when its `strain` and `strainVersion` are bit-equal to a day target's written pair,
    /// returns the row with the target's `hrOnlyStrain`. Every other row (imported days, days with no target,
    /// days whose value was rewritten since) is returned unchanged.
    public static func hrOnly(days: [DailyMetric], targets: [LiftStrainDayTarget]) -> [DailyMetric] {
        guard !targets.isEmpty else { return days }
        var byDay: [String: [LiftStrainDayTarget]] = [:]
        for target in targets { byDay[target.dayKey, default: []].append(target) }
        return days.map { day in
            guard let candidates = byDay[day.day] else { return day }
            for target in candidates.sorted(by: { $0.deviceId < $1.deviceId })
            where LiftStrainBits.same(day.strain, target.writtenStrain)
                && day.strainVersion == target.writtenStrainVersion {
                return day.replacingStrain(target.hrOnlyStrain)
            }
            return day
        }
    }
}

// MARK: - Bit helpers

enum LiftStrainBits {
    /// NULL-safe, bit-exact equality of two optional doubles.
    @inline(__always)
    static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.bitPattern == y.bitPattern
        default: return false
        }
    }

    /// The finite loads above 0 added smallest first, so the order they arrive in never changes a bit. Matches
    /// `StrengthStrain.dayMuscularLoad` exactly.
    static func dayLoad(_ loads: [Double]) -> Double {
        loads.filter { $0.isFinite && $0 > 0 }.sorted().reduce(0, +)
    }

    @inline(__always)
    static func usableLoad(_ m: Double) -> Double { (m.isFinite && m > 0) ? m : 0 }
}

/// A stored `(strain, strainVersion)` pair.
struct LiftStrainPair: Equatable {
    var strain: Double?
    var version: Int?

    func same(_ other: LiftStrainPair) -> Bool {
        LiftStrainBits.same(strain, other.strain) && version == other.version
    }
}

private struct LiftStrainTargetRow {
    var hrOnly: Double?
    var written: LiftStrainPair
    var orig: LiftStrainPair
    var applied: Double
}

// MARK: - Store API

extension WhoopStore {

    // MARK: Reads

    public func liftStrainRows(deviceId: String, liftSessionIds: [String]) async throws -> [LiftStrainRow] {
        guard !liftSessionIds.isEmpty else { return [] }
        return try syncRead { db in
            try Self.liftStrainRows(db: db, deviceId: deviceId, ids: liftSessionIds)
        }
    }

    /// The row for a workout key, preferring the given owner when several owners have a row at the same key.
    public func liftStrainRow(workoutStartTs: Int, sport: String, preferredDeviceId: String) async throws -> LiftStrainRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM liftStrain WHERE workoutStartTs = ? AND workoutSport = ?
                ORDER BY (deviceId = ?) DESC, deviceId LIMIT 1
                """, arguments: [workoutStartTs, sport, preferredDeviceId]).map(LiftStrainRow.decode)
        }
    }

    /// The bodyweight each lift was first computed with, so a later profile change never rewrites an old score.
    public func liftStrainBodyweights(deviceId: String, liftSessionIds: [String]? = nil) async throws
        -> [String: LiftStrainFrozenBodyweight] {
        if let ids = liftSessionIds, ids.isEmpty { return [:] }
        return try syncRead { db in
            let rows: [Row]
            if let ids = liftSessionIds {
                rows = try Self.chunked(ids).flatMap { chunk in
                    try Row.fetchAll(db, sql: """
                        SELECT liftSessionId, bodyweightKg, bodyweightIsDefault FROM liftStrain
                        WHERE deviceId = ? AND liftSessionId IN (\(Self.placeholders(chunk.count)))
                        """, arguments: StatementArguments([deviceId] + chunk))
                }
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT liftSessionId, bodyweightKg, bodyweightIsDefault FROM liftStrain WHERE deviceId = ?
                    """, arguments: [deviceId])
            }
            var out: [String: LiftStrainFrozenBodyweight] = [:]
            for row in rows {
                out[row["liftSessionId"]] = LiftStrainFrozenBodyweight(
                    kg: row["bodyweightKg"], isDefault: (row["bodyweightIsDefault"] as Int? ?? 0) != 0)
            }
            return out
        }
    }

    /// Every owner's applied lifts on a day, joined to the workout they were combined into (a deleted or
    /// rewritten workout drops out). The input of the day's muscular load.
    public func liftStrainAppliedLoads(dayKey: String) async throws -> [LiftStrainAppliedLoad] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ls.deviceId, ls.liftSessionId, ls.workoutStartTs, w.endTs AS workoutEndTs, ls.appliedMuscularLoad
                  FROM liftStrain ls
                  JOIN workout w ON w.deviceId = ls.deviceId AND w.startTs = ls.workoutStartTs AND w.sport = ls.workoutSport
                 WHERE ls.dayKey = ? AND ls.state = 'applied' AND ls.appliedMuscularLoad > 0
                   AND w.strainVersion = 2 AND w.strain IS ls.combinedStrain
                 ORDER BY w.endTs, ls.deviceId, ls.liftSessionId
                """, arguments: [dayKey]).map {
                LiftStrainAppliedLoad(
                    deviceId: $0["deviceId"], liftSessionId: $0["liftSessionId"],
                    workoutStartTs: $0["workoutStartTs"], workoutEndTs: $0["workoutEndTs"],
                    muscularLoad: $0["appliedMuscularLoad"])
            }
        }
    }

    public func liftStrainDayTargets(computedDeviceIds: [String], fromDay: String, toDay: String) async throws
        -> [LiftStrainDayTarget] {
        guard !computedDeviceIds.isEmpty else { return [] }
        return try syncRead { db in
            try Self.chunked(computedDeviceIds).flatMap { chunk in
                try Row.fetchAll(db, sql: """
                    SELECT deviceId, keyText, hrOnlyStrain, writtenStrain, writtenStrainVersion FROM liftStrainTarget
                    WHERE kind = 'day' AND keyText >= ? AND keyText <= ?
                      AND deviceId IN (\(Self.placeholders(chunk.count)))
                    ORDER BY keyText, deviceId
                    """, arguments: StatementArguments([fromDay, toDay] + chunk)).map {
                    LiftStrainDayTarget(
                        deviceId: $0["deviceId"], dayKey: $0["keyText"], hrOnlyStrain: $0["hrOnlyStrain"],
                        writtenStrain: $0["writtenStrain"], writtenStrainVersion: $0["writtenStrainVersion"])
                }
            }
        }
    }

    public func liftStrainJob(jobKey: String) async throws -> LiftStrainJobRow? {
        try syncRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM liftStrainJob WHERE jobKey = ?", arguments: [jobKey]).map {
                LiftStrainJobRow(
                    jobKey: $0["jobKey"], deviceId: $0["deviceId"], formulaVersion: $0["formulaVersion"],
                    state: LiftStrainJobState(rawValue: $0["state"] as String? ?? "") ?? .running,
                    cursorDay: $0["cursorDay"], upperDay: $0["upperDay"],
                    liftsApplied: $0["liftsApplied"], liftsSkipped: $0["liftsSkipped"],
                    daysApplied: $0["daysApplied"], conflicts: $0["conflicts"],
                    startedAt: $0["startedAt"], completedAt: $0["completedAt"], refreshedAt: $0["refreshedAt"])
            }
        }
    }

    public func liftStrainDisabled() async throws -> Bool {
        try syncRead { db in try Self.liftStrainIsDisabled(db) }
    }

    // MARK: Live (primary engine only)

    public func upsertLiftStrainComputed(deviceId: String, rows: [LiftStrainComputed], now: Int) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            try Self.upsertLiftStrainComputed(db: db, deviceId: deviceId, rows: rows, now: now)
        }
    }

    /// Visits every dirty lift row and day, in one transaction. Idempotent: a second call with nothing new
    /// changes nothing.
    ///
    /// `extraDayKeys` forces those days through the day settle even when no row of theirs is dirty; the settle is
    /// still idempotent, so a day whose value does not change is not written. `dayCombine` is the components-aware
    /// day combine (A7); nil uses `combine` for days too.
    public func applyLiftStrain(canonicalComputedDeviceId: String, now: Int,
                                combine: @escaping LiftStrainCombine,
                                dayCombine: LiftStrainDayCombine? = nil,
                                extraDayKeys: [String] = []) async throws -> LiftStrainApplyResult {
        try syncWrite { db in
            try Self.applyLiftStrainInTransaction(
                db: db, canonicalComputedDeviceId: canonicalComputedDeviceId, visit: .dirty,
                extraDayKeys: extraDayKeys, now: now, combine: combine, dayCombine: dayCombine)
        }
    }

    /// The logical days an apply with these inputs may settle: the days of the rows it would visit, the extra days
    /// and the days step C would pick. A superset of the days it writes, read without writing anything, so the
    /// caller can gather each day's parts before the (synchronous) settle transaction runs.
    public func liftStrainSettleDays(canonicalComputedDeviceId: String,
                                     extraDayKeys: [String] = []) async throws -> [String] {
        try syncRead { db in
            let disabled = try Self.liftStrainIsDisabled(db)
            var days = Set(extraDayKeys)
            for row in try Self.liftStrainRowsToVisit(db: db, visit: .dirty, disabled: disabled) {
                days.insert(row.dayKey)
            }
            try Self.collectLiftStrainDays(
                db: db, canonical: canonicalComputedDeviceId, disabled: disabled, into: &days)
            return days.sorted()
        }
    }

    // MARK: Backfill

    public func startLiftStrainJob(jobKey: String, deviceId: String, formulaVersion: Int, upperDay: String,
                                   now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO liftStrainJob (jobKey, deviceId, formulaVersion, state, cursorDay, upperDay, startedAt)
                VALUES (?, ?, ?, 'running', NULL, ?, ?)
                """, arguments: [jobKey, deviceId, formulaVersion, upperDay, now])
        }
    }

    /// One atomic chunk: owner fence, computed rows, the apply for exactly those rows plus the chunk's days,
    /// and the job cursor. Any throw rolls the whole chunk back.
    public func applyLiftStrainBackfillChunk(
        sourceOwner: HistoricalCursorScope,
        canonicalComputedDeviceId: String,
        chunk: LiftStrainChunkInput,
        jobKey: String,
        now: Int,
        combine: @escaping LiftStrainCombine,
        dayCombine: LiftStrainDayCombine? = nil
    ) async throws -> LiftStrainApplyResult {
        guard !sourceOwner.deviceId.isEmpty else { throw LiftReceiptStateError.emptyDeviceId }
        return try syncWrite { db in
            try assertReceiptLiftSourceOwner(sourceOwner, db: db, allowArchived: true)
            try Self.upsertLiftStrainComputed(db: db, deviceId: sourceOwner.deviceId, rows: chunk.rows, now: now)
            let result = try Self.applyLiftStrainInTransaction(
                db: db, canonicalComputedDeviceId: canonicalComputedDeviceId,
                visit: .sessions(deviceId: sourceOwner.deviceId, ids: chunk.rows.map(\.liftSessionId)),
                extraDayKeys: chunk.dayKeys, now: now, combine: combine, dayCombine: dayCombine)
            try db.execute(sql: """
                UPDATE liftStrainJob
                   SET cursorDay = ?, liftsApplied = liftsApplied + ?, liftsSkipped = liftsSkipped + ?,
                       daysApplied = daysApplied + ?, conflicts = conflicts + ?
                 WHERE jobKey = ? AND state = 'running'
                """, arguments: [chunk.lastDay, result.applied, result.notScored, result.dayWrites,
                                 result.conflicts, jobKey])
            return result
        }
    }

    /// Conditional on `running`, so two runners cannot double-complete and a reverted job stays reverted.
    public func completeLiftStrainJob(jobKey: String, now: Int) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE liftStrainJob SET state = 'complete', completedAt = ? WHERE jobKey = ? AND state = 'running'
                """, arguments: [now, jobKey])
            return db.changesCount > 0
        }
    }

    /// Proof that the post-backfill repository refresh ran. Only `complete` jobs are marked.
    public func markLiftStrainJobsRefreshed(jobKeys: [String], now: Int) async throws {
        guard !jobKeys.isEmpty else { return }
        try syncWrite { db in
            for chunk in Self.chunked(jobKeys) {
                var arguments = StatementArguments([now])
                arguments += StatementArguments(chunk)
                try db.execute(sql: """
                    UPDATE liftStrainJob SET refreshedAt = ?
                    WHERE state = 'complete' AND jobKey IN (\(Self.placeholders(chunk.count)))
                    """, arguments: arguments)
            }
        }
    }

    // MARK: Internal revert and re-enable (global, no UI)

    /// Restores every combined value to the one it was built from and switches the apply off. For each target
    /// whose stored value is still the one we wrote, the original bits come back; a value the heart-rate path
    /// rewrote since is kept. While disabled every apply uses a muscular load of 0, which is the reverted state.
    @discardableResult
    public func revertLiftStrain(reason: String, now: Int) async throws -> LiftStrainApplyResult {
        try syncWrite { db in
            var result = LiftStrainApplyResult()
            let targets = try Row.fetchAll(db, sql: """
                SELECT * FROM liftStrainTarget ORDER BY deviceId, kind, keyTs, keyText
                """)
            for t in targets {
                let deviceId: String = t["deviceId"]
                let kind: String = t["kind"]
                let keyTs: Int = t["keyTs"]
                let keyText: String = t["keyText"]
                let isWorkout = kind == "workout"
                let currentRow: Row?
                if isWorkout {
                    currentRow = try Row.fetchOne(db, sql: """
                        SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?
                        """, arguments: [deviceId, keyTs, keyText])
                } else {
                    currentRow = try Row.fetchOne(db, sql: """
                        SELECT strain, strainVersion FROM dailyMetric WHERE deviceId = ? AND day = ?
                        """, arguments: [deviceId, keyText])
                }
                guard let currentRow else {
                    try db.execute(sql: """
                        UPDATE liftStrainTarget SET appliedMuscularLoad = 0, updatedAt = ?
                        WHERE deviceId = ? AND kind = ? AND keyTs = ? AND keyText = ?
                        """, arguments: [now, deviceId, kind, keyTs, keyText])
                    continue
                }
                let current = LiftStrainPair(strain: currentRow["strain"], version: currentRow["strainVersion"])
                let written = LiftStrainPair(strain: t["writtenStrain"], version: t["writtenStrainVersion"])
                var stored = current
                if current.same(written) {
                    let orig = LiftStrainPair(strain: t["origStrain"], version: t["origStrainVersion"])
                    let hrOnly: Double? = t["hrOnlyStrain"]
                    // The original pair comes back whenever the heart-rate value is still the original one. A
                    // heart-rate value that is gone (nil) can never be restored as a version-2 NULL, which is
                    // not a valid prior state, so it falls back to the original pair too.
                    let restored: LiftStrainPair
                    if let hrOnly, !LiftStrainBits.same(hrOnly, orig.strain) {
                        restored = LiftStrainPair(strain: hrOnly, version: 2)
                    } else {
                        restored = orig
                    }
                    if !restored.same(current) {
                        if isWorkout {
                            try db.execute(sql: """
                                UPDATE workout SET strain = ?, strainVersion = ?
                                WHERE deviceId = ? AND startTs = ? AND sport = ? AND strain IS ?
                                """, arguments: [restored.strain, restored.version, deviceId, keyTs, keyText, current.strain])
                        } else {
                            try db.execute(sql: """
                                UPDATE dailyMetric SET strain = ?, strainVersion = ?
                                WHERE deviceId = ? AND day = ? AND strain IS ?
                                """, arguments: [restored.strain, restored.version, deviceId, keyText, current.strain])
                        }
                        if db.changesCount > 0 {
                            stored = restored
                            if isWorkout { result.workoutWrites += 1 } else { result.dayWrites += 1 }
                        } else {
                            result.conflicts += 1
                        }
                    }
                }
                try db.execute(sql: """
                    UPDATE liftStrainTarget
                       SET writtenStrain = ?, writtenStrainVersion = ?, appliedMuscularLoad = 0, updatedAt = ?
                     WHERE deviceId = ? AND kind = ? AND keyTs = ? AND keyText = ?
                    """, arguments: [stored.strain, stored.version, now, deviceId, kind, keyTs, keyText])
            }
            try db.execute(sql: """
                UPDATE liftStrain SET appliedMuscularLoad = 0, combinedStrain = NULL, state = 'pending', updatedAt = ?
                """, arguments: [now])
            try db.execute(sql: """
                INSERT OR REPLACE INTO liftStrainControl (scope, disabled, reason, updatedAt) VALUES ('global', 1, ?, ?)
                """, arguments: [reason, now])
            try db.execute(sql: "UPDATE liftStrainJob SET state = 'reverted'")
            return result
        }
    }

    /// Switches the apply back on and forgets every job, so the backfill and the live apply run again.
    public func enableLiftStrain(now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO liftStrainControl (scope, disabled, reason, updatedAt) VALUES ('global', 0, NULL, ?)
                """, arguments: [now])
            try db.execute(sql: "DELETE FROM liftStrainJob")
        }
    }

    // MARK: Workouts-tab re-key

    /// Moves a manually edited workout from `old` to `new` in one transaction, replacing the separate
    /// delete-then-upsert. When the old row still holds the value the apply wrote, the new row gets the
    /// heart-rate-only value first, so logged sets never stay in a value labelled heart rate. Lifts attached
    /// to the old key follow the workout (A6): their rows are repointed to the new key and the new day, reset
    /// to `pending`, and the apply in this same transaction recombines the new row. The old and the new day
    /// are both settled in this transaction, so the old day returns to its heart-rate value bit for bit and the
    /// new day includes the moved lift's load. `settle` is required: a rekey never leaves a day for a later pass.
    @discardableResult
    public func rekeyManualWorkout(deviceId: String, old: WorkoutRow, new: WorkoutRow,
                                   settle: LiftStrainRekeySettle) async throws -> LiftStrainApplyResult {
        try syncWrite { db in
            guard old.startTs != new.startTs || old.sport != new.sport else {
                _ = try Self.upsertWorkoutRows(db: db, rows: [new], deviceId: deviceId)
                return LiftStrainApplyResult()
            }
            let oldWorkout = try Row.fetchOne(db, sql: """
                SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [deviceId, old.startTs, old.sport])
            let target = try Row.fetchOne(db, sql: """
                SELECT hrOnlyStrain, writtenStrain, writtenStrainVersion FROM liftStrainTarget
                WHERE deviceId = ? AND kind = 'workout' AND keyTs = ? AND keyText = ?
                """, arguments: [deviceId, old.startTs, old.sport])
            let liftDays = try String.fetchAll(db, sql: """
                SELECT DISTINCT dayKey FROM liftStrain WHERE deviceId = ? AND workoutStartTs = ? AND workoutSport = ?
                """, arguments: [deviceId, old.startTs, old.sport])

            try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                           arguments: [deviceId, old.startTs, old.sport])

            var row = new
            if let oldWorkout, let target {
                let oldPair = LiftStrainPair(strain: oldWorkout["strain"], version: oldWorkout["strainVersion"])
                let written = LiftStrainPair(strain: target["writtenStrain"], version: target["writtenStrainVersion"])
                if oldPair.same(written) {
                    let hrOnly: Double? = target["hrOnlyStrain"]
                    row = WorkoutRow(
                        startTs: new.startTs, endTs: new.endTs, sport: new.sport, source: new.source,
                        durationS: new.durationS, energyKcal: new.energyKcal, avgHr: new.avgHr, maxHr: new.maxHr,
                        strain: hrOnly, distanceM: new.distanceM, zonesJSON: new.zonesJSON, notes: new.notes,
                        strainVersion: hrOnly != nil ? 2 : new.strainVersion)
                }
            }
            _ = try Self.upsertWorkoutRows(db: db, rows: [row], deviceId: deviceId)

            try db.execute(sql: """
                DELETE FROM liftStrainTarget WHERE deviceId = ? AND kind = 'workout' AND keyTs = ? AND keyText = ?
                """, arguments: [deviceId, old.startTs, old.sport])
            // The lifts follow the workout: same session, new key and day, nothing applied yet. The apply below
            // visits them as pending and builds the new target on the heart-rate-only value written above.
            try db.execute(sql: """
                UPDATE liftStrain
                   SET workoutStartTs = ?, workoutSport = ?, dayKey = ?, state = 'pending', hrOnlyStrain = NULL,
                       appliedMuscularLoad = 0, combinedStrain = NULL, updatedAt = ?
                 WHERE deviceId = ? AND workoutStartTs = ? AND workoutSport = ?
                """, arguments: [new.startTs, new.sport, settle.newDayKey, settle.now, deviceId, old.startTs, old.sport])

            guard target != nil || !liftDays.isEmpty else { return LiftStrainApplyResult() }
            var days = Set(liftDays)
            days.insert(settle.newDayKey)
            if let oldDay = settle.oldDayKey { days.insert(oldDay) }
            return try Self.applyLiftStrainInTransaction(
                db: db, canonicalComputedDeviceId: settle.canonicalComputedDeviceId, visit: .dirty,
                extraDayKeys: days.sorted(), now: settle.now, combine: settle.combine,
                dayCombine: settle.dayCombine)
        }
    }

    // MARK: - Statics shared with other transactions

    static func upsertLiftStrainComputed(db: Database, deviceId: String, rows: [LiftStrainComputed], now: Int) throws {
        for r in rows {
            // Computed columns only. `hrOnlyStrain`, `combinedStrain`, `appliedMuscularLoad` and `state` belong
            // to the apply and are never touched here; a new row starts `pending`. The WHERE clause makes a
            // re-save or a re-run of a completed backfill chunk write nothing.
            try db.execute(sql: """
                INSERT INTO liftStrain
                    (deviceId, liftSessionId, workoutStartTs, workoutSport, dayKey, formulaVersion, bodyweightKg,
                     bodyweightIsDefault, dose, volume, muscularLoad, workingSets, warmupSets, countedSets,
                     skippedJSON, unmappedSets, computedAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(deviceId, liftSessionId) DO UPDATE SET
                    workoutStartTs = excluded.workoutStartTs,
                    workoutSport = excluded.workoutSport,
                    dayKey = excluded.dayKey,
                    formulaVersion = excluded.formulaVersion,
                    bodyweightKg = excluded.bodyweightKg,
                    bodyweightIsDefault = excluded.bodyweightIsDefault,
                    dose = excluded.dose,
                    volume = excluded.volume,
                    muscularLoad = excluded.muscularLoad,
                    workingSets = excluded.workingSets,
                    warmupSets = excluded.warmupSets,
                    countedSets = excluded.countedSets,
                    skippedJSON = excluded.skippedJSON,
                    unmappedSets = excluded.unmappedSets,
                    computedAt = excluded.computedAt,
                    updatedAt = excluded.updatedAt
                WHERE liftStrain.workoutStartTs IS NOT excluded.workoutStartTs
                   OR liftStrain.workoutSport IS NOT excluded.workoutSport
                   OR liftStrain.dayKey IS NOT excluded.dayKey
                   OR liftStrain.formulaVersion IS NOT excluded.formulaVersion
                   OR liftStrain.bodyweightKg IS NOT excluded.bodyweightKg
                   OR liftStrain.bodyweightIsDefault IS NOT excluded.bodyweightIsDefault
                   OR liftStrain.dose IS NOT excluded.dose
                   OR liftStrain.volume IS NOT excluded.volume
                   OR liftStrain.muscularLoad IS NOT excluded.muscularLoad
                   OR liftStrain.workingSets IS NOT excluded.workingSets
                   OR liftStrain.warmupSets IS NOT excluded.warmupSets
                   OR liftStrain.countedSets IS NOT excluded.countedSets
                   OR liftStrain.skippedJSON IS NOT excluded.skippedJSON
                   OR liftStrain.unmappedSets IS NOT excluded.unmappedSets
                """, arguments: [deviceId, r.liftSessionId, r.workoutStartTs, r.workoutSport, r.dayKey,
                                 r.formulaVersion, r.bodyweightKg, r.bodyweightIsDefault ? 1 : 0, r.dose,
                                 r.volume, r.muscularLoad, r.workingSets, r.warmupSets, r.countedSets,
                                 r.skippedJSON, r.unmappedSets, now, now])
        }
    }

    static func liftStrainIsDisabled(_ db: Database) throws -> Bool {
        (try Int.fetchOne(db, sql: "SELECT disabled FROM liftStrainControl WHERE scope = 'global'") ?? 0) == 1
    }

    // MARK: - The apply

    /// Steps A to D of the plan. Writes only `strain` / `strainVersion` of workout and computed day rows, plus the
    /// tracking rows, and only when a value actually changes.
    static func applyLiftStrainInTransaction(
        db: Database,
        canonicalComputedDeviceId: String,
        visit: LiftStrainVisit,
        extraDayKeys: [String],
        now: Int,
        combine: LiftStrainCombine,
        dayCombine: LiftStrainDayCombine? = nil
    ) throws -> LiftStrainApplyResult {
        var result = LiftStrainApplyResult()
        let disabled = try liftStrainIsDisabled(db)

        // Step A: choose rows.
        let rows = try liftStrainRowsToVisit(db: db, visit: visit, disabled: disabled)

        // Step B: per row (workout).
        var dayKeys = Set(extraDayKeys)
        for ls in rows {
            result.rowsVisited += 1
            if try applyLiftStrainRow(db: db, ls: ls, disabled: disabled, now: now, combine: combine,
                                      result: &result) {
                dayKeys.insert(ls.dayKey)
            }
        }

        // Step B sweep: workout targets that no live lift row points at any more.
        try sweepOrphanWorkoutTargets(db: db, now: now, result: &result)

        // Step C: choose days.
        try collectLiftStrainDays(db: db, canonical: canonicalComputedDeviceId, disabled: disabled, into: &dayKeys)

        // Step D: settle each day.
        for day in dayKeys.sorted() {
            try settleLiftStrainDay(db: db, day: day, canonical: canonicalComputedDeviceId, disabled: disabled,
                                    now: now, combine: combine, dayCombine: dayCombine, result: &result)
        }
        return result
    }

    private static func liftStrainRowsToVisit(db: Database, visit: LiftStrainVisit, disabled: Bool) throws -> [LiftStrainRow] {
        var byKey: [String: LiftStrainRow] = [:]
        func add(_ rows: [Row]) {
            for r in rows {
                let row = LiftStrainRow.decode(r)
                byKey["\(row.deviceId)\u{1F}\(row.liftSessionId)"] = row
            }
        }
        switch visit {
        case .sessions(let deviceId, let ids):
            for row in try liftStrainRows(db: db, deviceId: deviceId, ids: ids) {
                byKey["\(row.deviceId)\u{1F}\(row.liftSessionId)"] = row
            }
        case .dirty:
            // (a) never applied, provisional with a changed stored value, or load changed since applied.
            // A notScored row is provisional and is revisited only when its workout's stored pair is no longer
            // the one the apply recorded, so an idle apply over many unscorable lifts writes nothing.
            add(try Row.fetchAll(db, sql: """
                SELECT ls.* FROM liftStrain ls
                 WHERE ls.state = 'pending'
                    OR (ls.state = 'notScored' AND NOT EXISTS (
                          SELECT 1 FROM liftStrainTarget t
                            JOIN workout w ON w.deviceId = ls.deviceId AND w.startTs = ls.workoutStartTs
                                          AND w.sport = ls.workoutSport
                           WHERE t.deviceId = ls.deviceId AND t.kind = 'workout'
                             AND t.keyTs = ls.workoutStartTs AND t.keyText = ls.workoutSport
                             AND w.strain IS t.writtenStrain AND w.strainVersion IS t.writtenStrainVersion))
                    OR (ls.state = 'applied'
                        AND ls.appliedMuscularLoad IS NOT (CASE WHEN ?1 = 1 THEN 0.0 ELSE ls.muscularLoad END))
                """, arguments: [disabled ? 1 : 0]))
            // (b) its workout was rewritten by someone else, or deleted.
            add(try Row.fetchAll(db, sql: """
                SELECT ls.* FROM liftStrain ls
                  JOIN liftStrainTarget t ON t.deviceId = ls.deviceId AND t.kind = 'workout'
                       AND t.keyTs = ls.workoutStartTs AND t.keyText = ls.workoutSport
                  LEFT JOIN workout w ON w.deviceId = ls.deviceId AND w.startTs = ls.workoutStartTs
                       AND w.sport = ls.workoutSport
                 WHERE ls.state != 'detached'
                   AND (w.startTs IS NULL OR w.strain IS NOT t.writtenStrain OR w.strainVersion IS NOT t.writtenStrainVersion)
                """))
            // (c) detached rows whose workout exists again.
            add(try Row.fetchAll(db, sql: """
                SELECT ls.* FROM liftStrain ls WHERE ls.state = 'detached'
                   AND EXISTS (SELECT 1 FROM workout w WHERE w.deviceId = ls.deviceId
                               AND w.startTs = ls.workoutStartTs AND w.sport = ls.workoutSport)
                """))
            // (d) an applied or provisional row that points at a key with no workout target: a re-save or a
            // backfill re-run sent the row back to a key it was re-keyed away from. Visiting it re-attaches it
            // (the workout exists) or detaches it (the workout is gone), and the sweep below then frees the
            // target the move left behind.
            add(try Row.fetchAll(db, sql: """
                SELECT ls.* FROM liftStrain ls
                 WHERE ls.state IN ('applied', 'notScored')
                   AND NOT EXISTS (SELECT 1 FROM liftStrainTarget t
                                    WHERE t.deviceId = ls.deviceId AND t.kind = 'workout'
                                      AND t.keyTs = ls.workoutStartTs AND t.keyText = ls.workoutSport)
                """))
        }
        return byKey.values.sorted {
            ($0.workoutStartTs, $0.deviceId, $0.liftSessionId) < ($1.workoutStartTs, $1.deviceId, $1.liftSessionId)
        }
    }

    /// Step B for one row. Returns true when anything about the row, its target or its workout changed, so its
    /// day is settled.
    private static func applyLiftStrainRow(
        db: Database, ls: LiftStrainRow, disabled: Bool, now: Int, combine: LiftStrainCombine,
        result: inout LiftStrainApplyResult
    ) throws -> Bool {
        guard let wRow = try Row.fetchOne(db, sql: """
            SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?
            """, arguments: [ls.deviceId, ls.workoutStartTs, ls.workoutSport]) else {
            // Detached: the workout is gone. No target is created for it.
            result.detached += 1
            let changed = ls.state != .detached || ls.appliedMuscularLoad != 0 || ls.combinedStrain != nil
            if changed {
                try db.execute(sql: """
                    UPDATE liftStrain SET state = 'detached', appliedMuscularLoad = 0, combinedStrain = NULL, updatedAt = ?
                    WHERE deviceId = ? AND liftSessionId = ?
                    """, arguments: [now, ls.deviceId, ls.liftSessionId])
            }
            return changed
        }
        let current = LiftStrainPair(strain: wRow["strain"], version: wRow["strainVersion"])

        // The target is created on the first visit with orig = hrOnly = written = current.
        try db.execute(sql: """
            INSERT OR IGNORE INTO liftStrainTarget
                (deviceId, kind, keyTs, keyText, origStrain, origStrainVersion, hrOnlyStrain, writtenStrain,
                 writtenStrainVersion, appliedMuscularLoad, formulaVersion, snapshotAt, updatedAt)
            VALUES (?, 'workout', ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            """, arguments: [ls.deviceId, ls.workoutStartTs, ls.workoutSport, current.strain, current.version,
                             current.strain, current.strain, current.version, ls.formulaVersion, now, now])
        let t = try fetchTarget(db, deviceId: ls.deviceId, kind: "workout", keyTs: ls.workoutStartTs,
                                keyText: ls.workoutSport)

        // Base rule: if the stored value is still the one we wrote, build on the heart-rate value we recorded;
        // otherwise someone rewrote it and the stored value is the new heart-rate value.
        let base: Double? = current.same(t.written) ? t.hrOnly : current.strain

        var state: LiftStrainRowState
        var load = 0.0
        var stored = current
        var workoutWritten = false
        if current.version != 2 || base == nil {
            // HR gate: no heart-rate-scored workout means no muscular load. Nothing is written to the workout.
            state = .notScored
            result.notScored += 1
        } else {
            state = .applied
            result.applied += 1
            load = disabled ? 0 : LiftStrainBits.usableLoad(ls.muscularLoad)
            let target = load > 0 ? combine(base!, load) : base!
            if !LiftStrainBits.same(target, current.strain) {
                try db.execute(sql: """
                    UPDATE workout SET strain = ?, strainVersion = 2
                     WHERE deviceId = ? AND startTs = ? AND sport = ? AND strain IS ?
                    """, arguments: [target, ls.deviceId, ls.workoutStartTs, ls.workoutSport, current.strain])
                if db.changesCount == 0 {
                    result.conflicts += 1
                    return false
                }
                result.workoutWrites += 1
                workoutWritten = true
                stored = LiftStrainPair(strain: target, version: 2)
            }
        }

        var changed = workoutWritten
        if !LiftStrainBits.same(t.hrOnly, base) || !t.written.same(stored) || t.applied != load {
            try db.execute(sql: """
                UPDATE liftStrainTarget
                   SET hrOnlyStrain = ?, writtenStrain = ?, writtenStrainVersion = ?, appliedMuscularLoad = ?, updatedAt = ?
                 WHERE deviceId = ? AND kind = 'workout' AND keyTs = ? AND keyText = ?
                """, arguments: [base, stored.strain, stored.version, load, now, ls.deviceId,
                                 ls.workoutStartTs, ls.workoutSport])
            changed = true
        }
        if ls.state != state || ls.appliedMuscularLoad != load
            || !LiftStrainBits.same(ls.combinedStrain, stored.strain) || !LiftStrainBits.same(ls.hrOnlyStrain, base) {
            try db.execute(sql: """
                UPDATE liftStrain
                   SET hrOnlyStrain = ?, combinedStrain = ?, appliedMuscularLoad = ?, state = ?, updatedAt = ?
                 WHERE deviceId = ? AND liftSessionId = ?
                """, arguments: [base, stored.strain, load, state.rawValue, now, ls.deviceId, ls.liftSessionId])
            changed = true
        }
        return changed
    }

    private static func fetchTarget(_ db: Database, deviceId: String, kind: String, keyTs: Int, keyText: String)
        throws -> LiftStrainTargetRow {
        let r = try Row.fetchOne(db, sql: """
            SELECT * FROM liftStrainTarget WHERE deviceId = ? AND kind = ? AND keyTs = ? AND keyText = ?
            """, arguments: [deviceId, kind, keyTs, keyText])!
        return LiftStrainTargetRow(
            hrOnly: r["hrOnlyStrain"],
            written: LiftStrainPair(strain: r["writtenStrain"], version: r["writtenStrainVersion"]),
            orig: LiftStrainPair(strain: r["origStrain"], version: r["origStrainVersion"]),
            applied: r["appliedMuscularLoad"])
    }

    /// Workout targets that recorded a combined value (or a muscular load) while no non-detached lift row points
    /// at their key: the lift was re-keyed away, re-saved at another start, or deleted. When the stored pair is
    /// still the one the apply wrote, the heart-rate-only value goes back with a guarded update; a value someone
    /// rewrote since is already a heart-rate value and is kept. The target is then dropped: a later lift at that
    /// key snapshots it afresh. The day of the workout is re-settled by Step C's orphan sweep.
    private static func sweepOrphanWorkoutTargets(db: Database, now: Int,
                                                  result: inout LiftStrainApplyResult) throws {
        let orphans = try Row.fetchAll(db, sql: """
            SELECT t.* FROM liftStrainTarget t
             WHERE t.kind = 'workout' AND (t.appliedMuscularLoad > 0 OR t.writtenStrain IS NOT t.hrOnlyStrain)
               AND NOT EXISTS (SELECT 1 FROM liftStrain ls
                                WHERE ls.deviceId = t.deviceId AND ls.workoutStartTs = t.keyTs
                                  AND ls.workoutSport = t.keyText AND ls.state != 'detached')
            """)
        for t in orphans {
            let deviceId: String = t["deviceId"]
            let keyTs: Int = t["keyTs"]
            let keyText: String = t["keyText"]
            if let w = try Row.fetchOne(db, sql: """
                SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?
                """, arguments: [deviceId, keyTs, keyText]) {
                let current = LiftStrainPair(strain: w["strain"], version: w["strainVersion"])
                let written = LiftStrainPair(strain: t["writtenStrain"], version: t["writtenStrainVersion"])
                if current.same(written) {
                    let orig = LiftStrainPair(strain: t["origStrain"], version: t["origStrainVersion"])
                    let hrOnly: Double? = t["hrOnlyStrain"]
                    // Same rule as the revert: never a version-2 NULL, and the original pair when it is the
                    // heart-rate value.
                    let restored: LiftStrainPair
                    if let hrOnly, !LiftStrainBits.same(hrOnly, orig.strain) {
                        restored = LiftStrainPair(strain: hrOnly, version: 2)
                    } else {
                        restored = orig
                    }
                    if !restored.same(current) {
                        try db.execute(sql: """
                            UPDATE workout SET strain = ?, strainVersion = ?
                             WHERE deviceId = ? AND startTs = ? AND sport = ? AND strain IS ?
                            """, arguments: [restored.strain, restored.version, deviceId, keyTs, keyText, current.strain])
                        if db.changesCount > 0 { result.workoutWrites += 1 } else { result.conflicts += 1 }
                    }
                }
            }
            try db.execute(sql: """
                DELETE FROM liftStrainTarget WHERE deviceId = ? AND kind = 'workout' AND keyTs = ? AND keyText = ?
                """, arguments: [deviceId, keyTs, keyText])
        }
    }

    /// The applied-lift join behind M_day: a lift counts only while its workout still holds the value we wrote.
    private static let appliedLoadJoin = """
        FROM liftStrain ls
        JOIN workout w ON w.deviceId = ls.deviceId AND w.startTs = ls.workoutStartTs AND w.sport = ls.workoutSport
        WHERE ls.state = 'applied' AND ls.appliedMuscularLoad > 0
          AND w.strainVersion = 2 AND w.strain IS ls.combinedStrain
        """

    /// Step C: the days that need a settle besides the visited rows' days and `extraDayKeys`.
    private static func collectLiftStrainDays(db: Database, canonical: String, disabled: Bool,
                                              into days: inout Set<String>) throws {
        // Day rows rewritten by someone else since the apply recorded them.
        days.formUnion(try String.fetchAll(db, sql: """
            SELECT t.keyText FROM liftStrainTarget t
              JOIN dailyMetric d ON d.deviceId = t.deviceId AND d.day = t.keyText
             WHERE t.kind = 'day' AND (d.strain IS NOT t.writtenStrain OR d.strainVersion IS NOT t.writtenStrainVersion)
            """))

        // Applied lift days that have a day row without a day target. Every row the dashboard can pick is a
        // candidate: the canonical computed row and each lift owner's own "<owner>-noop" row, so a row written
        // after the first settle of the day (for example by a transient engine) is settled on the next apply.
        days.formUnion(try String.fetchAll(db, sql: """
            SELECT DISTINCT ls.dayKey \(appliedLoadJoin)
               AND EXISTS (SELECT 1 FROM dailyMetric d
                            WHERE d.day = ls.dayKey
                              AND (d.deviceId = ?1 OR d.deviceId = ls.deviceId || '-noop')
                              AND NOT EXISTS (SELECT 1 FROM liftStrainTarget t
                                               WHERE t.deviceId = d.deviceId AND t.kind = 'day'
                                                 AND t.keyTs = 0 AND t.keyText = ls.dayKey))
            """, arguments: [canonical]))

        // Orphan sweep (A5): a day target that recorded a muscular load (or whose written value differs from the
        // heart-rate value) while the lifts that justified it are gone or different now, for example because the
        // owner's data was deleted. Re-settling restores the heart-rate value exactly when M_day is 0.
        let candidates = try Row.fetchAll(db, sql: """
            SELECT deviceId, keyText, appliedMuscularLoad FROM liftStrainTarget
             WHERE kind = 'day' AND (appliedMuscularLoad > 0 OR writtenStrain IS NOT hrOnlyStrain)
            """)
        guard !candidates.isEmpty else { return }
        var loadsByDay: [String: [Double]] = [:]
        if !disabled {
            for r in try Row.fetchAll(db, sql: """
                SELECT ls.dayKey AS dayKey, ls.appliedMuscularLoad AS m \(appliedLoadJoin)
                   AND ls.dayKey IN (SELECT keyText FROM liftStrainTarget
                                      WHERE kind = 'day' AND (appliedMuscularLoad > 0 OR writtenStrain IS NOT hrOnlyStrain))
                """) {
                loadsByDay[r["dayKey"], default: []].append(r["m"])
            }
        }
        for c in candidates {
            let day: String = c["keyText"]
            let applied: Double = c["appliedMuscularLoad"]
            if LiftStrainBits.dayLoad(loadsByDay[day] ?? []) != applied { days.insert(day) }
        }
    }

    /// Step D for one logical day.
    private static func settleLiftStrainDay(
        db: Database, day: String, canonical: String, disabled: Bool, now: Int, combine: LiftStrainCombine,
        dayCombine: LiftStrainDayCombine?, result: inout LiftStrainApplyResult
    ) throws {
        // M_day is per user, not per owner: every owner's applied lifts on the day, smallest first.
        let mDay: Double = disabled ? 0 : LiftStrainBits.dayLoad(try Double.fetchAll(db, sql: """
            SELECT ls.appliedMuscularLoad \(appliedLoadJoin) AND ls.dayKey = ?
            """, arguments: [day]))

        // Every existing day row that can be the dashboard's pick for this day.
        var ids: Set<String> = [canonical]
        ids.formUnion(try String.fetchAll(db, sql: """
            SELECT DISTINCT deviceId || '-noop' FROM liftStrain WHERE dayKey = ?
            """, arguments: [day]))
        ids.formUnion(try String.fetchAll(db, sql: """
            SELECT deviceId FROM liftStrainTarget WHERE kind = 'day' AND keyText = ?
            """, arguments: [day]))

        for id in ids.sorted() {
            guard let dRow = try Row.fetchOne(db, sql: """
                SELECT strain, strainVersion FROM dailyMetric WHERE deviceId = ? AND day = ?
                """, arguments: [id, day]) else { continue }  // no row: the pass that creates it settles it
            let hasTarget = try Int.fetchOne(db, sql: """
                SELECT 1 FROM liftStrainTarget WHERE deviceId = ? AND kind = 'day' AND keyTs = 0 AND keyText = ?
                """, arguments: [id, day]) != nil
            if mDay == 0 && !hasTarget { continue }  // days with no applied lifts are never touched

            let current = LiftStrainPair(strain: dRow["strain"], version: dRow["strainVersion"])
            if !hasTarget {
                let formulaVersion = try Int.fetchOne(db, sql: """
                    SELECT MAX(formulaVersion) FROM liftStrain WHERE dayKey = ?
                    """, arguments: [day]) ?? 1
                try db.execute(sql: """
                    INSERT OR IGNORE INTO liftStrainTarget
                        (deviceId, kind, keyTs, keyText, origStrain, origStrainVersion, hrOnlyStrain, writtenStrain,
                         writtenStrainVersion, appliedMuscularLoad, formulaVersion, snapshotAt, updatedAt)
                    VALUES (?, 'day', 0, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    """, arguments: [id, day, current.strain, current.version, current.strain, current.strain,
                                     current.version, formulaVersion, now, now])
            }
            let t = try fetchTarget(db, deviceId: id, kind: "day", keyTs: 0, keyText: day)
            let base: Double? = current.same(t.written) ? t.hrOnly : current.strain

            var load = 0.0
            var stored = current
            if current.version == 2, let base {
                load = mDay
                let target = mDay > 0 ? (dayCombine?(day, base, mDay) ?? combine(base, mDay)) : base
                if !LiftStrainBits.same(target, current.strain) {
                    try db.execute(sql: """
                        UPDATE dailyMetric SET strain = ?, strainVersion = 2
                         WHERE deviceId = ? AND day = ? AND strain IS ?
                        """, arguments: [target, id, day, current.strain])
                    if db.changesCount == 0 {
                        result.conflicts += 1
                        continue
                    }
                    result.dayWrites += 1
                    stored = LiftStrainPair(strain: target, version: 2)
                }
            }
            if !LiftStrainBits.same(t.hrOnly, base) || !t.written.same(stored) || t.applied != load {
                try db.execute(sql: """
                    UPDATE liftStrainTarget
                       SET hrOnlyStrain = ?, writtenStrain = ?, writtenStrainVersion = ?, appliedMuscularLoad = ?, updatedAt = ?
                     WHERE deviceId = ? AND kind = 'day' AND keyTs = 0 AND keyText = ?
                    """, arguments: [base, stored.strain, stored.version, load, now, id, day])
            }
        }
    }

    // MARK: - Small helpers

    private static func liftStrainRows(db: Database, deviceId: String, ids: [String]) throws -> [LiftStrainRow] {
        try chunked(ids).flatMap { chunk in
            try Row.fetchAll(db, sql: """
                SELECT * FROM liftStrain WHERE deviceId = ? AND liftSessionId IN (\(placeholders(chunk.count)))
                ORDER BY workoutStartTs, liftSessionId
                """, arguments: StatementArguments([deviceId] + chunk)).map(LiftStrainRow.decode)
        }
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private static func chunked(_ values: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }
}
