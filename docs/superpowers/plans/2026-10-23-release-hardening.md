# NOOP 2.0 release hardening

## Scope and starting point

Easton authorized a code audit, confirmed fixes, regression tests, an independent review, and one unmerged draft PR. The clarification on 2026-10-23 makes PR 78 the intended delivery PR, not a prerequisite. GitHub determines the actual number.

- Verified default branch: `main`, commit `a7ade2598d439d33cd20816d69ccc991b29322fc`.
- Local branch: `audit/noop-2-release-hardening-20261023`.
- The open PR 77 is outside this base. Requalify the combined candidate after any additional merges.
- Preserve all features, physiological formulas, collection cadence, data compatibility, UI design, and every Coach prompt/template/instruction literal.
- No deployment, release publication, phone installation, or commands to physical straps.

## Investigation and implementation

The specialist investigations run in parallel. Changes require a traced execution path and a reproducible failure or measured bottleneck.

1. **Bluetooth lifecycle.** Reproduce transport state surviving radio loss and Forget. Share complete retirement cleanup with normal disconnect, preserve buffered readings and their original owner, and fence stale callbacks. Add native lifecycle regression tests; run protocol tests. Physical radio and energy validation remains a release gate.
2. **Sleep ownership and undo.** Reproduce canonical-row mutations failing after re-pair, repeated clipping against the detected onset, adjusted-row lookup misses, and lost recovered-score overrides on undo. Use exact natural-key ownership and transactional snapshot/delete/restore. Test failure rollback, no-op deletion, repeated edits, and conflicting undo. Preserve formulas and migrations.
3. **Coach request ownership.** Reproduce provider/key retargeting and stale replies across suspended context loads, consent changes, and retries. Capture immutable request destinations and ownership; invalidate obsolete work and outbound history. Test without real credentials or network. Compare protected prompt literals with the base.
4. **Measured live workout processing.** Benchmark the production projection cache on synthetic long workouts with canonical tail corrections. If the repeated full rebuild is material, use the existing exact tail-replacement accumulator operation, retain authoritative fallback paths, and verify output equivalence including pauses. Report host microbenchmark results separately from device performance.
5. **Broader review.** Inspect startup, publication, widgets, HealthKit, import/export, dependencies, notifications, source/version contracts, and recent history. Record reviewed scope and unresolved hypotheses without presenting them as confirmed bugs.
6. **Additional reproduced paths.** Fence weekly Coach insight ownership, reject unrepresentable imported numbers before integer conversion, and declare required-reason API use in the app and widget bundles. Verify existing prompt literals and valid numeric rounding remain unchanged. Investigate any source-switch or bootstrap races found while tracing the complete Bluetooth lifecycle before including narrow, tested fixes.

## Verification and delivery

- Baseline: preserve the 20 source-audit results and pure Swift package results.
- During edits: red/green regression evidence and focused tests for changed behavior; no weakened assertions or portability edits to product code solely for this host.
- Final local pass: inspect the combined diff, run affected audits and CI classifier/gate tests, verify release notes/build, and prove Coach prompt literals unchanged.
- Independent reviewer: challenge concurrency, transaction boundaries, data preservation, caching assumptions, test realism, and complexity; resolve confirmed findings.
- Push a single draft PR from the verified base using GitHub. Inspect CI for the exact resulting head, including native iOS tests and relevant packages. Leave it unmerged.
- Report confirmed findings with source evidence, tests, measured medians/p95 where available, unmeasured device metrics, and exact remaining release gates.

## Environment limits

This host is Linux with a temporary official Swift 6.4.1 toolchain. It has no Xcode, iOS simulator, Instruments, iPhone, or WHOOP 4.0/5.0/MG hardware. Portable tests and source-derived harnesses do not substitute for native integration tests or physical Bluetooth, memory, startup, rendering, and energy measurements.
