# WHOOP upstream reconciliation, 19 October 2026

This directory records the WHOOP port integrated after PR #61. The two JSON files are immutable packet evidence against the older base `38682a54803b232373d5c453386c80a7a74d6cc0`. Their hashes, migration numbers and verification statements describe that packet. They do not describe the final reconciled tree or establish a current test pass.

| Provenance | Revision |
| --- | --- |
| Original packet target, `eastonplace/noop-ios` | `38682a54803b232373d5c453386c80a7a74d6cc0` |
| Upstream source, `ryanbr/noop` | `8e4b0c16e7640607600fa6bde5424095eba6034e` |
| Post-PR #61 integration base | `00eadc67c23fee97fd064f1aeb6d79b7a7f2e537` |

[packet-manifest.json](packet-manifest.json) and [packet-reconciliation-matrix.json](packet-reconciliation-matrix.json) are byte-identical copies of the supplied manifest and finding matrix. Keep them unchanged. The repository's [LICENSE](../../LICENSE), [NOTICE](../../NOTICE) and [ATTRIBUTION.md](../../ATTRIBUTION.md) retain the source licensing and attribution.

## Integrated behavior

- WHOOP 4 scoring selects historical, realtime, standard, then legacy transport per complete UTC hour before exact bounds and limits. WHOOP 5 retains whole-window historical-or-standard selection. Other providers keep their existing predicate.
- The forward R-R migration adds nullable `tsSuspect`, translates explicit legacy channels 8–10, and annotates exactly 500 ms WHOOP 5 historical/standard beats when same-device, same-second stored HR is below 100 bpm. It preserves existing annotations and raw beat keys. The shared decoded transaction applies the same rule to new data and late HR.
- Nightly HRV requires 20 clean intervals per window and retains gap-aware RMSSD. Daily RHR uses the longest valid session's existing floor, including nil. Score, driver and trace paths agree on optional recovery-baseline eligibility.
- R-R provenance, quality and family witnesses enter the day cache and idle watermark. `cache-v5` invalidates the prior cache. Read failures bypass reuse.
- Background history main/settle identities advance together to v4. Existing 30-day grants, cancellation and durable progress remain. Pending history keeps the shared background request alive. BLE changes add framing diagnostics around existing admission.

The implementation entry points are [RRReadPolicy.swift](../../Packages/WhoopStore/Sources/WhoopStore/RRReadPolicy.swift), [RRQualityMigration.swift](../../Packages/WhoopStore/Sources/WhoopStore/RRQualityMigration.swift), [StreamStore.swift](../../Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift), [IntelligenceEngine.swift](../../Strand/Data/IntelligenceEngine.swift) and [AppModel.swift](../../Strand/App/AppModel.swift).

## Deviations from the packet

PR #61 already owns `v59-lift-strain`. The reconciled migrator retains it and registers **`v60-rr-quality-policy` immediately after it**. `WhoopStoreInfo.schemaVersion` and current-schema assertions use **60**. Do not apply the packet's v59 R-R registration over the current source or rewrite earlier migrations.

Two regression additions cover this newer integration:

- [RRReconciliationStoreIntegrationTests.swift](../../Packages/WhoopStore/Tests/WhoopStoreTests/RRReconciliationStoreIntegrationTests.swift) upgrades a real v59 schema through the current migrator twice. It asserts exact SQLite storage values across `liftStrain`, `liftStrainTarget`, `liftStrainJob`, `liftStrainControl`, `workout` and `dailyMetric`; raw R-R/HR preservation; the intended quality annotations; and migration order/idempotence.
- [IntelligenceHistoryRescoreGenerationTests.swift](../../StrandiOSTests/IntelligenceHistoryRescoreGenerationTests.swift) adds a real AppModel background main/settle case with an applied lift and an independent HR-only comparator. It asserts preserved Strength inputs, target snapshots, job/control state, refreshed combined strain, retained v3 progress and no changes after completion reentry.

The history fixtures disable autonomous constructor tasks through the default-on `startRuntimeTasks` lifecycle parameter, then drive the real background entry explicitly. This isolates grant execution from launch bootstrap and source-coordinator startup; it does not claim cold-launch coverage.

These describe source assertions. Their presence alone does not establish execution or a passing result.

## Verification and remaining limits

The packet retains 579 Linux XCTest passes: 511 full-protocol, 57 analytics/cache subset and 11 SQL-policy/migration/fingerprint subset tests. Its additional 19 Python SQL tests, eight apply-helper tests and Swift syntax checks apply to the recorded packet inputs. They do not validate the post-PR #61 integration, full Apple package graph, app or device.

Run the current repository source audits, eight-package build/test matrix, XcodeGen app/widget simulator build and app simulator tests on the final reconciled source. Retain the tested commit, toolchain and logs. This document does not record a current green result.

Before release, validate an upgrade from an existing v59 store with a verified backup. Check Strength data, raw row counts/keys/order, provenance and quality annotation, receipt replay, and normal backup/restore. Exercise history main/settle cancellation, restart and progress on a phone. Use representative WHOOP 4 and WHOOP 5/MG recordings to inspect HRV/RHR, Charge drivers, edited sleep, partial days and strap swaps. Observe reconnect and history diagnostics with a real strap.

Historical repair remains subject to iOS background grants. Lost WHOOP 4 provenance cannot be reconstructed from collapsed labels. Current-day and edited-session preservation can retain an older nonnil physiological value after fresh analysis returns nil. The broader HRV over-count refusal/persistence work remains deferred. This port does not establish a WHOOP 5/MG historical-offload hardware fix, device migration latency or power use.
