import GRDB

/// v59: storage for "Strength Strain on every lift".
///
/// Schema only. No data is created, copied or rewritten at migration time, so a database that never saves a lift
/// is byte-for-byte unchanged apart from four empty tables and their indexes.
///
/// - `liftStrain`: one row per lift session, holding what the app computed from the logged sets (dose, volume,
///   muscular load) next to the bookkeeping of what was applied to the stored Strain.
/// - `liftStrainTarget`: one row per stored Strain value that was ever combined (a workout row or a computed day
///   row). It snapshots the original `(strain, strainVersion)` so the combine is idempotent and can be reverted
///   bit for bit.
/// - `liftStrainJob`: the durable, resumable one-time backfill, keyed by formula version and lift owner.
/// - `liftStrainControl`: one global row. A missing row means enabled.
public enum LiftStrainMigration {
    public static let identifier = "v59-lift-strain"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS liftStrain (
                  deviceId TEXT NOT NULL,
                  liftSessionId TEXT NOT NULL,
                  workoutStartTs INTEGER NOT NULL, workoutSport TEXT NOT NULL, dayKey TEXT NOT NULL,
                  formulaVersion INTEGER NOT NULL, bodyweightKg REAL NOT NULL, bodyweightIsDefault INTEGER NOT NULL DEFAULT 0,
                  dose REAL NOT NULL, volume REAL NOT NULL, muscularLoad REAL NOT NULL,
                  workingSets INTEGER NOT NULL, warmupSets INTEGER NOT NULL, countedSets INTEGER NOT NULL,
                  skippedJSON TEXT NOT NULL, unmappedSets INTEGER NOT NULL,
                  hrOnlyStrain REAL, combinedStrain REAL, appliedMuscularLoad REAL NOT NULL DEFAULT 0,
                  state TEXT NOT NULL DEFAULT 'pending',
                  computedAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
                  PRIMARY KEY (deviceId, liftSessionId))
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS liftStrain_workout ON liftStrain(deviceId, workoutStartTs, workoutSport)
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS liftStrain_day ON liftStrain(dayKey)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS liftStrain_state ON liftStrain(state)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS liftStrainTarget (
                  deviceId TEXT NOT NULL,
                  kind TEXT NOT NULL,
                  keyTs INTEGER NOT NULL, keyText TEXT NOT NULL,
                  origStrain REAL, origStrainVersion INTEGER,
                  hrOnlyStrain REAL, writtenStrain REAL, writtenStrainVersion INTEGER,
                  appliedMuscularLoad REAL NOT NULL DEFAULT 0, formulaVersion INTEGER NOT NULL,
                  snapshotAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL,
                  PRIMARY KEY (deviceId, kind, keyTs, keyText))
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS liftStrainTarget_day ON liftStrainTarget(kind, keyText)
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS liftStrainJob (
                  jobKey TEXT PRIMARY KEY NOT NULL, deviceId TEXT NOT NULL, formulaVersion INTEGER NOT NULL,
                  state TEXT NOT NULL,
                  cursorDay TEXT, upperDay TEXT NOT NULL,
                  liftsApplied INTEGER NOT NULL DEFAULT 0, liftsSkipped INTEGER NOT NULL DEFAULT 0,
                  daysApplied INTEGER NOT NULL DEFAULT 0, conflicts INTEGER NOT NULL DEFAULT 0,
                  startedAt INTEGER NOT NULL, completedAt INTEGER, refreshedAt INTEGER)
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS liftStrainControl (
                  scope TEXT PRIMARY KEY NOT NULL,
                  disabled INTEGER NOT NULL DEFAULT 0, reason TEXT, updatedAt INTEGER NOT NULL)
                """)
        }
    }
}
