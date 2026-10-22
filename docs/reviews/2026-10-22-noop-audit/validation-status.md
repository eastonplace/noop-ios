# Validation status

Review date: 2026-10-22. Code commit: `1e0f7d8fda83a31c302e53580e2739db6212cdca` (the following audit-documentation commit does not change production code).

## Executed locally

| Check | Actual result |
| --- | --- |
| NoopPhase34Core full package | **107 passed**. |
| WhoopProtocol full package, final Broadcast patch | **528 passed**, zero failures, unchanged compiled test binary executed as UID/GID 65534. The root-only chmod fixture issue is explained in the BLE report. |
| OuraProtocol full package | **78 passed**. |
| Selected actual-source analytics package | **192 passed** after all metric changes and the HRV optimization. Nineteen production sources and eleven repository test source files; not the complete Apple-dependent package graph. |
| Actual-source lifting subset | **12 passed**; three new boundary/DST regressions failed on original code. Linux localization availability shim only. |
| Actual-source report URL | **1 passed** after an assertion-level failure against the original destination. |
| Exact-method storage/HealthKit | **8 pre/post assertions** fail before and pass after, using actual production methods with explicit platform/I/O seams. Pruning exercises SQLite at a 999-variable limit and preserves protected history. |
| Exact parser and real engine HR-arrival harness | **376 checks passed** across WHOOP 4 and 5/MG semantics, invalid values, equal arrivals, display dedup, cached replay and genuine silence. Not Apple Combine or CoreBluetooth execution. |
| Actual preference helper with Foundation/CoreFoundation | **12 persistence checks passed** for absent, explicit, registered and malformed preferences. Not the native app test target. |
| Widget exact-helper/production-SQL harness | **5 groups passed**; the original helper failed the two row-truncation cases. Includes dense midday RMSSD, 25-hour day, equal-timestamp RR, source priority and invalid bounds. |
| HRV original/patched equivalence | **37,555 fixtures, zero exact-output mismatches**, including Double bit patterns, gap flags and final HRV fields. |
| All twelve CI source-contract audits | **12 passed** on the final code. Project-hygiene's thirteen Python tests also passed. |
| Apple-target Swift syntax | **46 changed/new Swift files parsed**, zero diagnostics, exit 0. This does not resolve Apple imports or type-check the app. |
| Whitespace/conflict check | `git diff --check` passed. |

There are **67 newly added named regression tests** across the normal package/app test files, plus the existing updated report-destination expectation. Some ran in the actual-source Linux suites; native app/framework-dependent execution remains outstanding. The total is an inventory of added tests, not a claim that all 67 ran on iOS.

Existing source-audit warnings were retained: a Python regex escape warning and the main-branch marketing-version/changelog mismatch (the latter is existing PR67 work). Neither audit failed. No checks were disabled.

## Attempted but blocked locally

- **NoopLocalAccess:** dependency fetch succeeded with approved network execution; compilation then failed because the host lacks `sqlite3.h`, so GRDB's `CSQLite` module could not build. This is a recorded environment limitation, not a passing package run. The condensed diagnostic is in [evidence/local-access-attempt.txt](evidence/local-access-attempt.txt).
- **Full StrandAnalytics/WhoopStore/StrandImport graph:** the initial full analytics attempt could not fetch GRDB through the restricted proxy. The host also lacks Apple's Compression module used by WhoopStore. Focused analytics and real-SQLite harnesses bypass only those platform dependencies and are explicitly scoped above.
- **App, widgets and native iOS tests:** no Xcode, iOS SDK, Simulator, UIKit, CoreBluetooth or HealthKit runtime is available here. All native tests are included in the generated project's existing test directory for macOS CI.
- **WHOOP hardware, Instruments and battery:** no physical device or iPhone attached. No physical-device pass or quantified energy improvement is claimed.

## GitHub CI

The draft PR triggers the repository's existing `iOS build and tests` and Swift package workflows. Their current final-head status is shown by the PR checks and the delivery summary. This document records local evidence before those hosted runs; it deliberately does not predict or pre-mark a native build as passed.

The draft remains unmerged. Merge readiness requires the native and physical-device checks in [CODEX_HANDOFF.md](CODEX_HANDOFF.md), reconciliation of the remaining open-PR work, and user review.

## Commit grouping

| Commit | Change |
| --- | --- |
| `1f744808` | Connection intent/callbacks/removal, live arrival freshness, explicit Broadcast OFF and reboot diagnostics. |
| `59622450` | Seven physiological-input, chronology and sleep-cache/clipping corrections with regressions. |
| `bcb9cfeb` | Output-equivalent upstream HRV scratch-buffer optimization. |
| `b208308c` | Bounded raw pruning and cancellation-safe/owned HealthKit work. |
| `4081cea3` | Complete civil-day widget stress input. |
| `18d29c98` | Half-open calendar-week summaries. |
| `1e0f7d8f` | Fork-specific diagnostic report destination. |

An additional documentation commit contains this review, specialist reports, independent challenge, test evidence and device handoff.
