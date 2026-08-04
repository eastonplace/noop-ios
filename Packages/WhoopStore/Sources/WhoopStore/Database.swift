import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams (mirror the existing decoded tables, PK (deviceId, ts)).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v4") { db in
            // Server-derived metrics cached locally (Task 3.1: History = union(phone, server)).
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams (mirrors rawBatch.syncedAt).
            // The OLD upload path used a forward-only highwater per stream, which permanently
            // stranded backfilled (older-ts) rows once the highwater jumped to a recent ts.
            // The fix: `synced` is set to 1 only after a successful upload, so the Uploader can
            // drain WHERE synced=0 regardless of ts order. Existing rows default to 0 → they
            // re-upload once (idempotent server-side), catching up the currently-stranded rows.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the dense BATTERY_LEVEL-event battery series (nullable: the
            // command-response battery path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep signal aggregates cached from /v1/daily so the Sleep tab can display
            // SpO2, skin-temperature deviation, and respiration rate without a network round-trip.
            // All three are nullable: they require sufficient raw biometric data on the server.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        migrator.registerMigration("v8") { db in
            // Journal, workouts, and Apple-Health daily aggregates.
            // journal: one row per (deviceId, day, question), user-answered daily prompts.
            try db.create(table: "journal") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("question", .text).notNull()
                t.column("answeredYes", .integer).notNull()
                t.column("notes", .text)
                t.primaryKey(["deviceId", "day", "question"])
            }
            // workout: one row per (deviceId, startTs, sport). All metric columns nullable.
            try db.create(table: "workout") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationS", .double)
                t.column("energyKcal", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("strain", .double)
                t.column("distanceM", .double)
                t.column("zonesJSON", .text)
                t.column("notes", .text)
                t.primaryKey(["deviceId", "startTs", "sport"])
            }
            // appleDaily: Apple-Health-specific daily aggregates, one row per (deviceId, day).
            // All metric columns nullable.
            try db.create(table: "appleDaily") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("steps", .integer)
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("vo2max", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("walkingHr", .integer)
                t.column("weightKg", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Generic long-format metric store: the substrate for a metric explorer where every
            // metric is queryable/comparable uniformly. One row per (deviceId, day, key); `value`
            // is always a REAL so any scalar metric (server-derived, Apple-Health, journal-encoded,
            // …) can be projected into a single tall table and read back by key with no per-metric
            // schema. Natural key (deviceId, day, key).
            try db.create(table: "metricSeries") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .double).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            // Per-metric range reads scan (deviceId, key) then walk days in order. The PK is
            // (deviceId, day, key) so it can't serve those reads efficiently; this index makes
            // metricSeries(key:from:to:) and metricDays(key:) index-only.
            try db.create(index: "idx_metricSeries_device_key_day",
                          on: "metricSeries", columns: ["deviceId", "key", "day"])
        }

        // v10 (#78): WHOOP5 step_motion_counter persistence (macOS parity with Android's MIGRATION_2_3).
        // Additive only, the strap trims acked history and won't re-send it, so a destructive rebuild
        // would lose it; this preserves every existing row. No `synced` column (unused; see StreamStore).
        migrator.registerMigration("v10") { db in
            try db.create(table: "stepSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v11: on-device daily step total + whole-day calorie estimate on dailyMetric (macOS parity
        // with Android's MIGRATION_2_3). Additive only; both nullable, so existing rows are untouched
        // and an old reader that doesn't SELECT them keeps working.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "steps", .integer)
                t.add(column: "activeKcalEst", .double)
            }
        }

        // v12 (#156): PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer. Stored in its OWN
        // table (not hrSample) so the measured `hr` is never conflated with the derived estimate, reads
        // COALESCE hrSample first, ppgHrSample only where hrSample has no row. Additive only; bpm/conf
        // are REAL (bpm is a float estimate, conf is the 0–1 autocorrelation peak).
        migrator.registerMigration("v12") { db in
            try db.create(table: "ppgHrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("conf", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v13 (#318-adjacent): user-corrected sleep times. A `userEdited` flag on sleepSession marks a
        // session whose wake/sleep bounds the user fixed by hand; the post-sync recompute pass preserves
        // those bounds instead of re-upserting the strap-detected session over them (mirrors Android's
        // `userEdited` guard in IntelligenceEngine, PR #367). Additive + nullable-safe: NOT NULL DEFAULT 0
        // so every existing row reads as un-edited and old readers that don't SELECT it keep working.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "userEdited", .boolean).notNull().defaults(to: false)
            }
        }

        // v14 (#318): user-corrected sleep ONSET. `startTs` stays the immutable detected key (so the
        // recompute guard and daily override keep matching on it); the hand-set bedtime lives here.
        // Nullable, null means "onset not edited, use startTs". Additive, so existing rows/readers are
        // unaffected.
        migrator.registerMigration("v14") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "startTsAdjusted", .integer)
            }
        }

        // v15: the device registry. `deviceId` already keys every sample table (deviceId, ts), so it IS
        // the per-device discriminator, this just gives each device a row with brand/model/capabilities,
        // a single-active invariant (enforced in DeviceRegistryStore), and a dayOwnership override table so
        // one source owns a day's scores (never blended). Additive: the existing WHOOP is seeded with its
        // unchanged id "my-whoop" (zero sample-row migration). INSERT OR IGNORE so re-runs/restores are safe.
        migrator.registerMigration("v15-device-registry") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pairedDevice (
                    id TEXT PRIMARY KEY NOT NULL,
                    brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
                    sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
                    status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dayOwnership (
                    day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
                    deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
                    locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
                );
            """)
            // Seed the registry with the existing WHOOP so nothing is orphaned. selectedWhoopModel lives in
            // the app's UserDefaults; the store can't read it, so seed a neutral "WHOOP" row the app reconciles
            // on first launch from the live model.
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT OR IGNORE INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES ('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', 'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', \(now), \(now));
            """)
        }

        // v16: stable per-strap identity for multi-WHOOP support. `peripheralId` holds the BLE
        // CBPeripheral.identifier.uuidString (iOS/Mac) so NOOP can tell physical straps apart and
        // map a connected peripheral back to its registry row. Additive + nullable: the seeded
        // 'my-whoop' row keeps peripheralId NULL (it still connects to "any WHOOP" today; it adopts
        // its peripheral id later). New straps get id "whoop-<peripheralId>". Old readers that don't
        // SELECT it keep working.
        migrator.registerMigration("v16-paired-device-peripheral") { db in
            try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN peripheralId TEXT")
        }

        // v17 (Lab Book): the Health Records "marker" store, one row per dated reading the USER
        // entered themselves (spec 2026-06-19-v5-health-records-design.md §"New"). This is the richer
        // source-of-truth behind the daily `metricSeries` projection: a single day can hold several
        // readings, each carries a precise `takenAt` instant and `unit`, and notes / qualitative
        // (`valueText`) results don't fit a REAL-only `metricSeries` cell. Additive only, a NEW table,
        // no existing row touched, so an old reader is unaffected.
        //
        // NON-CLINICAL: holds ONLY user-entered values + an OPTIONAL user-entered `referenceText`
        // (their own report's range, shown back verbatim). NOOP ships no reference-range tables and
        // never asserts normality.
        //
        // `id` is a client-generated stable identifier (so a single reading can be edited/deleted by id
        // and a backup round-trips). The natural key (deviceId, markerKey, takenAt, source) is enforced
        // by a UNIQUE index so re-importing the same reading is idempotent. `value` is nullable (a
        // qualitative entry stores only `valueText`); `day` is the pre-derived yyyy-MM-dd key for the
        // projection. The (deviceId, markerKey, takenAt) index serves per-marker history reads in order.
        migrator.registerMigration("v17-lab-book") { db in
            try db.create(table: "labMarker") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("markerKey", .text).notNull()
                t.column("category", .text).notNull()
                t.column("day", .text).notNull()              // yyyy-MM-dd (projection key)
                t.column("takenAt", .integer).notNull()       // epoch seconds (precise instant)
                t.column("value", .double)                    // nullable: qualitative entries use valueText
                t.column("valueText", .text)
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("note", .text)
                t.column("referenceText", .text)              // user-entered range, verbatim
            }
            // Idempotent re-import: one reading per (deviceId, markerKey, takenAt, source).
            try db.create(index: "idx_labMarker_natural",
                          on: "labMarker",
                          columns: ["deviceId", "markerKey", "takenAt", "source"],
                          unique: true)
            // Per-marker history reads scan (deviceId, markerKey) then walk takenAt in order.
            try db.create(index: "idx_labMarker_device_marker_takenAt",
                          on: "labMarker", columns: ["deviceId", "markerKey", "takenAt"])
            // Per-category grouping for the Lab Book screen.
            try db.create(index: "idx_labMarker_device_category",
                          on: "labMarker", columns: ["deviceId", "category"])
        }

        // v18 (H8 + H2-persist): per-SLEEP-SESSION analytics the stager/interpreter already compute then
        // discard, banked alongside the existing `stagesJSON` on the same row (deviceId, startTs).
        //   • `motionJSON`, a compact JSON array of per-epoch motion magnitudes (the SleepStager's
        //                        per-epoch restlessness signal), one entry per stage epoch, SAME 30 s grid
        //                        as `stagesJSON`. Persisting it lets restlessness/wake-fragmentation read a
        //                        real per-epoch series instead of recomputing the whole stager.
        //   • `sleepStateJSON`, a compact JSON array of the decoded v18 band state per epoch (the
        //                        Interpreter's `(sb>>4)&3`), so the strap's own banked sleep/wake band is
        //                        durable rather than dropped after decode (H2 persist half).
        // Both nullable TEXT: every existing row reads back null (no per-epoch series yet), old readers that
        // don't SELECT them keep working, and a session with no raw/banked epoch data simply stores null,         // an ABSENT signal stays absent, never a fabricated zero series. Additive ALTERs only (no data
        // touched), so already-offloaded raw streams survive (the strap trims acked history and won't
        // re-send it). Twin of Android's MIGRATION_11_12.
        migrator.registerMigration("v18-sleep-motion-state") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "motionJSON", .text)
                t.add(column: "sleepStateJSON", .text)
            }
        }

        // v19 (#316 / @63 activity class): the per-record activity-class enum the decoder ALREADY reads off
        // @63 (0=still, 1=walk, 2=run; 0xFF/invalid stores nothing) but which was DROPPED at the storage
        // boundary, `StepSample` carried `activityClass` yet the v10 stepSample INSERT only listed
        // (deviceId, ts, counter), so it could never be persisted, read, or shown. This ALTER adds a NULLABLE
        // `activityClass INTEGER` to stepSample: additive only, no DEFAULT (a null means "no class for this
        // record", an absent signal stays absent, never a fabricated 0/"still"), so every existing row reads
        // back null and an old reader that doesn't SELECT it keeps working. Already-offloaded raw streams
        // survive (the strap trims acked history and won't re-send it). Twin of Android's MIGRATION_12_13.
        migrator.registerMigration("v19-step-activity-class") { db in
            try db.alter(table: "stepSample") { t in
                t.add(column: "activityClass", .integer)
            }
        }

        // v20 (#322 / task #53 numeric journal): a journal entry can carry a NUMERIC value (e.g.
        // "caffeine mg", "alcohol units") alongside the yes/no answer, not only a toggle. This ALTER adds
        // a NULLABLE `numericValue REAL` to `journal`: additive only, no DEFAULT (a null means "this row is
        // a plain yes/no answer with no numeric reading", which is every existing row + every imported WHOOP
        // row, so history reads back unchanged). A numeric log writes answeredYes=1 AND numericValue=v, so
        // the existing BehaviorInsights with/without split keeps working untouched; the value is carried for
        // dose-response later. Twin of Android's MIGRATION_13_14.
        migrator.registerMigration("v20-journal-numeric") { db in
            try db.alter(table: "journal") { t in
                t.add(column: "numericValue", .double)
            }
        }

        // v21 (#175 band sleep-state stream): the strap's OWN per-record band sleep_state (Interpreter's
        // @81 `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up) was DECODED but DROPPED at stream extraction —
        // so the whole band-state chain (the H7 morning-stillness re-onset CONFIRM guard + a Deep Timeline
        // display track) had no source, and the v18 `sleepStateJSON` per-session column was never fed. This
        // adds the RAW per-sample table, keyed by (deviceId, ts) exactly like stepSample/ppgHrSample, so a
        // second's band state is idempotently upserted (ON CONFLICT DO NOTHING) from the offload stream. New
        // table only (no existing data touched); already-offloaded history the strap has trimmed can't be
        // re-sent, so this is forward-looking for straps that emit the field (5/MG v18). `state` is the raw
        // 0-3 code carried VERBATIM — never a fabricated value; a strap that never reports it just has no rows.
        // Twin of Android's MIGRATION_14_15.
        migrator.registerMigration("v21-sleep-state-sample") { db in
            try db.create(table: "sleepStateSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("state", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v22 (Live Sessions): one row per silent-guardian coaching session. Natural key (deviceId, startTs).
        // Records the recovery-gated band it guarded (floor/ceiling bpm) + today's Charge at start, the time
        // split (in-band / below / above seconds), the two cue counts, and the HR source used, so the look-back
        // summary + the streak read entirely from here. `endTs` is nullable while a session is in progress
        // (a crash/kill leaves it open; the app closes it on next launch). All totals NOT NULL DEFAULT 0 so a
        // zero-length session reads cleanly. Additive, NEW table only (no existing row touched), so an old
        // reader is unaffected. See docs/superpowers/specs/2026-07-04-live-sessions-design.md. Twin of
        // Android's MIGRATION_15_16.
        migrator.registerMigration("v22-live-session") { db in
            try db.create(table: "liveSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer)
                t.column("chargeAtStart", .double)
                t.column("floorBpm", .double).notNull()
                t.column("ceilingBpm", .double).notNull()
                t.column("inBandSec", .double).notNull().defaults(to: 0)
                t.column("belowSec", .double).notNull().defaults(to: 0)
                t.column("aboveSec", .double).notNull().defaults(to: 0)
                t.column("pushCount", .integer).notNull().defaults(to: 0)
                t.column("easeCount", .integer).notNull().defaults(to: 0)
                t.column("hrSource", .text).notNull()
                t.primaryKey(["deviceId", "startTs"])
            }
        }

        // v23 (Spec 007 / G4): coaching presentation configuration. These tables reference the
        // existing journal catalog by immutable canonical question string; they never copy, rename,
        // migrate, or replace journal occurrences. The active set and its membership/order/Quick Add
        // flags are additive local configuration only.
        migrator.registerMigration("v23-coaching-behavior-sets") { db in
            try db.create(table: "coachingBehaviorSet") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("isActive", .boolean).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(table: "coachingBehaviorMembership") { t in
                t.column("setId", .text).notNull()
                t.column("canonicalQuestion", .text).notNull()
                t.column("coachingGroup", .text).notNull()
                t.column("sortIndex", .integer).notNull()
                t.column("isActive", .boolean).notNull()
                t.column("isQuickAdd", .boolean).notNull()
                t.primaryKey(["setId", "canonicalQuestion"])
            }
            try db.create(index: "idx_coachingMembership_set_order",
                          on: "coachingBehaviorMembership", columns: ["setId", "sortIndex"])
        }

        // v24 (Spec 007 / G4): coaching stacks are additive configuration plus a provenance log.
        // Stack items reference the existing immutable journal canonical. Logging a checked item still
        // writes the existing journal row through Repository; coachingStackUse records only which stack
        // initiated that write. There is deliberately no second quantity table: doses reuse
        // journal.numericValue + noop-journal-dose exactly as approved at the T130 gate.
        migrator.registerMigration("v24-coaching-stacks") { db in
            try db.create(table: "coachingStack") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("scheduleLabel", .text)
                t.column("isActive", .boolean).notNull()
                t.column("notes", .text)
                t.column("sortIndex", .integer).notNull()
            }
            try db.create(table: "coachingStackItem") { t in
                t.column("stackId", .text).notNull()
                t.column("canonicalQuestion", .text).notNull()
                t.column("dose", .double)
                t.column("unit", .text)
                t.column("sortIndex", .integer).notNull()
                t.primaryKey(["stackId", "canonicalQuestion"])
            }
            try db.create(table: "coachingStackUse") { t in
                t.column("id", .text).primaryKey()
                t.column("stackId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("loggedAt", .integer).notNull()
                t.column("notes", .text)
                t.column("skipped", .boolean).notNull()
            }
            try db.create(index: "idx_coachingStack_order",
                          on: "coachingStack", columns: ["sortIndex"])
            try db.create(index: "idx_coachingStackItem_stack_order",
                          on: "coachingStackItem", columns: ["stackId", "sortIndex"])
            try db.create(index: "idx_coachingStackUse_stack_time",
                          on: "coachingStackUse", columns: ["stackId", "loggedAt"])
        }

        // Private v25 = upstream v23: raw WHOOP 4.0 SpO2 ADC cache.
        migrator.registerMigration("v25-daily-spo2-raw") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Red", .integer)
                t.add(column: "spo2Ir", .integer)
            }
        }

        // Private v26 = upstream v24 (#163): equal R-R beat preservation.
        migrator.registerMigration("v26-rr-seq") { db in
            try db.create(table: "rrInterval_new") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "seq"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
                SELECT deviceId, ts, rrMs,
                       ROW_NUMBER() OVER (PARTITION BY deviceId, ts ORDER BY rrMs) - 1,
                       synced
                FROM rrInterval
                """)
            try db.execute(sql: "DROP TABLE rrInterval")
            try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
        }

        // Private v27 = upstream v26: percentage-to-fraction heal.
        migrator.registerMigration("v27-efficiency-heal") { db in
            try db.execute(sql: """
                UPDATE sleepSession
                SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
            try db.execute(sql: """
                UPDATE dailyMetric
                SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
        }

        // Private v28 = upstream v27 (#156): durable v26 PPG waveform.
        migrator.registerMigration("v28-ppg-waveform") { db in
            try db.create(table: "ppgWaveformSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v29-strain-v2-provenance") { db in
            // A pre-release build could add one or both provenance columns before GRDB recorded
            // this migration identifier. Treat that partially-applied shape as recoverable instead
            // of failing every subsequent store open with "duplicate column name".
            let dailyColumns = try Set(db.columns(in: "dailyMetric").map(\.name))
            if !dailyColumns.contains("strainVersion") {
                try db.alter(table: "dailyMetric") { t in
                    t.add(column: "strainVersion", .integer)
                }
            }
            let workoutColumns = try Set(db.columns(in: "workout").map(\.name))
            if !workoutColumns.contains("strainVersion") {
                try db.alter(table: "workout") { t in
                    t.add(column: "strainVersion", .integer)
                }
            }
            if try !db.tableExists("strainV2Shadow") {
                try db.create(table: "strainV2Shadow") { t in
                    t.column("deviceId", .text).notNull()
                    t.column("day", .text).notNull()
                    t.column("strain", .double).notNull()
                    t.primaryKey(["deviceId", "day"])
                }
            }
        }
        // v26's table rebuild accidentally omitted `rrMs` from the declared key even though every
        // insert has always used ON CONFLICT(deviceId, ts, rrMs, seq). SQLite therefore rejected the
        // statement before ingesting any row. Rebuild once with the intended key; this is lossless for
        // existing databases because the old narrower (deviceId, ts, seq) key was already unique.
        migrator.registerMigration("v30-rr-conflict-key") { db in
            let intendedKey = ["deviceId", "ts", "rrMs", "seq"]
            if try db.primaryKey("rrInterval").columns != intendedKey {
                // Recover safely if a pre-release/aborted migration left the staging table behind.
                if try db.tableExists("rrInterval_v30") {
                    try db.drop(table: "rrInterval_v30")
                }
                try db.create(table: "rrInterval_v30") { t in
                    t.column("deviceId", .text).notNull()
                    t.column("ts", .integer).notNull()
                    t.column("rrMs", .integer).notNull()
                    t.column("seq", .integer).notNull().defaults(to: 0)
                    t.column("synced", .integer).notNull().defaults(to: 0)
                    t.primaryKey(intendedKey)
                }
                try db.execute(sql: """
                    INSERT INTO rrInterval_v30 (deviceId, ts, rrMs, seq, synced)
                    SELECT deviceId, ts, rrMs, seq, synced FROM rrInterval
                    """)
                try db.execute(sql: "DROP TABLE rrInterval")
                try db.execute(sql: "ALTER TABLE rrInterval_v30 RENAME TO rrInterval")
            }
        }
        // v31: HealthKit anchored queries report deletion UUIDs but deliberately omit the original
        // sample dates. Preserve the source UUID-to-window mapping locally so an old deletion or a
        // moved sample can re-aggregate the correct civil days instead of guessing a recent window.
        migrator.registerMigration("v31-healthkit-object-index") { db in
            try db.create(table: "healthKitObjectIndex") { t in
                t.column("deviceId", .text).notNull()
                t.column("sampleType", .text).notNull()
                t.column("objectUUID", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.primaryKey(["deviceId", "sampleType", "objectUUID"])
            }
            try db.create(index: "idx_healthKitObjectIndex_window",
                          on: "healthKitObjectIndex",
                          columns: ["deviceId", "sampleType", "startTs", "endTs"])
        }
        // v32: one durable, source-scoped first-paint snapshot for the current dashboard. This is
        // deliberately a single keyed record, not a second 21-day daily-metrics cache: launch needs
        // exactly one indexed read while the normal repository refresh starts independently.
        migrator.registerMigration("v32-today-health-snapshot") { db in
            try db.create(table: "todayHealthSnapshot") { t in
                t.column("scopeId", .text).notNull().primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("displayDay", .text).notNull()
                t.column("logicalDay", .text).notNull()
                t.column("localDay", .text).notNull()
                t.column("generatedAt", .integer).notNull()
                t.column("rawFrontierTs", .integer)
                t.column("schemaVersion", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(index: "idx_todayHealthSnapshot_device_generated",
                          on: "todayHealthSnapshot",
                          columns: ["deviceId", "generatedAt"])
        }
        // v33: first-paint snapshots need an explicit database/source context. The database UUID lives
        // outside the snapshot row so it survives a snapshot clear, travels with a valid backup, and changes
        // when a replacement database is created. `contextId` lets the UPSERT reject a stale pre-restore
        // writer without decoding JSON inside SQLite.
        migrator.registerMigration("v33-today-health-snapshot-context") { db in
            try db.alter(table: "todayHealthSnapshot") { t in
                t.add(column: "contextId", .text)
            }
            try db.create(table: "todayHealthSnapshotDatabase") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try db.execute(sql: "INSERT INTO todayHealthSnapshotDatabase (id) VALUES (?)",
                           arguments: [UUID().uuidString])
        }
        // v34: order accepted first-paint writes with a durable SQLite sequence. `generatedAt` is a wall
        // clock diagnostic and can move backward after clock correction, restore, or test-time injection.
        // Existing rows start at zero and receive a real generation on their next accepted write.
        migrator.registerMigration("v34-today-health-snapshot-generation") { db in
            try db.alter(table: "todayHealthSnapshot") { t in
                t.add(column: "generation", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "todayHealthSnapshotGeneration") { t in
                t.column("id", .integer).primaryKey()
                t.column("value", .integer).notNull()
            }
            try db.execute(sql: """
                INSERT INTO todayHealthSnapshotGeneration (id, value)
                SELECT 1, COALESCE(MAX(generation), 0) FROM todayHealthSnapshot
                """)
            try db.create(index: "idx_todayHealthSnapshot_generation",
                          on: "todayHealthSnapshot", columns: ["generation"])
        }
        // v35: a historical chunk becomes visible to later analysis only after decoded rows, optional
        // raw capture, its strap trim, and this receipt commit in one SQLite transaction. The database UUID
        // plus device id fence restore, deletion, and re-pair boundaries; generation gives restart-safe order.
        migrator.registerMigration("v35-historical-data-commit-journal") { db in
            // A pre-release build created this table before its migration identifier shipped. Do not make
            // that database unopenable: v36 below rebuilds any existing v35-compatible journal into the
            // current receipt schema and records both migration identifiers.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS historicalDataCommitJournal (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    receiptId TEXT NOT NULL UNIQUE,
                    databaseInstanceId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    chunkEndUnix INTEGER NOT NULL,
                    committedAt INTEGER NOT NULL,
                    rawBatchId TEXT,
                    insertedRowsJSON BLOB NOT NULL,
                    UNIQUE (databaseInstanceId, deviceId, trim)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_historicalDataCommitJournal_database_device_generation
                ON historicalDataCommitJournal (databaseInstanceId, deviceId, generation)
                """)
        }
        // Receipt hardening: a historical commit is identified by the received-frame fingerprint inside a
        // durable device/lineage/cursor scope. Raw capture is evidence attached to that commit, not part of
        // its identity, so changing the research toggle cannot turn a safe replay into a false conflict.
        // The rebuild removes v35's device+trim-only UNIQUE constraint and backfills phase1 rows without
        // discarding their generation or receipt id.
        migrator.registerMigration("v36-historical-data-receipt-hardening") { db in
            if try db.tableExists("pairedDevice") {
                let pairedColumns = Set(try db.columns(in: "pairedDevice").map(\.name))
                if !pairedColumns.contains("historyLineage") {
                    try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN historyLineage TEXT")
                }
                if !pairedColumns.contains("historyCursorEpoch") {
                    try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN historyCursorEpoch INTEGER NOT NULL DEFAULT 0")
                }
                let ids = try String.fetchAll(db, sql: "SELECT id FROM pairedDevice ORDER BY id")
                for id in ids {
                    let lineage = try String.fetchOne(
                        db,
                        sql: "SELECT historyLineage FROM pairedDevice WHERE id = ?",
                        arguments: [id]
                    )
                    if lineage?.isEmpty != false {
                        try db.execute(
                            sql: "UPDATE pairedDevice SET historyLineage = ? WHERE id = ?",
                            arguments: [UUID().uuidString, id]
                        )
                    }
                }
            }

            try db.execute(sql: """
                CREATE TABLE historicalDataCommitJournal_v36 (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    receiptId TEXT NOT NULL UNIQUE,
                    databaseInstanceId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    lineage TEXT NOT NULL,
                    cursorEpoch INTEGER NOT NULL,
                    trimScope TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    chunkEndUnix INTEGER NOT NULL,
                    committedAt INTEGER NOT NULL,
                    fingerprint TEXT NOT NULL CHECK (length(trim(fingerprint)) > 0),
                    minDecodedTs INTEGER,
                    maxDecodedTs INTEGER,
                    touchedDaysJSON BLOB NOT NULL,
                    decodedRowsJSON BLOB NOT NULL,
                    insertedRowsJSON BLOB NOT NULL,
                    rawBatchId TEXT,
                    rawStatus TEXT NOT NULL,
                    burstJSON BLOB,
                    rawRangeJSON BLOB NOT NULL,
                    timestampHealJSON BLOB NOT NULL,
                    isFinal INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim)
                )
                """)

            let emptyDaysJSON = Data("[]".utf8)
            let emptyRawRangeJSON = Data("{\"source\":\"unavailable\",\"minReceivedTs\":null,\"maxReceivedTs\":null,\"frameCount\":0,\"byteCount\":0,\"hasHistoryEnd\":false}".utf8)
            let retainedRawRangeJSON = Data("{\"source\":\"retainedRawBatch\",\"minReceivedTs\":null,\"maxReceivedTs\":null,\"frameCount\":0,\"byteCount\":0,\"hasHistoryEnd\":false}".utf8)
            let emptyTimestampHealJSON = Data("{\"droppedRecordCount\":0,\"rawRowsDeleted\":0,\"computedRowsDeleted\":0,\"didChange\":false}".utf8)
            let oldRows = try Row.fetchAll(db, sql: """
                SELECT generation, receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix,
                       committedAt, rawBatchId, insertedRowsJSON
                FROM historicalDataCommitJournal
                ORDER BY generation ASC
                """)
            for row in oldRows {
                let deviceId: String = row["deviceId"]
                let registeredLineage = try String.fetchOne(
                    db,
                    sql: "SELECT historyLineage FROM pairedDevice WHERE id = ?",
                    arguments: [deviceId]
                )
                let lineage = registeredLineage?.isEmpty == false
                    ? registeredLineage!
                    : "device:\(deviceId)"
                let epoch = try Int.fetchOne(
                    db,
                    sql: "SELECT historyCursorEpoch FROM pairedDevice WHERE id = ?",
                    arguments: [deviceId]
                ) ?? 0
                let trim: Int = row["trim"]
                let receiptId: String = row["receiptId"]
                let rawBatchId: String? = row["rawBatchId"]
                let insertedRowsJSON: Data = row["insertedRowsJSON"]
                try db.execute(sql: """
                    INSERT INTO historicalDataCommitJournal_v36
                        (generation, receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch,
                         trimScope, trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs,
                         maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId,
                         rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal)
                    VALUES (?, ?, ?, ?, ?, ?, 'historical', ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                    """, arguments: [
                        row["generation"], receiptId, row["databaseInstanceId"], deviceId,
                        lineage, epoch, trim, row["chunkEndUnix"], row["committedAt"], "legacy:" + receiptId,
                        emptyDaysJSON, insertedRowsJSON, insertedRowsJSON, rawBatchId,
                        rawBatchId == nil ? "disabled" : "captured",
                        rawBatchId == nil ? emptyRawRangeJSON : retainedRawRangeJSON,
                        emptyTimestampHealJSON, trim == Int(UInt32.max) ? 1 : 0,
                    ])
            }
            try db.execute(sql: "DROP TABLE historicalDataCommitJournal")
            try db.execute(sql: "ALTER TABLE historicalDataCommitJournal_v36 RENAME TO historicalDataCommitJournal")
            try db.execute(sql: """
                CREATE INDEX idx_historicalDataCommitJournal_scope_generation
                ON historicalDataCommitJournal
                    (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, generation)
                """)

            try db.execute(sql: """
                CREATE TABLE historicalCursor (
                    deviceId TEXT NOT NULL,
                    lineage TEXT NOT NULL,
                    cursorEpoch INTEGER NOT NULL,
                    trimScope TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    watermarkGeneration INTEGER NOT NULL,
                    PRIMARY KEY (deviceId, lineage, cursorEpoch, trimScope)
                )
                """)
            try db.execute(sql: """
                INSERT INTO historicalCursor
                    (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
                SELECT receipt.deviceId, receipt.lineage, receipt.cursorEpoch, receipt.trimScope,
                       receipt.trim, receipt.generation
                FROM historicalDataCommitJournal AS receipt
                INNER JOIN (
                    SELECT deviceId, lineage, cursorEpoch, trimScope, MAX(generation) AS generation
                    FROM historicalDataCommitJournal
                    GROUP BY deviceId, lineage, cursorEpoch, trimScope
                ) AS latest
                    ON receipt.deviceId = latest.deviceId
                    AND receipt.lineage = latest.lineage
                    AND receipt.cursorEpoch = latest.cursorEpoch
                    AND receipt.trimScope = latest.trimScope
                    AND receipt.generation = latest.generation
                """)
        }

        // v37: raw batches share the historical receipt fence. The original rawBatch primary key was
        // only batchId, so reusing an id after a physical re-pair could either collide with old bytes or
        // silently resolve to the wrong capture. Keep cross-device batch IDs collision-safe while allowing
        // the same logical id in separate lineage/epoch scopes.
        migrator.registerMigration("v37-scoped-raw-batch-identity") { db in
            try db.execute(sql: """
                CREATE TABLE rawBatch_v37 (
                    batchId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    lineage TEXT NOT NULL,
                    cursorEpoch INTEGER NOT NULL,
                    capturedAt INTEGER NOT NULL,
                    deviceClockRef INTEGER NOT NULL,
                    wallClockRef INTEGER NOT NULL,
                    startTs INTEGER NOT NULL,
                    endTs INTEGER NOT NULL,
                    frameCount INTEGER NOT NULL,
                    byteSize INTEGER NOT NULL,
                    framesBlob BLOB NOT NULL,
                    syncedAt INTEGER,
                    PRIMARY KEY (batchId, deviceId, lineage, cursorEpoch)
                )
                """)
            try db.execute(sql: """
                INSERT INTO rawBatch_v37
                    (batchId, deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                SELECT raw.batchId, raw.deviceId,
                       COALESCE(NULLIF(device.historyLineage, ''), 'device:' || raw.deviceId),
                       COALESCE(device.historyCursorEpoch, 0),
                       raw.capturedAt, raw.deviceClockRef, raw.wallClockRef, raw.startTs, raw.endTs,
                       raw.frameCount, raw.byteSize, raw.framesBlob, raw.syncedAt
                FROM rawBatch AS raw
                LEFT JOIN pairedDevice AS device ON device.id = raw.deviceId
                """)
            try db.execute(sql: "DROP TABLE rawBatch")
            try db.execute(sql: "ALTER TABLE rawBatch_v37 RENAME TO rawBatch")
            try db.execute(sql: """
                CREATE INDEX idx_rawBatch_batch_device_scope
                ON rawBatch (batchId, deviceId, lineage, cursorEpoch)
                """)
        }

        // v38: analysis acknowledgement is durable and source-scoped. The database identity is part
        // of the key even though the current database normally has one identity row, so a replacement
        // or restore can never make an old checkpoint acknowledge receipts from another database.
        migrator.registerMigration("v38-historical-analysis-checkpoint") { db in
            try db.create(table: "historicalAnalysisCheckpoint") { t in
                t.column("databaseInstanceId", .text).notNull()
                t.column("consumerId", .text).notNull()
                t.column("deviceId", .text).notNull()
                t.column("lineage", .text).notNull()
                t.column("cursorEpoch", .integer).notNull()
                t.column("trimScope", .text).notNull()
                t.column("throughGeneration", .integer).notNull().defaults(to: 0)
                t.column("throughTrim", .integer).notNull().defaults(to: 0)
                t.column("pendingGeneration", .integer)
                t.column("pendingTrim", .integer)
                t.column("pendingReceiptId", .text)
                t.column("pendingFingerprint", .text)
                t.column("pendingPayload", .blob)
                t.primaryKey([
                    "databaseInstanceId", "consumerId", "deviceId", "lineage", "cursorEpoch", "trimScope",
                ])
            }
            try db.create(
                index: "idx_historicalAnalysisCheckpoint_database_consumer_generation",
                on: "historicalAnalysisCheckpoint",
                columns: ["databaseInstanceId", "consumerId", "throughGeneration"]
            )
            try db.create(
                index: "idx_historicalAnalysisCheckpoint_pending",
                on: "historicalAnalysisCheckpoint",
                columns: ["databaseInstanceId", "consumerId", "pendingGeneration"]
            )
        }

        // v39: databases that already ran the original v36/v37 bodies need a forward repair. Keep the
        // historical cursor as one real receipt edge (rather than independently maxed trim/generation),
        // and move legacy raw evidence into the exact lineage/epoch carried by its receipt. The v36/v37
        // bodies above remain correct for new upgrades; this migration repairs databases that recorded them
        // before that correction shipped.
        migrator.registerMigration("v39-historical-receipt-scope-repair") { db in
            // A cursor may have been advanced only by journal receipts. Rebuild those scopes from the
            // newest receipt row, retaining any standalone cursor scope that has no durable receipt.
            try db.execute(sql: """
                DELETE FROM historicalCursor
                WHERE EXISTS (
                    SELECT 1
                    FROM historicalDataCommitJournal AS receipt
                    WHERE receipt.deviceId = historicalCursor.deviceId
                        AND receipt.lineage = historicalCursor.lineage
                        AND receipt.cursorEpoch = historicalCursor.cursorEpoch
                        AND receipt.trimScope = historicalCursor.trimScope
                )
                """)
            try db.execute(sql: """
                INSERT INTO historicalCursor
                    (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
                SELECT receipt.deviceId, receipt.lineage, receipt.cursorEpoch, receipt.trimScope,
                       receipt.trim, receipt.generation
                FROM historicalDataCommitJournal AS receipt
                INNER JOIN (
                    SELECT deviceId, lineage, cursorEpoch, trimScope, MAX(generation) AS generation
                    FROM historicalDataCommitJournal
                    GROUP BY deviceId, lineage, cursorEpoch, trimScope
                ) AS latest
                    ON receipt.deviceId = latest.deviceId
                    AND receipt.lineage = latest.lineage
                    AND receipt.cursorEpoch = latest.cursorEpoch
                    AND receipt.trimScope = latest.trimScope
                    AND receipt.generation = latest.generation
                """)

            // v37 originally gave every legacy raw batch the fallback device scope. Receipt lookup is
            // scope-qualified, so a registered device's retained raw capture then became unreachable.
            // Old rawBatch ids were globally unique before v37. If a later scoped row already owns the
            // target identity, leave the legacy row intact rather than overwrite potentially distinct bytes.
            try db.execute(sql: """
                UPDATE rawBatch AS raw
                SET lineage = (
                        SELECT receipt.lineage
                        FROM historicalDataCommitJournal AS receipt
                        WHERE receipt.rawStatus = 'captured'
                            AND receipt.rawBatchId = raw.batchId
                            AND receipt.deviceId = raw.deviceId
                        ORDER BY receipt.generation DESC
                        LIMIT 1
                    ),
                    cursorEpoch = (
                        SELECT receipt.cursorEpoch
                        FROM historicalDataCommitJournal AS receipt
                        WHERE receipt.rawStatus = 'captured'
                            AND receipt.rawBatchId = raw.batchId
                            AND receipt.deviceId = raw.deviceId
                        ORDER BY receipt.generation DESC
                        LIMIT 1
                    )
                WHERE raw.lineage = 'device:' || raw.deviceId
                    AND raw.cursorEpoch = 0
                    AND EXISTS (
                        SELECT 1
                        FROM historicalDataCommitJournal AS receipt
                        WHERE receipt.rawStatus = 'captured'
                            AND receipt.rawBatchId = raw.batchId
                            AND receipt.deviceId = raw.deviceId
                            AND (receipt.lineage != raw.lineage
                                OR receipt.cursorEpoch != raw.cursorEpoch)
                    )
                    AND NOT EXISTS (
                        SELECT 1
                        FROM rawBatch AS collision
                        INNER JOIN historicalDataCommitJournal AS receipt
                            ON receipt.rawStatus = 'captured'
                            AND receipt.rawBatchId = raw.batchId
                            AND receipt.deviceId = raw.deviceId
                        WHERE collision.batchId = raw.batchId
                            AND collision.deviceId = raw.deviceId
                            AND collision.lineage = receipt.lineage
                            AND collision.cursorEpoch = receipt.cursorEpoch
                            AND collision.rowid != raw.rowid
                    )
                """)
        }
        return migrator
    }
}
