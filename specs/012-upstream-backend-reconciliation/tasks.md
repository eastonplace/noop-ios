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
- [ ] T022 Build signed Release for iPhone and install in place with data preserved.
- [ ] T023 Record available physical WHOOP QA and focused iPhone visual evidence.
- [x] T024 Commit, push, open draft PR, and record exact evidence.
- [x] T025 Diagnose the pre-run GitHub Actions failures and record the external billing gate.
