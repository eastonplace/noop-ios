import GRDB

/// The tables owned by the Lift Log. Every row carries `deviceId` so the parent privacy-delete path
/// can clear the feature without relying on foreign keys.
public enum LiftLogSchema {
    public static let migrationIdentifier = "v40-lift-log"
    public static let deviceScopedTables = [
        "liftExercise", "liftProgram", "liftProgramItem", "liftSession", "liftSet",
        LiftReceiptStateSchema.tableName,
    ]
}

/// Additive persistence for programs, sessions, and performed sets.
enum LiftLogMigration {
    static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(LiftLogSchema.migrationIdentifier) { db in
            try db.create(table: "liftExercise", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("primaryMuscle", .text)
                t.column("secondaryMuscles", .text)
                t.column("createdAt", .integer).notNull()
                t.column("lastUsedTs", .integer)
            }
            try db.create(index: "idx_liftExercise_natural", on: "liftExercise",
                          columns: ["deviceId", "name"], options: [.unique, .ifNotExists])

            try db.create(table: "liftProgram", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("note", .text)
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("archived", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_liftProgram_device_updatedAt", on: "liftProgram",
                          columns: ["deviceId", "updatedAt"], options: [.ifNotExists])

            try db.create(table: "liftProgramItem", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("programId", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("exercise", .text).notNull()
                t.column("targetSets", .integer)
                t.column("targetRepsLow", .integer)
                t.column("targetRepsHigh", .integer)
                t.column("targetRpe", .double)
                t.column("targetWeightKg", .double)
                t.column("restSec", .integer)
                t.column("note", .text)
            }
            try db.create(index: "idx_liftProgramItem_device", on: "liftProgramItem",
                          columns: ["deviceId"], options: [.ifNotExists])
            try db.create(index: "idx_liftProgramItem_program_ord", on: "liftProgramItem",
                          columns: ["programId", "ord"], options: [.ifNotExists])

            try db.create(table: "liftSession", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer)
                t.column("sport", .text).notNull()
                t.column("programId", .text)
                t.column("programName", .text)
                t.column("sessionRpe", .double)
                t.column("note", .text)
            }
            try db.create(index: "idx_liftSession_natural", on: "liftSession",
                          columns: ["deviceId", "startTs", "sport"], options: [.unique, .ifNotExists])

            try db.create(table: "liftSet", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("exercise", .text).notNull()
                t.column("primaryMuscle", .text)
                t.column("secondaryMuscles", .text)
                t.column("setIndex", .integer).notNull()
                t.column("weightKg", .double)
                t.column("reps", .integer)
                t.column("rpe", .double)
                t.column("isWarmup", .integer).notNull().defaults(to: 0)
                t.column("startTs", .integer)
                t.column("endTs", .integer)
                t.column("restSec", .integer)
                t.column("note", .text)
            }
            try db.create(index: "idx_liftSet_device_exercise", on: "liftSet",
                          columns: ["deviceId", "exercise"], options: [.ifNotExists])
            try db.create(index: "idx_liftSet_session_ord", on: "liftSet",
                          columns: ["sessionId", "ord"], options: [.ifNotExists])
        }
    }
}
