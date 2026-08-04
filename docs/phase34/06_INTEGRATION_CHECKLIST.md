# Integration Checklist

## Baseline

- [ ] Confirm the branch descends from `976d7d48df6930046eb38cb2f46febb18a986a48`.
- [ ] Record current Phase 2 test counts and XcodeGen state.
- [ ] Create a multi-year fixture with pending Phase 2 receipts and one staged legacy checkpoint.
- [ ] Keep the PR draft.

## Tested core

- [ ] Add one copy of `NoopPhase34Core`.
- [ ] Preserve `Sendable`, actor isolation, and Codable behavior.
- [ ] Run all **46** reference tests with warnings as errors.

## Database and lifecycle

- [ ] Register v40–v43 after current v39.
- [ ] Test fresh DB, v39 upgrade, partial prerelease schema, locked/protected store, and backup restore.
- [ ] Add `historicalReceiptConsumer`, `historicalAnalysisWork`, `analysisMutationJournal`,
      `verifiedHealthProjection`, `verifiedSnapshotCommit`, and `externalPublicationOutbox` to deletion/restore audits.
- [ ] Use `workKindKey` for SQL identity.
- [ ] Verify no old database instance work, mutation, or projection can run after restore.
- [ ] Retire old receipt scope before re-pair/source activation.

## Canonical Health

- [ ] One Sleep precedence implementation.
- [ ] Explicit active-source authority rank.
- [ ] Imported WHOOP wins an imported day.
- [ ] `.off`: legacy, then provisional.
- [ ] `.shadow`: legacy; V2 fills a true blank; provisional last.
- [ ] `.on`: V2, then legacy, then provisional.
- [ ] One WAL read supplies daily, Sleep, metric series, stress, and Apple Trends inputs.
- [ ] Today, Sleep, Trends, widget, Live Activity, Watch, and exports use the same point/projection.
- [ ] Historical provenance uses the displayed wake day.
- [ ] Metadata-only evidence does not rebuild visible UI.

## Repository and pages

- [ ] Exact publication clears authoritative missing values and sessions.
- [ ] Snapshot save/read-back occurs before in-memory publication.
- [ ] Snapshot failure keeps authoritative Repository success and schedules retry.
- [ ] Recent cache stays bounded.
- [ ] History extent drives navigation.
- [ ] Sleep uses recent pages and exact older loads.
- [ ] Trends uses captured canonical inputs and bounded refresh.
- [ ] No current-day/post-backfill/launch path reads 4,000 days.
- [ ] Calendar-day bounds use `HealthCalendar`, not fixed seconds.
- [ ] Local 04:00 rollover passes ordinary, spring-forward, and fall-back tests.

## Historical receipt and storage

- [ ] Fingerprint V2 excludes derived timestamps, recorded zone, and capture preference.
- [ ] Trim ACK occurs after raw/cursor/receipt commit and does not wait for scoring.
- [ ] Same replay returns the original receipt across capture-setting change.
- [ ] Different immutable bytes never silently ACK.
- [ ] Decoded rows create analysis duty even when inserts are zero.
- [ ] Timestamp range metadata alone creates no work.
- [ ] Sparse buckets remain sparse.
- [ ] Strict decompression validates length before allocation.
- [ ] Strict frame decode validates count, bytes, and trailing data.
- [ ] Equal cursor generation changes nothing unless trim matches exactly.

## Durable analysis

- [ ] Work and consumer watermark commit together.
- [ ] Exact and full-repair work use stable keys.
- [ ] Lease heartbeat covers long analysis and verification.
- [ ] Current-day priority wins.
- [ ] New receipts during analysis create one follow-up item.
- [ ] Score rows commit before `analysisMutationJournal` record.
- [ ] Analysis generation comes only from that journal.
- [ ] Recovery, Strain V2, Sleep score, duration, source, day, algorithm, and frontier are verified.
- [ ] Today snapshot commits before exact Repository publication.
- [ ] Analysis work completes after exact projection/outbox persistence, not destination delivery.

## External publication

- [ ] Exact projection and all destination rows insert atomically.
- [ ] `verifiedSnapshotCommit` makes one analysis mutation map to one durable snapshot generation.
- [ ] Widget, Live Activity, and Watch supersede older pending snapshot generations.
- [ ] HealthKit preserves every analysis generation and exact changed-day set.
- [ ] Semantic replay compares decoded projection values.
- [ ] Widget does not wait for HealthKit.
- [ ] HealthKit is write-only and cannot prompt.
- [ ] Destination leases renew during long calls.
- [ ] Batch caps self-signal until no due work remains.
- [ ] Projection pruning keeps recent rows per context and every referenced row.
- [ ] Prune and state-transition errors are reported.

## BLE and source transition

- [ ] Callback matching uses peripheral, characteristic object generation, and connection generation.
- [ ] Stale exact token is retired before stale-link return.
- [ ] Old scope consumer watermark advances before new lineage activation.
- [ ] Old nonterminal work is quarantined with reason.
- [ ] Missing/archived active target leaves current active row unchanged.

## Cleanup

- [ ] Remove checkpoint consumer after converting or quarantining old staged state.
- [ ] Remove forced 21-day post-backfill owner.
- [ ] Remove broad post-backfill/current-day refreshes.
- [ ] Remove local production Sleep selectors/recomputation.
- [ ] Remove independent external projection.
- [ ] Remove dead code and obsolete tests.
- [ ] Keep RR/event schema changes deferred until stable decoder identity exists.

## Release validation

- [ ] XcodeGen and source audits pass.
- [ ] App and extensions build.
- [ ] Retained package tests pass.
- [ ] iOS tests pass.
- [ ] `audit_phase34.py` returns zero errors.
- [ ] SQL smoke and migration fixtures pass.
- [ ] Query plans use expected indexes.
- [ ] Large-DB latency thresholds pass.
- [ ] Physical overnight, locked, reconnect, DST, and timezone matrix passes.
