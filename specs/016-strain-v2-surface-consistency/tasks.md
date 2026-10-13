# Tasks

## Phase 1 — Setup and failing coverage

- [x] T001 Create feature 016 artifacts and import the supplied audit inventory in `specs/016-strain-v2-surface-consistency/`
- [x] T002 [P] Add failing DailyMetric provenance tests in `Packages/WhoopStore/Tests/WhoopStoreTests/`
- [x] T003 [P] Add failing WorkoutRow copy/relabel tests in `StrandiOSTests/`
- [x] T004 [P] Add failing resolver/freshness matrix tests in `Packages/WhoopStore/Tests/WhoopStoreTests/`
- [x] T005 [P] Add failing live-workout Building and finish-equivalence tests in `StrandiOSTests/`
- [x] T006 Classify all production Strain occurrences in `specs/016-strain-v2-surface-consistency/surface-matrix.csv`

## Phase 2 — Foundational provenance and resolver

- [x] T007 [US4] Add preservation-first DailyMetric and WorkoutRow replacement APIs in `Packages/WhoopStore/Sources/WhoopStore/`
- [x] T008 [US4] Refactor daily merge/sleep/step and workout edit/relabel/import copy paths across `Strand/` and `Packages/`
- [x] T009 [US1] Add `ResolvedStrain` and pure `StrainResolver` in shared domain source under `Packages/WhoopStore/Sources/WhoopStore/`
- [x] T010 [US1] Publish canonical and imported daily/workout Strain APIs from `Strand/Data/Repository.swift`

## Phase 3 — Live daily consistency

- [x] T011 [US1] Add authoritative incremental physiological-day accumulator parity coverage in `Packages/StrandAnalytics/Tests/`
- [x] T012 [US1] Implement shared live-day coordinator outside Today in `Strand/App/` and `Strand/Data/`
- [x] T013 [US1] Replace Today private live ownership and make Today/detail consume the same resolved value in `Strand/Screens/TodayView.swift`
- [x] T014 [US1] Reconcile live state across day rollover, cycle changes, backgrounding, and backfill completion in `Strand/App/`

## Phase 4 — Live workout and durable finish

- [x] T015 [US2] Replace persisted numeric live default with Building/scored state in `Strand/App/ActiveWorkoutPersistence.swift` and `Strand/App/AppModel.swift`
- [x] T016 [US2] Render Building progress and genuine scored zero distinctly in `Strand/Screens/LiveWorkoutView.swift`
- [x] T017 [US3] Convert workout finish to an awaited durable read-back transaction in `Strand/App/AppModel.swift`
- [x] T018 [US3] Add saving/failure/retry and double-submit protection in `Strand/Screens/LiveWorkoutView.swift`
- [x] T019 [US3] Re-resolve workout detail by natural key in `Strand/Screens/WorkoutDetailView.swift`

## Phase 5 — Surface migration

- [x] T020 [P] [US1] Migrate Trends, weekly summaries, Coupled, metric explorer, compare, and reports in `Strand/Screens/`
- [x] T021 [P] [US1] Migrate widget and Live Activity models in `StrandiOS/` and widget sources
- [x] T022 [P] [US1] Migrate Watch snapshot/complication and coaching/notification text in Watch and app sources
- [x] T023 [US4] Restrict workout aggregates/headlines to canonical V2 and label imported comparisons in workout screens
- [x] T024 [US4] Retire ambiguous user-facing Effort presentation aliases and add a static allowlisted audit script under `scripts/`

## Phase 6 — Verification and delivery

- [~] T025 Run every package suite, focused app tests, source audit, simulator build, signed device build, and database quick check
- [ ] T026 Install in place and complete physical Home/detail, Building, finish/list/detail/relaunch, widget, Live Activity, and Watch QA
- [x] T027 Record exact evidence in `specs/016-strain-v2-surface-consistency/qa/verification.md`
- [x] T028 Commit and push `codex/strain-v2-surface-consistency`, open a child PR against `codex/noop-v2-trends-performance`, and leave both unmerged
- [ ] T029 Run the no-mistakes gate and resolve findings without merging

## Dependencies

- T007–T010 block every surface migration.
- T011 blocks T012–T014; T015 blocks T016–T018.
- T017 must pass before T019 and physical finish QA.
- T020–T024 must complete before source audit and cross-surface equality acceptance.
- T025 and T026 both gate T028–T029.
