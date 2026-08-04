# Recommended Internal Commit Sequence

Use one draft PR and one final review gate. These commits provide rollback and bisectability. Codex must not
stop for user review between them.

## Commit 1 — Tested core and additive migrations

- Add `NoopPhase34Core` once.
- Register v40–v43.
- Add stable `workKindKey`, analysis mutation journal, verified projection, `verifiedSnapshotCommit`, and external outbox.
- Expand deletion/restore schema audits.

**Gate:** 46 reference tests, migration tests, fresh/v39/partial-prerelease/restore fixtures.

## Commit 2 — One canonical health read generation

- Add one GRDB surface snapshot.
- Build canonical Sleep/stress/Apple model with explicit source authority.
- Wire Today, Sleep, and Trends.
- Add presentation identity and save-before-publish ordering.

**Gate:** same Sleep day/value/source/model across screens; one WAL generation; scalar-only score works.

## Commit 3 — Exact, recent, and historical Repository reads

- Typed request/outcome.
- Exact changed-day publication.
- Bounded recent cache and aggregate history extent.
- Paginated Sleep and exact historical-day loading.
- Remove 4,000-day launch/current-day/post-backfill reads.

**Gate:** multi-year fixture keeps full navigation with bounded startup/query count.

## Commit 4 — Receipt V2, strict cursor/raw storage, transactional admission

- Immutable-byte fingerprint V2.
- Sparse timestamp buckets and recorded zone.
- Strict raw decompression/replay.
- Strict cursor generation pair.
- Transactional receipt admission using stable work identity.

**Gate:** replay, corruption, sparse-range, lost-ACK, and admission crash tests.

## Commit 5 — Exact scoring, durable mutation, verification, publication

- Extract exact civil-day scorer without formula changes.
- Add analysis mutation generation after score commit.
- Run one leased durable coordinator with heartbeat.
- Verify scores, commit Today snapshot, exact-publish Repository.

**Gate:** every crash seam through Repository publication; exact-vs-legacy formula parity.

## Commit 6 — External outbox and lifecycle

- Persist exact verified projection plus destination rows atomically.
- Key latest-state sinks by snapshot generation. Key HealthKit by analysis generation and changed days.
- Reuse the durable analysis-to-snapshot mapping after a process stop.
- Add destination worker heartbeat, retry, semantic replay, and per-context pruning.
- Retire old receipt scopes on source transition.
- Wire launch, foreground, protected data, CoreBluetooth restoration, and BG processing.

**Gate:** process-death destination recovery, source/restore tests, same-generation surface parity.

## Commit 7 — BLE callback fix, remove superseded owners, qualify

- Apply exact characteristic/connection token handling.
- Remove checkpoint consumer, old post-backfill owner, broad refreshes, and local production score paths.
- Run static audit, query plans, full tests, performance traces, and physical overnight matrix.

**Gate:** audit has zero release blockers; app/extensions and all tests pass; release thresholds met.
