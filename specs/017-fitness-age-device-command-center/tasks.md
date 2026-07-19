# Tasks

## Phase 1 — Planning and failing coverage

- [x] T001 Create feature 017 spec, plan, requirements checklist, and task ledger in `specs/017-fitness-age-device-command-center/`
- [x] T002 [P] [US1] Add Fitness Age detail snapshot, pace-gate, attribution, and sparse-series tests in `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/`
- [x] T003 [P] [US3] Add device-health priority and status-mapping tests in `StrandTests/DeviceCommandCenterStatusTests.swift`
- [x] T004 [P] [US4] Add command action-gating tests in `StrandTests/DeviceCommandCenterStatusTests.swift`
- [x] T005 [P] [US3] Add connection uptime transition coverage in `StrandTests/DeviceCommandCenterStatusTests.swift`

## Phase 2 — Shared presentation foundations

- [x] T006 [US1] Add pure Fitness Age detail snapshot and exact equation-driver attribution in `Packages/StrandAnalytics/Sources/StrandAnalytics/FitnessAgePresentation.swift`
- [x] T007 [US1] Add flat Fitness Age hero, pace, driver-row, and trend primitives in `Packages/StrandDesign/Sources/StrandDesign/FitnessAgeDetailComponents.swift`
- [x] T008 [US3] Keep device command-center presentation flat and app-local so `DevicesView` composes narrow production status/action leaves without a second design abstraction
- [x] T009 [US3] Add pure command-center snapshot, health priority, sync/R22/power mapping, and action gates in `Strand/Screens/DeviceCommandCenterStatus.swift`

## Phase 3 — Fitness Age destination

- [x] T010 [US1] Implement real repository/profile loading and full `FitnessAgeDetailView` in `Strand/Screens/FitnessAgeDetailView.swift`
- [x] T011 [US2] Reuse readiness checklist, Settings fixes, honest placeholders, and generic trend drill-down across `Strand/Screens/FitnessAgeDetailView.swift` and `Strand/Screens/HealthView.swift`
- [x] T012 [US1] Route Health and eligible Today/catalog Fitness Age taps to the dedicated detail screen in `Strand/Screens/HealthView.swift`, `Strand/Screens/TodayView.swift`, and `Strand/Screens/DashboardCatalogView.swift`
- [ ] T013 [US1] Verify scored and calibrating states with production data during phone QA; do not ship fixture/demo routes

## Phase 4 — Device command center

- [x] T014 [US3] Add `connectedAt` and consistent connection-state mutators in `Strand/BLE/LiveState.swift`
- [x] T015 [US3] Audit and migrate every connect, reconnect, disconnect, Bluetooth-off, forget, and teardown branch in `Strand/BLE/BLEManager.swift`
- [x] T016 [US4] Add the four thin active-device command wrappers in `Strand/App/AppModel.swift`
- [x] T017 [US3] Recompose `DevicesView` as active command center first, with narrow timer leaves for packet freshness/uptime, in `Strand/Screens/DevicesView.swift`
- [x] T018 [US5] Preserve add/rename/switch/remove/re-add/delete-data flows for other and removed devices in `Strand/Screens/DevicesView.swift`
- [x] T019 [US4] Wire local command feedback, disabled reasons, and WHOOP/non-WHOOP capability handling in `Strand/Screens/DevicesView.swift`

## Phase 5 — Verification and unmerged delivery

- [x] T020 [US6] Add backward-compatible enriched snapshot and slow/fast publishers in `StrandiOSShared/WidgetSnapshot.swift` and `StrandiOS/Widgets/WidgetPublish.swift`
- [x] T021 [US6] Adopt component 41 Home/Lock families and add the circular-only Strain widget in `StrandiOSWidgets/`
- [x] T022 [US6] Add optional workout Live Activity state and mode-aware controller/rendering in `StrandiOSShared/`, `StrandiOS/Widgets/`, and `StrandiOSWidgets/`
- [x] T023 [US6] Add widget codec/publication and Live Activity transition/parity tests in `StrandiOSTests/`

## Phase 6 — Verification and unmerged delivery

- [x] T024 [P] Run StrandAnalytics and StrandDesign package suites and WhoopStore regressions
- [ ] T025 [P] Run focused Fitness Age, device resolver, action-gating, uptime, navigation, registry, widget, and activity tests
- [x] T026 Run source audits for fixture leakage, fake sync percentages/impacts, `bonded`-as-full-bond, battery-health wording, R22 live-stream claims, and unintended gray raised surfaces
- [x] T027 Run macOS compile and signed iPhone Release build using the configured Xcode build tooling
- [ ] T028 Install in place on the connected iPhone with the existing bundle ID and verify the production database remains populated
- [ ] T029 Complete physical-phone visual/interaction QA for all three components and record screenshots/results in `specs/017-fitness-age-device-command-center/qa/verification.md`
- [ ] T030 Run the no-mistakes review and resolve feature-owned findings
- [ ] T031 Commit and push the current child branch/PR #5 and leave PR #4 and PR #5 unmerged

## Dependencies

- T002 blocks T006–T013.
- T003–T004 block T009 and T017–T019.
- T005 blocks T014–T015.
- T006–T009 block both screen integrations.
- T014–T016 block command-center action wiring.
- T020–T023 block verification; T024–T027 block physical install; T028 blocks phone QA; T029–T030 block T031.

## Suggested implementation slice

Complete US1/US2 first as an independently testable Fitness Age destination, then US3/US4 as the active-device command center, and finally US5 regression work before device delivery.
