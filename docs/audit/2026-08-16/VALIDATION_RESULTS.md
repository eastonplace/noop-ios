# Validation results

## Identity

- Audit base: `b72ff860660915f5e709d106649820b8a4d284f3`.
- Tested source SHA: `dbe45e72f1fbd7e34d28012cb6294d1fed13ec79`.
- Worktree: `/private/tmp/noop-audit-p0-settings-whoop-20260816`.
- Branch: `codex/noop-audit-p0-settings-whoop-20260816`.

## Package suites

Each command was run from the isolated worktree.

| Command | Result |
| --- | --- |
| `swift test --package-path Packages/NoopLocalAccess` | 9 XCTest, 0 failures |
| `swift test --package-path Packages/NoopPhase34Core` | 21 XCTest + 99 Swift Testing, 120 total, 0 failures |
| `swift test --package-path Packages/OuraProtocol` | 78 XCTest, 0 failures |
| `swift test --package-path Packages/StrandAnalytics` | 1,199 XCTest, 0 failures |
| `swift test --package-path Packages/StrandDesign` | 97 tests, 0 failures, 0 skipped |
| `swift test --package-path Packages/StrandImport` | 193 XCTest, 0 failures, 1 skipped because `XIAOMI_REAL_DB` was absent |
| `swift test --package-path Packages/WhoopProtocol` | 328 XCTest, 0 failures; history-ingest p50 3.427 ms, p95 3.598 ms, max 3.732 ms |
| `swift test --package-path Packages/WhoopStore` | 447 XCTest, 0 failures |

The initial parallel package attempt stalled without child compiler output and was terminated. The suites were then run sequentially. The sequential results above are the authoritative package results.

## iOS project and simulator

- `xcodegen generate`: passed.
- Project: `/private/tmp/noop-audit-p0-settings-whoop-20260816/Strand.xcodeproj`.
- Scheme: `NOOPiOS`.
- Configuration: `Debug`.
- Simulator: `NOOP QA iPhone 17 Pro`, UDID `EFB5332C-8323-447A-9840-D9FB69A5703B`, iOS 26.5.
- Build: passed in 32.6 seconds with no warnings or errors.
- Test: passed with 484 tests, 0 failures, 1 skipped in 116.6 seconds.
- Derived data: `/private/tmp/noop-audit-p0-settings-whoop-20260816/DerivedData`.
- Build log: `/Users/eastonplace/Library/Developer/XcodeBuildMCP/workspaces/Noop-3309460202ce/logs/build_sim_2026-08-16T22-27-27-423Z_pid92798_68c07004.log`.
- Test log: `/Users/eastonplace/Library/Developer/XcodeBuildMCP/workspaces/Noop-3309460202ce/logs/test_sim_2026-08-16T22-28-20-103Z_pid92798_5559c054.log`.
- Result bundle: `/Users/eastonplace/Library/Developer/XcodeBuildMCP/workspaces/Noop-3309460202ce/result-bundles/test_sim_2026-08-16T22-28-20-103Z_pid92798_ef922e36.xcresult`.

No physical iPhone or WHOOP device was touched. No install, uninstall, reset, reseed, or app-container deletion was performed.

## Source and contract audits

Passed:

- `python3 Tools/qa/source_contract_audit.py` — 867 Swift files, 0 architecture warnings.
- `python3 Tools/qa/ui_unification_contract_audit.py`.
- `python3 Tools/qa/workout_runtime_contract_audit.py`.
- `python3 Tools/qa/workout_persistence_contract_audit.py`.
- `python3 Tools/qa/trends_snapshot_contract_audit.py`.
- `python3 Tools/qa/accessibility_localization_contract_audit.py`.
- `python3 Tools/qa/healthkit_sync_contract_audit.py`.
- `python3 Tools/qa/test_audit_phase34.py` — 11 tests, all passed.

`python3 Tools/qa/audit_phase34.py .` completed with 0 errors and 39 P34-012 warnings. `--strict` exits 1 because the existing warnings are treated as failures. The warnings are fixed-day-duration review findings across existing health-day paths; they were not changed as part of this branch.

## Not run

- Release build and signed physical-device install.
- WHOOP 4, WHOOP 5, or WHOOP MG physical qualification.
- Current phone App Group/token/database/log trace.
- Energy, wakeup, radio, or thermal measurement scenarios.
