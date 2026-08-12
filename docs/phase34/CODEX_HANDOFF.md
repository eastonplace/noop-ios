# Codex Handoff — Apply Reconciled Phase 3 + Phase 4

Work in `eastonplace-ai/noop` from a branch that descends from:

```text
976d7d48df6930046eb38cb2f46febb18a986a48
```

This package supersedes every earlier Phase 3/4 archive. Do not combine it with an older package. Implement it
as one draft PR. Use the internal commit sequence for rollback, then continue until the full branch is built,
tested, audited, and ready for one final QA. Do not stop for separate Phase 3A/3B/4A review gates.

## Non-negotiable product rules

1. App open shows the latest durable Recovery, current physiological-day Strain, and latest scored Sleep when available.
2. Prior-day Strain never appears as current Strain.
3. Today, Sleep, Trends, widget, Live Activity, Watch, and exports use the same production Sleep score and exact projection generation.
4. Raw rows, scoped cursor, and durable receipt commit atomically before trim ACK.
5. Trim ACK does not wait for scoring or external publication.
6. Current-day processing reads exact affected windows and bounded recent history, not years of raw data.
7. Score rows read back and verify before Today snapshot and Repository publication.
8. Source deletion, re-pair, and restore cannot resurrect old values or old work.
9. Destination failure cannot force an already completed analysis to run again.
10. Scoring formulas remain unchanged.

## Start with the supplied code

### Tested core

Install `ReferenceCore/Sources/NoopPhase34Core` once. Keep its tests. A local package is preferred when it does
not create a dependency cycle. Moving the files intact into an existing shared target is acceptable. Do not
copy separate state-machine implementations into several targets.

The package currently passes 46 tests. Preserve those tests and behavior.

### Repository integration

Apply every file in `integration/` using `docs/08_FILE_APPLICATION_MAP.md`. Large existing files use exact splice
maps because replacing a full 5,000-line file would be unsafe. Adapt access control and current repository type
labels mechanically. Keep the supplied contracts.

## Required implementation order

### 1. Migrations and identity

- Register `Phase34DatabaseMigrations` v40 through v43 after current v39.
- Add the new tables, including `verifiedSnapshotCommit`, to device deletion, restore, and schema audit tests.
- Keep `workKindKey` as SQL identity and `workKindJSON` as payload.
- Use `analysisMutationJournal.generation` as the only analysis generation.
- Keep receipt, analysis, Repository, snapshot, and destination delivery generation domains separate.
- Use `verifiedSnapshotCommit` to make analysis-to-snapshot replay idempotent after a process stop.
- Test fresh DB, v39 upgrade, partially created prerelease tables, backup restore, and foreign keys.

### 2. Canonical Health read model

- Add `canonicalHealthSurfaceSnapshot` to `WhoopStore`.
- Read daily rows, Sleep sessions, production/shadow score series, stress, and Apple daily rows in one GRDB read transaction.
- Preserve ordered source authority from active source to canonical fallback.
- Build `CanonicalHealthReadModel` during the same Repository merge as `days` and `sleeps`.
- Rebuild when Sleep V2 mode changes even if rows do not.
- Wire Today, Sleep, and Trends exactly as `CanonicalSurfacePatches.swift` describes.
- Widget, Live Activity, Watch, and HealthKit consume `VerifiedHealthProjection`, not Repository arrays.
- Widget, Live Activity, and Watch are latest-state sinks keyed by snapshot generation.
- HealthKit is mutation delivery keyed by analysis generation and exact changed days.
- Remove production Sleep recomputation and duplicate precedence from the views.

### 3. Today durability and presentation

- Replace direct metric-object presentation comparison with `TodaySnapshotPresentationIdentityBuilder`.
- Metadata-only generation, observation time, or frontier changes must not rebuild value-fed surfaces.
- Apply `VerifiedTodaySnapshotCommit` ordering:

```text
resolve candidate
→ save
→ read back
→ verify
→ publish committed snapshot
```

- On save/read failure, keep the last committed snapshot and schedule retry.
- Never publish the candidate before SQLite accepts it.

### 4. Repository exact/recent/history split

- Replace days-count Boolean refresh with typed request/outcome.
- Implement exact changed-day publication using the same canonical merge kernel.
- Load approximately 90–120 recent days for mounted dashboard surfaces.
- Load full-history `MIN/MAX/COUNT` metadata separately.
- Exact-load older selected days and page older Sleep wake-day groups.
- Remove 4,000-day reads from launch, current-day, post-backfill, Sleep initial load, and Trends refresh.
- Replace fixed calendar-day seconds with `HealthCalendar`. Its physiological day changes at local 04:00 across DST transitions.
- Keep full-history import/report paths off the current-day critical path.

### 5. Receipt V2 and storage hardening

- Build fingerprint V2 from immutable scope/trim/protocol/frame/HISTORY_END bytes only.
- Persist sparse timestamp buckets, recorded time zone, and explicit local repair days.
- Decoded physiological evidence creates analysis duty even when inserted count is zero.
- Timestamp range metadata alone does not create analysis duty.
- Empty legacy receipts advance without a full repair.
- Storage heal without exact days creates one low-priority full repair.
- Replace cursor write with strict greater-generation behavior.
- Apply strict raw decompression, exact packed-length validation, strict frame decoding, and semantic raw conflict handling.

Commit/ACK order must remain:

```text
rows + optional raw + receipt + cursor
→ transaction commit
→ durable watermark signal
→ trim ACK
```

### 6. Durable admission and exact analysis

- Add transactional receipt admission.
- Insert/coalesce work and advance the consumer watermark in one transaction.
- Use stable work kind identity.
- Retire old receipt scopes before source transition.
- Replace the old checkpoint consumer with one `HistoricalPipelineRuntime` and one `HistoricalPipelineCoordinator`.
- Keep the existing Intelligence coordinator as the sole formula execution owner.
- Extract exact civil-day windows from the existing per-day scorer. Do not change formulas.
- After score rows commit, call `recordAnalysisMutation`.
- Return that journal generation as the analysis generation.
- Renew leases during long analysis and verification.
- A new receipt during analysis creates one follow-up work item.

### 7. Verification and exact publication

Verify the persisted outputs produced by the exact analysis:

- Recovery: wake day, source, algorithm, baseline/coverage gates, persisted read-back.
- Strain: V2, correct physiological day, consumed frontier, no partial-stream regression.
- Sleep score: canonical source/model/day.
- Sleep duration: independently authoritative.
- Missing value: only a successful complete read can create unavailable evidence.

Then:

```text
verified Today snapshot commit
→ exact Repository publish
→ exact VerifiedHealthProjection + all destination rows transaction
→ analysis work complete and lease released
```

Do not run a broad Repository refresh at the end.

### 8. External publication

- Load the exact stored projection by context and snapshot generation.
- Compare semantic projection values on replay, not encoded JSON bytes.
- Keep recent completed projections per context.
- Keep every projection referenced by non-succeeded outbox work.
- Renew destination leases during HealthKit/Watch suspension.
- HealthKit is write-only and cannot present permissions.
- Batch caps must self-signal until no due work remains.
- Report prune and state-transition failures.
- Destination retries never re-open analysis work.

### 9. BLE and device lifecycle

- Match confirmed writes using peripheral ID, exact characteristic object generation, and connection generation.
- Retire a stale exact token before returning for a stale callback.
- Do not clear same-peripheral old-generation tokens until callback or timeout.
- Guard active-device changes in one transaction.
- Before re-pair/source replacement, retire the old receipt scope and cancel current runtime tasks.
- Delete all new device-owned rows during privacy deletion.
- Restore changes database identity and invalidates old work/mutations/projections.

## Remove superseded paths

Follow `docs/04_DELETE_AND_REPLACE_MANIFEST.md`. Required removals include:

- checkpoint-only historical execution path,
- old receipt consumer,
- forced 21-day post-backfill owner,
- global min/max receipt day expansion,
- broad current-day/post-backfill publication,
- production Sleep precedence in views,
- independent Trends data generation,
- independent external projection,
- pre-save Today snapshot publication.

Do not leave old and new production owners together at completion.

## Deferred schema risks

Do not guess a new RR or event primary key. Add diagnostics that compare decoded and inserted counts for a
first-seen fingerprint and retain raw evidence. A schema change requires a proven stable protocol sequence,
frame offset, or record ordinal.

## Required validation

Run:

```bash
swift test --package-path <installed NoopPhase34Core path> -Xswiftc -warnings-as-errors
python3 tools/qa/audit_phase34.py .
python3 tools/qa/validate_phase34_sql.py
```

Then run repository-standard:

- XcodeGen,
- source audits,
- app and extension builds,
- retained package tests,
- all NOOP iOS tests,
- migration/restore fixtures,
- SQL query plans and instrumentation,
- simulator UI checks,
- available physical-device and overnight matrix.

Implement every item in `repo-tests/Phase34RegressionTestPlan.md`. Do not make concurrency tests pass with
arbitrary sleeps or repeated yields. Add actor-idle, generation, durable-state, or signpost seams.

## Completion and return

Return one draft PR only after the full package is integrated. Include:

- PR URL and head SHA,
- exact base SHA,
- internal commit summary,
- files and old paths removed,
- build/test commands and exact counts,
- audit output,
- migration results,
- query plans and performance traces,
- simulator/device evidence,
- explicitly untested physical rows,
- remaining risks.

Do not merge the PR. The next action is an independent final QA of the GitHub branch.
