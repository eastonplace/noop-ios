# Validation status

Review date: 2026-10-22. Production-code commit: `1e0f7d8fda83a31c302e53580e2739db6212cdca`. Later documentation and calorie-golden expectation updates do not change production code.

## Executed locally

| Check | Actual result |
| --- | --- |
| NoopPhase34Core full package | **107 passed**. |
| WhoopProtocol full package, final Broadcast patch | **528 passed**, zero failures, unchanged compiled test binary executed as UID/GID 65534. The root-only chmod fixture issue is explained in the BLE report. |
| OuraProtocol full package | **78 passed**. |
| Selected actual-source analytics package | **192 passed** after all metric changes and the HRV optimization. Nineteen production sources and eleven repository test source files; not the complete Apple-dependent package graph. |
| Actual-source lifting subset | **12 passed**; three new boundary/DST regressions failed on original code. Linux localization availability shim only. |
| Actual-source report URL | **1 passed** after an assertion-level failure against the original destination. |
| Golden-calorie follow-up and workout suite | **10 passed** after correcting exactly one invalid-input expectation; all 1,123 other golden entries and every strict assertion remain unchanged. |
| Exact-method storage/HealthKit | **8 pre/post assertions** fail before and pass after, using actual production methods with explicit platform/I/O seams. Pruning exercises SQLite at a 999-variable limit and preserves protected history. |
| Exact parser and real engine HR-arrival harness | **376 checks passed** across WHOOP 4 and 5/MG semantics, invalid values, equal arrivals, display dedup, cached replay and genuine silence. Not Apple Combine or CoreBluetooth execution. |
| Actual preference helper with Foundation/CoreFoundation | **12 persistence checks passed** for absent, explicit, registered and malformed preferences. Not the native app test target. |
| Widget exact-helper/production-SQL harness | **5 groups passed**; the original helper failed the two row-truncation cases. Includes dense midday RMSSD, 25-hour day, equal-timestamp RR, source priority and invalid bounds. |
| HRV original/patched equivalence | **37,555 fixtures, zero exact-output mismatches**, including Double bit patterns, gap flags and final HRV fields. |
| CI source/audit validation | **11 source-audit scripts and the 13-test project-hygiene suite passed (12 commands total)** on the final code. |
| Apple-target Swift syntax | **48 changed/new Swift files parsed**, zero diagnostics, exit 0, including the two golden-test follow-up files. This does not resolve Apple imports or type-check the app. |
| Whitespace/conflict check | `git diff --check` passed. |

There are **67 newly added named regression tests** across the normal package/app test files, plus updated existing report-destination and invalid-input calorie expectations. Some ran in the actual-source Linux suites, and the native app unit-test step subsequently passed at the documentation checkpoint described below. The total is an inventory of added tests, not a claim that all 67 were individually confirmed in a final-head native run; remaining package and final-head integration checks still apply.

Existing source-audit warnings were retained: a Python regex escape warning and the main-branch marketing-version/changelog mismatch (the latter is existing PR67 work). Neither audit failed. No checks were disabled.

## Attempted but blocked locally

- **NoopLocalAccess:** dependency fetch succeeded with approved network execution; compilation then failed because the host lacks `sqlite3.h`, so GRDB's `CSQLite` module could not build. This is a recorded environment limitation, not a passing package run. The condensed diagnostic is in [evidence/local-access-attempt.txt](evidence/local-access-attempt.txt).
- **Full StrandAnalytics/WhoopStore/StrandImport graph:** the initial full analytics attempt could not fetch GRDB through the restricted proxy. The host also lacks Apple's Compression module used by WhoopStore. Focused analytics and real-SQLite harnesses bypass only those platform dependencies and are explicitly scoped above.
- **App, widgets and native iOS tests:** no Xcode, iOS SDK, Simulator, UIKit, CoreBluetooth or HealthKit runtime is available here. All native tests are included in the generated project's existing test directory for macOS CI.
- **WHOOP hardware, Instruments and battery:** no physical device or iPhone attached. No physical-device pass or quantified energy improvement is claimed.

## GitHub CI

The [draft PR #71](https://github.com/eastonplace/noop-ios/pull/71) triggers the repository's existing `iOS build and tests` and Swift package workflows. Hosted source audits passed at both initial documentation heads. These completed checkpoint results are recorded precisely; they are not substitutes for checks on the subsequent golden-test/documentation commit.

At `dc948c99b64ca0bff274637521dc5752a20d2cf9`:

- The [iPhone app and extension build and native `NOOPiOSTests` step both passed](https://github.com/eastonplace/noop-ios/actions/runs/39718743681/job/119627139803), using Xcode 26.6 / Apple Swift 6.3.3. The build ran from 03:55:38 to 04:05:22 UTC; native unit tests ran from 04:05:25 to 04:20:47 UTC on 2026-10-22. GitHub's step metadata confirms success; a complete native test count was not available from the cached partial log at this checkpoint. UI regressions were still running when the final follow-up was prepared.
- The macOS [WhoopProtocol job passed all 528 tests](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326191), [OuraProtocol passed all 78](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326204), [NoopLocalAccess passed all 9](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326156), and [StrandDesign passed all 257](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326136). NoopLocalAccess's hosted result resolves the validation gap from the local Linux host's missing SQLite headers.
- The [full StrandAnalytics job built successfully, then failed its test step](https://github.com/eastonplace/noop-ios/actions/runs/39718743671/job/119627326321): 1,519 XCTest tests, two assertion failures in one golden case, `rescore.kcal|messy day`. This was an actual test failure, not cancellation. WhoopStore, NoopPhase34Core and StrandImport had not completed at this checkpoint.

The same single golden mismatch had appeared in the earlier hosted run at `32a0314c`. Independent exact-base/head reproduction showed that the original expectation included five invalid HR samples, the behavior deliberately corrected by MET-07. Only that calorie literal is updated in the final follow-up; all 1,123 other golden entries and every bit-exact assertion remain unchanged. The corrected focused golden/workout suite passed all 10 tests locally. See [the follow-up evidence](golden-calorie-followup.md). Neither pre-correction full analytics run is reported as passing.

The subsequent push may cancel still-running jobs through the repository's existing workflow concurrency policy. Completed steps above retain their stated scope; any cancellation is not a passing UI or package result. Current final-head status is shown by the PR checks and delivery summary. The final-head hosted workflows must complete before merge.

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

Documentation commits contain this review, specialist reports, independent challenge, test evidence and device handoff, followed by retention/count wording clarifications from the delivery review. The final test/documentation commit corrects one invalid-input calorie golden expectation and records the hosted checkpoint and existing UI-baseline follow-up; it does not modify production code.
