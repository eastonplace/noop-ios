# Five NOOP Features Implementation Plan

> **For agentic workers:** Execute the independent feature tasks in parallel, then integrate
> and review the complete branch. User explicitly authorized implementation and a PR.

**Goal:** Deliver all five approved features in one reviewable, unmerged PR.

**Architecture:** Pure analytics and export/parsing helpers feed existing Repository,
ReceiptLift, Coach, WidgetKit and Workout-detail flows. Retain the local database and
verified App Group ownership contracts; use additive backward-compatible representations.

**Tech Stack:** Swift, SwiftUI, SwiftPM, GRDB/SQLite, ZIPFoundation, WidgetKit, App Intents.

**Spec:** `docs/superpowers/specs/2026-10-22-five-features-design.md`

## Global Constraints

All constraints in the spec apply. Root owns project/workflow integration and publishing.
Feature workers edit only assigned areas and do not commit or push concurrently.

## Review Focus

- Source/consent/date changes must suppress old Coach prose and stress results.
- Sparse/legacy/classified step data, sleep-awake gaps and wraps must remain interpretable.
- Failed or duplicate routine import must preserve all existing routines and Strength history.
- Legacy GPS decoding and pause/restart metadata must survive export and restore.
- New pure helpers must be wired to the actual current UI and data consumers.

## Task 1: Personal Stress

- [x] Write baseline-window, insufficient-history, current-day exclusion and cache-identity tests.
- [x] Implement `DaytimeStress.ScoringMode`, personal aggregation and a bounded source-aware resolver.
- [x] Add the opt-in control, mode explanation and foreground Today integration using existing UI.
- [x] Verify unchanged default analytics and DST behavior (44 focused tests); commit native source/cancellation tests for CI.

## Task 2: Coach Brief Widget

- [x] Add tests for App Group expiry, source/epoch isolation, consent clearing and interrupted output; execute pure payload tests.
- [x] Add a bounded pure Codable brief record in `NoopPhase34Core` and fail-closed App Group loader in `StrandiOSShared`.
- [x] Publish successful daily briefs from `LocalCoachEngine`; wire invalidation and scoped reloads.
- [x] Add `NOOPCoachBriefWidget` using existing widget visual components and Coach deep link.
- [ ] Verify empty/loading/expired views and native extension compilation.

## Task 3: Step Filtering

- [x] Add regression cases for non-gait activity, implausible rates, wraps and duplicate timestamps.
- [x] Add sleep-context tests for isolated movement, awake stages and coherent gait.
- [x] Adapt pure counters and daily/cycle/workout consumers without changing day boundaries.
- [x] Version derived analysis and add durable bounded history reanalysis where needed.
- [ ] Run existing step, Strain, daily-analysis and repair tests.

## Task 4: Routine Import

- [x] Test CSV quoting, XLSX sparse/shared-string cells, limits and malformed values.
- [x] Implement parser DTOs in StrandImport and adapter in Strand/Data.
- [x] Inject import into ReceiptLiftCoordinator; add file picker, preview and confirmation UI.
- [x] Add 10 native tests for consent, identities, source/transaction failures and deferred writes; execute 14 parser tests.

## Task 5: GPS Export

- [x] Test GPX/FIT serialization, checksums, bounds and invalid data in `WorkoutRouteExport`.
- [x] Extend finished-route and active-journal representations with backward-compatible metadata.
- [x] Add native Workout-detail export and a discoverable App Intent.
- [x] Verify pause/restart gaps and old route/backup decoding; add package to app/test targets.

## Task 6: Integration and PR

- [x] Run all 12 source audit commands and portable/component Swift suites; record native platform limits in `docs/five-features-review.md`.
- [x] Review the entire diff independently and resolve confirmed import/GPS cancellation and step-context defects.
- [x] Commit and push only the new branch through GitHub; open one draft PR targeting main (#70).
- [ ] Inspect native GitHub CI and fix attributable compilation/test failures where feasible.
- [ ] Update PR with exact results, remaining verification and pending-branch overlap.

## Pre-publication verification

On the completed feature tree: 142 portable/component tests passed (28 core, 44 stress,
37 step/cache, 14 spreadsheet parser, 10 route encoders, 9 route persistence/service);
all 12 static audit commands and syntax parsing of 64 changed Swift files passed.
Native Apple SDK typechecking, full database integration and simulator UI checks remain
assigned to the PR workflows and subsequent review.

## Native CI follow-up

The first full store run exposed GRDB overload inference producing SQL debug text inside
the personal-history query. Explicit String fragment types fix the query while retaining
bound values. The exact repository helper and six tests were executed against real
GRDB/SQLite: the original code reproduced the failure, and the corrected code passes all
six tests. Native full-suite reruns remain the authority for Apple-platform integration.

The first analytics run also exposed a DST fixture that depended on isolated movement
during detected sleep. It now includes a realistic retained walking bout in the boundary
hour, keeps the existing correct/incorrect-offset assertions, and pins the retained ticks.
The original failure was reproduced; all 17 exact-source day-boundary tests then passed.
The initial PR head compiled the complete iPhone app and extensions successfully in Xcode.

The `8c8b11d7` native rerun compiled the app/extensions again and passed all nine retained
package suites, including 641 WhoopStore and 1,536 StrandAnalytics tests. Its complete
artifact exposed an Apple XCTest isolation error in the GPS persistence test's teardown.
The teardown now constructs its own UserDefaults suite from the captured name instead
of capturing the non-Sendable instance returned to the test. This is a test-only fix;
full iOS unit and selected-screen UI verification remains assigned to the next rerun.
