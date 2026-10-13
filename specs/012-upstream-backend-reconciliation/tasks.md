# Tasks

## Setup

- [x] T001 Preserve and checksum the local-only String Catalog delta.
- [x] T002 Align canonical `main` to `42b868f5` without changing worktree content.
- [x] T003 Create isolated branch/worktree and preserve the implementation package.
- [x] T004 Extract and adapt the package reconciliation script.

## Import and correctness

- [x] T010 Apply the released backend allowlist and selected hotfixes.
- [x] T011 Reconcile private migrations and preservation tests.
- [x] T012 Implement deterministic R-R sequence storage and gap-aware HRV.
- [x] T013 Integrate WHOOP protocol/BLE/raw sensor and power behavior.
- [x] T014 Integrate storage/import/export/HealthKit/sleep/identity behavior.
- [x] T015 Wire private Today/Settings adapters and version metadata.

## Verification and delivery

- [x] T020 Pass scope/static gates and all four Swift package suites.
- [x] T021 Pass migration, R-R/HRV, import/export and HealthKit fixtures.
- [x] T022 Build signed iPhone app and install in place with data preserved; launch confirmed on
      Easton’s iPhone 17 Pro (iOS 26.5.2) on 2026-07-17.
- [ ] T023 Record available physical WHOOP QA and focused iPhone visual evidence.
- [x] T024 Commit, push, open draft PR, and record exact evidence.
- [x] T025 Diagnose the pre-run GitHub Actions failures and record the external billing gate.
- [x] T026 Reconcile the newer Strain V2 task without undoing backend fixes: schema v29,
      continuous HRR scoring, sleep-to-sleep shadow rows, imported-score protection, and canonical 0–21 display.
- [x] T027 Pass updated WhoopStore (273), StrandAnalytics (1,108), StrandImport (189),
      and NOOPiOS simulator (12) regression tests; produce a signed physical-device build.
