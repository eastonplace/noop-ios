#if DEBUG && os(iOS)
import Foundation
import GRDB
import WhoopStore
import UIKit

/// An opt-in local report. This reads the store and never changes its records.
enum DebugSleepSyncProbe {
    struct InitialSeriesSchedule: Sendable {
        let readinessAttempts: Int
        let readinessDelay: Duration
        let captureCount: Int
        let captureDelay: Duration

        static let live = InitialSeriesSchedule(
            readinessAttempts: 120,
            readinessDelay: .seconds(1),
            captureCount: 4,
            captureDelay: .seconds(20)
        )
    }

    @MainActor
    static func runInitialSeries(
        schedule: InitialSeriesSchedule,
        isStoreReady: () async -> Bool,
        pause: (Duration) async -> Void,
        export: (Int) async -> Void
    ) async -> Bool {
        guard schedule.readinessAttempts > 0, schedule.captureCount > 0 else { return false }
        for attempt in 0..<schedule.readinessAttempts {
            if await isStoreReady() {
                for sequence in 0..<schedule.captureCount {
                    if sequence > 0 { await pause(schedule.captureDelay) }
                    await export(sequence)
                }
                return true
            }
            if attempt + 1 < schedule.readinessAttempts {
                await pause(schedule.readinessDelay)
            }
        }
        return false
    }

    @MainActor
    static func runInitialSeries(
        repo: Repository,
        health: HealthKitBridge,
        intelligence: IntelligenceEngine
    ) async {
        let schedule = InitialSeriesSchedule.live
        let completed = await runInitialSeries(
            schedule: schedule,
            isStoreReady: { await repo.storeHandle() != nil },
            pause: { duration in try? await Task.sleep(for: duration) },
            export: { sequence in
                await export(
                    repo: repo,
                    health: health,
                    intelligence: intelligence,
                    sequence: sequence
                )
            }
        )
        if !completed {
            NSLog(
                "Sleep sync probe skipped: store unavailable after %d readiness attempts",
                schedule.readinessAttempts
            )
        }
    }

    @MainActor
    static func export(repo: Repository, health: HealthKitBridge,
                       intelligence: IntelligenceEngine, sequence: Int) async {
        guard let store = await repo.storeHandle(),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -5, to: Calendar.current.startOfDay(for: now))!
        let sourceIds = repo.importedReadIds
        let writer = store.registryWriter
        do {
            let data = try await Task.detached(priority: .utility) {
                try snapshot(writer: writer, sourceIds: sourceIds,
                             start: Int(start.timeIntervalSince1970), end: Int(now.timeIntervalSince1970))
            }.value
            var report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            report["activeSource"] = repo.deviceId
            report["capturedAt"] = Date().timeIntervalSince1970
            report["sequence"] = sequence
            report["analysisComputing"] = intelligence.computing
            report["analysisNote"] = intelligence.note as Any? ?? NSNull()
            report["scoringPhase"] = HealthKitScoringCoordinator.shared.diagnosticPhase
            report["analysisResults"] = intelligence.results.filter {
                $0.day >= Repository.localDayKey(start)
            }.map { ["day": $0.day, "sleep": $0.sleepMin as Any? ?? NSNull(),
                     "hrv": $0.hrv as Any? ?? NSNull(), "recovery": $0.recovery as Any? ?? NSNull()] }
            report["publishedDays"] = repo.days.filter { $0.day >= Repository.localDayKey(start) }.map {
                ["day": $0.day, "sleep": $0.totalSleepMin as Any? ?? NSNull(),
                 "hrv": $0.avgHrv as Any? ?? NSNull(), "recovery": $0.recovery as Any? ?? NSNull()]
            }
            report["healthError"] = health.lastError as Any? ?? NSNull()
            report["scoringRunning"] = HealthKitScoringCoordinator.shared.isRunning
            report["publicationBlocked"] = RepositoryPublicationBarrier.shared.blocksRefreshes
            if let snapshot = repo.todayHealthSnapshot {
                report["displaySnapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
            }
            report["logTail"] = Array(LiveState.persistedLogTail().suffix(100))
            for key in ["healthKit.pendingSyncWindow.v1", "healthKit.pendingScoringWindow.v1"] {
                if let value = UserDefaults.standard.data(forKey: key) {
                    report[key] = try JSONSerialization.jsonObject(with: value)
                }
            }
            let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: documents.appendingPathComponent("noop-sleep-sync-probe.json"), options: .atomic)
            try output.write(to: documents.appendingPathComponent("noop-sleep-sync-probe-\(sequence).json"), options: .atomic)
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
               let window = scene.windows.first(where: \.isKeyWindow) {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try image.pngData()?.write(to: documents.appendingPathComponent("noop-sleep-sync-probe-\(sequence).png"), options: .atomic)
            }
            NSLog("Sleep sync probe saved (%d bytes)", output.count)
        } catch {
            try? String(describing: error).write(
                to: documents.appendingPathComponent("noop-sleep-sync-probe-error.txt"),
                atomically: true, encoding: .utf8)
        }
    }

    private static func snapshot(writer: any DatabaseWriter, sourceIds: [String], start: Int, end: Int) throws -> Data {
        try writer.read { db in
            func rows(_ sql: String, _ arguments: StatementArguments = []) throws -> [[String: Any]] {
                try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                    var object: [String: Any] = [:]
                    for (name, value) in row {
                        switch value.storage {
                        case .null: object[name] = NSNull()
                        case .int64(let value): object[name] = value
                        case .double(let value): object[name] = value.isFinite ? value as Any : NSNull()
                        case .string(let value): object[name] = value
                        case .blob(let value): object[name] = ["byteCount": value.count]
                        }
                    }
                    return object
                }
            }
            var report: [String: Any] = ["start": start, "end": end]
            var errors: [String: String] = [:]
            func section(_ name: String, _ sql: String, _ arguments: StatementArguments = []) {
                do { report[name] = try rows(sql, arguments) }
                catch { errors[name] = String(describing: error) }
            }
            section("daily", "SELECT * FROM dailyMetric WHERE day >= date(?, 'unixepoch') ORDER BY day, deviceId", [start])
            section("sleep", "SELECT * FROM sleepSession WHERE endTs >= ? ORDER BY startTs LIMIT 100", [start])
            section("overrides", "SELECT * FROM sleepRecoveryDailyOverride WHERE day >= date(?, 'unixepoch') ORDER BY day", [start])
            section("attempts", "SELECT * FROM sleepRecoveryAttempt WHERE requestedEndTs >= ? ORDER BY updatedAt DESC LIMIT 30", [start])
            section("devices", "SELECT * FROM device")
            section("queueSchema", "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND (name LIKE '%historical%' OR name LIKE '%projection%' OR name LIKE '%publication%' OR name LIKE '%registry%')")
            for table in ["historicalMaterializationJob", "historicalAnalysisWork"] {
                section(table + "Counts", "SELECT state, COUNT(*) AS count FROM \(table) GROUP BY state")
                section(table + "Recent", "SELECT * FROM \(table) ORDER BY updatedAt DESC LIMIT 20")
            }
            section("analysisFailures", "SELECT lastErrorCode, COUNT(*) AS count, MIN(minimumTs) AS firstTs, MAX(maximumTs) AS lastTs FROM historicalAnalysisWork WHERE state = 'quarantined' GROUP BY lastErrorCode")
            section("materializationRanges", "SELECT state, COUNT(*) AS count, MIN(mappedRawMinTs) AS firstTs, MAX(mappedRawMaxTs) AS lastTs FROM historicalMaterializationJob GROUP BY state")
            var ids = Set(sourceIds + ["my-whoop", "apple-health"])
            if let devices = try? rows("SELECT id FROM device") {
                for device in devices { if let id = device["id"] as? String { ids.insert(id) } }
            }
            var coverage: [[String: Any]] = []
            for id in ids.sorted() {
                for table in ["hrSample", "rrInterval", "gravitySample", "respSample", "skinTempSample", "spo2Sample"] {
                    do {
                        let values = try rows("SELECT ts / 3600 AS utcHour, COUNT(*) AS count, MIN(ts) AS firstTs, MAX(ts) AS lastTs FROM \(table) WHERE deviceId = ? AND ts >= ? AND ts <= ? GROUP BY ts / 3600 ORDER BY utcHour", [id, start, end])
                        if !values.isEmpty { coverage.append(["source": id, "stream": table, "hours": values]) }
                    } catch { errors[table + ":" + id] = String(describing: error) }
                }
            }
            report["coverage"] = coverage
            report["errors"] = errors
            return try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        }
    }
}
#endif
