import GRDB

extension WhoopStore {
    /// Focused feature migrations kept next to the recovery store API. They are invoked
    /// under the same process-wide open gate as the main migrator, so concurrent cold
    /// launches cannot race them. GRDB records the stable identifiers in `grdb_migrations`.
    static func migrateSleepRecoverySchema(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("sleep-window-recovery-v1") { db in
            try db.create(table: "sleepRecoveryAttempt") { table in
                table.column("id", .text).primaryKey()
                table.column("deviceId", .text).notNull()
                table.column("source", .text).notNull()
                table.column("requestedStartTs", .integer).notNull()
                table.column("requestedEndTs", .integer).notNull()
                table.column("outcome", .text).notNull()
                table.column("confidence", .double).notNull()
                table.column("reason", .text).notNull()
                table.column("resultStartTs", .integer)
                table.column("resultEndTs", .integer)
                table.column("stagesAvailable", .boolean).notNull().defaults(to: false)
                table.column("restingHr", .integer)
                table.column("avgHrv", .double)
                table.column("algorithmVersion", .text).notNull()
                table.column("createdAt", .integer).notNull()
                table.column("updatedAt", .integer).notNull()
            }
            try db.create(
                index: "idx_sleepRecoveryAttempt_device_updated",
                on: "sleepRecoveryAttempt",
                columns: ["deviceId", "updatedAt"])
            try db.create(
                index: "idx_sleepRecoveryAttempt_device_window",
                on: "sleepRecoveryAttempt",
                columns: ["deviceId", "requestedStartTs", "requestedEndTs"])
        }

        // The normal analytics pass deletes/rebuilds computed daily rows from automatic
        // detections. A detector-missed but user-recovered night therefore needs a small,
        // durable overlay or the next pass would erase its Rest/Charge again. The triggers
        // preserve ONLY the corrected sleep/recovery fields; activity, steps, calories,
        // workouts and other daily signals continue to come from the latest engine row.
        migrator.registerMigration("sleep-window-recovery-daily-v1") { db in
            try db.create(table: "sleepRecoveryDailyOverride") { table in
                table.column("deviceId", .text).notNull()
                table.column("day", .text).notNull()
                table.column("sessionStartTs", .integer).notNull()
                table.column("totalSleepMin", .double)
                table.column("efficiency", .double)
                table.column("deepMin", .double)
                table.column("remMin", .double)
                table.column("lightMin", .double)
                table.column("disturbances", .integer)
                table.column("restingHr", .integer)
                table.column("avgHrv", .double)
                table.column("recovery", .double)
                table.column("restScore", .double)
                table.column("updatedAt", .integer).notNull()
                table.primaryKey(["deviceId", "day"])
            }
            try db.create(
                index: "idx_sleepRecoveryDailyOverride_session",
                on: "sleepRecoveryDailyOverride",
                columns: ["deviceId", "sessionStartTs"])

            let applyDaily = """
                UPDATE dailyMetric
                SET totalSleepMin = (SELECT totalSleepMin FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    efficiency = (SELECT efficiency FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    deepMin = (SELECT deepMin FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    remMin = (SELECT remMin FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    lightMin = (SELECT lightMin FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    disturbances = (SELECT disturbances FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    restingHr = (SELECT restingHr FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    avgHrv = (SELECT avgHrv FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day),
                    recovery = (SELECT recovery FROM sleepRecoveryDailyOverride o WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day)
                WHERE deviceId = NEW.deviceId AND day = NEW.day;
                """
            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_daily_insert
                AFTER INSERT ON dailyMetric
                WHEN EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day
                )
                BEGIN
                    \(applyDaily)
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_daily_update
                AFTER UPDATE OF totalSleepMin, efficiency, deepMin, remMin, lightMin,
                                disturbances, restingHr, avgHrv, recovery ON dailyMetric
                WHEN EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day
                )
                AND EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day
                      AND (NEW.totalSleepMin IS NOT o.totalSleepMin
                       OR NEW.efficiency IS NOT o.efficiency
                       OR NEW.deepMin IS NOT o.deepMin
                       OR NEW.remMin IS NOT o.remMin
                       OR NEW.lightMin IS NOT o.lightMin
                       OR NEW.disturbances IS NOT o.disturbances
                       OR NEW.restingHr IS NOT o.restingHr
                       OR NEW.avgHrv IS NOT o.avgHrv
                       OR NEW.recovery IS NOT o.recovery)
                )
                BEGIN
                    \(applyDaily)
                END;
                """)

            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_daily_delete
                AFTER DELETE ON dailyMetric
                WHEN EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.day = OLD.day
                )
                BEGIN
                    INSERT INTO dailyMetric
                        (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                         disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                         spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                         spo2Red, spo2Ir, strainVersion)
                    SELECT OLD.deviceId, OLD.day,
                           o.totalSleepMin, o.efficiency, o.deepMin, o.remMin, o.lightMin,
                           o.disturbances, o.restingHr, o.avgHrv, o.recovery,
                           OLD.strain, OLD.exerciseCount, OLD.spo2Pct, OLD.skinTempDevC,
                           OLD.respRateBpm, OLD.steps, OLD.activeKcalEst,
                           OLD.spo2Red, OLD.spo2Ir, OLD.strainVersion
                    FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.day = OLD.day;
                END;
                """)

            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_series_insert
                AFTER INSERT ON metricSeries
                WHEN NEW.key = 'sleep_performance'
                 AND EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day AND o.restScore IS NOT NULL
                 )
                BEGIN
                    UPDATE metricSeries
                    SET value = (SELECT restScore FROM sleepRecoveryDailyOverride o
                                 WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day)
                    WHERE deviceId = NEW.deviceId AND day = NEW.day AND key = NEW.key;
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_series_update
                AFTER UPDATE OF value ON metricSeries
                WHEN NEW.key = 'sleep_performance'
                 AND EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day
                      AND o.restScore IS NOT NULL AND NEW.value IS NOT o.restScore
                 )
                BEGIN
                    UPDATE metricSeries
                    SET value = (SELECT restScore FROM sleepRecoveryDailyOverride o
                                 WHERE o.deviceId = NEW.deviceId AND o.day = NEW.day)
                    WHERE deviceId = NEW.deviceId AND day = NEW.day AND key = NEW.key;
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_series_delete
                AFTER DELETE ON metricSeries
                WHEN OLD.key = 'sleep_performance'
                 AND EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.day = OLD.day AND o.restScore IS NOT NULL
                 )
                BEGIN
                    INSERT INTO metricSeries (deviceId, day, key, value)
                    SELECT OLD.deviceId, OLD.day, OLD.key, o.restScore
                    FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.day = OLD.day;
                END;
                """)

            // The cleanup migration below replaces this first version. Keeping it here
            // preserves deterministic migration history for databases that already ran it.
            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_session_delete
                AFTER DELETE ON sleepSession
                BEGIN
                    DELETE FROM sleepRecoveryDailyOverride
                    WHERE deviceId = OLD.deviceId AND sessionStartTs = OLD.startTs;
                END;
                """)
        }

        // Editing or deleting a recovered session must never leave the prior derived
        // Rest/Charge behind. Null the protected overlay first (so its own protection
        // triggers cannot restore stale values), clear the visible derived fields, then
        // release the overlay. The normal edit/delete flow immediately runs analytics and
        // may repopulate whatever remains defensible from the corrected session/raw data.
        migrator.registerMigration("sleep-window-recovery-invalidation-v1") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS sleepRecoveryDailyOverride_after_session_delete")

            let invalidate = """
                UPDATE sleepRecoveryDailyOverride
                SET totalSleepMin = NULL,
                    efficiency = NULL,
                    deepMin = NULL,
                    remMin = NULL,
                    lightMin = NULL,
                    disturbances = NULL,
                    restingHr = NULL,
                    avgHrv = NULL,
                    recovery = NULL,
                    restScore = NULL,
                    updatedAt = CAST(strftime('%s','now') AS INTEGER)
                WHERE deviceId = OLD.deviceId AND sessionStartTs = OLD.startTs;

                UPDATE dailyMetric
                SET totalSleepMin = NULL,
                    efficiency = NULL,
                    deepMin = NULL,
                    remMin = NULL,
                    lightMin = NULL,
                    disturbances = NULL,
                    restingHr = NULL,
                    avgHrv = NULL,
                    recovery = NULL
                WHERE deviceId = OLD.deviceId
                  AND day = (SELECT day FROM sleepRecoveryDailyOverride
                             WHERE deviceId = OLD.deviceId AND sessionStartTs = OLD.startTs);

                DELETE FROM metricSeries
                WHERE deviceId = OLD.deviceId
                  AND day = (SELECT day FROM sleepRecoveryDailyOverride
                             WHERE deviceId = OLD.deviceId AND sessionStartTs = OLD.startTs)
                  AND key = 'sleep_performance';

                DELETE FROM sleepRecoveryDailyOverride
                WHERE deviceId = OLD.deviceId AND sessionStartTs = OLD.startTs;
                """

            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_session_delete
                AFTER DELETE ON sleepSession
                WHEN EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.sessionStartTs = OLD.startTs
                )
                BEGIN
                    \(invalidate)
                END;
                """)

            try db.execute(sql: """
                CREATE TRIGGER sleepRecoveryDailyOverride_after_session_bounds_update
                AFTER UPDATE OF startTsAdjusted, endTs ON sleepSession
                WHEN EXISTS (
                    SELECT 1 FROM sleepRecoveryDailyOverride o
                    WHERE o.deviceId = OLD.deviceId AND o.sessionStartTs = OLD.startTs
                )
                AND (NEW.startTsAdjusted IS NOT OLD.startTsAdjusted OR NEW.endTs IS NOT OLD.endTs)
                BEGIN
                    \(invalidate)
                END;
                """)
        }

        try migrator.migrate(writer)
    }
}
