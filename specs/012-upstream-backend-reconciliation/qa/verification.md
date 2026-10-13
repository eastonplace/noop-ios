# Verification Ledger

Status: implementation and draft delivery complete; external CI and hardware gates active

Draft PR: https://github.com/eastonplace-ai/noop/pull/3

## Automated

- `Packages/WhoopProtocol`: 0 failures.
- `Packages/WhoopStore`: 268 tests, 0 failures.
- `Packages/StrandAnalytics`: 1,097 tests, 0 failures.
- `Packages/StrandImport`: 189 tests, 0 failures, 1 environment-fixture skip.
- `NOOPiOS` Release, generic physical iOS destination, signing disabled: build passed.

## GitHub Actions

- Both PR workflows were accepted for commit `70ff4df7`, but every macOS job ended before
  runner allocation: `runner_id` is `0`, `steps` is empty, and no job log exists.
- GitHub's check annotation says the jobs were not started because recent account payments
  failed or the Actions spending limit must be increased.
- This is an account billing/limit gate, not a source or workflow failure. CI must be rerun
  after resolving **Settings → Billing & plans**; no speculative workflow change was made.

## Database and data integrity

- Private coaching tables remain covered by migration-preservation tests.
- Private migrations are ordered as `v25-daily-spo2-raw`, `v26-rr-seq`,
  `v27-efficiency-heal`, and `v28-ppg-waveform`.
- Equal same-second R-R values survive with deterministic `seq`; replay remains idempotent.
- Gap-aware HRV fixtures pass.
- Fixed an integration regression where Oura's readiness contributor score could overwrite measured RHR.
- Removed an orphan `ouraRaw` deletion reference because this private fork does not ship that table.

## iPhone build/install

- Unsigned Release compile passed for `generic/platform=iOS` from regenerated `project.yml`.
- Signed build, in-place install, launch readback, and visual QA remain blocked: both paired iPhones are
  currently reported by CoreDevice as `unavailable`.
- No uninstall, container reset, demo seeding, or phone-data mutation was performed.

## Hardware

WHOOP 4.0/5.0/MG behavior remains `UNVERIFIED` on physical hardware in this run.

## Scope

- Pinned target `42b868f5d7c580d55848592a3aaacb2e0ea11963`.
- Pinned upstream stable `25eb933a2563d490583ecd4c0051dff581874bb8` plus only
  `f5f64977b9a83b2e74dccfee21daaeb5e7089a45` and
  `6a285e258c2443a2be64cbcb5eda9796878670e4`.
- No Android paths, Oura-cloud schema, upstream design system, or accidental iCloud ` 2.*` copies included.
- Private team, app group, app/widget bundle identifiers, Paper UI, and coaching schema preserved.
