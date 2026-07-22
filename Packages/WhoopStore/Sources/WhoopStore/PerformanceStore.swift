import Foundation
import GRDB
import WhoopProtocol

public struct AnalysisDayBundle: Equatable, Sendable {
    public let hr: [HRSample]
    public let rr: [RRInterval]
    public let resp: [RespSample]
    public let gravity: [GravitySample]
    public let steps: [StepSample]
    public let skinTemp: [SkinTempSample]
    public let spo2: [SpO2Sample]
    public let events: [WhoopEvent]
    public let sleepState: [SleepStateSample]
}

public struct SleepAuxiliaryMutationResult: Equatable, Sendable {
    public let motionUpdated: Int
    public let sleepStateUpdated: Int
    public let sessionsDeleted: Int
    public var totalChanged: Int { motionUpdated + sleepStateUpdated + sessionsDeleted }
    public init(motionUpdated: Int, sleepStateUpdated: Int, sessionsDeleted: Int) {
        self.motionUpdated = motionUpdated; self.sleepStateUpdated = sleepStateUpdated
        self.sessionsDeleted = sessionsDeleted
    }
}

public struct WorkoutReconcileResult: Equatable, Sendable {
    public let insertedOrUpdated: Int
    public let deleted: Int
    public var totalChanged: Int { insertedOrUpdated + deleted }
    public init(insertedOrUpdated: Int, deleted: Int) {
        self.insertedOrUpdated = insertedOrUpdated; self.deleted = deleted
    }
}

extension WhoopStore {
    /// Reads the complete analysis window from one WAL snapshot, avoiding nine actor/database
    /// round trips and guaranteeing every signal reflects the same committed state.
    public func analysisDayBundle(deviceId: String, from: Int, to: Int, limit: Int) async throws
        -> AnalysisDayBundle {
        try syncRead { db in
            let hr = try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                ) ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, deviceId, from, to, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
            let rr = try Row.fetchAll(db, sql: """
                SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts, seq LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
            let resp = try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
            let gravity = try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
            let steps = try Row.fetchAll(db, sql: """
                SELECT ts, counter, activityClass FROM stepSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"]) }
            let skinTemp = try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"]) }
            let spo2 = try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
            let decoder = JSONDecoder()
            let events = try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts, kind LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row -> WhoopEvent in
                    let json: String = row["payloadJSON"]
                    let payload = (try? decoder.decode([String: ParsedValue].self,
                                                       from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
            let sleepState = try Row.fetchAll(db, sql: """
                SELECT ts, state FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"]) }
            return AnalysisDayBundle(hr: hr, rr: rr, resp: resp, gravity: gravity, steps: steps,
                                     skinTemp: skinTemp, spo2: spo2, events: events,
                                     sleepState: sleepState)
        }
    }

    @discardableResult
    public func applySleepAuxiliaryMutations(
        deviceId: String,
        motionByStart: [Int: [Double]],
        sleepStateByStart: [Int: [Int]],
        deletingSessionStarts: [Int]
    ) async throws -> SleepAuxiliaryMutationResult {
        try syncWrite { db in
            var motionUpdated = 0, sleepStateUpdated = 0, sessionsDeleted = 0
            for (start, values) in motionByStart {
                let json = values.isEmpty ? nil : Self.encodeDoubleArray(values)
                try db.execute(sql: """
                    UPDATE sleepSession SET motionJSON = ?
                    WHERE deviceId = ? AND startTs = ? AND motionJSON IS NOT ?
                    """, arguments: [json, deviceId, start, json])
                motionUpdated += db.changesCount
            }
            for (start, values) in sleepStateByStart {
                let json = values.isEmpty ? nil : Self.encodeIntArray(values)
                try db.execute(sql: """
                    UPDATE sleepSession SET sleepStateJSON = ?
                    WHERE deviceId = ? AND startTs = ? AND sleepStateJSON IS NOT ?
                    """, arguments: [json, deviceId, start, json])
                sleepStateUpdated += db.changesCount
            }
            for start in Set(deletingSessionStarts) {
                try db.execute(sql: "DELETE FROM sleepSession WHERE deviceId = ? AND startTs = ?",
                               arguments: [deviceId, start])
                sessionsDeleted += db.changesCount
            }
            return SleepAuxiliaryMutationResult(motionUpdated: motionUpdated,
                                                sleepStateUpdated: sleepStateUpdated,
                                                sessionsDeleted: sessionsDeleted)
        }
    }

    /// Reconciles detector-owned rows only; manual/imported workouts are never deleted.
    @discardableResult
    public func reconcileDetectedWorkouts(
        _ rows: [WorkoutRow], deviceId: String, from: Int, to: Int
    ) async throws -> WorkoutReconcileResult {
        try syncWrite { db in
            let desiredKeys = Set(rows.map { "\($0.startTs)\u{1F}\($0.sport)" })
            let existing = try Row.fetchAll(db, sql: """
                SELECT startTs, sport FROM workout
                WHERE deviceId = ? AND startTs >= ? AND startTs <= ?
                  AND (source = ? OR source = 'detected')
                """, arguments: [deviceId, from, to, deviceId])
            var deleted = 0
            for row in existing {
                let start: Int = row["startTs"]
                let sport: String = row["sport"]
                guard !desiredKeys.contains("\(start)\u{1F}\(sport)") else { continue }
                try db.execute(sql: "DELETE FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                               arguments: [deviceId, start, sport])
                deleted += db.changesCount
            }
            var changed = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO workout
                        (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                         avgHr, maxHr, strain, distanceM, zonesJSON, notes, strainVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs, source = excluded.source,
                        durationS = excluded.durationS, energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr, maxHr = excluded.maxHr,
                        strain = excluded.strain, distanceM = excluded.distanceM,
                        zonesJSON = excluded.zonesJSON, notes = excluded.notes,
                        strainVersion = excluded.strainVersion
                    WHERE workout.endTs IS NOT excluded.endTs OR workout.source IS NOT excluded.source
                       OR workout.durationS IS NOT excluded.durationS OR workout.energyKcal IS NOT excluded.energyKcal
                       OR workout.avgHr IS NOT excluded.avgHr OR workout.maxHr IS NOT excluded.maxHr
                       OR workout.strain IS NOT excluded.strain OR workout.distanceM IS NOT excluded.distanceM
                       OR workout.zonesJSON IS NOT excluded.zonesJSON OR workout.notes IS NOT excluded.notes
                       OR workout.strainVersion IS NOT excluded.strainVersion
                    """, arguments: [deviceId, r.startTs, r.endTs, r.sport, r.source, r.durationS,
                                     r.energyKcal, r.avgHr, r.maxHr, r.strain, r.distanceM,
                                     r.zonesJSON, r.notes, r.strainVersion])
                changed += db.changesCount
            }
            return WorkoutReconcileResult(insertedOrUpdated: changed, deleted: deleted)
        }
    }
}
