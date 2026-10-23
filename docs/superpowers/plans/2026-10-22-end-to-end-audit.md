# NOOP end-to-end audit and repair plan

**Goal:** Fix confirmed defects on an isolated branch and deliver one unmerged draft PR.

**Architecture:** Keep the existing WHOOP protocol, persistence, analytics, and iOS boundaries. Use small repairs with regression cases. Preserve stored history and useful collection.

**Tech stack:** Swift 6, CoreBluetooth, SwiftUI, GRDB/SQLite, HealthKit, SwiftPM, XcodeGen.

**Review base:** `6f49d855d6f747103f4dc2a60949cb933445c3c0` (`main`).

## Constraints

- Support WHOOP 4.0, WHOOP 5.0, and WHOOP MG.
- Do not reduce essential sampling or useful sensor collection.
- Do not rewrite historical data, redesign UI, merge, deploy, or publish a release.
- Distinguish executed checks from device and iOS checks that cannot run locally.
- Check existing PRs #66, #67, and #68 before duplicating changes.

## Review and implementation tasks

1. Inventory the complete source and dependency graph; inspect recent commits and upstream `ryanbr/noop`.
2. Audit BLE lifecycle and WHOOP commands. Confirm defects, add targeted regressions, implement bounded fixes.
3. Audit analytics, sleep/recovery/strain and timestamp handling. Reproduce calculation defects before repair.
4. Audit durable intake, SQLite migrations, retries, HealthKit and source identity. Preserve save-before-ACK behavior.
5. Audit app lifecycle, repository caches, notifications, security, dependency use and WHOOP-only boundaries.
6. Run baseline and final available checks. Review the whole diff independently; resolve review findings.
7. Commit related fixes separately, push through GitHub, and open one draft PR with the findings and Codex handoff.

## Review focus

- Reconnection and source changes must not misassign buffered data or issue stale commands.
- Missing, duplicate, delayed, and out-of-order samples must not inflate health estimates.
- Day boundaries and DST must use a consistent calendar and source.
- Cancellation and background expiry must leave durable work available for retry.
- Dependency removal must preserve saved history, imported data, and supported WHOOP behavior.

## Execution record

Parallel specialists own BLE, analytics, and storage/HealthKit. The coordinator owns app/dependency integration and delivery. A fresh reviewer challenges the final diff. Detailed outcomes and coverage are recorded in the audit report accompanying the PR.

The supplied task already authorizes implementation and GitHub delivery. No additional approval checkpoint is required.
