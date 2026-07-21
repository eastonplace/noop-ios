# Tasks 012 — Wave 2 Ship Plan (Kits 42–47 + Widget Fix + Sleep Performance V2)

> **Parallelize.** Tasks tagged with the same lane share files and run in order
> inside that lane; different lanes run CONCURRENTLY via subagents. `[P]` = safe to
> parallelize even within its lane. Only two sync points: Lane 2 takes Lane 1's
> gates when ready, and the Sleep Integration Slot starts after Lanes 1 and 6.
> Gate per merged unit = package tests + all targets build. Screenshots only at
> final QA.

## Setup (serial, fast)

- [x] T001 `git pull origin main` first (this local clone can lag origin), then branch off `main`; merge PR #6 (`agent/sleep-performance-v2-foundation`) into the working branch; run `swift test` in `Packages/StrandAnalytics` to confirm the 15 foundation tests pass
- [x] T002 Record SHA-256 checksums of the six lab kit files in `design-lab-snapshot-wave2.sha256`; skim each lab file header for design intent before assigning lanes

## Lane 1 — Kit 46, Sheets & Alerts

- [ ] T101 Promote `PaperSheetCard`, `ConfirmGateCard`, `HoldToConfirmButton`, `DestructiveGateCard`, `SuccessFlashCard` to StrandDesign with action-closure APIs; merge `PaperToastCard` into the existing `PaperToast.swift` (one toast, no visual regression at existing call sites); update lab to consume
- [ ] T102 Wire `DestructiveGateCard` into the real destructive flows (clear data, delete imports, remove device, delete journal item) preserving each exact effect; migrate toast call sites (`WorkoutsView`, `SleepView`, `BackupSyncView`, `DataSourcesView`); Undo only where genuinely reversible

## Lane 2 — Kit 43, Settings

- [ ] T201 Inventory every interactive control in `SettingsView.swift` + all settings sub-screens into `tool-inventory.md` (row, type, store/binding, destination) — the spec's one formal parity artifact
- [ ] T202 Promote the Settings Kit (`SettingsRowModel` + `custom(id:view:)` case, `SettingsSectionModel`, `SettingsProfileHeader`, `SettingsSectionCard`, `SettingsRowView`, `SettingsScreenTemplate`) with Binding-based APIs; update lab to consume
- [ ] T203 [P] Rebuild settings sub-screens on `SettingsScreenTemplate` bound to real stores per the inventory (parallelize sub-screens across subagents; non-fitting rows use the `custom` case, never get cut)
- [ ] T204 Rebuild the Settings root (real profile header, quarantined destructive section using Lane 1 gates, real version footer); then diff `tool-inventory.md` — zero lost controls, fix any gap immediately

## Lane 3 — Kit 42 Metric Detail + Kit 45 Compare

- [ ] T301 Promote `MetricDetailConfig`/`MetricDetailHeroCard`/`MetricDetailTemplate` (reusing production `TrendPanelChart`, all sections optional-by-config) and the Compare kit (`CompareSeries`, `ComparePickerRow`, `CompareLagChips`, `CompareDualChart`, `CompareCorrelationCard`, `CompareStatDuo`); update lab to consume
- [ ] T302 Build the `MetricDetailConfig` adapter over `MetricCatalog` + `repo.resolvedSeries` with unit tests for the sparse-window rule (window relative to latest point, expand only on zero, "as of" dating, rail omitted when no typical-range source); adopt in `MetricExplorerView` detail keeping the range control, insight cards, annotations, and exports via config sections
- [ ] T303 Adopt the Compare A/B pair experience over `repo.resolvedSeries` (existing picker + range control, real dated series, `CorrelationEngine.pearson` with real n — add one Pearson-parity test); keep 3–4-metric compare via the existing overlay restyled; defer `CompareLagChips` unless a real lag computation exists

## Lane 4 — Kit 44, Journal & Check-ins

- [ ] T401 Promote the Journal kit with tri-state `Binding<Bool?>`/value bindings; update lab to consume
- [ ] T402 Re-skin `JournalLogCard` preserving tri-state, `journalDeviceId` write path, wake-day attribution, imported-question adoption, and full #322 edit mode; add write-path unit tests; bind `JournalMoodRow` to `MoodStore`
- [ ] T403 [P] Adopt `JournalImpactCard` for the InsightsView behaviour-effect cards (existing with/without model, real n, significance) and `JournalStreakStrip` from real history

## Lane 5 — Widget sizing fix

- [ ] T501 Fix `NOOPRecoverySmallWidgetView` (and check siblings + accessories) in `Packages/StrandDesign/Sources/StrandDesign/WidgetLiveComponents.swift`: remove manual padding stacked on system content margins, expand the root frame to fill the container, scale ring/type from family geometry (see plan.md Lane 5); verify in WidgetKit previews, the add-widget gallery, and on device — no dead band, no clipping

## Lane 6 — Sleep Performance V2 engine (shadow mode)

Execute `docs/superpowers/plans/2026-07-20-sleep-performance-v2.md`; its hard
invariants are merge blockers and its constants are the approved contract.

- [ ] T601 [P] Work unit 1: run foundation tests; add the property-boundary suite (`SleepPerformanceV2PropertyTests.swift`)
- [ ] T602 Work unit 2: `SleepNightSummary` from the existing main-night selector + edit seam (naps excluded, efficiency counted once, imported rows only when sources provide real values)
- [ ] T603 [P] Work unit 3: `SleepStressV1` + tests (renormalize missing signals, nil under six windows, no self-baseline)
- [ ] T604 Work unit 4: chronological `SleepScoringContextBuilder` + oldest-first replay in `IntelligenceEngine` with 30-night warm-up
- [ ] T605 Work unit 5: shadow persistence of the V2 component/version series under the computed source (no authority change, imported WHOOP untouched)
- [ ] T606 Work unit 6: Recovery exactness behind the flag — one `recoveryInput` threaded to Recovery, drivers, and trace; delete live `AnalyticsEngine.Rest.composite(daily:)` reconstruction paths per the doc
- [ ] T607 Work unit 7: source-aware day-keyed score points; remove the last-non-null "last night" fallback; freshness + provenance tests
- [ ] T608 Build the real conditional alarm evaluator + actuation path: `Sleep goal` evaluates canonical `SleepNeedV2` against current banked sleep; `In the green` uses the existing `RecoveryForecaster` conservatively (`forecast.low` crossing the existing green threshold); pre-arm the window endpoint as a strap fail-safe, opportunistically re-arm through encrypted BLE when the condition is met, persist evaluation/actuation provenance + readback, and test missing/stale/disconnected/background cases without claiming guaranteed early wake on iOS

## Sleep Integration Slot (ONE lane; starts after Lanes 1 & 6)

- [ ] T701 Promote the Sleep Alarm kit (`SleepAlarmModuleCard`, `SleepNeedBreakdownCard`, `SleepPlanTimeline`) parameterizing clock/need/mode-availability (lab keeps fixture constants); update lab to consume
- [ ] T702 Adopt Kit 47 + Sleep V2 phase G together across `SmartAlarmView`, `SleepView`, `WindDownNudge`, `TodayView`, `CoupledView`, `MetricCatalog`: alarm module arms the strap silent alarm with smart modes on canonical `SleepNeedV2` need (truthful disabled states, live "asleep by", real clock); `SleepNeedBreakdownCard` = V2 need breakdown; `SleepPlanTimeline` from tonight's real plan; per-day overrides + honesty card + wind-down stay reachable; canonical `SleepScoreExplanation` copy per the plan doc (flag-aware); add the alarm need-recompute test
- [ ] T703 Work unit 10 (SEPARATE final commit, may trail the ship): migration, compatibility key, authority flip — ONLY after the sleep plan doc's own release gates pass

## Final QA (once)

- [ ] T801 Full build matrix (package tests, xcodegen, iOS/widgets/watch/macOS) + confirm non-iPhone targets inherited no unintended redesign
- [ ] T802 One consolidated visual pass: six surfaces + widget families on iPhone, light/dark + Dynamic Type XL + Reduce Motion, screenshots to `outputs/<date>/qa/012-adoption/`; install in place on device; spot-check routes; commit and merge
