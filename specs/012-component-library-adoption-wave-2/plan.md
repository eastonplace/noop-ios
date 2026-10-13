# Plan 012 — Wave 2 Ship Plan (Kits 42–47 + Widget Fix + Sleep Performance V2)

Read `spec.md` first. Rules everywhere: **preserve the lab's visual design
pixel-for-pixel, replace only the data plumbing, never let an existing production
tool disappear, and parallelize everything that doesn't share files.**

## Parallelization map (read before starting)

Run these lanes concurrently with subagents; sync only at the marked join points.

```text
Lane 1  Kit 46 Sheets & Alerts promotion+wiring ─┐
Lane 2  Kit 43 Settings (inventory → adopt)      ├─ join: Settings destructive rows
Lane 3  Kit 42 Metric Detail + Kit 45 Compare    │        use Lane 1 gates
Lane 4  Kit 44 Journal & Check-ins               │
Lane 5  Widget sizing fix (independent, tiny)    │
Lane 6  Sleep V2 phases A–F (package + engine)  ─┴─ join: SLEEP INTEGRATION SLOT
                                                     (Kit 47 + Sleep V2 UI phase G
                                                      land together, one lane)
Final   Consolidated QA + device install
```

- Lanes 1–5 touch disjoint files except the Lane 1→2 join (Settings destructive
  rows adopt the promoted gates; Settings work can start immediately and take the
  gates when ready).
- Lane 6 is package/engine work (`StrandAnalytics`, `WhoopStore`,
  `IntelligenceEngine`) — zero overlap with the UI lanes until the integration slot.
- The SLEEP INTEGRATION SLOT is the only serialized stretch: `SleepView`,
  `SmartAlarmView`, `WindDownNudge`, `MetricCatalog`, `TodayView`, `CoupledView`
  are touched by both Kit 47 and Sleep V2 phase G — one lane does both at once so
  those files are edited exactly once.

## Technical context

- This repo, current `main`. Kits ≤41 are already adopted (spec 011 + later
  commits: Strain V2, flat surfaces, Devices, Widgets & Live).
- Lab: `projects/noop-design-lab/NOOPDesignLab/` — the six kit files are
  fixture-only. Read each fully before porting; their headers document intent.
- Spec 011 established the promotion pipeline (promote to StrandDesign → lab
  consumes production component → adopt in app). Reuse it.
- Sleep V2 foundation: PR #6 (`agent/sleep-performance-v2-foundation`) adds
  `SleepNeedV2.swift`, `SleepPerformanceV2.swift` + 15 passing tests + the plan doc
  `docs/superpowers/plans/2026-07-20-sleep-performance-v2.md`. Merge PR #6 into the
  working branch first — it is additive-only and changes no production behavior.

## Promotion rules (all kits)

1. **Fixture state → bindings.** Lab `@State` seeds (`initiallyOn`,
   `initialAnswer`, frozen constants) become `Binding`/display-model + action
   closures in the promoted API. Fixture initializers stay lab-side.
2. **No fixture time.** `SleepAlarmClock.now` (frozen 9:26 PM) and hardcoded series
   never ship.
3. **Config over screens.** Kits 42/43 are config-driven (`MetricDetailConfig`,
   `SettingsSectionModel`). Adapting a surface = writing config/adapters in the app
   target, not editing the component.
4. **Dedupe.** `PaperToastCard` merges with the existing `PaperToast.swift`;
   `MetricDetailTemplate` reuses the production `TrendPanelChart`. One
   implementation each.
5. **`OverlayStage` is lab staging chrome — never port it.** Production uses real
   `.sheet` + detents and existing overlay hosting.
6. Localize new strings in the existing xcstrings catalogs. `StrandHaptic` on
   meaningful events only. Honor Reduce Motion.

## Lane 1 — Kit 46, Sheets & Alerts

Promote `PaperSheetCard`, `ConfirmGateCard`, `HoldToConfirmButton`,
`DestructiveGateCard`, `SuccessFlashCard`; merge `PaperToastCard` into
`PaperToast`. Wire gates into real destructive flows (clear data, delete imports,
remove device, delete journal item) preserving each flow's exact effect. Migrate
existing toast call sites (`WorkoutsView`, `SleepView`, `BackupSyncView`,
`DataSourcesView`) with zero behavior change; Undo only where reversible today.

## Lane 2 — Kit 43, Settings (highest tool-loss risk)

`SettingsView.swift` is ~2,850 lines of real tools. First produce a row-by-row
inventory of EVERY interactive control in SettingsView + sub-screens
(Notifications, Data Sources, Backup & Sync, Storage, Automations,
Siri/Shortcuts, …) mapped to the seven `SettingsRowModel` cases. This inventory is
the ONE formal parity artifact of the spec — diff it once after adoption; zero
losses.

- Fitting rows: rebuild via `SettingsSectionModel` + `SettingsScreenTemplate`
  bound to real stores (`BehaviorStore`, `NotificationSettingsStore`,
  `KeyMetricPrefs`, profile, units…). Segmented rows pick inline with paper chips,
  never the system menu.
- Non-fitting rows: add a `custom(id:view:)` case and host the existing view
  inside a `SettingsSectionCard`. Never delete a row because the grammar lacks a
  shape.
- Destructive rows: visually quarantined, routed through Lane 1 gates.
- `SettingsProfileHeader` binds real profile; footer shows the real bundle
  version. Sub-screens can be parallelized across subagents; root screen last.

## Lane 3 — Kit 42 Metric Detail + Kit 45 Compare

**Metric Detail:** one `MetricDetailConfig` adapter per metric over
`MetricCatalog` + `repo.resolvedSeries`. Preserve the sparse-metric window rule
documented at the top of `MetricExplorerView.swift` (window relative to latest
point; expand only on zero points; hero shows latest + "as of"). Typical-range
rail binds to an existing baseline/typical computation or is omitted via config —
never invented. Keep every existing dossier tool (W/M/3M/6M/1Y/ALL control,
insight cards, annotations, exports) via optional config sections. Same
`TrendPanelChart` instance as Trends V2. When Sleep V2's component series land in
`MetricCatalog` (phase G5), they flow through the same adapter — coordinate the
descriptor list with Lane 6, but don't block on it.

**Compare:** adopt the lab A/B pair experience (`ComparePickerRow` slots select
from the full catalog via the existing picker, swap trades axes, `CompareDualChart`
renders real dated series, `CompareCorrelationCard` binds
`CorrelationEngine.pearson` with real n and today's windowed-aggregate pairing).
Capability rule: 3–4-metric compare stays — pair view primary, existing normalized
overlay (restyled surfaces only) for >2. Keep the range control and UTC
day-parsing. `CompareLagChips` only if a real lag computation exists; otherwise
defer.

## Lane 4 — Kit 44, Journal & Check-ins

Re-skin `JournalLogCard` rows with `JournalHabitToggle` / `JournalQuantityRow` /
`JournalMoodRow`, preserving exactly: tri-state (tap-again clears), writes under
`Repository.journalDeviceId` only, wake-day attribution, imported-question
adoption, and the full #322 edit mode (groups, rename/regroup/convert/reorder).
`JournalMoodRow` → `MoodStore`. `JournalImpactCard` adopts the InsightsView
behaviour-effect cards bound to the existing with/without model with real n and
significance. `JournalStreakStrip` from real logged history.

## Lane 5 — Widget sizing fix (kit 41 follow-up)

Symptom: the small recovery widget renders content in a reduced block with a dead
band of empty container (see owner screenshot). Fix in
`Packages/StrandDesign/Sources/StrandDesign/WidgetLiveComponents.swift`
(`NOOPRecoverySmallWidgetView` and siblings), host
`StrandiOSWidgets/NOOPWidget.swift`. Likely causes, in order:

- Manual `.padding(13)` stacked on top of the system content margins applied with
  `.containerBackground(for: .widget)` — drop or shrink the manual padding, or use
  `.contentMarginsDisabled()` deliberately with own margins; don't double-pad.
- Root layout not expanding: give the content `frame(maxWidth:.infinity,
  maxHeight:.infinity)` so header/ring/footer distribute across the full
  container in each family.
- Lab-canvas-tuned fixed type/offsets (9pt title, 8pt footer, `offset(y: 4)`):
  scale ring stroke and score type from available geometry per family instead.

Check medium/large and lock-screen accessories for the same double-padding while
in there. Verify in WidgetKit previews + the add-widget gallery + on device.

## Lane 6 — Sleep Performance V2 (engine work)

Merge PR #6, then execute
`docs/superpowers/plans/2026-07-20-sleep-performance-v2.md` work units 1–7 in
order (foundation QA, `SleepNightSummary`, `SleepStressV1`, chronological
`SleepScoringContextBuilder`, shadow persistence, Recovery exactness behind the
flag, freshness/provenance). That doc's hard invariants are merge blockers; its
constants are the approved contract — no silent coefficient changes. Everything
runs in **shadow mode** (`SleepPerformanceV2Prefs`: off/shadow/on), so this lane
never blocks UI shipping. Units 1–4 are package-only and safe to parallelize with
all UI lanes; units 5–7 touch `IntelligenceEngine`/`Repository`/`WhoopStore` —
still disjoint from the UI lanes.

### Lane 6 conditional alarm expansion

Build a real evaluator and actuation service before the Sleep Integration Slot.
`Sleep goal` uses canonical `SleepNeedV2` plus current persisted/banked sleep.
`In the green` reuses `RecoveryForecaster`; the early-wake condition is met only
when the forecast's lower confidence bound crosses the existing green threshold.
Never use yesterday's final Recovery as a proxy.

Persist mode, window, evaluated-at time, source/model version, input freshness,
condition result, BLE connection state, requested strap time, readback time, and
failure reason. Pre-arm the latest window endpoint first. At foreground, bond or
restoration, repository refresh/analyze completion, and best-effort BG refresh,
re-evaluate and move the fixed firmware alarm earlier only through an encrypted
live BLE session. Confirmed WHOOP 4 readback is authoritative; WHOOP 5/MG remains
explicitly experimental until its fire/readback path is proven. The UI must not
promise guaranteed adaptive early wake under iOS background scheduling.

## SLEEP INTEGRATION SLOT — Kit 47 + Sleep V2 phase G (one lane, after Lanes 1 & 6)

One lane edits the sleep surfaces exactly once, combining Kit 47 adoption with
Sleep V2's UI/copy phase (plan doc G1–G7, work units 8–9):

- `SleepAlarmModuleCard` becomes the Alarms-screen + Sleep-page module, adapted
  honestly: arming = strap silent alarm (`BehaviorStore.smartAlarmEnabled` +
  BLE arm/disarm via `AppModel`); "Exact time" arms at the set time; smart modes
  ("Sleep goal", "In the green") compute the wake window from the **canonical
  dynamic Sleep Need** (`SleepNeedV2` via the context builder — not the old
  `sleepNeedMin`, not a separate 8h default) and recovery state, with truthful
  disabled states when inputs are missing. Frozen lab clock → real clock;
  "be asleep by" recomputes live.
- `SleepNeedBreakdownCard` IS the UI for V2's need breakdown: baseline + Effort
  addition + debt repayment − nap credit, from `ScoredSleepDay`/persisted
  components (plan doc G2). No second need math.
- `SleepPlanTimeline` renders tonight's real plan (now → asleep-by → wake window).
- `WindDownNudge` planning reads canonical need (plan doc G6); per-day overrides
  (PR#554) stay reachable under the module; honesty card stays.
- Same pass applies the canonical `SleepScoreExplanation` copy to `SleepView`,
  `TodayView`, `CoupledView`, `MetricCatalog` per plan doc G2–G5, with V1 wording
  still shown while the flag is off/shadow (copy switches with the flag, or is
  written flag-aware — follow the plan doc).

Authority flip (work unit 10) is a separate final commit gated by the plan doc's
own release gates; it may land after this spec ships.

## Verification (deliberately light)

- Per merged unit: `xcodegen` + package tests + NOOPiOS/widgets/watch/macOS
  targets compile. That's it — no per-lane screenshot gates.
- Focused unit tests only where behavior is subtle: sparse-window adapter, journal
  write path, Pearson parity, gate hold timing, alarm need recompute. Sleep V2
  keeps its own test suites per the plan doc.
- One formal parity artifact: the Settings tool inventory, diffed once. Other
  lanes carry their preserve-lists inside their task descriptions.
- Final consolidated QA: one pass over the six surfaces + widget on iPhone
  (light/dark, Dynamic Type XL, Reduce Motion), screenshots to
  `outputs/<date>/qa/012-adoption/`, in-place device install, route spot-check.
