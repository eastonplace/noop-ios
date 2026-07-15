# Spec 008 — Design Lab Adoption (NOOP Paper Reskin)

> **Visual and interaction authority:** the approved NOOP Design Lab
> (`projects/noop-design-lab`, registry `ComponentScopeCatalog.swift`, categories scoped
> `shared` and `noop`) supersedes ad-hoc per-screen component implementations for the
> surfaces named below. Existing rulings remain binding: the Paper palette and strain
> accent (`StrandPalette`), strain scale/terminology, data-honesty (no fabricated
> values), accessibility floors, and the spec-004 workout journey contract are unchanged.
> Lab **fixture data never ships**; every adopted component binds to the real engine or
> repository source named in this spec, or renders its honest empty state.

## Goal

Converge the Paper-reskin app onto the lab-approved component grammar: promote the
lab-validated atoms and micro-components into `StrandDesign` (or confirm parity where an
equivalent already exists), replace duplicated ad-hoc implementations across screens with
the canonical versions, adopt the lab's micro-detailed Sleep and Stress decompositions
and motion standards, and prove every adoption with simulator evidence. No engine,
scoring, persistence-schema, or navigation-topology change.

## User Stories

### US1 — One canonical atom layer (P1)

As a user, every status pill, badge, value token, progress-dot strip, segmented control,
search field, and icon button looks and behaves identically on every screen, including
press feedback, selection motion, and VoiceOver semantics.

**Acceptance scenarios**

1. The segmented range/mode selectors on Trends, Stress, and Sleep use one control with
   the sliding matched-geometry thumb and selection haptic from the lab.
2. Status pills on Today, Live, Devices, and Backup share one component; pulsing is
   present only for genuinely live states and is disabled under Reduce Motion.
3. Search fields on Explore/Workouts surfaces share one component with identical clear
   affordance and focus behavior.
4. No screen hand-rolls a chip/badge/token that duplicates a promoted atom; a repo-wide
   audit lists zero remaining duplicates for converged families.

### US2 — Micro-detailed Sleep surface (P1)

As a user on the Sleep screen, the night decomposes into legible micro-detail — stage
timeline coupled to tappable stage rows, window strip, stages-vs-typical, sparkline
tiles, and the debt ledger — with the lab's selection and reveal motion.

**Acceptance scenarios**

1. Tapping a stage breakdown row highlights that stage on the hypnogram and recedes the
   others; tapping again clears it (existing `selectedStage` behavior, lab motion).
2. Stage rows render the pip-rail grammar (swatch, uppercase stage, colored share %,
   segmented rail, right-aligned duration) via the canonical `PipBar`.
3. The debt ledger's diverging bars stagger in on first appearance and freeze under
   Reduce Motion; values remain the memoized `SleepModel` outputs, never re-derived in
   view code.
4. A night with no stage timeline, no HR buckets, or zero ledger nights renders the
   existing honest empty copy, restyled only.

### US3 — Micro-detailed Stress surface (P1)

As a user on the Stress screen and Today's stress card, the day reads hour by hour:
load line with peak annotation, band legend, time-in-band split, hourly strip, and
vs-baseline tiles with direction-aware deltas.

**Acceptance scenarios**

1. The daytime load line draws on with the lab reveal (trim), shows band guides at 1.0
   and 2.0, and annotates the true peak hour from `DaytimeStress.Result` — never a
   hardcoded peak.
2. Time-in-band rows render Calm/Moderate/High with durations from `StressTotals` on
   the canonical pip rail; a day with zero scored hours renders empty rails.
3. Resting HR and HRV tiles tint their deltas by stress direction exactly as
   `markerTile` does today (increase-is-stress vs decrease-is-stress preserved).
4. The sustained-high breathe nudge appears only when `day.sustainedHigh` is true and
   routes to the existing Breathe trainer.

### US4 — Transient feedback and states (P2)

As a user, save/undo/import actions confirm with one toast grammar; loading, empty,
live-vital, and offline states share the lab-verified presentations.

**Acceptance scenarios**

1. A canonical `PaperToast` presents low, waits ~2.4 s, exits without ceremony, keeps
   its action reachable for the full dwell, and announces via VoiceOver.
2. The Sleep delete-undo banner and Backup/Data-source operation confirmations adopt
   the toast/operation grammar without changing their engine semantics or undo windows.
3. Skeleton, empty-state, and live-vital (waiting/live/stale/offline) presentations
   match the lab specimens and are driven only by real `LiveState`/repository state.

### US5 — Trends and navigation refinements (P2)

As a user, multiseries trends gain per-metric summary rows (dot, name, sparkline,
latest value, signed delta), and day navigation/headers use the lab's numeric
continuity motion.

**Acceptance scenarios**

1. Trends overview lists one summary row per active series, values from the same
   `TrendPoint` series the chart renders — no second derivation.
2. The day navigator animates date changes with `contentTransition(.numericText)` and
   disables the forward chevron at today.
3. Tab crossfade, quick-action sheet, and More-tab behavior are unchanged.

## Functional Requirements

### Canonical atoms (StrandDesign promotions)

- **FR-001** `StrandDesign` MUST gain the lab atoms that have no package equivalent:
  `ValueToken` (labeled monospaced value chip), `MicroBadge`, `MicroStatusDot`,
  `ProgressDots`, `MicroIconButton`, `PaperSearchField`, and `PaperToast`, with the
  lab's metrics, Reduce Motion behavior, and accessibility semantics.
- **FR-002** Where a package equivalent exists, the lab component MUST NOT be
  duplicated; instead the equivalent is upgraded in place: `SegmentedPillControl` gains
  the sliding matched-geometry thumb + `sensoryFeedback(.selection…)`; `StatePill` /
  `StatusBadge` gain the lab's pulse-overlay option; `PipBar` remains the single
  segmented-rail implementation.
- **FR-003** Promoted components MUST be visual-only (no engine or repository access),
  previewable with `#Preview`, and localized-string-ready. Stateful composition stays
  in the app target (same boundary as spec 004).
- **FR-004** Every converged family MUST end with zero remaining ad-hoc duplicates in
  `Strand/Screens` and `StrandiOS`; the audit list in `research.md` is the checklist.

### Sleep (SleepView, engine untouched)

- **FR-005** Stage breakdown rows MUST keep `selectedStage` coupling and data
  (`Stages` totals over time-in-bed) and adopt lab row metrics and motion
  (`StrandMotion` mapping per research.md). The pip rail MUST be `PipBar`.
- **FR-006** The paper stage card MUST keep the existing `Hypnogram` (intervals,
  smoothing, hover) — the lab's fixture hypnogram is NOT ported; only its dim-others
  selection treatment is added, driven by the same `selectedStage`.
- **FR-007** The sleep window strip, stages-vs-typical rows (LiquidTube value +
  DiagonalHatch typical + mean marker), metric tile grid (StatTile sparkline +
  vs-typical captions), and debt ledger MUST remain bound to the memoized `SleepModel`
  fields they read today; adoption changes presentation metrics/motion only.
- **FR-008** Debt-ledger delta bars MUST gain the lab's staggered reveal
  (per-bar delay ≤ 0.02 s × index) with a Reduce Motion static fallback.

### Stress (StressView, TodayView card, engine untouched)

- **FR-009** The daytime section MUST adopt: draw-on line reveal, dashed band guides at
  1.0/2.0, peak marker dot + "PEAK x.x · <hour>" annotation from `day.peak`, hour
  ruler, and the 0–1/1–2/2–3 band legend. Data stays `DaytimeStress.Result.hours`.
- **FR-010** `StressTotalsBar` MUST render Calm/Moderate/High on the canonical pip rail
  (replacing per-band LiquidTube fill) with durations from `StressTotals`; zero scored
  hours renders empty rails, not fabricated fill.
- **FR-011** Today's pinned stress card MUST keep `StressTimelineBar` hourly strip and
  its calibrating placeholder behavior (`#706/#684`); the strip gains the lab's
  band-opacity treatment only.
- **FR-012** Marker tiles MUST keep `markerTile` delta semantics (±0.5 threshold,
  direction-aware tint, "at baseline" fallback) unchanged.

### States and transient feedback

- **FR-013** `PaperToast` MUST support: message, optional action (kept tappable for the
  full dwell), 2.4 s auto-dismiss, cancellation on disappear, Reduce Motion fade, and
  `.accessibilityAddTraits(.updatesFrequently)` plus a VoiceOver announcement.
- **FR-014** The Sleep undo banner MUST migrate to the toast grammar without shortening
  the existing undo window or changing `presentSleepUndo`/`undoSleepDelete` semantics.
- **FR-015** Backup/import operation cards (BackupSyncView, data sources) MUST keep the
  idle/running/success/failure/retry state machine and adopt the lab operation-card
  presentation; failure copy remains the existing honest strings.
- **FR-016** Live-vital presentation (LiveView) MUST map waiting/live/stale/offline to
  the lab StatusPill treatment driven by real `LiveState`; no synthetic state.

### Trends, navigation, shared micros

- **FR-017** TrendsView overview MUST add per-series summary rows (dot, localized name,
  ≤ 7-point sparkline, latest value, signed delta vs prior period) computed from the
  exact `TrendPoint` series already charted.
- **FR-018** The day navigator MUST adopt numeric-continuity motion and disabled-at-today
  forward chevron without changing the date cursor logic or reload behavior.
- **FR-019** Screens listed in the shared-micros audit MUST replace hand-rolled chips,
  badges, tokens, and progress dots with the promoted atoms, preserving each screen's
  strings and data bindings.
- **FR-020** All new strings MUST be localized; all touched controls MUST pass XL
  Dynamic Type, VoiceOver labels/traits, dark mode, and Reduce Motion checks.

### Boundaries

- **FR-021** No change to: Repository schema, GRDB tables, scoring engines
  (`SleepModel`, `StressModel`, `DaytimeStress`, strain/recovery math), BLE/HealthKit
  paths, widget/Live Activity payloads, macOS shell, or the spec-004 workout
  coordinator contract.
- **FR-022** No lab fixture value, fixture series, or fixture asset ships. The lab app
  itself is not a dependency; code is ported, not imported.
- **FR-023** The `noop-design-lab` project is read-only for this spec except for a
  final parity note in its `component-coverage.md` recording what was adopted.

## Screen-by-Screen Mapping (authoritative)

| Lab category (ordinal) | Product surface(s) | Navigation route | State owner | Engine / data source |
|---|---|---|---|---|
| Navigation (1) | `ScreenScaffold` headers, `DayNavBar`, `PaperTabBar` | `RootTabView` tabs 0–3 | shell `@State selectedTab`, per-screen date cursor | `Repository.days` day keys |
| Surfaces (2) | `NoteCard` sites, expandable More groups, quick-action sheet, confirmations | `RootTabView` `QuickAction`, sheet routes | screen-local | n/a (presentation) |
| Ranges (3) | Recovery detail contributors, `TypicalRangeBar/Row` sites | `CoupledView`, Sleep/Stress captions | view-local | 30-day typicals from `Repository.days` |
| Trends (4) | `TrendsView`, `TrendsReportView` | tab 1; NavRouter `.trends` | `TrendChart` selection state | `exploreSeries` → `TrendPoint` |
| Sleep (5) | `SleepView` S3 paper stack | tab 2 | `SleepView` `@State` + memoized `SleepModel` | `repo.sleeps`, `CachedSleepSession`, intervals, `HRBucket`, `SleepDebtLedger` |
| Stress (6) | `StressView`, `StressCheckInCard`, Today stress card | Today card → `paperPillarDetail = .stress` | `StressModel` cache key, `DaytimeStress.Result` | `repo.series("stress", "my-whoop")`, `repo.days` RHR/HRV baselines |
| Workout (7) | `WorkoutsView` rows, `WorkoutDetailView` zones/splits/route | Workouts route; spec-004 coordinator | `AppModel` + detail view state | workout repository, route store, captured sessions |
| Journal (8) | journal questions/associations surfaces, `StressCheckInCard` | Insights hub routes | journal engine state | journal tables via `Repository` |
| Coaching (9) | coaching/experiment cards in Insights hub | `NavRouter .insightsHub` | hub view state | coaching engine outputs |
| Devices (10) | `DevicesView`, `AddDeviceWizard`, `XiaomiBandView` | NavRouter `.devices` sheet | `BLEManager`/`SourceCoordinator` | `LiveState` connectivity + battery |
| Settings (11) | `SettingsView`, More groups | More tab | `@AppStorage`, `NotificationSettingsStore` | settings stores |
| States (12) | skeletons/empty/live-vital/offline + new toast | cross-screen | screen-local + `LiveState` | real load/empty/connectivity state |
| Utilities (13) | `BreathingView`, `SmartAlarmView`, `RhythmView` | quick action `.breathe`, More | `BiofeedbackController` | biofeedback prefs, HR stream |
| Onboarding (14) | `TermsGateView`, wizard progress | first-run + Devices | wizard step state | terms/consent flags |
| Shared micros (24) | cross-screen chip/token/dot convergence | n/a | n/a | n/a (presentation) |

Lab categories 15–23 and 25–27 are `lift`-scoped and are **out of scope here** (see the
separate Lift package `projects/lifting/specs/008-design-lab-alignment/`).

## Key Entities

- **Promoted atom:** a StrandDesign view ported from the lab with a contract in
  `contracts/component-contracts.md`.
- **Upgraded equivalent:** an existing StrandDesign view gaining lab behavior in place.
- **Adoption site:** a screen location listed in the mapping table where an ad-hoc
  implementation is replaced.
- **Convergence audit row:** file/line of a duplicate slated for replacement, tracked
  to zero.

## Edge Cases and Failure States

- Sleep: no stage intervals; naps only; low-confidence staging note; zero ledger
  nights; missing resting HR; WHOOP-imported vs on-device score sources.
- Stress: calibrating (no baseline) placeholder on Today; zero scored hours; missing
  HRV/RHR day; sustained-high false at exactly the threshold boundary.
- Toast: action tapped at dismissal instant (action wins; dismissal cancels); toast
  triggered twice (restart dwell, no stacking); screen dismissed mid-dwell (task
  cancelled).
- Live vitals: BLE source flapping between stale/live must not strobe the pulse
  animation (state changes debounce at the existing `LiveState` cadence).
- Reduce Motion active: every reveal/stagger/pulse renders its static fallback.
- Dynamic Type XL: value columns never truncate; rows wrap detail text instead.
- Dark mode: all promoted atoms render from `StrandPalette` tokens only.

## Success Criteria

- **SC-001** Zero remaining duplicates for converged families (audited list, grep
  evidence recorded in tasks.md).
- **SC-002** Sleep and Stress screenshot sets match the approved lab compositions for
  structure and motion states while showing only real fixture-seeded engine data.
- **SC-003** All touched screens pass the accessibility/theme matrix (XL type, dark,
  Reduce Motion, VoiceOver spot checks) with evidence.
- **SC-004** No diff outside the files named in plan.md's file strategy; engine and
  schema fingerprints unchanged (focused git diff review).
- **SC-005** iOS and macOS targets build; existing unit/UI suites pass; new
  component/UI tests pass.

## Assumptions and Boundaries

- iPhone is the adoption target; macOS compiles unchanged (shared screens keep working
  since promotions are additive and upgrades preserve API).
- Spec-004 evidence conventions (`outputs/<date>/…/qa/`) and the dirty-tree discipline
  apply.
- If specs 005–007 land concurrently, adoption sites they rewrite take the canonical
  atoms directly; the convergence audit is re-run before the final phase.
