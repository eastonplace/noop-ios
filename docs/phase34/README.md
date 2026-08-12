# NOOP Reconciled Phase 3 + Phase 4 Codex Bundle

**Repository:** `eastonplace-ai/noop`
**Required base:** `976d7d48df6930046eb38cb2f46febb18a986a48`
**Phase 2 PR:** `#27`
**Prepared:** August 4, 2026
**GitHub changes performed:** none

This is the single package to give Codex. It reconciles:

1. the independent agent’s Phase 3/4 QA and code bundle,
2. the earlier Phase 3/4 QA and code produced in this conversation,
3. the final committed Phase 2 branch and hosted CI state.

Phase 2 did commit while QA was in progress. The final GitHub head is the same `976d7d48` target used here, and
its hosted workflow is green. See `docs/00_RECONCILIATION_REPORT.md`.

## What this package implements

### Phase 3: one Health read model

- One canonical Sleep score for Today, Sleep, Trends, widget, Live Activity, Watch, and exports.
- One WAL read generation for daily rows, Sleep sessions, score series, stress, and Apple Trends data.
- Verified Today snapshot save/read-back before publication.
- Exact changed-day Repository updates.
- Bounded recent cache, full-history extent metadata, and on-demand older history.

### Phase 4: one durable processing pipeline

- Immutable BLE receipt identity and strict cursor/raw replay.
- Trim ACK after raw/cursor/receipt commit, without waiting for scoring.
- Transactional receipt admission and leased exact-day work.
- Separate durable analysis generation after score rows commit.
- Score read-back verification, committed Today snapshot, and exact Repository publication.
- One exact verified projection with durable widget, Live Activity, HealthKit, and Watch delivery.
- Source-scope retirement, restore isolation, retries, lease heartbeat, and crash recovery.

## Validation performed here

- `ReferenceCore`: Swift 6.2.1 build passed.
- `ReferenceCore`: **46 tests passed**.
- All **24** integration Swift files and the repository parity test passed Swift syntax parsing.
- SQLite migration and hot-path smoke tests passed.
- All **11** audit-tool unit tests passed.
- The bundle validator passed.
- Calendar tests cover ordinary rollover, spring-forward, and fall-back at local 04:00.

The private repository was available through the GitHub connector, not as a local Xcode checkout. Codex still
must apply the integration files, run XcodeGen, compile all targets, run the full repository tests, inspect SQL
query plans, and perform device/overnight qualification. The package removes design and code-generation work;
that remaining work is integration and verification.

## Reading order

1. `docs/00_RECONCILIATION_REPORT.md`
2. `docs/01_RELEASE_QA_REPORT.md`
3. `CODEX_HANDOFF.md`
4. `docs/03_PHASE_3_4_COMBINED_PLAN.md`
5. `docs/04_DELETE_AND_REPLACE_MANIFEST.md`
6. `docs/08_FILE_APPLICATION_MAP.md`
7. `ReferenceCore/`
8. `integration/`
9. `repo-tests/Phase34RegressionTestPlan.md`
10. `validation/VALIDATION_SUMMARY.md`

## Decision

Use one combined draft PR and one final QA gate. Internal commits are encouraged for rollback. Codex must not
leave the old and new production owners active together.
