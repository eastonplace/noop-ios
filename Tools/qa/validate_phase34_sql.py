#!/usr/bin/env python3
"""Executable SQLite smoke tests for the reconciled Phase 3/4 schema and hot-path statements."""
from __future__ import annotations

import json
import sqlite3


def create_schema(db: sqlite3.Connection) -> None:
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("""
        CREATE TABLE historicalDataCommitJournal (
            generation INTEGER PRIMARY KEY AUTOINCREMENT,
            databaseInstanceId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            lineage TEXT NOT NULL,
            cursorEpoch INTEGER NOT NULL,
            trimScope TEXT NOT NULL,
            fingerprintVersion INTEGER NOT NULL DEFAULT 1,
            timestampBucketsJSON BLOB,
            recordedTimeZoneIdentifier TEXT,
            explicitAffectedDaysJSON BLOB
        )
    """)
    db.execute("""
        CREATE TABLE historicalReceiptConsumer (
            consumerId TEXT NOT NULL,
            databaseInstanceId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            lineage TEXT NOT NULL,
            cursorEpoch INTEGER NOT NULL CHECK(cursorEpoch >= 0),
            trimScope TEXT NOT NULL,
            throughGeneration INTEGER NOT NULL DEFAULT 0 CHECK(throughGeneration >= 0),
            updatedAt INTEGER NOT NULL,
            PRIMARY KEY (consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
        )
    """)
    db.execute("""
        CREATE TABLE historicalAnalysisWork (
            workId TEXT PRIMARY KEY,
            databaseInstanceId TEXT NOT NULL,
            sourceId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            lineage TEXT NOT NULL,
            cursorEpoch INTEGER NOT NULL CHECK(cursorEpoch >= 0),
            trimScope TEXT NOT NULL,
            firstReceiptGeneration INTEGER NOT NULL CHECK(firstReceiptGeneration > 0),
            lastReceiptGeneration INTEGER NOT NULL CHECK(lastReceiptGeneration >= firstReceiptGeneration),
            minimumTs INTEGER,
            maximumTs INTEGER,
            affectedDaysJSON BLOB NOT NULL,
            recordedTimeZoneIdentifier TEXT NOT NULL,
            workKindKey TEXT NOT NULL CHECK(length(workKindKey) > 0),
            workKindJSON BLOB NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL CHECK(state IN (
                'pending','analyzing','verifying','snapshotCommitted','repositoryPublished',
                'complete','retryable','quarantined'
            )),
            attemptCount INTEGER NOT NULL DEFAULT 0 CHECK(attemptCount >= 0),
            nextAttemptAt INTEGER,
            leaseOwner TEXT,
            leaseExpiresAt INTEGER,
            analyzedThroughReceiptGeneration INTEGER,
            analysisGeneration INTEGER,
            snapshotGeneration INTEGER,
            pendingDestinationsJSON BLOB NOT NULL,
            lastErrorCode TEXT,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            CHECK(minimumTs IS NULL OR maximumTs IS NULL OR minimumTs <= maximumTs)
        )
    """)
    db.execute("""
        CREATE TABLE analysisMutationJournal (
            generation INTEGER PRIMARY KEY AUTOINCREMENT,
            workId TEXT NOT NULL,
            databaseInstanceId TEXT NOT NULL,
            sourceId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            lineage TEXT NOT NULL,
            cursorEpoch INTEGER NOT NULL CHECK(cursorEpoch >= 0),
            trimScope TEXT NOT NULL,
            throughReceiptGeneration INTEGER NOT NULL CHECK(throughReceiptGeneration > 0),
            analyzedDaysJSON BLOB NOT NULL,
            rawFrontierTs INTEGER CHECK(rawFrontierTs IS NULL OR rawFrontierTs >= 0),
            algorithmBundleVersion TEXT NOT NULL CHECK(length(algorithmBundleVersion) > 0),
            createdAt INTEGER NOT NULL,
            UNIQUE(workId, throughReceiptGeneration)
        )
    """)
    db.execute("""
        CREATE TABLE verifiedHealthProjection (
            contextId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            snapshotGeneration INTEGER NOT NULL CHECK(snapshotGeneration > 0),
            projectionJSON BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY(contextId, snapshotGeneration)
        )
    """)
    db.execute("""
        CREATE TABLE verifiedSnapshotCommit (
            contextId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            analysisGeneration INTEGER NOT NULL CHECK(analysisGeneration > 0),
            throughReceiptGeneration INTEGER NOT NULL CHECK(throughReceiptGeneration > 0),
            snapshotGeneration INTEGER NOT NULL CHECK(snapshotGeneration > 0),
            changedDaysJSON BLOB NOT NULL,
            createdAt INTEGER NOT NULL,
            PRIMARY KEY(contextId, analysisGeneration),
            FOREIGN KEY(contextId, snapshotGeneration)
                REFERENCES verifiedHealthProjection(contextId, snapshotGeneration)
                ON DELETE CASCADE
        )
    """)
    db.execute("""
        CREATE TABLE externalPublicationOutbox (
            idempotencyKey TEXT PRIMARY KEY,
            contextId TEXT NOT NULL,
            deviceId TEXT NOT NULL,
            snapshotGeneration INTEGER NOT NULL CHECK(snapshotGeneration > 0),
            analysisGeneration INTEGER NOT NULL CHECK(analysisGeneration > 0),
            changedDaysJSON BLOB NOT NULL,
            destination TEXT NOT NULL CHECK(destination IN ('widget','liveActivity','healthKit','watch')),
            state TEXT NOT NULL CHECK(state IN (
                'pending','inFlight','retryable','succeeded','superseded','quarantined'
            )),
            attemptCount INTEGER NOT NULL DEFAULT 0 CHECK(attemptCount >= 0),
            nextAttemptAt INTEGER,
            leaseOwner TEXT,
            leaseExpiresAt INTEGER,
            lastErrorCode TEXT,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            FOREIGN KEY(contextId, snapshotGeneration)
                REFERENCES verifiedHealthProjection(contextId, snapshotGeneration)
                ON DELETE CASCADE
        )
    """)


def main() -> None:
    db = sqlite3.connect(":memory:")
    create_schema(db)
    now = 1_700_000_000

    work_args = (
        "work-1", "db-1", "source", "device", "lineage", 1, "history",
        10, 11, 100, 200, json.dumps(["2026-08-03"]), "America/New_York",
        "exact-days", json.dumps({"exactDays": {}}), 1000, "pending", 0, None, None, None,
        None, None, None, json.dumps([]), None, now, now,
    )
    db.execute("""
        INSERT INTO historicalAnalysisWork (
            workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
            firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs,
            affectedDaysJSON, recordedTimeZoneIdentifier, workKindKey, workKindJSON,
            priority, state, attemptCount, nextAttemptAt, leaseOwner, leaseExpiresAt,
            analyzedThroughReceiptGeneration, analysisGeneration, snapshotGeneration,
            pendingDestinationsJSON, lastErrorCode, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, work_args)
    db.execute("""
        INSERT INTO analysisMutationJournal (
            generation, workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
            throughReceiptGeneration, analyzedDaysJSON, rawFrontierTs,
            algorithmBundleVersion, createdAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        10, "work-1", "db-1", "source", "device", "lineage", 1, "history",
        11, json.dumps(["2026-08-03"]), 200, "bundle-v1", now,
    ))
    db.execute("""
        INSERT INTO historicalReceiptConsumer
            (consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
             throughGeneration, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
        DO UPDATE SET
            throughGeneration = MAX(historicalReceiptConsumer.throughGeneration, excluded.throughGeneration),
            updatedAt = excluded.updatedAt
    """, ("phase34.analysis", "db-1", "device", "lineage", 1, "history", 11, now))

    for context, generation in (("ctx-a", 1), ("ctx-a", 2), ("ctx-b", 1), ("ctx-b", 2)):
        projection = json.dumps({
            "contextId": context,
            "deviceId": "device",
            "generation": generation,
        }, sort_keys=True).encode()
        db.execute("""
            INSERT INTO verifiedHealthProjection
                (contextId, deviceId, snapshotGeneration, projectionJSON, createdAt)
            VALUES (?, ?, ?, ?, ?)
        """, (context, "device", generation, projection, now + generation))

    changed_days = json.dumps(["2026-08-03"]).encode()
    db.executemany("""
        INSERT INTO verifiedSnapshotCommit (
            contextId, deviceId, analysisGeneration, throughReceiptGeneration,
            snapshotGeneration, changedDaysJSON, createdAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
    """, [
        # This old snapshot mapping belongs to pending work and must survive projection pruning.
        ("ctx-a", "device", 10, 11, 1, changed_days, now + 2),
        ("ctx-a", "device", 11, 21, 2, changed_days, now + 3),
        ("ctx-a", "device", 12, 22, 2, changed_days, now + 4),
    ])
    rows = [
        ("ctx-a|snapshot|1|widget", "ctx-a", "device", 1, 10, changed_days,
         "widget", "superseded", 0, None, None, None, "superseded_by_newer_snapshot", now, now),
        ("ctx-a|snapshot|2|widget", "ctx-a", "device", 2, 11, changed_days,
         "widget", "pending", 0, None, None, None, None, now + 1, now + 1),
        # Two historical HealthKit mutations may share one current snapshot. Both must remain durable.
        ("ctx-a|analysis|10|healthKit", "ctx-a", "device", 1, 10, changed_days,
         "healthKit", "succeeded", 0, None, None, None, None, now + 2, now + 2),
        ("ctx-a|analysis|11|healthKit", "ctx-a", "device", 2, 11, changed_days,
         "healthKit", "pending", 0, None, None, None, None, now + 3, now + 3),
        ("ctx-a|analysis|12|healthKit", "ctx-a", "device", 2, 12, changed_days,
         "healthKit", "pending", 0, None, None, None, None, now + 4, now + 4),
    ]
    db.executemany("""
        INSERT INTO externalPublicationOutbox (
            idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
            changedDaysJSON, destination, state, attemptCount, nextAttemptAt,
            leaseOwner, leaseExpiresAt, lastErrorCode, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, rows)
    db.commit()

    assert db.execute("SELECT workKindKey FROM historicalAnalysisWork").fetchone()[0] == "exact-days"
    assert db.execute("SELECT generation FROM analysisMutationJournal").fetchone()[0] == 10
    assert db.execute("SELECT throughGeneration FROM historicalReceiptConsumer").fetchone()[0] == 11
    assert db.execute("SELECT COUNT(*) FROM externalPublicationOutbox").fetchone()[0] == 5
    assert db.execute("SELECT COUNT(*) FROM verifiedSnapshotCommit").fetchone()[0] == 3
    assert db.execute("""
        SELECT COUNT(*) FROM externalPublicationOutbox
        WHERE destination = 'healthKit' AND snapshotGeneration = 2
    """).fetchone()[0] == 2

    # Latest-state work runs first and newest-first. HealthKit then drains every analysis oldest-first.
    ordered = [row[0] for row in db.execute("""
        SELECT idempotencyKey FROM externalPublicationOutbox
        WHERE state IN ('pending', 'retryable') AND leaseOwner IS NULL
        ORDER BY
          CASE destination
            WHEN 'widget' THEN 0 WHEN 'liveActivity' THEN 1 WHEN 'watch' THEN 2
            WHEN 'healthKit' THEN 3 ELSE 4 END ASC,
          CASE WHEN destination IN ('widget','liveActivity','watch')
               THEN snapshotGeneration ELSE 0 END DESC,
          CASE WHEN destination = 'healthKit' THEN analysisGeneration ELSE 0 END ASC,
          createdAt ASC
    """)]
    assert ordered == [
        "ctx-a|snapshot|2|widget",
        "ctx-a|analysis|11|healthKit",
        "ctx-a|analysis|12|healthKit",
    ]

    # Per-context retention keeps newest rows plus payloads referenced by nonterminal outbox items.
    for context in ("ctx-a", "ctx-b"):
        retained = [row[0] for row in db.execute("""
            SELECT snapshotGeneration FROM verifiedHealthProjection
            WHERE contextId = ? ORDER BY snapshotGeneration DESC LIMIT 1
        """, (context,))]
        placeholders = ",".join("?" for _ in retained)
        db.execute(f"""
            DELETE FROM verifiedHealthProjection
            WHERE contextId = ?
              AND snapshotGeneration NOT IN ({placeholders})
              AND NOT EXISTS (
                  SELECT 1 FROM externalPublicationOutbox o
                  WHERE o.contextId = verifiedHealthProjection.contextId
                    AND o.snapshotGeneration = verifiedHealthProjection.snapshotGeneration
                    AND o.state NOT IN ('succeeded', 'superseded')
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM verifiedSnapshotCommit c
                  JOIN analysisMutationJournal m ON m.generation = c.analysisGeneration
                  JOIN historicalAnalysisWork w ON w.workId = m.workId
                  WHERE c.contextId = verifiedHealthProjection.contextId
                    AND c.snapshotGeneration = verifiedHealthProjection.snapshotGeneration
                    AND w.state NOT IN ('complete', 'quarantined')
              )
        """, (context, *retained))
    db.commit()
    assert [row[0] for row in db.execute(
        "SELECT snapshotGeneration FROM verifiedHealthProjection WHERE contextId='ctx-a' ORDER BY 1"
    )] == [1, 2]
    assert [row[0] for row in db.execute(
        "SELECT snapshotGeneration FROM verifiedHealthProjection WHERE contextId='ctx-b' ORDER BY 1"
    )] == [2]

    commit_columns = {row[1] for row in db.execute("PRAGMA table_info(verifiedSnapshotCommit)")}
    assert {"analysisGeneration", "throughReceiptGeneration", "changedDaysJSON"}.issubset(commit_columns)
    columns = {row[1] for row in db.execute("PRAGMA table_info(externalPublicationOutbox)")}
    assert {"analysisGeneration", "changedDaysJSON"}.issubset(columns)
    table_sql = db.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='externalPublicationOutbox'"
    ).fetchone()[0].lower().replace(" ", "").replace("\n", "")
    assert "superseded" in table_sql
    assert "unique(contextid,snapshotgeneration,destination)" not in table_sql

    print("PASS: reconciled Phase 3/4 migration, ordering, and replay SQL smoke tests")


if __name__ == "__main__":
    main()
